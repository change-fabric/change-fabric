# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'json'
require 'open3'
require_relative 'browserless_js'
require_relative 'change_docker'
require_relative 'frame_video'
require_relative 'prototype_capture'
require_relative 'prototype_ux_lint'
require_relative 'walkthrough_compose'
require_relative 'walkthrough_device'
require_relative 'walkthrough_browser_frame'
require_relative 'walkthrough_inset'
require_relative 'walkthrough_message'
require_relative 'walkthrough_cache'

# Live scenes: a cf:walkthrough scene whose screen is a running app's URL
# instead of a prototype HTML file. The controlled clock cannot reach into a
# real app (its server, sockets, and timers run on their own time), so a live
# scene is recorded in real time: a CDP screencast runs while the scripted
# steps play, and each frame tick at the board fps samples the latest
# screencast frame. Sessions come from a persona's pre-scene login or from an
# earlier live scene (session_from_scene), are held in memory for the run,
# and are never written to disk. Env-sourced values (passwords and the like)
# reach the page only; every log line, report, and error is masked.
module WalkthroughLive
  class CaptureError < StandardError; end
  class MissingEnvError < StandardError; end

  # 3: desktop frames are taken only once the page lays out at its viewport,
  # and phone composites carry square pixels (no pHYs aspect metadata).
  # 4: input runs through PrototypeCapture::DISPATCH_JS in timeline seq
  # order (a scroll before a move on one frame; an instant scroll or a
  # glide on a missing target fails instead of being skipped).
  CAPTURE_VERSION = 4
  WAIT_UNTIL = %w[domcontentloaded load].freeze
  DEFAULT_WAIT = { 'until' => 'load', 'settle_ms' => 0 }.freeze
  STORAGE_AREAS = %w[sessionStorage localStorage].freeze
  LOGIN_STEPS = %w[fill click wait].freeze
  BROWSER_KEYS = %w[add_hosts network ignore_https_errors].freeze
  OPS = PrototypeCapture::OPS
  # Keys that would carry a literal credential; a value only ever comes from
  # an env var name.
  LITERAL_KEYS = %w[value password secret token text].freeze
  NAME_RE = /\A[a-z0-9][a-z0-9-]*\z/
  ENV_RE = /\A[A-Z_][A-Z0-9_]*\z/
  HOST_RE = /\A[A-Za-z0-9.-]+:[0-9A-Fa-f:.]+\z/
  TIMEOUT_MS = 30_000
  # The bound on waiting at a navigate cut for the destination to paint,
  # and after a navigate run's last frame for the page to go quiet before
  # its session is exported.
  NAVIGATE_WAIT_MS = 5000
  # 95, not 90: q90 costs about 6 dB PSNR on small text against a PNG of
  # the same page (39.6 vs 45.4), more than the final x264 encode loses; q95
  # adds about a fifth to frame bytes.
  JPEG_QUALITY = 95
  MASK = '[masked]'

  module_function

  def live?(scene) = scene['screen'].is_a?(Hash) && scene['screen'].key?('url')

  def compose?(scene) = WalkthroughCompose.compose?(scene)

  # Filmed in real time through the browser: a live scene, or a compose
  # scene (the built-in compose page, captured the same way).
  def realtime?(scene) = live?(scene) || compose?(scene) || WalkthroughMessage.realtime?(scene)

  # Filmed from a built-in page (compose or message) rather than a URL.
  def builtin?(scene) = compose?(scene) || WalkthroughMessage.realtime?(scene)

  def url(scene) = scene.dig('screen', 'url')

  # -- validation ----------------------------------------------------------

  def board_errors(board)
    browser_errors(board['browser']) + persona_errors(board['personas']) + WalkthroughDevice.board_errors(board)
  end

  def browser_errors(browser)
    return [] if browser.nil?
    return [ 'browser must be an object' ] unless browser.is_a?(Hash)

    errors = []
    unknown = browser.keys - BROWSER_KEYS
    errors << "browser has unknown keys: #{unknown.join(', ')}" unless unknown.empty?
    hosts = browser.fetch('add_hosts', [])
    unless hosts.is_a?(Array) && hosts.all? { |h| h.is_a?(String) && h.match?(HOST_RE) }
      errors << 'browser.add_hosts must be a list of "host:ip" strings'
    end
    errors << 'browser.network must be a non-empty string' if browser.key?('network') && browser['network'].to_s.strip.empty?
    errors << 'browser.network must not be none; a live scene needs the network' if browser['network'] == 'none'
    errors << 'browser.ignore_https_errors must be true or false' if browser.key?('ignore_https_errors') && ![ true, false ].include?(browser['ignore_https_errors'])
    errors
  end

  def persona_errors(personas)
    return [] if personas.nil?
    return [ 'personas must be an object' ] unless personas.is_a?(Hash)

    personas.flat_map do |name, persona|
      label = "persona #{name.inspect}"
      errs = name.to_s.match?(NAME_RE) ? [] : [ 'name must match [a-z0-9][a-z0-9-]*' ]
      errs.concat(login_errors(persona.is_a?(Hash) ? persona['login'] : nil))
      errs.map { |e| "#{label}: #{e}" }
    end
  end

  def login_errors(login)
    return [ 'login is required' ] unless login.is_a?(Hash)

    errors = []
    errors << 'login.url must be an http(s) URL' unless http_url?(login['url'])
    errors << 'login.success_selector is required' if login['success_selector'].to_s.strip.empty?
    steps = login['steps']
    return errors << 'login.steps must be a non-empty list' unless steps.is_a?(Array) && !steps.empty?

    steps.each_with_index { |step, i| errors.concat(login_step_errors(step).map { |e| "login.steps #{i}: #{e}" }) }
    errors
  end

  def login_step_errors(step)
    return [ 'must be an object' ] unless step.is_a?(Hash)

    errors = []
    errors << "type must be one of #{LOGIN_STEPS.join(', ')}" unless LOGIN_STEPS.include?(step['type'])
    errors << 'selector is required' if step['selector'].to_s.strip.empty?
    literal = step.keys & LITERAL_KEYS
    errors << "#{literal.join(', ')} is a literal credential; name an env var with env instead" unless literal.empty?
    if step['type'] == 'fill'
      errors << 'fill needs env, the name of an env var holding the value' unless step.key?('env')
      errors << 'env must be an env var name like APP_PASSWORD' if step.key?('env') && !step['env'].to_s.match?(ENV_RE)
    elsif step.key?('env')
      errors << 'env applies only to a fill step'
    end
    errors
  end

  def http_url?(value) = value.is_a?(String) && value.match?(%r{\Ahttps?://[^\s/]+}i)

  # Errors for one live scene. `orders` maps scene id to order; `by_id` maps
  # scene id to scene, so session_from_scene can check the parent is live.
  def scene_errors(scene, board, orders, by_id, root: nil)
    errors = if compose?(scene) then compose_scene_errors(scene, orders, by_id)
    elsif WalkthroughMessage.message?(scene) then message_scene_errors(scene, board, orders, root)
    else live_scene_errors(scene, board, orders, by_id)
    end
    errors.concat(wait_errors(scene['wait']))
    errors.concat(WalkthroughDevice.scene_errors(scene))
    errors.concat(per_device_errors(scene))
    errors
  end

  def live_scene_errors(scene, board, orders, by_id)
    errors = []
    errors << 'screen.url must be an http(s) URL' unless http_url?(url(scene))
    errors << 'a live scene has no store; it films the real app' if scene.key?('store')
    errors << 'a live scene has no images; it films the real app' unless Array(scene['images']).empty?
    errors.concat(persona_ref_errors(scene, board))
    errors.concat(session_from_errors(scene, orders, by_id))
    errors.concat(storage_errors(scene['storage']))
  end

  def compose_scene_errors(scene, orders, by_id)
    errors = WalkthroughCompose.errors(scene, { orders: orders, realtime: by_id.select { |_, s| live?(s) }.keys })
    %w[persona session_from_scene storage].each { |k| errors << "a compose scene takes no #{k}" if scene.key?(k) }
    errors
  end

  def message_scene_errors(scene, board, orders, root)
    errors = WalkthroughMessage.errors(scene, { orders: orders, board: board, root: root })
    %w[persona session_from_scene storage store].each { |k| errors << "a message scene takes no #{k}" if scene.key?(k) }
    errors
  end

  # Interactions given per device must name only the scene's devices.
  def per_device_errors(scene)
    list = scene['interactions']
    return [] unless list.is_a?(Hash)

    extra = list.keys - WalkthroughDevice.devices(scene)
    extra.empty? ? [] : [ "interactions name devices the scene does not film: #{extra.join(', ')}" ]
  end

  def persona_ref_errors(scene, board)
    name = scene['persona']
    return [] if name.nil?
    return [ "persona #{name.inspect} is not in the top-level personas" ] unless (board['personas'] || {}).key?(name)
    return [ 'persona and session_from_scene are exclusive' ] if scene['session_from_scene']

    []
  end

  def session_from_errors(scene, orders, by_id)
    from = scene['session_from_scene']
    return [] if from.nil?
    return [ "session_from_scene #{from} is not a scene" ] unless orders.key?(from)
    return [ "session_from_scene #{from} must be an earlier scene" ] if orders[from] >= scene['order'].to_i
    return [ "session_from_scene #{from} must be a live scene" ] unless live?(by_id[from])

    []
  end

  def wait_errors(wait)
    return [] if wait.nil?
    return [ 'wait must be an object' ] unless wait.is_a?(Hash)

    errors = []
    unknown = wait.keys - %w[until selector settle_ms zoom style]
    errors << "wait has unknown keys: #{unknown.join(', ')}" unless unknown.empty?
    errors << "wait.until must be one of #{WAIT_UNTIL.join(', ')} (networkidle hangs under dev servers)" if wait.key?('until') && !WAIT_UNTIL.include?(wait['until'])
    errors << 'wait.selector must be a non-empty string' if wait.key?('selector') && wait['selector'].to_s.strip.empty?
    errors << 'wait.style must be a non-empty CSS string' if wait.key?('style') && wait['style'].to_s.strip.empty?
    errors << 'wait.settle_ms must be a non-negative integer' if wait.key?('settle_ms') && !(wait['settle_ms'].is_a?(Integer) && !wait['settle_ms'].negative?)
    errors
  end

  def storage_errors(storage)
    return [] if storage.nil?
    return [ 'storage must be an object' ] unless storage.is_a?(Hash)

    errors = []
    unknown = storage.keys - %w[clear set]
    errors << "storage has unknown keys: #{unknown.join(', ')}" unless unknown.empty?
    clear = storage.fetch('clear', [])
    errors << 'storage.clear must be a list of strings' unless clear.is_a?(Array) && clear.all? { |c| c.is_a?(String) && !c.empty? }
    set = storage.fetch('set', {})
    if !set.is_a?(Hash) || !(set.keys - STORAGE_AREAS).empty? || !set.values.all?(Hash)
      errors << "storage.set maps #{STORAGE_AREAS.join(' or ')} to an object of keys"
    end
    errors
  end

  # Interaction checks a live scene adds: env typing needs a URL, and a type
  # op takes exactly one of text or env.
  def interaction_errors(interactions, live:)
    interactions.each_with_index.flat_map do |op, i|
      errs = []
      errs << 'env typing needs a screen.url' if !live && op.key?('env')
      if op['op'] == 'type'
        errs << 'type takes exactly one of text or env' if op.key?('text') == op.key?('env')
        errs << 'env must be an env var name like APP_PASSWORD' if op.key?('env') && !op['env'].to_s.match?(ENV_RE)
        errs << 'after_line must be a non-empty string' if op.key?('after_line') && op['after_line'].to_s.empty?
        errs << 'after_line needs a live or compose scene' if !live && op.key?('after_line')
        errs << 'replace must be true' if op.key?('replace') && op['replace'] != true
      elsif op.key?('env') || op.key?('after_line') || op.key?('replace')
        errs << 'env and after_line apply only to a type op'
      end
      errs.map { |e| "interaction #{i}: #{e}" }
    end
  end

  # Every interaction of a scene, shared or per device.
  def all_interactions(scene)
    list = scene['interactions']
    list.is_a?(Hash) ? list.values.flat_map { |v| Array(v) } : Array(list)
  end

  def viewport_for(board) = PrototypeCapture::DEFAULT_VIEWPORT.merge(board['viewport'] || {})

  def fps_for(board) = board['fps'] || PrototypeCapture::FPS

  # A live scene's navigate cut (WalkthroughTimeline.cut), or nil.
  def navigate_cut(board, scene)
    return nil unless live?(scene)

    WalkthroughTimeline.cut(board, scene, lead: WalkthroughDevice.devices(scene).first, fps: fps_for(board))
  end

  # The scene a navigate tap hands to, when the pair is a valid run: the
  # next scene by order, live, starting from this scene's session.
  def pair_next(board, scene)
    return nil unless navigate_cut(board, scene)

    nxt = WalkthroughTimeline.next_scene(board, scene)
    nxt if nxt && live?(nxt) && nxt['session_from_scene'] == scene['id']
  end

  # The tapping scene a scene is the second half of, or nil.
  def pair_parent(board, scene)
    from = scene['session_from_scene'] or return nil
    parent = Array(board['scenes']).find { |s| s['id'] == from }
    parent if parent && pair_next(board, parent)&.fetch('id') == scene['id']
  end

  # A scene's length in ms: trimmed to its navigate cut plus the next
  # scene's overlap when it taps to navigate, else the derived duration.
  def duration_ms(board, scene)
    cut = navigate_cut(board, scene)
    cut ? WalkthroughTimeline.frames_ms(cut['frames'], fps_for(board)) : PrototypeCapture.scene_duration(scene)
  end

  def persona_env_names(persona) = Array(persona.dig('login', 'steps')).filter_map { |s| s['env'] }

  # -- secrets -------------------------------------------------------------

  # Every env var name the board types or fills.
  def env_names(board)
    persona = (board['personas'] || {}).values.flat_map { |p| persona_env_names(p) }
    typed = Array(board['scenes']).flat_map { |s| all_interactions(s).filter_map { |op| op['env'] } }
    (persona + typed).uniq
  end

  # Holds env values for the run and masks them out of anything written.
  class Secrets
    def initialize(names, env: ENV)
      @values = names.to_h { |n| [ n, env[n] ] }
    end

    def fetch(name)
      value = @values[name]
      raise MissingEnvError, "env #{name} is not set" if value.nil? || value.empty?

      value
    end

    def mask(text)
      @values.values.compact.reject(&:empty?).sort_by { |v| -v.length }.reduce(text.to_s) { |acc, v| acc.gsub(v, MASK) }
    end

    # A JSON-shaped value with every string masked.
    # Masks each string (and hash key) in place, never the serialized JSON,
    # so escaped secrets are caught and non-string primitives stay intact.
    def mask_deep(value)
      case value
      when Hash then value.to_h { |k, v| [ k.is_a?(String) ? mask(k) : k, mask_deep(v) ] }
      when Array then value.map { |v| mask_deep(v) }
      when String then mask(value)
      else value
      end
    end
  end

  # -- keys ----------------------------------------------------------------

  def browser_opts(board) = board['browser'] || {}

  # A persona's identity in a key: its login spec, which names env vars but
  # never holds their values.
  def persona_spec(board, name) = name && { name: name, login: (board['personas'] || {}).fetch(name, {}) }

  # Live frames key: URL, persona login spec, parent session key, steps,
  # waits, storage, viewport, fps, duration, and browser options. No env
  # value is key material; changing a password does not re-key a scene.
  def frames_key(board, scene, parent_key: nil, root: nil)
    WalkthroughCache.key(live: url(scene), compose: compose_material(scene),
                         message: WalkthroughMessage.realtime?(scene) ? WalkthroughMessage.material(scene, root) : nil, persona: persona_spec(board, scene['persona']),
                         session_from: parent_key, interactions: scene['interactions'] || [], wait: scene['wait'],
                         storage: scene['storage'], viewport: board['viewport'], fps: fps_for(board),
                         duration_ms: duration_ms(board, scene), browser: browser_opts(board),
                         devices: WalkthroughDevice.specs(board, scene), layout: WalkthroughDevice.layout_name(scene),
                         stage: WalkthroughSharpness.stage_size(board, scene),
                         **(WalkthroughDevice.fullbleed?(scene) ? { scrim: WalkthroughDevice.scrim(board), scrim_version: 2 } : {}),
                         **(WalkthroughBrowserFrame.browser?(scene) ? { frame: WalkthroughBrowserFrame.material(scene) } : {}),
                         **(WalkthroughInset.inset?(scene) ? { inset: WalkthroughInset.material(scene) } : {}),
                         **PrototypeCapture.timeline_material(all_interactions(scene)),
                         browserless: PrototypeCapture.browserless_digest, capture_version: CAPTURE_VERSION)
  end

  # A compose scene keys on its spec and the template version; a from_scene
  # compose also keys on its source scene's key (via parent_key).
  def compose_material(scene)
    compose?(scene) ? { spec: scene['compose'], template: WalkthroughCompose::TEMPLATE_VERSION } : nil
  end

  # The scene whose capture this one depends on: the session parent of a
  # live scene, or the link source of a from_scene compose scene.
  def parent_id(scene) = compose?(scene) ? scene.dig('compose', 'from_scene') : scene['session_from_scene']

  def prepare(board, scene, root, memo = {})
    return memo[scene['id']] if memo[scene['id']]

    parent = nil
    if (from = parent_id(scene))
      found = board['scenes'].find { |s| s['id'] == from } || raise(ArgumentError, "unknown source scene #{from}")
      parent = prepare(board, found, root, memo)
    end
    key = frames_key(board, scene, parent_key: parent && parent[:key], root: root)
    # A navigate run captures both scenes at once, so the tapping scene's
    # key covers the next scene's material too (keyed under this scene's
    # own key); the next scene keys on this one, so a change to either
    # recaptures both.
    if (nxt = pair_next(board, scene))
      key = WalkthroughCache.key(run: key, next: frames_key(board, nxt, parent_key: key, root: root))
    end
    memo[scene['id']] = { key: key, live: true, parent: from, compose: compose?(scene),
                          out_dir: File.join(root, '.cache', 'frames', key) }
  end

  # -- the /function modules -----------------------------------------------

  # Opens a fresh context and page for one device spec (`dev` in JS: w, h,
  # dpr, mobile, ua). A phone gets real mobile emulation: touch, isMobile,
  # and a mobile user agent.
  def page_setup_js(ignore_https)
    <<~JS.chomp
      #{BrowserlessJs.fresh_context_js}
      #{BrowserlessJs.ensure_viewport_js}
      const browser = basePage.browser();
      const sleep = (ms) => new Promise((r) => setTimeout(r, Math.max(0, ms)));
      const openPage = async (dev) => {
        const context = await newBrowserContext(browser);
        const page = context ? await context.newPage() : await browser.newPage();
        page.setDefaultTimeout(#{TIMEOUT_MS});
        await page.setViewport({ width: dev.w, height: dev.h, deviceScaleFactor: dev.dpr, isMobile: !!dev.mobile, hasTouch: !!dev.mobile });
        if (dev.mobile) await page.setUserAgent(dev.ua);
        const client = await page.createCDPSession();
        #{ignore_https ? 'await client.send("Security.setIgnoreCertificateErrors", { ignore: true });' : ''}
        return { context, page, client };
      };
    JS
  end

  # Restores a session's cookies, then its storage for the matching origin,
  # then the scene's storage seed, all before the first navigation. Cookies
  # and storage are keyed by origin, not device, so a session crosses
  # between desktop and phone scenes unchanged. Returns the document script
  # id, removed once the page has loaded so a later in-scene navigation
  # keeps what the app wrote.
  def restore_js(session, storage)
    <<~JS.chomp
      const session = #{JSON.generate(session || { 'cookies' => [], 'origins' => {} })};
      const storageSeed = #{JSON.generate(storage || {})};
      const restore = async (page, client) => {
        if (session.cookies.length) await client.send("Network.setCookies", { cookies: session.cookies });
        return (await page.evaluateOnNewDocument((s, st) => {
          if (window !== window.top) return;
          const put = (area, entries) => { for (const [k, v] of Object.entries(entries || {})) { try { window[area].setItem(k, typeof v === "string" ? v : JSON.stringify(v)); } catch (e) { void e; } } };
          const o = s.origins[location.origin];
          if (o) { put("localStorage", o.localStorage); put("sessionStorage", o.sessionStorage); }
          for (const c of (st.clear || [])) {
            try {
              if (c === "localStorage" || c === "sessionStorage") window[c].clear();
              else { localStorage.removeItem(c); sessionStorage.removeItem(c); }
            } catch (e) { void e; }
          }
          for (const [area, entries] of Object.entries(st.set || {})) put(area, entries);
        }, session, storageSeed)).identifier;
      };
    JS
  end

  # mailto:, sms:, and tel: links are caught on click (and window.open)
  # instead of followed, and queued for the capture loop to collect. An app
  # that assigns location.href to such a link directly is not caught.
  LINK_HOOK = <<~JS
    (() => {
      if (window !== window.top) return;
      window.__cfLinks = [];
      const re = /^(mailto|sms|smsto|tel):/i;
      document.addEventListener("click", (ev) => {
        const a = ev.target && ev.target.closest && ev.target.closest("a[href]");
        if (a && re.test(a.getAttribute("href"))) { ev.preventDefault(); window.__cfLinks.push(a.href); }
      }, true);
      const open = window.open;
      window.open = function (u, ...rest) { if (re.test(String(u))) { window.__cfLinks.push(String(u)); return null; } return open.call(window, u, ...rest); };
    })();
  JS

  def dump_session_js
    <<~JS.chomp
      const dumpSession = async (page, client) => {
        const all = (await client.send("Network.getAllCookies")).cookies;
        const cookies = all.map((c) => {
          const out = { name: c.name, value: c.value, domain: c.domain, path: c.path, secure: c.secure, httpOnly: c.httpOnly };
          if (c.sameSite) out.sameSite = c.sameSite;
          if (!c.session && c.expires > 0) out.expires = c.expires;
          return out;
        });
        let here = null;
        try { here = await page.evaluate(() => ({ origin: location.origin, localStorage: { ...localStorage }, sessionStorage: { ...sessionStorage }, ua: navigator.userAgent })); } catch (e) { void e; }
        const origins = Object.assign({}, session.origins);
        if (here && here.origin && here.origin !== "null") origins[here.origin] = { localStorage: here.localStorage, sessionStorage: here.sessionStorage };
        return { cookies, origins, url: page.url(), ua: here && here.ua };
      };
    JS
  end

  def desktop_spec(board) = viewport_for(board).merge('name' => 'desktop', 'mobile' => false)

  # A persona's pre-scene login on the board's desktop viewport: fill from
  # env values, click, wait, then the success selector, returning the
  # session. `values` maps env name to value.
  def login_module(board, persona, values)
    login = persona.fetch('login')
    steps = login['steps'].map { |s| s['env'] ? s.merge('value' => values.fetch(s['env'])) : s }
    <<~JS
      export default async function ({ page: basePage }) {
        #{page_setup_js(browser_opts(board)['ignore_https_errors'])}
        #{restore_js(nil, nil)}
        #{dump_session_js}
        const { context, page, client } = await openPage(#{JSON.generate(desktop_spec(board))});
        await page.goto(#{JSON.generate(login['url'])}, { waitUntil: "domcontentloaded" });
        for (const step of #{JSON.generate(steps)}) {
          await page.waitForSelector(step.selector);
          if (step.type === "fill") {
            await page.$eval(step.selector, (el) => { el.value = ""; });
            await page.type(step.selector, step.value);
          } else if (step.type === "click") {
            await page.click(step.selector);
          }
        }
        await page.waitForSelector(#{JSON.generate(login['success_selector'])});
        const out = await dumpSession(page, client);
        if (context) await context.close();
        return { data: { session: out }, type: "application/json" };
      }
    JS
  end

  # One device's real-time run, as a JS function `runDevice(job)`. A
  # screencast keeps the latest frame; each tick, at a fixed fps from the
  # moment the page is ready, samples it. Unique frames travel once and
  # `ticks` maps each frame to one.
  def run_device_js(board, scene)
    wait = DEFAULT_WAIT.merge(scene['wait'] || {})
    <<~JS.chomp
      const ux = #{JSON.generate(PrototypeUxLint::BROWSER_JS)};
      const linkHook = #{JSON.generate(LINK_HOOK)};
      const hideCursor = #{JSON.generate(BrowserlessJs::HIDE_CURSOR_SCRIPT)};
      const stepMs = #{PrototypeCapture.frame_ms(fps_for(board))};
      #{BrowserlessJs::SCREENCAST_SAMPLER_JS}
      const runDevice = async (job) => {
        const dev = job.dev;
        const { context, page, client } = await openPage(dev);
        const pageErrors = [];
        page.on("pageerror", (err) => pageErrors.push(String(err && err.message || err)));
        const seedId = await restore(page, client);
        await page.evaluateOnNewDocument(linkHook);
        await page.evaluateOnNewDocument(hideCursor);
        const safe = async (fn, fallback) => { try { return await fn(); } catch (e) { void e; return fallback; } };
        if (job.html) {
          await page.setContent(job.html, { waitUntil: "load" });
          await page.evaluate(linkHook);
          await page.evaluate(hideCursor);
        } else {
          await page.goto(job.url, { waitUntil: #{JSON.generate(wait['until'])} });
        }
        // A desktop page must lay out at its viewport, never the container's
        // default window; a phone's layout width is the page's own choice.
        if (!dev.mobile) {
          const laid = await ensureViewport(page, { width: dev.w, height: dev.h, deviceScaleFactor: dev.dpr, mobile: false });
          if (laid[0] !== dev.w || laid[1] !== dev.h) throw new Error(`viewport mismatch: laid out at ${laid[0]}x${laid[1]}, not ${dev.w}x${dev.h}`);
        }
        #{wait['selector'] ? "await page.waitForSelector(#{JSON.generate(wait['selector'])});" : ''}
        #{wait['zoom'] ? "await page.evaluate((z) => { document.documentElement.style.zoom = String(z); }, #{wait['zoom'].to_f});" : ''}
        #{wait['style'] ? "await page.addStyleTag({ content: #{JSON.generate(wait['style'])} });" : ''}
        await sleep(#{wait['settle_ms'].to_i});
        await page.removeScriptToEvaluateOnNewDocument(seedId);
        const ensureUx = () => safe(() => page.evaluate(ux), null);
        const aim = async (sel) => {
          await ensureUx();
          return safe(() => page.evaluate((s) => {
            if (window.__cfUx && window.__cfUx.aim) return window.__cfUx.aim(s);
            const r = document.querySelector(s).getBoundingClientRect();
            return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
          }, sel), null);
        };
        // CDP takes whole pixels; a full-bleed phone's dpr (2.7692) is not.
        const sampler = ScreencastSampler({ quality: #{JPEG_QUALITY}, maxWidth: Math.ceil(dev.w * dev.dpr), maxHeight: Math.ceil(dev.h * dev.dpr) });
        if (job.shots) {
          sampler.seed((await client.send("Page.captureScreenshot", { format: "jpeg", quality: #{JPEG_QUALITY} })).data);
          await sampler.attach(client);
        }
        const lintAt = new Set(job.lint);
        const cursor = [], lint = [], devices = [], links = [];
        const overlays = {};
        let inset = null;
        let insetHi = null;
        let insetError = null;
        // A navigate run (the tapping scene and the next one, filmed as one)
        // must reach the next scene's url after the cut. Compared as parsed
        // URLs, so browser canonicalization (an origin's trailing slash, a
        // default port) is not a mismatch.
        const canon = (u) => { try { return new URL(u).href; } catch (e) { void e; return u; } };
        const reached = new Set();
        const linkFrames = [];
        const st = { pos: { x: dev.w / 2, y: dev.h / 2 }, from: null, down: false, resting: null };
        st.from = st.pos;
        const dispatch = (#{PrototypeCapture::DISPATCH_JS})(page, { aim, mobile: !!dev.mobile, st });
        let t0 = Date.now();
        for (let i = 0; i < job.events.length; i++) {
          const leaving = job.cutFrame !== undefined && i === job.cutFrame ? page.url() : null;
          for (const ev of job.events[i]) await dispatch(ev);
          // The cut: the incoming scene's first frame must show the painted
          // destination, never a blank page mid-load. Recording pauses (the
          // outgoing scene already holds its last frame before the tap),
          // the run waits for the new document to load, network idle, fonts and two
          // animation frames, then resumes from a fresh shot; the clock
          // shifts by the wait, so it adds no video time.
          if (leaving !== null) {
            const paused = Date.now();
            if (job.shots) await sampler.detach();
            const until = paused + #{NAVIGATE_WAIT_MS};
            while (page.url() === leaving && Date.now() < until) await sleep(25);
            await safe(() => page.waitForNetworkIdle({ idleTime: 200, timeout: Math.max(until - Date.now(), 1) }), null);
            await safe(() => page.waitForFunction(() => document.readyState === "complete", { timeout: Math.max(until - Date.now(), 1) }), null);
            await safe(() => page.evaluate(() => document.fonts.ready.then(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))))), null);
            // The next scene's own frame-0 input, on the painted destination.
            for (const ev of job.entryEvents || []) await dispatch(ev);
            if (job.shots) {
              sampler.seed((await client.send("Page.captureScreenshot", { format: "jpeg", quality: #{JPEG_QUALITY} })).data);
              await sampler.attach(client);
            }
            t0 += Date.now() - paused;
          }
          await sleep(t0 + i * stepMs - Date.now());
          for (const href of await safe(() => page.evaluate(() => (window.__cfLinks || []).splice(0)), [])) { links.push(href); linkFrames.push(i); }
          if (job.expectUrl && i >= job.cutFrame) reached.add(canon(page.url()));
          let fresh = false;
          await ensureUx();
          for (const key of await safe(() => page.evaluate(() => window.__cfUx.overlays()), [])) {
            if (!(key in overlays)) { overlays[key] = i; fresh = true; }
          }
          if (lintAt.has(i) || fresh) {
            const targets = st.resting ? [{ selector: st.resting, x: st.pos.x, y: st.pos.y }] : [];
            for (const f of await safe(() => page.evaluate((t, b) => window.__cfUx.lint(t, b), targets, job.band), [])) lint.push(Object.assign({ frame: i, device: dev.name }, f));
            for (const d of await safe(() => page.evaluate(() => window.__cfUx.devices()), [])) devices.push(Object.assign({ frame: i, group: job.group }, d));
          }
          if (job.inset && i === job.inset.frame) {
            inset = await safe(() => page.evaluate((s) => { const el = document.querySelector(s); if (!el) return null; const r = el.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height }; }, job.inset.selector), null);
            if (!inset) throw new Error(`inset selector not found: ${job.inset.selector}`);
            // The same padded, viewport-clamped region the composite crops,
            // shot at scale x dpr so the inset is not an upscaled 1x crop.
            // The clip shot renders the page at that scale for one compositor
            // frame, which the screencast would deliver as the latest frame and,
            // on a static page, keep for the rest of the scene. So the recording
            // stops for the still, the viewport is checked and restored, and it
            // resumes from a fresh full-viewport frame.
            if (job.shots) await sampler.detach();
            try {
              const p = job.inset.pad;
              const cl = (v, max) => Math.min(Math.max(v, 0), max);
              const x0 = cl(inset.x - p, dev.w), y0 = cl(inset.y - p, dev.h);
              const x1 = cl(inset.x + inset.w + p, dev.w), y1 = cl(inset.y + inset.h + p, dev.h);
              if (x1 - x0 < 1 || y1 - y0 < 1) throw new Error(`inset region is off screen: ${JSON.stringify(inset)}`);
              const scroll = await page.evaluate(() => ({ x: window.scrollX, y: window.scrollY }));
              const clip = { x: x0 + scroll.x, y: y0 + scroll.y, width: x1 - x0, height: y1 - y0, scale: job.inset.scale * (dev.dpr || 1) };
              insetHi = (await client.send("Page.captureScreenshot", { format: "png", clip })).data;
            } catch (e) { insetError = String(e && e.message || e); }
            const vp = await safe(() => page.evaluate(() => ({ w: window.innerWidth, h: window.innerHeight, dpr: window.devicePixelRatio })), null);
            if (!vp || vp.w !== dev.w || vp.h !== dev.h || vp.dpr !== (dev.dpr || 1)) {
              await page.setViewport({ width: dev.w, height: dev.h, deviceScaleFactor: dev.dpr, isMobile: !!dev.mobile, hasTouch: !!dev.mobile });
            }
            if (job.shots) {
              sampler.seed((await client.send("Page.captureScreenshot", { format: "jpeg", quality: #{JPEG_QUALITY} })).data);
              await sampler.attach(client);
            }
          }
          sampler.tick();
          cursor.push({ x: st.pos.x, y: st.pos.y, down: st.down });
          st.down = false;
        }
        if (job.shots) await sampler.detach();
        const sampled = sampler.result();
        // The built-in page's end state, so a run can confirm what was sent
        // or tapped.
        const composed = job.html ? await safe(() => page.evaluate(() => {
          const val = (id, prop) => { const el = document.getElementById(id); return el ? el[prop] : null; };
          const view = document.querySelector(".cfm");
          return { body: val("body", "value"), send: val("send", "textContent"), status: val("status", "textContent"),
                   bubbles: [...document.querySelectorAll(".bubble, .cfm-out")].map((b) => b.textContent),
                   view: view ? view.className : null, cta: val("cta", "className") };
        }), null) : null;
        if (job.expectUrl) {
          if (!reached.has(canon(job.expectUrl))) {
            throw new Error(`tap-navigate never reached the next scene's url ${job.expectUrl} (after the cut: ${[...reached].join(", ") || "nothing"})`);
          }
          // The session handed on is the page at rest, not mid-request.
          await safe(() => page.waitForNetworkIdle({ idleTime: 200, timeout: #{NAVIGATE_WAIT_MS} }), null);
        }
        const out = await dumpSession(page, client);
        if (context) await context.close();
        return { name: dev.name, frames: sampled.frames, ticks: sampled.ticks, cursor, pageErrors, lint, devices, overlays, links, linkFrames, composed, inset, insetHi, insetError, session: out };
      };
    JS
  end

  # The capture module: every device of the scene runs in parallel against
  # the same URL (or compose page) and the same starting session.
  def capture_module(board, scene, jobs:, session:)
    <<~JS
      export default async function ({ page: basePage }) {
        #{page_setup_js(browser_opts(board)['ignore_https_errors'])}
        #{restore_js(session, scene['storage'])}
        #{dump_session_js}
        #{run_device_js(board, scene)}
        const results = await Promise.all(#{JSON.generate(jobs)}.map(runDevice));
        return { data: { devices: results }, type: "application/json" };
      }
    JS
  end

  # -- driving -------------------------------------------------------------

  # Interactions with env typing resolved to the real value, in memory only.
  def resolve_interactions(interactions, secrets)
    Array(interactions).map { |op| op['env'] ? op.merge('text' => secrets.fetch(op['env'])).except('env') : op }
  end

  # A scene's interactions for one device: shared as a list, or per device
  # as { "desktop": [...], "phone": [...] }.
  def interactions_for(scene, device)
    list = scene['interactions']
    list.is_a?(Hash) ? Array(list[device]) : Array(list)
  end

  def login(session:, board:, persona:, secrets:)
    values = persona_env_names(persona).to_h { |n| [ n, secrets.fetch(n) ] }
    guard(secrets) { PrototypeCapture.run_with_retry(session, login_module(board, persona, values), retries: 0).fetch('session') }
  end

  # A dropped connection after a live page acted leaves its state unknown, so
  # a job that drives the real app (no built-in html) is never replayed;
  # built-in compose and message pages are local and safe to retry.
  def retries_for(jobs) = jobs.any? { |j| j['html'].nil? } ? 0 : PrototypeCapture::BATCH_RETRIES

  # Re-raises any error with env values masked out of its message.
  def guard(secrets)
    yield
  rescue MissingEnvError
    raise
  rescue StandardError => e
    raise CaptureError, secrets.mask("#{e.class}: #{e.message}")
  end

  # One device's job: its spec, frame plan, lint frames, caption band, and
  # page source (the scene URL, or the compose page for that device).
  # rubocop:disable Metrics/ParameterLists
  def job(board, scene, spec, secrets, compose:, shots:, root: nil)
    # rubocop:enable Metrics/ParameterLists
    fps = fps_for(board)
    frames = PrototypeCapture.frame_count(duration_ms(board, scene), fps)
    ops = interactions_for(scene, spec['name'])
    timeline = PrototypeCapture.timeline!(resolve_interactions(ops, secrets), frames, fps, label: "#{scene['id']} #{spec['name']}")
    plan = WalkthroughTimeline.to_plan(timeline)
    band = caption_band(board, scene)
    { 'dev' => spec, 'plan' => plan, 'events' => timeline.events_by_frame,
      'lint' => PrototypeUxLint.lint_frames(plan, frames), 'band' => band, 'shots' => shots,
      'group' => WalkthroughDevice.group(scene, spec['name']),
      'url' => url(scene), 'html' => page_html(scene, spec['name'], compose: compose, board: board, root: root) }
  end

  # The in-page caption band share: a browser frame maps it through the
  # frame's own transform; otherwise only the full-bleed desktop frame meets
  # the band in the page, and a device layout is checked on the canvas.
  def caption_band(board, scene)
    return WalkthroughBrowserFrame.page_band(board) if WalkthroughBrowserFrame.browser?(scene)

    WalkthroughDevice.default?(scene) ? PrototypeUxLint::CAPTION_BAND : 0
  end

  # The built-in page a compose or message scene films on one device.
  def page_html(scene, device, compose:, board:, root:)
    return WalkthroughCompose.html(compose, device) if compose
    return WalkthroughMessage.page(scene['message'], device, board: board, root: root) if WalkthroughMessage.realtime?(scene)

    nil
  end

  # Captures one live or compose scene into out_dir (NNNNNN.png composited
  # on the board canvas, cursor.json, taps.json for a phone, links.json, a
  # null end-state.json, ux-lint.json) and returns its end session (the
  # first device's). With `shots: false` it only replays for the session.
  # With `next_scene` (the scene a navigate tap hands to) the two capture
  # as one continuous run on the tapping device, split at the cut into
  # out_dir and next_out_dir, and the end session is the next scene's.
  # rubocop:disable Metrics/ParameterLists
  def capture(session:, board:, scene:, out_dir:, secrets:, browser_session: nil, docker: nil, work: nil, shots: true, compose: nil,
              next_scene: nil, next_out_dir: nil)
    # rubocop:enable Metrics/ParameterLists
    specs = WalkthroughDevice.specs(board, scene)
    cut = next_scene && navigate_cut(board, scene)
    jobs = specs.map do |spec|
      next run_job(board, scene, next_scene, spec, secrets, cut, shots: shots) if cut && spec['name'] == cut['device']

      job(board, scene, spec, secrets, compose: compose, shots: shots, root: work)
    end
    # The desktop run reads the inset element's box at its frame.
    jobs.each { |j| j['inset'] = run_inset(board, scene, next_scene, cut) if shots && j['dev']['name'] == 'desktop' }
    launch = BrowserlessJs.capture_launch_args(WalkthroughDevice.capture_scale(specs))
    code = capture_module(board, scene, jobs: jobs, session: browser_session)
    result = guard(secrets) { PrototypeCapture.run_with_retry(session, code, retries: retries_for(jobs), launch_args: launch) }
    runs = result['devices']
    lead = cut ? runs.find { |r| r['name'] == cut['device'] } : runs.first
    return lead['session'] unless shots

    write = ->(sc, rs, dir) { SceneWriter.new(board: board, scene: sc, secrets: secrets, docker: docker, work: work).write(rs, dir) }
    unless cut
      write.call(scene, runs, out_dir)
      return lead['session']
    end

    head, tail = NavigateRun.split(lead, cut, inset_to_next: run_inset(board, scene, next_scene, cut)&.dig('owner') == 'next')
    write.call(scene, runs.map { |r| r.equal?(lead) ? head : r }, out_dir)
    write.call(next_scene, [ tail ], next_out_dir)
    File.write(File.join(next_out_dir, 'handoff.json'), JSON.pretty_generate(NavigateRun.handoff(lead, cut)))
    tail['session']
  end

  # The tapping device's job for a navigate run: the tapping scene's events
  # through the cut frame (its release and navigate), then the next scene's
  # from that frame on, as one plan of cut + next-scene frames. The page is
  # never reloaded; the run asserts it reaches the next scene's url.
  # rubocop:disable Metrics/ParameterLists
  def run_job(board, scene, nxt, spec, secrets, cut, shots:)
    # rubocop:enable Metrics/ParameterLists
    fps = fps_for(board)
    name = spec['name']
    at = cut['cut_frame']
    head = PrototypeCapture.timeline!(resolve_interactions(interactions_for(scene, name), secrets), at + 1, fps, label: "#{scene['id']} #{name}")
    frames = PrototypeCapture.frame_count(duration_ms(board, nxt), fps)
    tail = PrototypeCapture.timeline!(resolve_interactions(interactions_for(nxt, name), secrets), frames, fps, label: "#{nxt['id']} #{name}")
    events = head.events_by_frame
    after = tail.events_by_frame
    # The next scene's frame-0 input runs once the destination has painted
    # (entryEvents, after the wait at the cut), never beside the release.
    events.concat(after.drop(1))
    lint = PrototypeUxLint.lint_frames(WalkthroughTimeline.to_plan(head), at) +
           PrototypeUxLint.lint_frames(WalkthroughTimeline.to_plan(tail), frames).map { |f| f + at }
    { 'dev' => spec, 'events' => events, 'lint' => lint.uniq.sort, 'band' => caption_band(board, scene), 'shots' => shots,
      'group' => WalkthroughDevice.group(scene, name), 'url' => url(scene), 'html' => nil,
      'expectUrl' => url(nxt), 'cutFrame' => at, 'entryEvents' => after.first.to_a }
  end

  # The desktop inset of a scene, or of a navigate run: the next scene's,
  # moved onto the run's frames (validation allows one of the two).
  def run_inset(board, scene, nxt, cut)
    fps = fps_for(board)
    later = cut && WalkthroughInset.job(nxt, fps)
    return WalkthroughInset.job(scene, fps) unless later

    later.merge('frame' => later['frame'] + cut['cut_frame'], 'owner' => 'next')
  end

  # Splits a navigate run's lead device result at the cut into the tapping
  # scene's half and the next scene's half.
  module NavigateRun
    module_function

    # The tapping scene: the run's frames up to the cut, then its last
    # frame before the tap held for the overlap (the outgoing page of a
    # transition stays as it was when the finger lifted). The next scene:
    # the run from the cut on, its first cursor point carrying the tap
    # ripple's age and where the press landed, so the ripple finishes in
    # place even when the next scene's frame-0 input moves the pointer.
    def split(run, cut, inset_to_next: false)
      at = cut['cut_frame']
      overlap = cut['overlap']
      ticks = Array(run['ticks'])
      cursor = Array(run['cursor'])
      tail_cursor = cursor.drop(at)
      press = cursor[cut['press_frame']] || {}
      tail_cursor[0] = tail_cursor[0].merge('carry' => at - cut['press_frame'], 'carry_x' => press['x'], 'carry_y' => press['y']).compact if tail_cursor[0]
      head = run.merge('ticks' => ticks.first(at) + ([ ticks[at - 1] ] * overlap),
                       'cursor' => (cursor.first(at) + cursor.drop(at).first(overlap)).then { |c| pad(c, at + overlap) },
                       **before(run, at))
      tail = run.merge('ticks' => ticks.drop(at), 'cursor' => tail_cursor, **after(run, at))
      inset_to(head, tail, inset_to_next)
    end

    def pad(list, size) = list.size >= size || list.empty? ? list : list + ([ list.last ] * (size - list.size))

    def before(run, at)
      { 'lint' => Array(run['lint']).select { |f| f['frame'] < at }, 'devices' => Array(run['devices']).select { |d| d['frame'] < at },
        'overlays' => (run['overlays'] || {}).select { |_, f| f < at }, 'links' => links(run) { |f| f < at } }
    end

    def after(run, at)
      shift = ->(h) { h.merge('frame' => h['frame'] - at) }
      { 'lint' => Array(run['lint']).select { |f| f['frame'] >= at }.map(&shift),
        'devices' => Array(run['devices']).select { |d| d['frame'] >= at }.map(&shift),
        'overlays' => (run['overlays'] || {}).filter_map { |k, f| [ k, f - at ] if f >= at }.to_h, 'links' => links(run) { |f| f >= at } }
    end

    def links(run)
      frames = Array(run['linkFrames'])
      Array(run['links']).each_with_index.select { |_, i| yield(frames[i].to_i) }.map(&:first)
    end

    # The inset goes to the half whose scene declared it.
    def inset_to(head, tail, to_next)
      none = { 'inset' => nil, 'insetHi' => nil, 'insetError' => nil }
      to_next ? [ head.merge(none), tail ] : [ head, tail.merge(none) ]
    end

    # The handoff at the cut, keyed by device: where the tap landed and how
    # many frames its ripple had shown.
    def handoff(run, cut)
      at = Array(run['cursor'])[cut['press_frame']] || {}
      { run['name'] => { 'x' => at['x'], 'y' => at['y'], 'ripple_age_at_cut' => cut['cut_frame'] - cut['press_frame'] } }
    end
  end

  # Writes one captured scene to disk: frames composited per the scene's
  # device layout, cursor tracks mapped onto the canvas, caught links, and
  # the masked lint report.
  class SceneWriter
    def initialize(board:, scene:, secrets:, docker:, work:)
      @board = board
      @scene = scene
      @secrets = secrets
      @docker = docker || ->(argv) { Open3.capture2e(*argv) }
      @work = work
      @framed = WalkthroughBrowserFrame.browser?(scene)
      @layout = layout_for(board)
      @stage = layout_for(WalkthroughSharpness.stage_board(board, scene))
    end

    def write(runs, out_dir)
      FileUtils.rm_rf(out_dir)
      FileUtils.mkdir_p(out_dir)
      dirs = runs.to_h { |run| [ run['name'], write_jpgs(run, File.join(out_dir, 'jpg', run['name'])) ] }
      # The composite filter is positional over the layout's rects, so feed
      # inputs in rect order, not the scene's authored device order.
      plan = inset_plan(runs)
      composite!(@stage.rects.map { |r| dirs.fetch(r.name) }, out_dir, plan, hires: plan && write_inset_still(runs, out_dir))
      FileUtils.rm_rf(File.join(out_dir, 'jpg'))
      write_tracks(runs, out_dir)
      links = runs.flat_map { |r| Array(r['links']) }.uniq.map { |href| WalkthroughCompose.parse_link(href).merge('href' => href) }
      File.write(File.join(out_dir, 'links.json'), JSON.pretty_generate(@secrets.mask_deep(links)))
      PrototypeUxLint.write(out_dir, @secrets.mask_deep(report(runs)))
      File.write(File.join(out_dir, 'end-state.json'), "null\n")
    end

    private

    # The device layout on `board`: cursor tracks and frame lint use the
    # canvas; frames are composited on the scene's stage.
    def layout_for(board) = @framed ? WalkthroughBrowserFrame.layout(board) : WalkthroughDevice.layout(board, @scene)

    def write_jpgs(run, dir)
      FrameVideo.write_jpgs(dir, run['frames'], run['ticks'])
      dir
    end

    # The desktop arrow (hidden when there is no desktop) is cursor.json; a
    # phone's tap ripples are taps.json.
    def write_tracks(runs, out_dir)
      by_name = runs.to_h { |r| [ r['name'], r ] }
      frames = runs.first['cursor'].size
      desk = @layout.rect('desktop')
      arrow = desk ? WalkthroughDevice.arrow_path(desk, by_name['desktop']['cursor']) : WalkthroughDevice.hidden_path(frames)
      File.write(File.join(out_dir, 'cursor.json'), JSON.pretty_generate(arrow))
      phone = @layout.rect('phone')
      return unless phone

      File.write(File.join(out_dir, 'taps.json'), JSON.pretty_generate(WalkthroughDevice.ripple_path(phone, by_name['phone']['cursor'], ripple_size)))
    end

    # The ripple in canvas px, grown with a full-bleed phone's scale.
    def ripple_size = WalkthroughDevice::RIPPLE * WalkthroughDevice.sprite_scale(@board, @scene)

    def report(runs)
      raw = runs.flat_map { |r| Array(r['lint']) } + WalkthroughDevice.frame_findings(@layout)
      overlays = runs.map { |r| r['overlays'] || {} }.reduce({}) { |acc, o| o.merge(acc) }
      PrototypeUxLint.scene_report(@scene['id'], raw, overlays: overlays, devices: runs.flat_map { |r| Array(r['devices']) })
                     .merge('aim' => 'safe', 'live' => true)
    end

    # The magnified inset on the stage, or nil. The element box (viewport
    # CSS px) maps through the stage layout's content rect; the region is
    # written to inset.json beside the frames.
    def inset_plan(runs)
      desk = runs.find { |r| r['name'] == 'desktop' }
      return nil unless WalkthroughInset.inset?(@scene) && desk && desk['inset']

      WalkthroughInset.plan(@scene, @stage, desk['inset'], viewport_w: viewport_for(@board)['w'], fps: fps_for(@board), frames: desk['cursor'].size)
    end

    # The hi-res element still captured at at_ms, written beside the jpgs
    # (removed with them), or nil with a warning when that capture failed,
    # in which case the composite upscales the 1x crop instead.
    def write_inset_still(runs, out_dir)
      desk = runs.find { |r| r['name'] == 'desktop' } || {}
      data = desk['insetHi']
      unless data.is_a?(String) && !data.empty?
        reason = desk['insetError'] ? " (#{desk['insetError']})" : ''
        warn "walkthrough: scene #{@scene['id']}: hi-res inset capture failed#{reason}; upscaling the 1x crop"
        return nil
      end
      path = File.join(out_dir, 'jpg', 'inset.png')
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, data.unpack1('m'))
      path
    end

    def viewport_for(board) = WalkthroughLive.viewport_for(board)

    def fps_for(board) = WalkthroughLive.fps_for(board)

    def container(path) = File.join('/work', path.delete_prefix("#{@work}/"))

    # A browser-framed scene draws its chrome text from files written
    # beside the frames (removed with the jpg dir); others use the device
    # layout filter.
    def composite_filter(out_dir)
      return WalkthroughDevice.filter(@stage) unless @framed

      title, address = WalkthroughBrowserFrame.write_text(@stage, @scene, File.join(out_dir, 'jpg', 'chrome'))
      WalkthroughBrowserFrame.filter(@stage, title_file: container(title), address_file: container(address))
    end

    # JPEG screencast frames become PNGs on the board canvas in the pinned
    # FFmpeg container, offline.
    def composite!(dirs, out_dir, inset = nil, hires: nil)
      inputs = dirs.flat_map { |d| [ '-start_number', '1', '-i', File.join(container(d), '%06d.jpg') ] }
      hires = nil unless inset
      inputs += [ '-i', container(hires) ] if hires
      filter = WalkthroughInset.append(composite_filter(out_dir), inset, hires: hires && dirs.size)
      args = [ '-hide_banner', '-nostdin', '-y', *inputs, '-filter_complex', filter, '-map', '[out]',
               '-start_number', '1', File.join(container(out_dir), '%06d.png') ]
      argv = ChangeDocker.run_command(network: 'none', image: ChangeDocker::FFMPEG_IMAGE, args: args, mounts: { @work => '/work' }, workdir: '/work')
      out, status = @docker.call(argv)
      raise CaptureError, "ffmpeg frame composite failed:\n#{out.to_s.lines.last(10).join}" unless status.success?

      File.write(File.join(out_dir, 'inset.json'), JSON.pretty_generate(inset.to_h.merge('region' => WalkthroughInset.region(inset), 'hires' => !hires.nil?))) if inset
    end
  end
end
