# frozen_string_literal: true

require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require_relative 'browserless_js'
require_relative 'change_docker'
require_relative 'prototype_imagegen'
require_relative 'prototype_ux_lint'
require_relative 'walkthrough_cache'
require_relative 'walkthrough_environment'
require_relative 'walkthrough_browser_frame'

# Records a cf:prototype mock screen as a PNG frame sequence under a fixed,
# controlled clock, in the pinned browserless container and nowhere else.
# Time only moves when the capture loop advances it, animations are paused
# and seeked to virtual time, and input is real mouse and keyboard events, so
# the same inputs give the same frames. There is no screencast fallback:
# content the clock cannot control fails loudly instead.
module PrototypeCapture
  class UnsupportedContentError < StandardError; end

  FPS = 30
  BATCH_FRAMES = 90
  CAPTURE_VERSION = 1
  START_MS = 1_767_225_600_000 # 2026-01-01T00:00:00Z
  LOCALE = 'en-US'
  DEFAULT_VIEWPORT = { 'w' => 1920, 'h' => 1080, 'dpr' => 1 }.freeze
  OPS = %w[move click dblclick type key hover scroll wait].freeze
  # Key names a `key` op may press after any modifiers; a single printable
  # character is also accepted. Aliases normalize to Puppeteer key names.
  MODIFIERS = %w[Control Shift Alt Meta].freeze
  KEY_ALIASES = { 'Ctrl' => 'Control', 'Cmd' => 'Meta', 'Option' => 'Alt', 'Esc' => 'Escape', 'Return' => 'Enter',
                  'Del' => 'Delete', 'Space' => ' ' }.freeze
  NAMED_KEYS = (%w[Enter Escape Tab Backspace Delete Insert Home End PageUp PageDown
                   ArrowUp ArrowDown ArrowLeft ArrowRight] + (1..12).map { |n| "F#{n}" }).freeze
  UNSUPPORTED_TAGS = %w[video canvas iframe].freeze
  LOTTIE_MARKERS = [ /<lottie-player\b/i, /<dotlottie-player\b/i, /\blottie(?:\.min)?\.js\b/i, /\bbodymovin\b/i ].freeze
  ATTR_RE = /\b(src|href)\s*=\s*(["'])(.*?)\2/im
  SRCSET_RE = /\b(srcset|imagesrcset)\s*=\s*(["'])(.*?)\2/im
  MIME = { '.css' => 'text/css', '.js' => 'text/javascript', '.svg' => 'image/svg+xml', '.png' => 'image/png',
           '.jpg' => 'image/jpeg', '.jpeg' => 'image/jpeg', '.gif' => 'image/gif', '.webp' => 'image/webp',
           '.woff2' => 'font/woff2', '.woff' => 'font/woff', '.ttf' => 'font/ttf', '.otf' => 'font/otf',
           '.json' => 'application/json' }.freeze

  module_function

  # -- screen loading ------------------------------------------------------

  def check_supported!(html, label = 'screen')
    UNSUPPORTED_TAGS.each do |tag|
      raise UnsupportedContentError, "#{label}: <#{tag}> is not supported under the controlled clock" if html.match?(/<#{tag}\b/i)
    end
    LOTTIE_MARKERS.each do |re|
      raise UnsupportedContentError, "#{label}: Lottie content (#{re.source}) is not supported" if html.match?(re)
    end
    html.scan(ATTR_RE).each do |attr, _q, value|
      raise UnsupportedContentError, "#{label}: remote #{attr}=#{value} is not supported" if remote?(value)
    end
    html.scan(SRCSET_RE).each do |attr, _q, value|
      srcset_candidates(value).each do |url, _desc|
        raise UnsupportedContentError, "#{label}: remote #{attr} candidate #{url} is not supported" if remote?(url)
      end
    end
    true
  end

  def remote?(value) = value.strip.match?(%r{\A(?:https?:)?//}i)

  def local_ref?(value)
    v = value.strip
    !(v.empty? || v.start_with?('#', 'data:', 'about:', 'javascript:', 'mailto:') || remote?(v))
  end

  # Inlines a screen's local assets by string assembly: stylesheets and
  # scripts become inline elements, everything else a data URI. Only src, href,
  # and srcset/imagesrcset values are discovered; CSS is never parsed, though a local
  # url() reference inside an inlined stylesheet is swapped for a data URI.
  #
  # `remap` swaps draft image keys for final-quality ones in each local ref
  # before it is resolved, so a --final capture inlines the high-quality
  # image the screen's content-keyed cache path would otherwise miss.
  #
  # Every local ref must resolve inside `root` (default: the walkthrough
  # slug dir, the parent of a screens/ dir), so a screen cannot inline a
  # file from elsewhere on disk.
  def inline_screen(path, remap: {}, root: nil)
    dir = File.dirname(File.expand_path(path))
    root ||= default_root(dir)
    html = File.read(path)
    check_supported!(html, File.basename(path))
    html = html.gsub(%r{<link\b[^>]*\bhref\s*=\s*(["'])([^"']+\.css)\1[^>]*>}im) do
      href = Regexp.last_match(2)
      tag = Regexp.last_match(0)
      next tag unless local_ref?(href)

      media = tag[/\bmedia\s*=\s*(["'])([^"']*)\1/im, 2]
      media_attr = media && !media.strip.empty? && media.strip.casecmp('all') != 0 ? %( media="#{media}") : ''
      "<style#{media_attr}>#{inline_css(asset_path(dir, swap_keys(href, remap), root), remap, root)}</style>"
    end
    html = html.gsub(%r{<script\b([^>]*)\bsrc\s*=\s*(["'])([^"']+)\2([^>]*)>\s*</script>}im) do
      src = Regexp.last_match(3)
      next Regexp.last_match(0) unless local_ref?(src)

      attrs = (Regexp.last_match(1) + Regexp.last_match(4)).rstrip
      file = asset_path(dir, swap_keys(src, remap), root)
      # defer and async do nothing on an inline classic script, so a script
      # carrying either keeps a src (as a data URI) to keep its timing.
      next "<script#{attrs} src=\"#{data_uri(file)}\"></script>" if attrs.match?(/\b(?:defer|async)\b/i)

      "<script#{attrs}>#{File.read(file).gsub('</script', '<\/script')}</script>"
    end
    html = html.gsub(%r{(<style\b[^>]*>)(.*?)(</style>)}im) do
      open_tag, body, close_tag = Regexp.last_match.captures
      "#{open_tag}#{inline_css_urls(body, dir, 'style', remap, root)}#{close_tag}"
    end
    html = html.gsub(/(\sstyle\s*=\s*)(["'])(.*?)\2/im) do
      lead, quote, body = Regexp.last_match.captures
      inlined = inline_css_urls(body, dir, 'style', remap, root)
      inlined = inlined.gsub('"', "'") if quote == '"'
      "#{lead}#{quote}#{inlined}#{quote}"
    end
    html = html.gsub(SRCSET_RE) do
      attr, quote, value = Regexp.last_match.captures
      inlined = srcset_candidates(value).map do |url, desc|
        "#{local_ref?(url) ? ref_uri(dir, url, remap, root) : url}#{desc}"
      end
      "#{attr}=#{quote}#{inlined.join(', ')}#{quote}"
    end
    html.gsub(ATTR_RE) do
      attr, quote, value = Regexp.last_match.captures
      next Regexp.last_match(0) unless local_ref?(value) && !value.end_with?('.html')

      "#{attr}=#{quote}#{ref_uri(dir, value, remap, root)}#{quote}"
    end
  end

  # [url, descriptor] pairs of a srcset value. A data: candidate may itself
  # hold a comma, so a candidate starting with data: runs to the next
  # whitespace rather than the next comma.
  def srcset_candidates(value)
    value.scan(/\s*(data:\S*[^\s,]|[^\s,]+)(\s+[^,]*?)?\s*(?:,|\z)/).map { |url, desc| [ url, desc.to_s.rstrip ] }
  end

  # Draft => final image pairs the screen never references, so inlining them
  # would swap nothing (the screen points at a stable path, not the keyed one).
  # Matches on the raw refs (screen src/href values plus url() refs in its
  # local stylesheets) without resolving them, so a --final render whose
  # draft images were never generated is not aborted by a missing asset.
  def unmatched_remap(html_path, remap)
    return [] if remap.empty?

    refs = local_refs(html_path)
    remap.keys.reject { |draft| refs.any? { |ref| ref.include?(draft) } }
  end

  def local_refs(html_path)
    dir = File.dirname(File.expand_path(html_path))
    html = File.read(html_path)
    srcset = html.scan(SRCSET_RE).flat_map { |_attr, _q, value| srcset_candidates(value).map(&:first) }
    refs = (html.scan(ATTR_RE).map(&:last) + srcset).select { |v| local_ref?(v) }
    css = refs.select { |r| r.split(/[?#]/).first.end_with?('.css') }.filter_map do |r|
      path = File.expand_path(r.split(/[?#]/).first, dir)
      File.read(path) if File.file?(path)
    end
    refs + css.flat_map { |c| c.scan(/url\(\s*(["']?)([^"')]+)\1\s*\)/i).map(&:last) }
  end

  def swap_keys(ref, remap) = remap.reduce(ref) { |acc, (draft, final)| acc.gsub(draft, final) }

  # Draft image key => final-quality key for one scene, used when rendering
  # --final. Empty for a draft render and for images already at final
  # quality, so draft hashes never change.
  def final_remap(scene, root, final)
    return {} unless final

    Array(scene['images']).each_with_object({}) do |img, map|
      args = { prompt: img['prompt'].to_s, size: img['size'] || '1024x1024', refs: Array(img['refs']).map { |r| File.join(root, r) },
               model: img['model'] || PrototypeImagegen::MODEL }
      draft = PrototypeImagegen.asset_key(**args, quality: img['quality'] || PrototypeImagegen::QUALITY_DRAFT)
      high = PrototypeImagegen.asset_key(**args, quality: PrototypeImagegen::QUALITY_FINAL)
      map[draft] = high unless draft == high
    end
  end

  def default_root(dir) = File.basename(dir) == 'screens' ? File.dirname(dir) : dir

  # Resolves a local ref against `dir`, refusing one that lands outside
  # `root` (after symlinks), so `../../etc/passwd` never reaches a frame.
  def asset_path(dir, ref, root = nil)
    path = File.expand_path(ref.split(/[?#]/).first, dir)
    raise UnsupportedContentError, "missing local asset #{ref}" unless File.file?(path)

    base = File.realpath(root || default_root(dir))
    real = File.realpath(path)
    raise UnsupportedContentError, "local asset #{ref} resolves outside #{base}" unless real.start_with?(base + File::SEPARATOR)

    path
  end

  def inline_css(path, remap = {}, root = nil, seen = [])
    inline_css_urls(File.read(path), File.dirname(path), File.basename(path), remap, root, seen + [ File.expand_path(path) ])
  end

  CSS_IMPORT_RE = /@import\s+(?:url\(\s*(["']?)([^"')]+)\1\s*\)|(["'])([^"']+)\3)\s*([^;]*);/i

  # Replaces each local @import of a .css file with that file's inlined rules
  # (a trailing media query becomes an @media wrapper), so the imported rules
  # load under setContent and an edit to the imported file changes the output.
  # Imports that are not local .css files are left as they were.
  def inline_css_imports(css, dir, label, remap, root, seen)
    css.gsub(CSS_IMPORT_RE) do
      ref = Regexp.last_match(2) || Regexp.last_match(4)
      cond = Regexp.last_match(5).to_s.strip
      raise UnsupportedContentError, "#{label}: remote @import #{ref} is not supported" if remote?(ref)
      next Regexp.last_match(0) unless local_ref?(ref) && ref.split(/[?#]/).first.end_with?('.css')

      file = asset_path(dir, swap_keys(ref, remap), root)
      raise UnsupportedContentError, "#{label}: circular @import #{ref}" if seen.include?(file)
      raise UnsupportedContentError, "#{label}: @import #{ref} with #{cond} is not supported" if cond.match?(/\b(?:layer|supports)\b/i)

      body = inline_css(file, remap, root, seen)
      cond.empty? ? body : "@media #{cond} {#{body}}"
    end
  end

  # Swaps every local url() in a CSS fragment for a data URI resolved
  # against `dir`; shared by linked stylesheets, <style> blocks, and style
  # attributes so none of them leaves a file reference behind.
  def inline_css_urls(css, dir, label, remap = {}, root = nil, seen = [])
    css = inline_css_imports(css, dir, label, remap, root, seen)
    css.gsub(/url\(\s*(["']?)([^"')]+)\1\s*\)/i) do
      ref = Regexp.last_match(2)
      raise UnsupportedContentError, "#{label}: remote url(#{ref}) is not supported" if remote?(ref)

      local_ref?(ref) ? "url(\"#{ref_uri(dir, ref, remap, root)}\")" : Regexp.last_match(0)
    end
  end

  # A data URI for a local ref, keeping its #fragment so an SVG sprite
  # reference such as sprite.svg#save still selects its symbol.
  def ref_uri(dir, ref, remap = {}, root = nil)
    swapped = swap_keys(ref, remap)
    "#{data_uri(asset_path(dir, swapped, root))}#{swapped[/#.*\z/]}"
  end

  def data_uri(path)
    mime = MIME.fetch(File.extname(path).downcase, 'application/octet-stream')
    "data:#{mime};base64,#{Base64.strict_encode64(File.binread(path))}"
  end

  # -- mock state ----------------------------------------------------------

  def resolve_state(seed, from_end_state: nil, patch: [])
    state = JSON.parse(JSON.generate(from_end_state || seed || {}))
    Array(patch).each { |op| apply_patch!(state, op) }
    state
  end

  def apply_patch!(state, op)
    keys = op.fetch('path').to_s.split('.')
    last = keys.pop
    parent = keys.reduce(state) { |node, key| node.is_a?(Array) ? node.fetch(Integer(key)) : (node[key] ||= {}) }
    index = parent.is_a?(Array) ? Integer(last) : last
    case op.fetch('op')
    when 'set' then parent[index] = op['value']
    when 'push' then (parent[index] ||= []) << op['value']
    when 'delete' then parent.is_a?(Array) ? parent.delete_at(index) : parent.delete(index)
    else raise ArgumentError, "unknown patch op #{op['op']}"
    end
  end

  def default_prng_seed(scene_id) = Digest::SHA256.hexdigest(scene_id.to_s)[0, 8].to_i(16)

  # -- timing and input ----------------------------------------------------

  def frame_ms(fps = FPS) = 1000.0 / fps

  def frame_count(duration_ms, fps = FPS) = (duration_ms * fps / 1000.0).ceil

  def frame_at(t_ms, fps = FPS) = (t_ms * fps / 1000.0).floor

  def ease(name, p)
    p = p.clamp(0.0, 1.0)
    case name.to_s
    when '', 'linear' then p
    when 'easeInOutCubic' then p < 0.5 ? 4 * (p**3) : 1 - (((-2 * p) + 2)**3 / 2)
    when 'easeOutCubic' then 1 - ((1 - p)**3)
    when 'easeInCubic' then p**3
    else raise ArgumentError, "unknown easing #{name}"
    end
  end

  # Per-frame input plan. Each entry lists what the page does at that frame:
  # `move` (target plus eased progress, 1.0 on the last move frame), `hover`
  # and `click` targets, and the characters `type` sends to a target.
  def schedule(interactions, frames, fps = FPS)
    plan = Array.new(frames) { |i| { 'frame' => i } }
    Array(interactions).each do |op|
      raise ArgumentError, "unknown interaction op #{op['op']}" unless OPS.include?(op['op'])

      start = frame_at(op['t_ms'].to_i, fps)
      case op['op']
      when 'move' then schedule_move(plan, op, start, fps)
      when 'click', 'dblclick', 'hover' then plan.dig(start)&.store(op['op'], op['target'])
      when 'type' then schedule_type(plan, op, fps)
      when 'key' then plan.dig(start)&.then { |e| (e['key'] ||= []) << { 'keys' => key_chord(op['keys']), 'target' => op['target'] }.compact }
      when 'scroll' then plan.dig(start)&.store('scroll', { 'target' => op['target'], 'dx' => op['dx'], 'dy' => op['dy'], 'block' => op['block'] }.compact)
      end
    end
    plan
  end

  # "Ctrl+Shift+Esc" -> ["Control", "Shift", "Escape"]: modifiers first, in
  # authored order, then the one key they modify. Raises on anything else.
  def key_chord(spec)
    parts = spec.to_s == '+' ? [ '+' ] : spec.to_s.split(/\+(?=.)/)
    names = parts.map { |p| KEY_ALIASES.fetch(p, p) }
    *mods, last = names
    raise ArgumentError, "key #{spec.inspect} is empty" if last.nil? || last.empty?
    bad = mods.reject { |m| MODIFIERS.include?(m) }
    raise ArgumentError, "key #{spec.inspect}: #{bad.join(', ')} is not a modifier (#{MODIFIERS.join(', ')})" unless bad.empty?
    raise ArgumentError, "key #{spec.inspect}: unknown key #{last}" unless last.length == 1 || NAMED_KEYS.include?(last) || MODIFIERS.include?(last)

    names
  end

  def schedule_move(plan, op, start, fps)
    span = [ frame_count(op['duration_ms'].to_i, fps), 1 ].max
    (1..span).each do |k|
      entry = plan[start + k - 1] or break
      entry['move'] = { 'target' => op['target'], 'p' => ease(op['easing'], k.to_f / span), 'first' => k == 1 }
    end
  end

  def schedule_type(plan, op, fps)
    cps = (op['cps'] || 12).to_f
    op['text'].to_s.each_char.with_index do |char, k|
      entry = plan[frame_at(op['t_ms'].to_i + (k * 1000.0 / cps), fps)] or break
      entry['type'] ||= { 'target' => op['target'], 'text' => +'', 'focus' => k.zero? }
      entry['type']['text'] << char
      entry['type']['focus'] ||= k.zero?
      entry['type']['after_line'] = op['after_line'] if k.zero? && op['after_line']
      entry['type']['replace'] = true if k.zero? && op['replace']
    end
  end

  def cursor_path(positions)
    positions.each_with_index.map do |pos, i|
      { 'frame' => i + 1, 'x' => pos['x'].round(2), 'y' => pos['y'].round(2), 'down' => pos['down'] ? true : false }
    end
  end

  # Frames per /function call, scaled down from BATCH_FRAMES (sized for a
  # 1280x720 page) by pixel count: a 1080p batch of 90 PNGs returns hundreds
  # of megabytes of base64 and runs past FUNCTION_TIMEOUT_MS, so browserless
  # drops the connection mid-response.
  BATCH_PIXELS = 1280 * 720

  # Browserless's CDP websocket drops a response over 256 MiB (the call hangs
  # to its timeout), so a batch's measured base64 bytes stay under half that.
  BATCH_MAX_BYTES = 128 * 1024 * 1024

  # `bytes_per_frame` (measured from a finished batch) further caps the size.
  def batch_size(viewport, bytes_per_frame: nil)
    vp = DEFAULT_VIEWPORT.merge(viewport || {})
    pixels = vp['w'] * vp['h'] * (vp['dpr']**2)
    size = (BATCH_FRAMES * BATCH_PIXELS / pixels.to_f).floor.clamp(10, BATCH_FRAMES)
    return size unless bytes_per_frame&.positive?

    [ size, BATCH_MAX_BYTES / bytes_per_frame ].min.clamp(1, BATCH_FRAMES)
  end

  # -- keys ----------------------------------------------------------------

  def browserless_digest = ChangeDocker::BROWSERLESS_IMAGE.split('@').last

  def frames_key(inputs)
    WalkthroughCache.key(inputs.merge(browserless: browserless_digest, capture_version: CAPTURE_VERSION))
  end

  # -- the /function module ------------------------------------------------

  def clock_script(prng_seed:, start_ms: START_MS, state: nil)
    <<~JS.chomp
      (() => { window.__cfRealRaf = window.requestAnimationFrame.bind(window); })();
      #{BrowserlessJs.fixed_clock_js(start_ms: start_ms, prng_seed: prng_seed)}
      (() => { window.__CF_SEED__ = #{JSON.generate(state)}; })();
    JS
  end

  # page.setContent rewrites the current document instead of navigating, so
  # an evaluateOnNewDocument script never runs for it. The clock goes in as
  # the first script of the page itself, ahead of any screen script.
  def with_clock(html, script)
    tag = "<script>#{script.gsub('</script', '<\\/script')}</script>"
    return html.sub(/<head\b[^>]*>/i) { |m| "#{m}#{tag}" } if html.match?(/<head\b/i)

    "#{tag}#{html}"
  end

  # The locale pin, frozen clock, and seeded state, inlined ahead of every
  # screen script so a setContent load actually runs them.
  def with_document_scripts(html, prng_seed:, state:)
    with_clock(html, BrowserlessJs.locale_script(LOCALE) + clock_script(prng_seed: prng_seed, state: state))
  end

  # `lint` lists the frames PrototypeUxLint checks; `shots: false` replays
  # without screenshots (a lint-only pass over a cached capture), and
  # `aim: 'centre'` reproduces the pre-lint cursor targeting for such a pass.
  def function_module(html:, plan:, range:, viewport:, prng_seed:, state:, fps: FPS, lint: [], shots: true, aim: 'safe')
    vp = DEFAULT_VIEWPORT.merge(viewport || {})
    <<~JS
      export default async function ({ page: basePage }) {
        #{BrowserlessJs.fresh_context_js}
        const browser = basePage.browser();
        const context = await newBrowserContext(browser);
        const page = context ? await context.newPage() : await browser.newPage();
        const locale = #{JSON.generate(LOCALE)};
        const plan = #{JSON.generate(plan)};
        const first = #{range.first};
        const last = #{range.last - (range.exclude_end? ? 1 : 0)};
        const stepMs = #{frame_ms(fps)};
        const pageErrors = [];
        page.on("pageerror", (err) => pageErrors.push(String(err && err.message || err)));
        await page.setViewport({ width: #{vp['w']}, height: #{vp['h']}, deviceScaleFactor: #{vp['dpr']} });
        await page.setExtraHTTPHeaders(#{BrowserlessJs.locale_header_js});
        #{BrowserlessJs.inline_html_js(with_document_scripts(html, prng_seed: prng_seed, state: state), page_var: 'page')}
        const client = #{BrowserlessJs.cdp_session_js('page')};
        await client.send("Animation.enable");
        await client.send("Animation.setPlaybackRate", { playbackRate: 0 });
        await page.evaluate(#{JSON.generate(PrototypeUxLint::BROWSER_JS)});
        const lintAt = new Set(#{JSON.generate(lint)});
        const aimMode = #{JSON.generate(aim)};
        const center = async (sel) => page.evaluate((s, mode) => {
          if (mode === "safe") return window.__cfUx.aim(s);
          const r = document.querySelector(s).getBoundingClientRect();
          return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
        }, sel, aimMode);
        const lint = [];
        const devices = [];
        const overlays = {};
        let resting = null;
        let pos = { x: #{vp['w'] / 2.0}, y: #{vp['h'] / 2.0} };
        let from = pos;
        let down = false;
        const frames = [];
        const cursor = [];
        for (let i = 0; i <= last; i++) {
          const step = plan[i] || {};
          const virtualMs = await page.evaluate((ms) => window.__cfAdvance(ms), stepMs);
          await page.evaluate((now) => {
            window.__cfAnimStart = window.__cfAnimStart || new WeakMap();
            for (const anim of document.getAnimations()) {
              if (!window.__cfAnimStart.has(anim)) window.__cfAnimStart.set(anim, now);
              anim.pause();
              anim.currentTime = now - window.__cfAnimStart.get(anim);
            }
          }, virtualMs - #{START_MS});
          if (step.move) {
            if (step.move.first) from = pos;
            const to = await center(step.move.target);
            pos = { x: from.x + (to.x - from.x) * step.move.p, y: from.y + (to.y - from.y) * step.move.p };
            await page.mouse.move(pos.x, pos.y);
            resting = step.move.p >= 1 ? step.move.target : null;
          }
          if (step.hover) { pos = await center(step.hover); await page.mouse.move(pos.x, pos.y); resting = step.hover; }
          if (step.click) {
            pos = await center(step.click);
            resting = step.click;
            await page.mouse.move(pos.x, pos.y);
            await page.mouse.down(); down = true;
            await page.mouse.up();
          }
          if (step.dblclick) {
            pos = await center(step.dblclick);
            resting = step.dblclick;
            await page.mouse.move(pos.x, pos.y);
            await page.mouse.click(pos.x, pos.y, { clickCount: 1 });
            await page.mouse.click(pos.x, pos.y, { clickCount: 2 });
            down = true;
          }
          if (step.scroll) {
            await page.evaluate((s) => {
              const el = document.querySelector(s.target);
              if (!el) throw new Error(`scroll target not found: ${s.target}`);
              if (s.dx === undefined && s.dy === undefined) el.scrollIntoView({ block: s.block || "center", behavior: "instant" });
              else el.scrollBy({ left: s.dx || 0, top: s.dy || 0, behavior: "instant" });
            }, step.scroll);
          }
          if (step.type) {
            if (step.type.focus) await page.focus(step.type.target);
            for (const ch of step.type.text) await page.keyboard.type(ch);
          }
          for (const press of step.key || []) {
            if (press.target) await page.focus(press.target);
            const mods = press.keys.slice(0, -1);
            for (const m of mods) await page.keyboard.down(m);
            await page.keyboard.press(press.keys[press.keys.length - 1]);
            for (const m of mods.reverse()) await page.keyboard.up(m);
          }
          await page.evaluate(() => new Promise((r) => window.__cfRealRaf(() => window.__cfRealRaf(r))));
          let fresh = false;
          for (const key of await page.evaluate(() => window.__cfUx.overlays())) {
            if (!(key in overlays)) { overlays[key] = i; fresh = true; }
          }
          if (i >= first) {
            if (lintAt.has(i) || fresh) {
              const targets = resting ? [{ selector: resting, x: pos.x, y: pos.y }] : [];
              for (const f of await page.evaluate((t, b) => window.__cfUx.lint(t, b), targets, #{PrototypeUxLint::CAPTION_BAND})) lint.push(Object.assign({ frame: i }, f));
              for (const d of await page.evaluate(() => window.__cfUx.devices())) devices.push(Object.assign({ frame: i }, d));
            }
            if (#{shots}) frames.push(#{BrowserlessJs.screenshot_js('client')});
            cursor.push({ x: pos.x, y: pos.y, down });
          }
          down = false;
        }
        const endState = await page.evaluate(() => (window.CFStore && typeof window.CFStore.dump === "function") ? window.CFStore.dump() : null);
        if (context) await context.close();
        const firstSeen = Object.fromEntries(Object.entries(overlays).filter(([, f]) => f >= first));
        return { data: { frames, cursor, endState, blockedRequests, pageErrors, lint, devices, overlays: firstSeen }, type: "application/json" };
      }
    JS
  end

  # Raises on any sign the page escaped the controlled environment.
  def check_result!(result, label)
    blocked = Array(result['blockedRequests'])
    raise UnsupportedContentError, "#{label}: network request #{blocked.first['url']} left the page" unless blocked.empty?

    idb = Array(result['pageErrors']).find { |msg| msg.include?('indexedDB') }
    raise UnsupportedContentError, "#{label}: indexedDB is not supported (#{idb})" if idb

    result
  end

  # Captures one scene into out_dir: NNNNNN.png frames, cursor.json, and
  # end-state.json. `session` responds to run_function; the CLI passes the
  # one from ChangeDocker.with_browserless.
  def capture(session:, html:, interactions:, duration_ms:, out_dir:, state:, prng_seed:, viewport: nil, fps: FPS, label: 'scene')
    frames = frame_count(duration_ms, fps)
    plan = schedule(interactions, frames, fps)
    lint_frames = PrototypeUxLint.lint_frames(plan, frames)
    FileUtils.mkdir_p(out_dir)
    positions = []
    findings = []
    devices = []
    overlays = {}
    end_state = nil
    # Each batch replays the scene from its seeded start, without screenshots
    # before its first frame, so the DOM, store, and clock it captures from are
    # exactly the ones the previous batch ended on.
    first = 0
    size = batch_size(viewport)
    while first < frames
      range = first...[ first + size, frames ].min
      first = range.end
      code = function_module(html: html, plan: plan, range: range, viewport: viewport, prng_seed: prng_seed, state: state, fps: fps,
                             lint: lint_frames)
      result = check_result!(run_with_retry(session, code), label)
      findings.concat(Array(result['lint']))
      devices.concat(Array(result['devices']))
      overlays = Array(result['overlays']).to_h.merge(overlays)
      result['frames'].each_with_index do |b64, k|
        File.binwrite(File.join(out_dir, format('%06d.png', range.first + k + 1)), Base64.decode64(b64))
      end
      positions.concat(result['cursor'])
      end_state = result['endState']
      measured = result['frames'].sum(&:bytesize) / [ result['frames'].size, 1 ].max
      size = batch_size(viewport, bytes_per_frame: measured)
    end
    File.write(File.join(out_dir, 'cursor.json'), JSON.pretty_generate(cursor_path(positions)))
    PrototypeUxLint.write(out_dir, PrototypeUxLint.scene_report(label, findings, overlays: overlays, devices: devices).merge('aim' => 'safe'))
    File.write(File.join(out_dir, 'end-state.json'), JSON.pretty_generate(end_state))
    out_dir
  end

  # Lints a scene whose frames are already cached, without screenshots: one
  # replay of the whole scene. It aims the cursor the way the cached frames
  # were aimed (an older report's `aim`, else control centres, as frames
  # captured before the lint existed were), so it reports what the cached
  # video actually shows. Writes and returns the scene report.
  def lint_only(session:, html:, interactions:, duration_ms:, out_dir:, state:, prng_seed:, viewport: nil, fps: FPS, label: 'scene',
                aim: PrototypeUxLint.prior_aim(out_dir))
    frames = frame_count(duration_ms, fps)
    plan = schedule(interactions, frames, fps)
    code = function_module(html: html, plan: plan, range: 0...frames, viewport: viewport, prng_seed: prng_seed, state: state,
                           fps: fps, lint: PrototypeUxLint.lint_frames(plan, frames), shots: false, aim: aim)
    result = check_result!(run_with_retry(session, code), label)
    report = PrototypeUxLint.scene_report(label, Array(result['lint']), overlays: result['overlays'] || {},
                                                 devices: Array(result['devices'])).merge('aim' => aim)
    PrototypeUxLint.write(out_dir, report)
    report
  end

  # browserless occasionally drops a long /function response mid-body
  # (EOFError, ECONNRESET) on an otherwise healthy session. A batch is a pure
  # replay from its seeded start, so re-running it is safe.
  BATCH_RETRIES = 2
  # ECONNREFUSED is a dropped response too: the container died mid-request.
  DROPPED = [ EOFError, Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNREFUSED ].freeze

  class BrowserlessGoneError < StandardError; end

  # Before each retry the container must still answer; if it does not, retrying
  # only talks into a void, so fail with a clear error instead.
  def run_with_retry(session, code, retries: BATCH_RETRIES)
    attempt = 0
    begin
      session.run_function(code)
    rescue *DROPPED => e
      attempt += 1
      raise if attempt > retries

      unless session.alive?
        raise BrowserlessGoneError, "browserless container gone (#{e.class}: #{e.message}); something removed it mid-render"
      end

      retry
    end
  end

  # -- storyboard driving --------------------------------------------------

  def scene_duration(scene)
    timing = scene['timing'] || {}
    measured = scene.dig('narration', 'measured_ms').to_i
    [ timing['min_ms'].to_i, measured + timing.fetch('pad_ms', 0).to_i ].max
  end

  def sha256_file(path) = File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil

  # Why the capture driver skips a scene, or nil to capture it. Live scenes
  # and ai-broll scenes carry no screen.html; walkthrough_render.rb owns both.
  def skip_reason(scene)
    return 'ai-broll scene, rendered by walkthrough_render.rb' if scene['kind'] == 'ai-broll'
    return 'live scene, captured by walkthrough_render.rb' if scene.dig('screen', 'url')
    return 'compose scene, rendered in real time by walkthrough_compose.rb' if scene['kind'] == 'compose'
    return 'no screen.html to capture' if scene.dig('screen', 'html').to_s.empty?

    nil
  end

  # Resolves a scene's starting state and frames_key, recursing through its
  # from_scene chain via that scene's cached end-state.json.
  def prepare(board, scene, root, memo = {}, final: false)
    return memo[scene['id']] if memo[scene['id']]

    store = scene['store'] || {}
    seed_path = store['seed'] && File.join(root, store['seed'])
    seed = seed_path && File.file?(seed_path) ? JSON.parse(File.read(seed_path)) : {}
    from = nil
    if store['from_scene']
      parent = board['scenes'].find { |s| s['id'] == store['from_scene'] } || raise(ArgumentError, "unknown from_scene #{store['from_scene']}")
      parent_end = File.join(prepare(board, parent, root, memo, final: final)[:out_dir], 'end-state.json')
      raise ArgumentError, "capture #{parent['id']} before #{scene['id']}" unless File.file?(parent_end)

      from = JSON.parse(File.read(parent_end))
    end
    state = resolve_state(seed, from_end_state: from, patch: store['patch'])
    html_path = File.join(root, scene.dig('screen', 'html'))
    prng = store['prng_seed'] || default_prng_seed(scene['id'])
    remap = final_remap(scene, root, final)
    key = frames_key(html: sha256_file(html_path), inlined: Digest::SHA256.hexdigest(inline_screen(html_path, remap: remap, root: root)),
                     tokens: board['tokens_css_sha256'], interactions: scene['interactions'] || [],
                     viewport: board['viewport'], fps: board['fps'] || FPS, duration_ms: scene_duration(scene),
                     seed: seed_path && sha256_file(seed_path),
                     mock_store: sha256_file(File.join(root, 'screens', 'mock-store.js')),
                     state: WalkthroughCache.key(state), prng_seed: prng, **(remap.empty? ? {} : { images: remap }),
                     **(WalkthroughEnvironment.environment?(scene) ? { desktop_kit: WalkthroughEnvironment.version } : {}),
                     **(WalkthroughBrowserFrame.browser?(scene) ? { frame: WalkthroughBrowserFrame.material(scene) } : {}))
    memo[scene['id']] = { key: key, state: state, prng_seed: prng, html_path: html_path, remap: remap, root: root,
                          out_dir: File.join(root, '.cache', 'frames', key) }
  end

  # Records a scene's scripted motion into its frames cache, writing the
  # end-state.json that from_scene dependents resolve against.
  def capture_motion(board, scene, prep, session)
    duration = scene_duration(scene)
    puts "#{scene['id']}: capturing #{frame_count(duration, board['fps'] || FPS)} frames"
    capture(session: session, html: inline_screen(prep[:html_path], root: prep[:root]), interactions: scene['interactions'] || [],
            duration_ms: duration, out_dir: prep[:out_dir], state: prep[:state], prng_seed: prep[:prng_seed],
            viewport: board['viewport'], fps: board['fps'] || FPS, label: scene['id'])
    WalkthroughBrowserFrame.frame_dir!(board, scene, prep[:out_dir], work: prep[:root]) if WalkthroughBrowserFrame.browser?(scene)
  end

  # A still of a from_scene dependent needs each ancestor's post-interaction
  # end state, which only a motion capture writes; capture any that are
  # missing, root first, so stills-first review works on a fresh cache.
  def ensure_parents(board, scene, root, memo, session)
    parent_id = (scene['store'] || {})['from_scene']
    return unless parent_id

    parent = board['scenes'].find { |s| s['id'] == parent_id } || raise(ArgumentError, "unknown from_scene #{parent_id}")
    ensure_parents(board, parent, root, memo, session)
    prep = prepare(board, parent, root, memo)
    capture_motion(board, parent, prep, session) unless File.file?(File.join(prep[:out_dir], 'end-state.json'))
  end
end

if __FILE__ == $PROGRAM_NAME
  board_path = ARGV[0] || abort('usage: prototype_capture.rb walkthrough/<slug>/storyboard.json [--scene <id>] [--still]')
  only = ARGV.include?('--scene') ? ARGV[ARGV.index('--scene') + 1] : nil
  still = ARGV.include?('--still')
  board = JSON.parse(File.read(board_path))
  root = File.dirname(File.expand_path(board_path))
  WalkthroughCache.ensure_gitignore(root)
  scenes = board['scenes'].sort_by { |s| s['order'].to_i }
  ChangeDocker.with_browserless(network: nil) do |session|
    memo = {}
    scenes.each do |scene|
      next if only && scene['id'] != only
      reason = PrototypeCapture.skip_reason(scene)
      next puts("#{scene['id']}: #{reason}") if reason

      PrototypeCapture.ensure_parents(board, scene, root, memo, session) if still
      prep = PrototypeCapture.prepare(board, scene, root, memo)
      if still
        dir = File.join(root, '.cache', 'stills', scene['id'])
        PrototypeCapture.capture(session: session, html: PrototypeCapture.inline_screen(prep[:html_path], root: prep[:root]), interactions: [],
                                 duration_ms: PrototypeCapture.frame_ms, out_dir: dir, state: prep[:state],
                                 prng_seed: prep[:prng_seed], viewport: board['viewport'], label: scene['id'])
        puts "#{scene['id']}: still #{File.join(dir, '000001.png')}"
        next
      end
      if File.file?(File.join(prep[:out_dir], 'end-state.json'))
        puts "#{scene['id']}: cached #{prep[:key][0, 12]}"
        next
      end
      PrototypeCapture.capture_motion(board, scene, prep, session)
    end
  end
end
