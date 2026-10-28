# frozen_string_literal: true

require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require_relative 'browserless_js'
require_relative 'change_docker'
require_relative 'walkthrough_cache'

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
  OPS = %w[move click type hover wait].freeze
  UNSUPPORTED_TAGS = %w[video canvas iframe].freeze
  LOTTIE_MARKERS = [ /<lottie-player\b/i, /<dotlottie-player\b/i, /\blottie(?:\.min)?\.js\b/i, /\bbodymovin\b/i ].freeze
  ATTR_RE = /\b(src|href)\s*=\s*(["'])(.*?)\2/im
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
    true
  end

  def remote?(value) = value.strip.match?(%r{\A(?:https?:)?//}i)

  def local_ref?(value)
    v = value.strip
    !(v.empty? || v.start_with?('#', 'data:', 'about:', 'javascript:', 'mailto:') || remote?(v))
  end

  # Inlines a screen's local assets by string assembly: stylesheets and
  # scripts become inline elements, everything else a data URI. Only src and
  # href attribute values are discovered; CSS is never parsed, though a local
  # url() reference inside an inlined stylesheet is swapped for a data URI.
  def inline_screen(path)
    dir = File.dirname(File.expand_path(path))
    html = File.read(path)
    check_supported!(html, File.basename(path))
    html = html.gsub(%r{<link\b[^>]*\bhref\s*=\s*(["'])([^"']+\.css)\1[^>]*>}im) do
      href = Regexp.last_match(2)
      local_ref?(href) ? "<style>#{inline_css(asset_path(dir, href))}</style>" : Regexp.last_match(0)
    end
    html = html.gsub(%r{<script\b([^>]*)\bsrc\s*=\s*(["'])([^"']+)\2([^>]*)>\s*</script>}im) do
      src = Regexp.last_match(3)
      next Regexp.last_match(0) unless local_ref?(src)

      "<script#{(Regexp.last_match(1) + Regexp.last_match(4)).rstrip}>#{File.read(asset_path(dir, src)).gsub('</script', '<\/script')}</script>"
    end
    html.gsub(ATTR_RE) do
      attr, quote, value = Regexp.last_match.captures
      next Regexp.last_match(0) unless local_ref?(value) && !value.end_with?('.html')

      "#{attr}=#{quote}#{data_uri(asset_path(dir, value))}#{quote}"
    end
  end

  def asset_path(dir, ref)
    path = File.expand_path(ref.split(/[?#]/).first, dir)
    raise UnsupportedContentError, "missing local asset #{ref}" unless File.file?(path)

    path
  end

  def inline_css(path)
    css = File.read(path)
    dir = File.dirname(path)
    css.gsub(/url\(\s*(["']?)([^"')]+)\1\s*\)/i) do
      ref = Regexp.last_match(2)
      raise UnsupportedContentError, "#{File.basename(path)}: remote url(#{ref}) is not supported" if remote?(ref)

      local_ref?(ref) ? "url(\"#{data_uri(asset_path(dir, ref))}\")" : Regexp.last_match(0)
    end
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
      when 'click', 'hover' then plan.dig(start)&.store(op['op'], op['target'])
      when 'type' then schedule_type(plan, op, fps)
      end
    end
    plan
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

  def batch_size(viewport)
    vp = DEFAULT_VIEWPORT.merge(viewport || {})
    pixels = vp['w'] * vp['h'] * (vp['dpr']**2)
    (BATCH_FRAMES * BATCH_PIXELS / pixels.to_f).floor.clamp(10, BATCH_FRAMES)
  end

  def batches(frames, size = BATCH_FRAMES)
    (0...frames).step(size).map { |first| first...[ first + size, frames ].min }
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

  def function_module(html:, plan:, range:, viewport:, prng_seed:, state:, fps: FPS)
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
        #{BrowserlessJs.locale_js('locale', page_var: 'page')}
        #{BrowserlessJs.inline_html_js(with_clock(html, clock_script(prng_seed: prng_seed, state: state)), page_var: 'page')}
        const client = #{BrowserlessJs.cdp_session_js('page')};
        await client.send("Animation.enable");
        await client.send("Animation.setPlaybackRate", { playbackRate: 0 });
        const center = async (sel) => {
          const box = await page.$eval(sel, (el) => { const r = el.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; });
          return box;
        };
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
          }
          if (step.hover) { pos = await center(step.hover); await page.mouse.move(pos.x, pos.y); }
          if (step.click) {
            pos = await center(step.click);
            await page.mouse.move(pos.x, pos.y);
            await page.mouse.down(); down = true;
            await page.mouse.up();
          }
          if (step.type) {
            if (step.type.focus) await page.focus(step.type.target);
            for (const ch of step.type.text) await page.keyboard.type(ch);
          }
          await page.evaluate(() => new Promise((r) => window.__cfRealRaf(() => window.__cfRealRaf(r))));
          if (i >= first) {
            frames.push(#{BrowserlessJs.screenshot_js('client')});
            cursor.push({ x: pos.x, y: pos.y, down });
          }
          down = false;
        }
        const endState = await page.evaluate(() => (window.CFStore && typeof window.CFStore.dump === "function") ? window.CFStore.dump() : null);
        if (context) await context.close();
        return { data: { frames, cursor, endState, blockedRequests, pageErrors }, type: "application/json" };
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
    FileUtils.mkdir_p(out_dir)
    positions = []
    end_state = nil
    # Each batch replays the scene from its seeded start, without screenshots
    # before its first frame, so the DOM, store, and clock it captures from are
    # exactly the ones the previous batch ended on.
    batches(frames, batch_size(viewport)).each do |range|
      code = function_module(html: html, plan: plan, range: range, viewport: viewport, prng_seed: prng_seed, state: state, fps: fps)
      result = check_result!(run_with_retry(session, code), label)
      result['frames'].each_with_index do |b64, k|
        File.binwrite(File.join(out_dir, format('%06d.png', range.first + k + 1)), Base64.decode64(b64))
      end
      positions.concat(result['cursor'])
      end_state = result['endState']
    end
    File.write(File.join(out_dir, 'cursor.json'), JSON.pretty_generate(cursor_path(positions)))
    File.write(File.join(out_dir, 'end-state.json'), JSON.pretty_generate(end_state))
    out_dir
  end

  # browserless occasionally drops a long /function response mid-body
  # (EOFError, ECONNRESET) on an otherwise healthy session. A batch is a pure
  # replay from its seeded start, so re-running it is safe.
  BATCH_RETRIES = 2
  DROPPED = [ EOFError, Errno::ECONNRESET, Errno::EPIPE ].freeze

  def run_with_retry(session, code, retries: BATCH_RETRIES)
    attempt = 0
    begin
      session.run_function(code)
    rescue *DROPPED
      attempt += 1
      raise if attempt > retries

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

  # Resolves a scene's starting state and frames_key, recursing through its
  # from_scene chain via that scene's cached end-state.json.
  def prepare(board, scene, root, memo = {})
    return memo[scene['id']] if memo[scene['id']]

    store = scene['store'] || {}
    seed_path = store['seed'] && File.join(root, store['seed'])
    seed = seed_path && File.file?(seed_path) ? JSON.parse(File.read(seed_path)) : {}
    from = nil
    if store['from_scene']
      parent = board['scenes'].find { |s| s['id'] == store['from_scene'] } || raise(ArgumentError, "unknown from_scene #{store['from_scene']}")
      parent_end = File.join(prepare(board, parent, root, memo)[:out_dir], 'end-state.json')
      raise ArgumentError, "capture #{parent['id']} before #{scene['id']}" unless File.file?(parent_end)

      from = JSON.parse(File.read(parent_end))
    end
    state = resolve_state(seed, from_end_state: from, patch: store['patch'])
    html_path = File.join(root, scene.dig('screen', 'html'))
    prng = store['prng_seed'] || default_prng_seed(scene['id'])
    key = frames_key(html: sha256_file(html_path), inlined: Digest::SHA256.hexdigest(inline_screen(html_path)),
                     tokens: board['tokens_css_sha256'], interactions: scene['interactions'] || [],
                     viewport: board['viewport'], fps: board['fps'] || FPS, duration_ms: scene_duration(scene),
                     seed: seed_path && sha256_file(seed_path),
                     mock_store: sha256_file(File.join(root, 'screens', 'mock-store.js')),
                     state: WalkthroughCache.key(state), prng_seed: prng)
    memo[scene['id']] = { key: key, state: state, prng_seed: prng, html_path: html_path,
                          out_dir: File.join(root, '.cache', 'frames', key) }
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

      prep = PrototypeCapture.prepare(board, scene, root, memo)
      if still
        dir = File.join(root, '.cache', 'stills', scene['id'])
        PrototypeCapture.capture(session: session, html: PrototypeCapture.inline_screen(prep[:html_path]), interactions: [],
                                 duration_ms: PrototypeCapture.frame_ms, out_dir: dir, state: prep[:state],
                                 prng_seed: prep[:prng_seed], viewport: board['viewport'], label: scene['id'])
        puts "#{scene['id']}: still #{File.join(dir, '000001.png')}"
        next
      end
      if File.file?(File.join(prep[:out_dir], 'end-state.json'))
        puts "#{scene['id']}: cached #{prep[:key][0, 12]}"
        next
      end
      duration = PrototypeCapture.scene_duration(scene)
      puts "#{scene['id']}: capturing #{PrototypeCapture.frame_count(duration, board['fps'] || PrototypeCapture::FPS)} frames"
      PrototypeCapture.capture(session: session, html: PrototypeCapture.inline_screen(prep[:html_path]),
                               interactions: scene['interactions'] || [], duration_ms: duration, out_dir: prep[:out_dir],
                               state: prep[:state], prng_seed: prep[:prng_seed], viewport: board['viewport'],
                               fps: board['fps'] || PrototypeCapture::FPS, label: scene['id'])
    end
  end
end
