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
#                      scroll, or text-overflow) with scroll size past client size.
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
  VERSION = 1
  REPORT = 'ux-lint.json'
  SETTLE_FRAMES = 15 # also lint half a second after each click, once a toast has landed

  class FindingsError < StandardError; end

  BROWSER_JS = <<~'JS'
    (() => {
      if (window.__cfUx) return;
      const CONTROL = 'button, a[href], input[type=submit], input[type=button], [role=button], [role=link], [role=tab], [role=menuitem], [role=switch], [role=checkbox]';
      const OVERLAY = '[role=status], [role=alert], [role=dialog], [aria-modal=true], [data-cf-overlay], [class~=toast], [class~=snackbar], [class~=sheet]';
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
        return parts.join(' > ');
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
      const accName = (el) => {
        const by = el.getAttribute('aria-labelledby');
        if (by) { const t = by.split(/\s+/).map((id) => { const n = document.getElementById(id); return n ? n.textContent : ''; }).join(' ').trim(); if (t) return t; }
        const direct = (el.getAttribute('aria-label') || el.getAttribute('title') || (el.tagName === 'INPUT' ? el.value : '') || '').trim();
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
          const shown = textRects(el).map((t) => t.text).join(' ');
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
        document.querySelectorAll('body *').forEach((el) => {
          if (/^(INPUT|TEXTAREA|SELECT|SCRIPT|STYLE|TEMPLATE)$/.test(el.tagName)) return;
          if (!Array.prototype.some.call(el.childNodes, (n) => n.nodeType === 3 && n.textContent.trim())) return;
          if (!visible(el) || allowed(el, 'clipped-text')) return;
          const cs = getComputedStyle(el);
          const clips = (v) => /hidden|clip|auto|scroll/.test(v);
          const x = el.scrollWidth > el.clientWidth + 1 && (clips(cs.overflowX) || cs.textOverflow !== 'clip');
          const y = el.scrollHeight > el.clientHeight + 1 && clips(cs.overflowY);
          if (x || y) out.push({ rule: 'clipped-text', target: sel(el), detail: 'text clipped ' + (x ? 'horizontally' : 'vertically') + ' ("' + el.textContent.trim().slice(0, 40) + '")' });
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
      const lint = (targets) => {
        const found = [...emptyControls(), ...occlusion(), ...clipped(), ...contradictions()];
        (targets || []).forEach(({ selector, x, y }) => {
          const el = document.querySelector(selector);
          if (el && !allowed(el, 'cursor-over-label') && overText(el, x, y)) found.push({ rule: 'cursor-over-label', target: selector, detail: 'cursor at ' + Math.round(x) + ',' + Math.round(y) + ' covers the label' });
        });
        return found;
      };
      const overlays = () => Array.prototype.filter.call(document.querySelectorAll(OVERLAY), visible).map(sel);
      window.__cfUx = { lint, aim, overlays };
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

  def scene_report(scene_id, raw, overlays: {})
    { 'version' => VERSION, 'scene' => scene_id, 'findings' => merge(raw), 'overlays' => overlays }
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
