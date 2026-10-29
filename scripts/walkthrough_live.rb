# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'json'
require 'open3'
require_relative 'browserless_js'
require_relative 'change_docker'
require_relative 'prototype_capture'
require_relative 'prototype_ux_lint'
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

  CAPTURE_VERSION = 1
  WAIT_UNTIL = %w[domcontentloaded load].freeze
  DEFAULT_WAIT = { 'until' => 'load', 'settle_ms' => 0 }.freeze
  STORAGE_AREAS = %w[sessionStorage localStorage].freeze
  LOGIN_STEPS = %w[fill click wait].freeze
  BROWSER_KEYS = %w[add_hosts network ignore_https_errors].freeze
  OPS = (PrototypeCapture::OPS + %w[scroll]).freeze
  # Keys that would carry a literal credential; a value only ever comes from
  # an env var name.
  LITERAL_KEYS = %w[value password secret token text].freeze
  NAME_RE = /\A[a-z0-9][a-z0-9-]*\z/
  ENV_RE = /\A[A-Z_][A-Z0-9_]*\z/
  HOST_RE = /\A[A-Za-z0-9.-]+:[0-9A-Fa-f:.]+\z/
  TIMEOUT_MS = 30_000
  JPEG_QUALITY = 90
  MASK = '[masked]'

  module_function

  def live?(scene) = scene['screen'].is_a?(Hash) && scene['screen'].key?('url')

  def url(scene) = scene.dig('screen', 'url')

  # -- validation ----------------------------------------------------------

  def board_errors(board)
    browser_errors(board['browser']) + persona_errors(board['personas'])
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
  def scene_errors(scene, board, orders, by_id)
    errors = []
    errors << 'screen.url must be an http(s) URL' unless http_url?(url(scene))
    errors << 'a live scene has no store; it films the real app' if scene.key?('store')
    errors << 'a live scene has no images; it films the real app' unless Array(scene['images']).empty?
    errors.concat(persona_ref_errors(scene, board))
    errors.concat(session_from_errors(scene, orders, by_id))
    errors.concat(wait_errors(scene['wait']))
    errors.concat(storage_errors(scene['storage']))
    errors
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
    unknown = wait.keys - %w[until selector settle_ms]
    errors << "wait has unknown keys: #{unknown.join(', ')}" unless unknown.empty?
    errors << "wait.until must be one of #{WAIT_UNTIL.join(', ')} (networkidle hangs under dev servers)" if wait.key?('until') && !WAIT_UNTIL.include?(wait['until'])
    errors << 'wait.selector must be a non-empty string' if wait.key?('selector') && wait['selector'].to_s.strip.empty?
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

  # Interaction checks a live scene adds: scroll needs a target, and a type
  # op takes exactly one of text or env.
  def interaction_errors(interactions, live:)
    interactions.each_with_index.flat_map do |op, i|
      errs = []
      errs << 'scroll and env typing need a screen.url' if !live && (op['op'] == 'scroll' || op.key?('env'))
      if op['op'] == 'type'
        errs << 'type takes exactly one of text or env' if op.key?('text') == op.key?('env')
        errs << 'env must be an env var name like APP_PASSWORD' if op.key?('env') && !op['env'].to_s.match?(ENV_RE)
      elsif op.key?('env')
        errs << 'env applies only to a type op'
      end
      errs.map { |e| "interaction #{i}: #{e}" }
    end
  end

  # -- secrets -------------------------------------------------------------

  # Every env var name the board types or fills.
  def env_names(board)
    persona = (board['personas'] || {}).values.flat_map { |p| Array(p.dig('login', 'steps')).filter_map { |s| s['env'] } }
    typed = Array(board['scenes']).flat_map { |s| Array(s['interactions']).filter_map { |op| op['env'] } }
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
    def mask_deep(value) = JSON.parse(mask(JSON.generate(value)))
  end

  # -- keys ----------------------------------------------------------------

  def browser_opts(board) = board['browser'] || {}

  # A persona's identity in a key: its login spec, which names env vars but
  # never holds their values.
  def persona_spec(board, name) = name && { name: name, login: (board['personas'] || {}).fetch(name, {}) }

  # Live frames key: URL, persona login spec, parent session key, steps,
  # waits, storage, viewport, fps, duration, and browser options. No env
  # value is key material; changing a password does not re-key a scene.
  def frames_key(board, scene, parent_key: nil)
    WalkthroughCache.key(live: url(scene), persona: persona_spec(board, scene['persona']), session_from: parent_key,
                         interactions: scene['interactions'] || [], wait: scene['wait'], storage: scene['storage'],
                         viewport: board['viewport'], fps: board['fps'] || PrototypeCapture::FPS,
                         duration_ms: PrototypeCapture.scene_duration(scene), browser: browser_opts(board),
                         browserless: PrototypeCapture.browserless_digest, capture_version: CAPTURE_VERSION)
  end

  def prepare(board, scene, root, memo = {})
    return memo[scene['id']] if memo[scene['id']]

    parent = nil
    if (from = scene['session_from_scene'])
      found = board['scenes'].find { |s| s['id'] == from } || raise(ArgumentError, "unknown session_from_scene #{from}")
      parent = prepare(board, found, root, memo)
    end
    key = frames_key(board, scene, parent_key: parent && parent[:key])
    memo[scene['id']] = { key: key, live: true, parent: from, out_dir: File.join(root, '.cache', 'frames', key) }
  end

  # -- the /function modules -----------------------------------------------

  def page_setup_js(viewport, ignore_https)
    vp = PrototypeCapture::DEFAULT_VIEWPORT.merge(viewport || {})
    <<~JS.chomp
      #{BrowserlessJs.fresh_context_js}
      const browser = basePage.browser();
      const context = await newBrowserContext(browser);
      const page = context ? await context.newPage() : await browser.newPage();
      page.setDefaultTimeout(#{TIMEOUT_MS});
      await page.setViewport({ width: #{vp['w']}, height: #{vp['h']}, deviceScaleFactor: #{vp['dpr']} });
      const client = #{BrowserlessJs.cdp_session_js('page')};
      #{ignore_https ? 'await client.send("Security.setIgnoreCertificateErrors", { ignore: true });' : ''}
      const sleep = (ms) => new Promise((r) => setTimeout(r, Math.max(0, ms)));
    JS
  end

  # Restores a session's cookies, then its storage for the matching origin,
  # then the scene's storage seed, all before the first navigation. The
  # document script is removed once the scene's page has loaded, so a later
  # in-scene navigation keeps what the app wrote.
  def restore_js(session, storage)
    <<~JS.chomp
      const session = #{JSON.generate(session || { 'cookies' => [], 'origins' => {} })};
      if (session.cookies.length) await client.send("Network.setCookies", { cookies: session.cookies });
      const seed = await page.evaluateOnNewDocument((s, st) => {
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
      }, session, #{JSON.generate(storage || {})});
    JS
  end

  def dump_session_js
    <<~JS.chomp
      const dumpSession = async () => {
        const all = (await client.send("Network.getAllCookies")).cookies;
        const cookies = all.map((c) => {
          const out = { name: c.name, value: c.value, domain: c.domain, path: c.path, secure: c.secure, httpOnly: c.httpOnly };
          if (c.sameSite) out.sameSite = c.sameSite;
          if (!c.session && c.expires > 0) out.expires = c.expires;
          return out;
        });
        let here = null;
        try { here = await page.evaluate(() => ({ origin: location.origin, localStorage: { ...localStorage }, sessionStorage: { ...sessionStorage } })); } catch (e) { void e; }
        const origins = Object.assign({}, session.origins);
        if (here && here.origin && here.origin !== "null") origins[here.origin] = { localStorage: here.localStorage, sessionStorage: here.sessionStorage };
        return { cookies, origins, url: page.url() };
      };
    JS
  end

  # A persona's pre-scene login: fill from env values, click, wait, then the
  # success selector, returning the session. `values` maps env name to value.
  def login_module(board, persona, values)
    login = persona.fetch('login')
    steps = login['steps'].map { |s| s['env'] ? s.merge('value' => values.fetch(s['env'])) : s }
    <<~JS
      export default async function ({ page: basePage }) {
        #{page_setup_js(board['viewport'], browser_opts(board)['ignore_https_errors'])}
        #{restore_js(nil, nil)}
        #{dump_session_js}
        await page.goto(#{JSON.generate(login['url'])}, { waitUntil: "domcontentloaded" });
        for (const step of #{JSON.generate(steps)}) {
          if (step.type === "fill") {
            await page.waitForSelector(step.selector);
            await page.$eval(step.selector, (el) => { el.value = ""; });
            await page.type(step.selector, step.value);
          } else if (step.type === "click") {
            await page.waitForSelector(step.selector);
            await page.click(step.selector);
          } else {
            await page.waitForSelector(step.selector);
          }
        }
        await page.waitForSelector(#{JSON.generate(login['success_selector'])});
        const out = await dumpSession();
        if (context) await context.close();
        return { data: { session: out }, type: "application/json" };
      }
    JS
  end

  # The real-time capture of one live scene. A screencast keeps the latest
  # frame; each tick, at a fixed fps from the moment the page is ready,
  # samples it. Unique frames travel once; `ticks` maps each frame to one.
  def capture_module(board, scene, plan:, session:, lint:, shots: true)
    wait = DEFAULT_WAIT.merge(scene['wait'] || {})
    vp = PrototypeCapture::DEFAULT_VIEWPORT.merge(board['viewport'] || {})
    fps = board['fps'] || PrototypeCapture::FPS
    <<~JS
      export default async function ({ page: basePage }) {
        #{page_setup_js(board['viewport'], browser_opts(board)['ignore_https_errors'])}
        #{restore_js(session, scene['storage'])}
        #{dump_session_js}
        const plan = #{JSON.generate(plan)};
        const lintAt = new Set(#{JSON.generate(lint)});
        const pageErrors = [];
        page.on("pageerror", (err) => pageErrors.push(String(err && err.message || err)));
        await page.goto(#{JSON.generate(url(scene))}, { waitUntil: #{JSON.generate(wait['until'])} });
        #{wait['selector'] ? "await page.waitForSelector(#{JSON.generate(wait['selector'])});" : ''}
        await sleep(#{wait['settle_ms'].to_i});
        await page.removeScriptToEvaluateOnNewDocument(seed.identifier);
        const ux = #{JSON.generate(PrototypeUxLint::BROWSER_JS)};
        const safe = async (fn, fallback) => { try { return await fn(); } catch (e) { void e; return fallback; } };
        const ensureUx = () => safe(() => page.evaluate(ux), null);
        const aim = async (sel) => {
          await ensureUx();
          return safe(() => page.evaluate((s) => {
            if (window.__cfUx && window.__cfUx.aim) return window.__cfUx.aim(s);
            const r = document.querySelector(s).getBoundingClientRect();
            return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
          }, sel), null);
        };
        const shots = #{shots};
        const store = [];
        let latest = -1;
        if (shots) {
          store.push((await client.send("Page.captureScreenshot", { format: "jpeg", quality: #{JPEG_QUALITY} })).data);
          latest = 0;
          client.on("Page.screencastFrame", (f) => {
            store.push(f.data); latest = store.length - 1;
            client.send("Page.screencastFrameAck", { sessionId: f.sessionId }).catch(() => {});
          });
          await client.send("Page.startScreencast", { format: "jpeg", quality: #{JPEG_QUALITY}, maxWidth: #{vp['w'] * vp['dpr']}, maxHeight: #{vp['h'] * vp['dpr']}, everyNthFrame: 1 });
        }
        const stepMs = #{PrototypeCapture.frame_ms(fps)};
        const ticks = [];
        const cursor = [];
        const lint = [];
        const devices = [];
        const overlays = {};
        let resting = null;
        let pos = { x: #{vp['w'] / 2.0}, y: #{vp['h'] / 2.0} };
        let from = pos;
        let down = false;
        const t0 = Date.now();
        for (let i = 0; i < plan.length; i++) {
          const step = plan[i] || {};
          if (step.move) {
            if (step.move.first) from = pos;
            const to = await aim(step.move.target);
            if (to) { pos = { x: from.x + (to.x - from.x) * step.move.p, y: from.y + (to.y - from.y) * step.move.p }; await page.mouse.move(pos.x, pos.y); }
            resting = step.move.p >= 1 ? step.move.target : null;
          }
          if (step.scroll) {
            await safe(() => page.evaluate((s) => { const el = document.querySelector(s); if (el) el.scrollIntoView({ block: "center" }); }, step.scroll), null);
          }
          if (step.hover) { const to = await aim(step.hover); if (to) { pos = to; await page.mouse.move(pos.x, pos.y); } resting = step.hover; }
          if (step.click) {
            const to = await aim(step.click);
            if (to) pos = to;
            resting = step.click;
            await page.mouse.move(pos.x, pos.y);
            await page.mouse.down(); down = true;
            await page.mouse.up();
          }
          if (step.type) {
            if (step.type.focus) await page.focus(step.type.target);
            for (const ch of step.type.text) await page.keyboard.type(ch);
          }
          await sleep(t0 + i * stepMs - Date.now());
          let fresh = false;
          await ensureUx();
          for (const key of await safe(() => page.evaluate(() => window.__cfUx.overlays()), [])) {
            if (!(key in overlays)) { overlays[key] = i; fresh = true; }
          }
          if (lintAt.has(i) || fresh) {
            const targets = resting ? [{ selector: resting, x: pos.x, y: pos.y }] : [];
            for (const f of await safe(() => page.evaluate((t, b) => window.__cfUx.lint(t, b), targets, #{PrototypeUxLint::CAPTION_BAND}), [])) lint.push(Object.assign({ frame: i }, f));
            for (const d of await safe(() => page.evaluate(() => window.__cfUx.devices()), [])) devices.push(Object.assign({ frame: i }, d));
          }
          ticks.push(latest);
          cursor.push({ x: pos.x, y: pos.y, down });
          down = false;
        }
        if (shots) await client.send("Page.stopScreencast");
        const out = await dumpSession();
        if (context) await context.close();
        return { data: { frames: store, ticks, cursor, pageErrors, lint, devices, overlays, session: out }, type: "application/json" };
      }
    JS
  end

  # -- driving -------------------------------------------------------------

  # Interactions with env typing resolved to the real value, in memory only.
  def resolve_interactions(interactions, secrets)
    Array(interactions).map { |op| op['env'] ? op.merge('text' => secrets.fetch(op['env'])).except('env') : op }
  end

  def login(session:, board:, persona:, secrets:)
    values = Array(persona.dig('login', 'steps')).filter_map { |s| s['env'] }.to_h { |n| [ n, secrets.fetch(n) ] }
    guard(secrets) { PrototypeCapture.run_with_retry(session, login_module(board, persona, values)).fetch('session') }
  end

  # Re-raises any error with env values masked out of its message.
  def guard(secrets)
    yield
  rescue MissingEnvError
    raise
  rescue StandardError => e
    raise CaptureError, secrets.mask("#{e.class}: #{e.message}")
  end

  # Captures one live scene into out_dir (NNNNNN.png, cursor.json, a null
  # end-state.json, ux-lint.json) and returns its end session. With
  # `shots: false` it only replays to produce the session. JPEG screencast
  # frames become PNGs in the pinned FFmpeg container, offline.
  # rubocop:disable Metrics/ParameterLists
  def capture(session:, board:, scene:, out_dir:, secrets:, browser_session: nil, docker: nil, work: nil, shots: true)
    # rubocop:enable Metrics/ParameterLists
    fps = board['fps'] || PrototypeCapture::FPS
    frames = PrototypeCapture.frame_count(PrototypeCapture.scene_duration(scene), fps)
    plan = PrototypeCapture.schedule(resolve_interactions(scene['interactions'], secrets).map { |op| op['op'] == 'scroll' ? op.merge('op' => 'wait') : op }, frames, fps)
    Array(scene['interactions']).each { |op| plan.dig(PrototypeCapture.frame_at(op['t_ms'].to_i, fps))&.store('scroll', op['target']) if op['op'] == 'scroll' }
    lint_frames = PrototypeUxLint.lint_frames(plan, frames)
    result = guard(secrets) do
      PrototypeCapture.run_with_retry(session, capture_module(board, scene, plan: plan, session: browser_session, lint: lint_frames, shots: shots))
    end
    write_scene(result, out_dir, scene['id'], secrets, docker: docker, work: work, board: board) if shots
    result['session']
  end

  # rubocop:disable Metrics/ParameterLists
  def write_scene(result, out_dir, label, secrets, docker:, work:, board:)
    # rubocop:enable Metrics/ParameterLists
    FileUtils.rm_rf(out_dir)
    FileUtils.mkdir_p(out_dir)
    jpg_dir = File.join(out_dir, 'jpg')
    FileUtils.mkdir_p(jpg_dir)
    result['ticks'].each_with_index do |idx, i|
      File.binwrite(File.join(jpg_dir, format('%06d.jpg', i + 1)), Base64.decode64(result['frames'][[ idx, 0 ].max]))
    end
    to_png!(jpg_dir, out_dir, docker: docker, work: work, board: board)
    FileUtils.rm_rf(jpg_dir)
    File.write(File.join(out_dir, 'cursor.json'), JSON.pretty_generate(PrototypeCapture.cursor_path(result['cursor'])))
    report = PrototypeUxLint.scene_report(label, Array(result['lint']), overlays: result['overlays'] || {},
                                                 devices: Array(result['devices'])).merge('aim' => 'safe', 'live' => true)
    PrototypeUxLint.write(out_dir, secrets.mask_deep(report))
    File.write(File.join(out_dir, 'end-state.json'), "null\n")
  end

  def to_png!(jpg_dir, out_dir, docker:, work:, board:)
    vp = PrototypeCapture::DEFAULT_VIEWPORT.merge(board['viewport'] || {})
    rel = ->(p) { File.join('/work', p.delete_prefix("#{work}/")) }
    args = [ '-hide_banner', '-nostdin', '-y', '-start_number', '1', '-i', File.join(rel.call(jpg_dir), '%06d.jpg'),
             '-vf', "scale=#{vp['w']}:#{vp['h']}", '-start_number', '1', File.join(rel.call(out_dir), '%06d.png') ]
    argv = ChangeDocker.run_command(network: 'none', image: ChangeDocker::FFMPEG_IMAGE, args: args, mounts: { work => '/work' }, workdir: '/work')
    out, status = (docker || ->(a) { Open3.capture2e(*a) }).call(argv)
    raise CaptureError, "ffmpeg jpeg to png failed:\n#{out.to_s.lines.last(10).join}" unless status.success?
  end
end
