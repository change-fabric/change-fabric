# frozen_string_literal: true

require 'json'
require 'fileutils'

# The free, deterministic UX lint that runs inside every cf:prototype capture.
# The browser half (BROWSER_JS) is evaluated into the page; it only reads
# layout, so a clean screen's frames and frame keys are unchanged. It checks,
# at the frames `lint_frames` picks (scene start, middle, end, every scripted
# step, and the frame any toast or sheet first appears):
#
#   empty-control      a control, status, toast, or sheet with no accessible
#                      name, or no rendered text (non-empty, visible, non-zero
#                      size, not transparent, not masked). A small (<= 64px)
#                      icon button with an aria-label or title is allowed.
#   occlusion          elementFromPoint at a visible control's centre or inset
#                      corners hits something outside it. A control inside an
#                      `inert` or `aria-hidden="true"` subtree is not checked,
#                      so a modal sheet marks the page behind it inert.
#   clipped-text       a text element that clips (overflow hidden, clip, auto,
#                      scroll, or text-overflow) with scroll size past client size,
#                      or text or a control partly cut off by an ancestor's
#                      non-visible overflow (a button sliced by the phone edge).
#   caption-safe       a visible control or device frame reaching into the
#                      bottom caption band (CAPTION_BAND of the viewport height),
#                      where players draw cues.
#   device-frame       a device frame ([data-cf-device], .phone, .device) whose
#                      layout size, aspect ratio, or rendered size differs from
#                      the first scene's. Only a scene declaring `camera.zoom`
#                      may change the rendered size, and only up to that factor
#                      (see device_findings). Shape and layout never change.
#   cursor-over-label  the cursor sprite's footprint at its aimed point covers
#                      the target's label text. `aim` picks the centre when it
#                      is clear, else the label's end padding, the bottom
#                      padding, or the icon, so the capture itself avoids it.
#   contradictory-state  data-attribute driven: a visible [data-cf-success]
#                      whose scope (nearest [data-cf-state] ancestor, or the
#                      element named by data-cf-for) is "pending", or a visible
#                      [data-cf-when] that does not list its scope's state.
#
# `data-ux-allow="<rule> ..."` on an element or ancestor opts it out of a rule.
module PrototypeUxLint
  VERSION = 2
  REPORT = 'ux-lint.json'
  SETTLE_FRAMES = 15 # also lint half a second after each click, once a toast has landed
  # Players draw a two-line cue in roughly the bottom tenth of the frame; the
  # band adds a margin above it.
  CAPTION_BAND = 0.15
  DEVICE_TOLERANCE = 0.01

  class FindingsError < StandardError; end

  BROWSER_JS = <<~'JS'
    (() => {
      if (window.__cfUx) return;
      const CONTROL = 'button, a[href], input[type=submit], input[type=button], [role=button], [role=link], [role=tab], [role=menuitem], [role=switch], [role=checkbox]';
      const OVERLAY = '[role=status], [role=alert], [role=dialog], [aria-modal=true], [data-cf-overlay], [class~=toast], [class~=snackbar], [class~=sheet]';
      const DEVICE = '[data-cf-device], [class~=phone], [class~=device]';
      const FOOT = { w: 12, h: 18 };
      const allowed = (el, rule) => { const a = el.closest('[data-ux-allow]'); return !!a && a.getAttribute('data-ux-allow').split(/\s+/).includes(rule); };
      const alpha = (c) => {
        if (!c || c === 'transparent') return 0;
        const slash = c.match(/\/\s*([\d.]+)(%?)/);
        if (slash) return parseFloat(slash[1]) / (slash[2] ? 100 : 1);
        const m = c.match(/rgba\(([^)]+)\)/);
        if (m) return parseFloat(m[1].split(',')[3]);
        return 1;
      };
      const inViewport = (r) => r.right > 0 && r.bottom > 0 && r.left < innerWidth && r.top < innerHeight;
      const visible = (el) => {
        if (!el || !el.isConnected) return false;
        const r = el.getBoundingClientRect();
        if (r.width < 1 || r.height < 1 || !inViewport(r)) return false;
        if (getComputedStyle(el).visibility !== 'visible') return false;
        for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
          const cs = getComputedStyle(n);
          if (cs.display === 'none' || parseFloat(cs.opacity) < 0.05) return false;
        }
        return true;
      };
      const masked = (el) => { for (let n = el; n && n.nodeType === 1; n = n.parentElement) { const cs = getComputedStyle(n); const m = cs.webkitMaskImage || cs.maskImage; if (m && m !== 'none') return true; } return false; };
      const sel = (el) => {
        if (el.id) return '#' + el.id;
        const parts = [];
        for (let n = el; n && n.nodeType === 1 && n !== document.body; n = n.parentElement) {
          if (n.id) { parts.unshift('#' + n.id); break; }
          const sib = Array.prototype.filter.call(n.parentElement.children, (c) => c.tagName === n.tagName);
          parts.unshift(n.tagName.toLowerCase() + (sib.length > 1 ? ':nth-of-type(' + (sib.indexOf(n) + 1) + ')' : ''));
        }
        return parts.join(' > ') || el.tagName.toLowerCase();
      };
      const textRects = (el) => {
        const out = [];
        const box = el.getBoundingClientRect();
        const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!node.textContent.trim()) continue;
          const p = node.parentElement;
          if (!visible(p) || masked(p)) continue;
          const cs = getComputedStyle(p);
          if (parseFloat(cs.fontSize) <= 0 || alpha(cs.color) < 0.05 || alpha(cs.webkitTextFillColor || cs.color) < 0.05) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          for (const r of range.getClientRects()) {
            if (r.width >= 1 && r.height >= 1 && r.right > box.left && r.left < box.right && r.bottom > box.top && r.top < box.bottom) out.push({ r, text: node.textContent.trim() });
          }
        }
        return out;
      };
      // An input button paints its label natively, with no text node to walk.
      const inputLabel = (el) => {
        if (el.tagName !== 'INPUT') return '';
        const t = (el.getAttribute('type') || '').toLowerCase();
        if (!/^(submit|button|reset)$/.test(t)) return '';
        return el.value.trim() || ({ submit: 'Submit', reset: 'Reset' }[t] || '');
      };
      const shownInputLabel = (el) => {
        const cs = getComputedStyle(el);
        return parseFloat(cs.fontSize) > 0 && alpha(cs.color) >= 0.05 && alpha(cs.webkitTextFillColor || cs.color) >= 0.05 && !masked(el) ? inputLabel(el) : '';
      };
      const accName = (el) => {
        const by = el.getAttribute('aria-labelledby');
        if (by) { const t = by.split(/\s+/).map((id) => { const n = document.getElementById(id); return n ? n.textContent : ''; }).join(' ').trim(); if (t) return t; }
        const direct = (el.getAttribute('aria-label') || el.getAttribute('title') || inputLabel(el) || '').trim();
        if (direct) return direct;
        const alt = Array.prototype.map.call(el.querySelectorAll('img[alt]'), (i) => i.alt).join(' ').trim();
        return (el.textContent.trim() || alt);
      };
      const interactive = (el) => !el.closest('[inert], [aria-hidden="true"]');
      const emptyControls = () => {
        const out = [];
        const seen = new Set();
        document.querySelectorAll(CONTROL + ', ' + OVERLAY).forEach((el) => {
          if (seen.has(el) || !visible(el) || allowed(el, 'empty-control')) return;
          seen.add(el);
          const overlay = el.matches(OVERLAY);
          const name = accName(el);
          const shown = shownInputLabel(el) || textRects(el).map((t) => t.text).join(' ');
          const r = el.getBoundingClientRect();
          const iconButton = !overlay && (el.hasAttribute('aria-label') || el.hasAttribute('title') || el.hasAttribute('aria-labelledby')) && r.width <= 64 && r.height <= 64;
          if (!name) out.push({ rule: 'empty-control', target: sel(el), detail: (overlay ? 'overlay' : 'control') + ' has no accessible name' });
          else if (!shown && !iconButton) out.push({ rule: 'empty-control', target: sel(el), detail: (overlay ? 'overlay' : 'control') + ' renders no visible text (name "' + name.slice(0, 60) + '")' });
        });
        return out;
      };
      const occlusion = () => {
        const out = [];
        document.querySelectorAll(CONTROL).forEach((el) => {
          if (!visible(el) || !interactive(el) || allowed(el, 'occlusion')) return;
          const r = el.getBoundingClientRect();
          const i = Math.min(4, r.width / 4, r.height / 4);
          const pts = [[r.left + r.width / 2, r.top + r.height / 2], [r.left + i, r.top + i], [r.right - i, r.top + i], [r.left + i, r.bottom - i], [r.right - i, r.bottom - i]];
          for (const [x, y] of pts) {
            if (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) continue;
            const hit = document.elementFromPoint(x, y);
            if (!hit || el.contains(hit) || hit.contains(el)) continue;
            out.push({ rule: 'occlusion', target: sel(el), detail: 'covered by ' + sel(hit) + ' at ' + Math.round(x) + ',' + Math.round(y) });
            break;
          }
        });
        return out;
      };
      const clipped = () => {
        const out = [];
        const flagged = new Set();
        document.querySelectorAll('body *').forEach((el) => {
          if (/^(INPUT|TEXTAREA|SELECT|SCRIPT|STYLE|TEMPLATE)$/.test(el.tagName)) return;
          if (!Array.prototype.some.call(el.childNodes, (n) => n.nodeType === 3 && n.textContent.trim())) return;
          if (!visible(el) || allowed(el, 'clipped-text')) return;
          const cs = getComputedStyle(el);
          const clips = (v) => /hidden|clip|auto|scroll/.test(v);
          const x = el.scrollWidth > el.clientWidth + 1 && (clips(cs.overflowX) || cs.textOverflow !== 'clip');
          const y = el.scrollHeight > el.clientHeight + 1 && clips(cs.overflowY);
          if (x || y) { out.push({ rule: 'clipped-text', target: sel(el), detail: 'text clipped ' + (x ? 'horizontally' : 'vertically') + ' ("' + el.textContent.trim().slice(0, 40) + '")' }); flagged.add(el); }
        });
        // Text or a control partly outside an ancestor that clips its overflow.
        // The padding box in viewport pixels: client sizes are layout pixels,
        // so scale them by the rendered/layout ratio of a transformed box.
        const clipBox = (n) => {
          const r = n.getBoundingClientRect();
          const sx = n.offsetWidth ? r.width / n.offsetWidth : 1;
          const sy = n.offsetHeight ? r.height / n.offsetHeight : 1;
          const left = r.left + n.clientLeft * sx;
          const top = r.top + n.clientTop * sy;
          return { left, top, right: left + n.clientWidth * sx, bottom: top + n.clientHeight * sy };
        };
        const partly = (r, b) => r.right > b.left && r.left < b.right && r.bottom > b.top && r.top < b.bottom && (r.left < b.left - 1 || r.top < b.top - 1 || r.right > b.right + 1 || r.bottom > b.bottom + 1);
        const cutBy = (el, rects) => {
          for (let a = el.parentElement; a && a !== document.documentElement; a = a.parentElement) {
            const cs = getComputedStyle(a);
            if (!/hidden|clip|auto|scroll/.test(cs.overflowX + ' ' + cs.overflowY)) continue;
            const b = clipBox(a);
            if (rects.some((r) => partly(r, b))) return a;
            // Wholly clipped away here, so no outer ancestor shows any of it.
            if (rects.every((r) => r.right <= b.left || r.left >= b.right || r.bottom <= b.top || r.top >= b.bottom)) return null;
          }
          return null;
        };
        document.querySelectorAll('body *').forEach((el) => {
          if (flagged.has(el) || /^(SCRIPT|STYLE|TEMPLATE)$/.test(el.tagName) || !visible(el) || allowed(el, 'clipped-text')) return;
          const control = el.matches(CONTROL);
          const own = Array.prototype.some.call(el.childNodes, (n) => n.nodeType === 3 && n.textContent.trim());
          if (!control && !own) return;
          const rects = control ? [el.getBoundingClientRect()] : textRects(el).map((t) => t.r);
          const a = rects.length && cutBy(el, rects);
          if (a) out.push({ rule: 'clipped-text', target: sel(el), detail: (control ? 'control' : 'text') + ' cut off by ' + sel(a) + ' ("' + el.textContent.trim().slice(0, 40) + '")' });
        });
        return out;
      };
      const devices = () => Array.prototype.filter.call(document.querySelectorAll(DEVICE), visible).map((el) => {
        const r = el.getBoundingClientRect();
        return { target: sel(el), w: Math.round(r.width * 10) / 10, h: Math.round(r.height * 10) / 10, lw: el.offsetWidth, lh: el.offsetHeight };
      });
      const captionSafe = (band) => {
        if (!band) return [];
        const top = innerHeight * (1 - band);
        const out = [];
        document.querySelectorAll(CONTROL + ', ' + DEVICE).forEach((el) => {
          if (!visible(el) || allowed(el, 'caption-safe')) return;
          if (!el.matches(DEVICE) && !interactive(el)) return;
          const r = el.getBoundingClientRect();
          if (r.bottom > top + 1 && r.top < innerHeight) out.push({ rule: 'caption-safe', target: sel(el), detail: (el.matches(DEVICE) ? 'device frame' : 'control') + ' bottom ' + Math.round(r.bottom) + ' inside the caption band from ' + Math.round(top) });
        });
        return out;
      };
      const contradictions = () => {
        const out = [];
        const scopeOf = (el) => (el.getAttribute('data-cf-for') && document.getElementById(el.getAttribute('data-cf-for'))) || el.parentElement && el.parentElement.closest('[data-cf-state]');
        document.querySelectorAll('[data-cf-success]').forEach((el) => {
          const scope = scopeOf(el);
          if (scope && visible(el) && scope.getAttribute('data-cf-state') === 'pending') out.push({ rule: 'contradictory-state', target: sel(el), detail: 'success shown while ' + sel(scope) + ' is pending' });
        });
        document.querySelectorAll('[data-cf-when]').forEach((el) => {
          const scope = scopeOf(el);
          if (!scope || !visible(el)) return;
          const state = scope.getAttribute('data-cf-state');
          if (!el.getAttribute('data-cf-when').split(/\s+/).includes(state)) out.push({ rule: 'contradictory-state', target: sel(el), detail: 'shown for "' + el.getAttribute('data-cf-when') + '" while ' + sel(scope) + ' is "' + state + '"' });
        });
        return out;
      };
      const overText = (el, x, y) => textRects(el).some(({ r }) => x < r.right && x + FOOT.w > r.left && y < r.bottom && y + FOOT.h > r.top);
      // The point the cursor should rest on for `el`: its centre when the
      // sprite there clears the label, else a padding or icon point.
      const aim = (target) => {
        const el = typeof target === 'string' ? document.querySelector(target) : target;
        const r = el.getBoundingClientRect();
        const centre = { x: r.left + r.width / 2, y: r.top + r.height / 2 };
        if (!overText(el, centre.x, centre.y)) return centre;
        const texts = textRects(el).map((t) => t.r);
        const right = Math.max(...texts.map((t) => t.right));
        const bottom = Math.max(...texts.map((t) => t.bottom));
        const icon = el.querySelector('svg, img, [class~=i], [class*=icon]');
        const ib = icon && icon.getBoundingClientRect();
        const candidates = [
          { x: (right + r.right) / 2, y: centre.y },
          { x: centre.x, y: (bottom + r.bottom) / 2 },
          ib && { x: ib.left + ib.width / 2, y: ib.top + ib.height / 2 }
        ].filter((p) => p && p.x > r.left && p.x < r.right && p.y > r.top && p.y < r.bottom);
        return candidates.find((p) => !overText(el, p.x, p.y)) || centre;
      };
      const lint = (targets, band) => {
        const found = [...emptyControls(), ...occlusion(), ...clipped(), ...contradictions(), ...captionSafe(band)];
        (targets || []).forEach(({ selector, x, y }) => {
          const el = document.querySelector(selector);
          if (el && !allowed(el, 'cursor-over-label') && overText(el, x, y)) found.push({ rule: 'cursor-over-label', target: selector, detail: 'cursor at ' + Math.round(x) + ',' + Math.round(y) + ' covers the label' });
        });
        return found;
      };
      const overlays = () => Array.prototype.filter.call(document.querySelectorAll(OVERLAY), visible).map(sel);
      window.__cfUx = { lint, aim, overlays, devices };
    })();
  JS

  module_function

  # The frames (0-based) to lint: start, middle, end, every frame a step
  # lands on (a move's last frame, a hover, a click, a typed character), and
  # SETTLE_FRAMES after each click. Overlay first appearances are added live.
  def lint_frames(plan, frames)
    picks = [ 0, frames / 2, frames - 1 ]
    plan.each_with_index do |step, i|
      picks << i if step['click'] || step['hover'] || step['type'] || step.dig('move', 'p').to_f >= 1.0
      picks << i + SETTLE_FRAMES if step['click']
    end
    picks.select { |f| f >= 0 && f < frames }.uniq.sort
  end

  # Collapses repeats of the same rule on the same target across frames into
  # one finding with its first frame and a count.
  def merge(raw)
    raw.each_with_object({}) do |f, acc|
      key = [ f['rule'], f['target'], f['detail'].to_s.sub(/ at \d+,\d+\z/, '') ]
      if acc[key] then acc[key]['frames'] += 1
      else acc[key] = f.merge('frames' => 1)
      end
    end.values.sort_by { |f| [ f['frame'].to_i, f['rule'], f['target'] ] }
  end

  def scene_report(scene_id, raw, overlays: {}, devices: [])
    { 'version' => VERSION, 'scene' => scene_id, 'findings' => merge(raw), 'overlays' => overlays,
      'devices' => device_samples(devices) }
  end

  # One sample per distinct device measurement, keeping its first frame.
  def device_samples(raw)
    raw.uniq { |d| d.values_at('group', 'target', 'w', 'h', 'lw', 'lh') }
  end

  # The aim an existing (possibly stale) report was captured with, so a
  # lint-only pass over its frames aims the cursor the same way.
  def prior_aim(dir)
    path = File.join(dir, REPORT)
    aim = File.file?(path) ? JSON.parse(File.read(path))['aim'] : nil
    %w[safe centre].include?(aim) ? aim : 'centre'
  rescue JSON::ParserError
    'centre'
  end

  # device-frame findings across scene reports (in storyboard order). The
  # first device sample is the baseline: every later one must keep its layout
  # size and aspect ratio, and its rendered size, except that a scene whose
  # `zoom` (from camera.zoom) is set may render anywhere between the baseline
  # and baseline times that factor. Samples compare only within their group
  # (device and layout, such as "phone side_by_side"); a sample with no
  # group is "desktop single". Returns { scene_id => [finding] }.
  def device_findings(reports, zoom: {})
    bases = {}
    reports.to_h do |report|
      found = Array(report['devices']).filter_map do |d|
        base = bases[d['group'] || DEFAULT_GROUP] ||= d
        device_problem(d, base, zoom.fetch(report['scene'], 1.0).to_f)&.then do |detail|
          { 'frame' => d['frame'], 'rule' => 'device-frame', 'target' => d['target'], 'detail' => detail }
        end
      end
      [ report['scene'], merge(found) ]
    end
  end

  DEFAULT_GROUP = 'desktop single'

  def device_problem(dev, base, zoom)
    return "layout #{dev['lw']}x#{dev['lh']} differs from #{base['lw']}x#{base['lh']}" unless dev.values_at('lw', 'lh') == base.values_at('lw', 'lh')
    return "aspect #{ratio(dev).round(3)} differs from #{ratio(base).round(3)}" unless near?(ratio(dev), ratio(base))

    scale = dev['w'].to_f / base['w']
    lo, hi = [ 1.0, zoom ].minmax
    return nil if scale.between?(lo - DEVICE_TOLERANCE, hi + DEVICE_TOLERANCE)

    detail = "rendered #{dev['w']}x#{dev['h']} is #{scale.round(3)}x the first scene's #{base['w']}x#{base['h']}"
    zoom == 1.0 ? "#{detail}; declare camera.zoom for a size change" : "#{detail}, past camera.zoom #{zoom}"
  end

  def ratio(dev) = dev['w'].to_f / dev['h']
  def near?(a, b) = (a - b).abs <= b * DEVICE_TOLERANCE

  # Adds device-frame findings to each report (in place) and returns them.
  def with_device_findings(reports, zoom: {})
    found = device_findings(reports, zoom: zoom)
    reports.map { |r| r.merge('findings' => r['findings'] + found.fetch(r['scene'], [])) }
  end

  def write(dir, report)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, REPORT), "#{JSON.pretty_generate(report)}\n")
  end

  # A cached scene report, or nil when the frames predate this lint version.
  def read(dir)
    path = File.join(dir, REPORT)
    return nil unless File.file?(path)

    report = JSON.parse(File.read(path))
    report['version'] == VERSION ? report : nil
  end

  def total(reports) = reports.sum { |r| r['findings'].size }

  def summary_lines(reports)
    reports.flat_map do |r|
      r['findings'].map { |f| "#{r['scene']}: #{f['rule']} #{f['target']} (frame #{f['frame']}): #{f['detail']}" }
    end
  end

  # Raises when any finding is open, unless allowed.
  def gate!(reports, allow: false)
    n = total(reports)
    return if n.zero? || allow

    raise FindingsError, "#{n} UX lint finding(s) block --final (pass --allow-ux-findings to override):\n" \
                         "#{summary_lines(reports).join("\n")}"
  end
end
