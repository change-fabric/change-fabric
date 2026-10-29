# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'json'
require 'open3'
require_relative 'browserless_js'
require_relative 'change_docker'
require_relative 'prototype_capture'
require_relative 'prototype_ux_lint'
require_relative 'walkthrough_compose'
require_relative 'walkthrough_device'
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

  def compose?(scene) = WalkthroughCompose.compose?(scene)

  # Filmed in real time through the browser: a live scene, or a compose
  # scene (the built-in compose page, captured the same way).
  def realtime?(scene) = live?(scene) || compose?(scene)

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
  def scene_errors(scene, board, orders, by_id)
    errors = compose?(scene) ? compose_scene_errors(scene, orders, by_id) : live_scene_errors(scene, board, orders, by_id)
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
        errs << 'after_line must be a non-empty string' if op.key?('after_line') && op['after_line'].to_s.empty?
        errs << 'after_line needs a live or compose scene' if !live && op.key?('after_line')
      elsif op.key?('env') || op.key?('after_line')
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
    WalkthroughCache.key(live: url(scene), compose: compose_material(scene), persona: persona_spec(board, scene['persona']),
                         session_from: parent_key, interactions: scene['interactions'] || [], wait: scene['wait'],
                         storage: scene['storage'], viewport: board['viewport'], fps: fps_for(board),
                         duration_ms: PrototypeCapture.scene_duration(scene), browser: browser_opts(board),
                         devices: WalkthroughDevice.specs(board, scene), layout: WalkthroughDevice.layout_name(scene),
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
    key = frames_key(board, scene, parent_key: parent && parent[:key])
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
      const stepMs = #{PrototypeCapture.frame_ms(fps_for(board))};
      const runDevice = async (job) => {
        const dev = job.dev;
        const { context, page, client } = await openPage(dev);
        const pageErrors = [];
        page.on("pageerror", (err) => pageErrors.push(String(err && err.message || err)));
        const seedId = await restore(page, client);
        await page.evaluateOnNewDocument(linkHook);
        const safe = async (fn, fallback) => { try { return await fn(); } catch (e) { void e; return fallback; } };
        if (job.html) {
          await page.setContent(job.html, { waitUntil: "load" });
          await page.evaluate(linkHook);
        } else {
          await page.goto(job.url, { waitUntil: #{JSON.generate(wait['until'])} });
        }
        #{wait['selector'] ? "await page.waitForSelector(#{JSON.generate(wait['selector'])});" : ''}
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
        const store = [];
        let latest = -1;
        if (job.shots) {
          store.push((await client.send("Page.captureScreenshot", { format: "jpeg", quality: #{JPEG_QUALITY} })).data);
          latest = 0;
          client.on("Page.screencastFrame", (f) => {
            store.push(f.data); latest = store.length - 1;
            client.send("Page.screencastFrameAck", { sessionId: f.sessionId }).catch(() => {});
          });
          await client.send("Page.startScreencast", { format: "jpeg", quality: #{JPEG_QUALITY}, maxWidth: dev.w * dev.dpr, maxHeight: dev.h * dev.dpr, everyNthFrame: 1 });
        }
        const lintAt = new Set(job.lint);
        const ticks = [], cursor = [], lint = [], devices = [], links = [];
        const overlays = {};
        let resting = null;
        let pos = { x: dev.w / 2, y: dev.h / 2 };
        let from = pos;
        let down = false;
        const t0 = Date.now();
        for (let i = 0; i < job.plan.length; i++) {
          const step = job.plan[i] || {};
          if (step.move) {
            if (step.move.first) from = pos;
            const to = await aim(step.move.target);
            if (to) { pos = { x: from.x + (to.x - from.x) * step.move.p, y: from.y + (to.y - from.y) * step.move.p }; if (!dev.mobile) await page.mouse.move(pos.x, pos.y); }
            resting = step.move.p >= 1 ? step.move.target : null;
          }
          if (step.scroll) await safe(() => page.evaluate((s) => { const el = document.querySelector(s); if (el) el.scrollIntoView({ block: "center" }); }, step.scroll), null);
          if (step.hover) { const to = await aim(step.hover); if (to) { pos = to; if (!dev.mobile) await page.mouse.move(pos.x, pos.y); } resting = step.hover; }
          if (step.click) {
            const to = await aim(step.click);
            if (to) pos = to;
            resting = step.click;
            if (dev.mobile) { await page.touchscreen.tap(pos.x, pos.y); }
            else { await page.mouse.move(pos.x, pos.y); await page.mouse.down(); await page.mouse.up(); }
            down = true;
          }
          if (step.type) {
            if (step.type.focus) await page.focus(step.type.target);
            // after_line puts the caret at the end of the first line that
            // starts with it, so typing fills in a prefilled template line.
            if (step.type.after_line) await page.$eval(step.type.target, (el, prefix) => {
              const lines = el.value.split("\\n");
              const at = lines.findIndex((l) => l.startsWith(prefix));
              if (at < 0) throw new Error(`no line starting with ${prefix}`);
              const end = lines.slice(0, at + 1).join("\\n").length;
              el.setSelectionRange(end, end);
            }, step.type.after_line);
            for (const ch of step.type.text) await page.keyboard.type(ch);
          }
          await sleep(t0 + i * stepMs - Date.now());
          for (const href of await safe(() => page.evaluate(() => (window.__cfLinks || []).splice(0)), [])) links.push(href);
          let fresh = false;
          await ensureUx();
          for (const key of await safe(() => page.evaluate(() => window.__cfUx.overlays()), [])) {
            if (!(key in overlays)) { overlays[key] = i; fresh = true; }
          }
          if (lintAt.has(i) || fresh) {
            const targets = resting ? [{ selector: resting, x: pos.x, y: pos.y }] : [];
            for (const f of await safe(() => page.evaluate((t, b) => window.__cfUx.lint(t, b), targets, job.band), [])) lint.push(Object.assign({ frame: i, device: dev.name }, f));
            for (const d of await safe(() => page.evaluate(() => window.__cfUx.devices()), [])) devices.push(Object.assign({ frame: i, group: job.group }, d));
          }
          ticks.push(latest);
          cursor.push({ x: pos.x, y: pos.y, down });
          down = false;
        }
        if (job.shots) await client.send("Page.stopScreencast");
        // The compose page's end fields, so a run can confirm what was sent.
        const composed = job.html ? await safe(() => page.evaluate(() => ({
          body: document.getElementById("body").value, send: document.getElementById("send").textContent,
          status: document.getElementById("status").textContent,
          bubbles: [...document.querySelectorAll(".bubble")].map((b) => b.textContent) })), null) : null;
        const out = await dumpSession(page, client);
        if (context) await context.close();
        return { name: dev.name, frames: store, ticks, cursor, pageErrors, lint, devices, overlays, links, composed, session: out };
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

  # One device's job: its spec, frame plan, lint frames, caption band, and
  # page source (the scene URL, or the compose page for that device).
  def job(board, scene, spec, secrets, compose:, shots:)
    fps = fps_for(board)
    frames = PrototypeCapture.frame_count(PrototypeCapture.scene_duration(scene), fps)
    ops = interactions_for(scene, spec['name'])
    plan = PrototypeCapture.schedule(resolve_interactions(ops, secrets).map { |op| op['op'] == 'scroll' ? op.merge('op' => 'wait') : op }, frames, fps)
    mark_scrolls(plan, ops, fps)
    # Only the full-bleed desktop frame meets the caption band in the page;
    # a composited frame is checked on the canvas instead.
    band = WalkthroughDevice.default?(scene) ? PrototypeUxLint::CAPTION_BAND : 0
    { 'dev' => spec, 'plan' => plan, 'lint' => PrototypeUxLint.lint_frames(plan, frames), 'band' => band, 'shots' => shots,
      'group' => WalkthroughDevice.group(scene, spec['name']),
      'url' => compose ? nil : url(scene), 'html' => compose && WalkthroughCompose.html(compose, spec['name']) }
  end

  # Captures one live or compose scene into out_dir (NNNNNN.png composited
  # on the board canvas, cursor.json, taps.json for a phone, links.json, a
  # null end-state.json, ux-lint.json) and returns its end session (the
  # first device's). With `shots: false` it only replays for the session.
  # rubocop:disable Metrics/ParameterLists
  def capture(session:, board:, scene:, out_dir:, secrets:, browser_session: nil, docker: nil, work: nil, shots: true, compose: nil)
    # rubocop:enable Metrics/ParameterLists
    jobs = WalkthroughDevice.specs(board, scene).map { |spec| job(board, scene, spec, secrets, compose: compose, shots: shots) }
    result = guard(secrets) do
      PrototypeCapture.run_with_retry(session, capture_module(board, scene, jobs: jobs, session: browser_session))
    end
    runs = result['devices']
    SceneWriter.new(board: board, scene: scene, secrets: secrets, docker: docker, work: work).write(runs, out_dir) if shots
    runs.first['session']
  end

  # PrototypeCapture.schedule knows no scroll op (it is scheduled as a wait),
  # so the scroll target is added to its frame here.
  def mark_scrolls(plan, interactions, fps)
    Array(interactions).each do |op|
      plan.dig(PrototypeCapture.frame_at(op['t_ms'].to_i, fps))&.store('scroll', op['target']) if op['op'] == 'scroll'
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
      @layout = WalkthroughDevice.layout(board, scene)
    end

    def write(runs, out_dir)
      FileUtils.rm_rf(out_dir)
      FileUtils.mkdir_p(out_dir)
      dirs = runs.map { |run| write_jpgs(run, File.join(out_dir, 'jpg', run['name'])) }
      composite!(dirs, out_dir)
      FileUtils.rm_rf(File.join(out_dir, 'jpg'))
      write_tracks(runs, out_dir)
      links = runs.flat_map { |r| Array(r['links']) }.uniq.map { |href| WalkthroughCompose.parse_link(href).merge('href' => href) }
      File.write(File.join(out_dir, 'links.json'), JSON.pretty_generate(@secrets.mask_deep(links)))
      PrototypeUxLint.write(out_dir, @secrets.mask_deep(report(runs)))
      File.write(File.join(out_dir, 'end-state.json'), "null\n")
    end

    private

    def write_jpgs(run, dir)
      FileUtils.mkdir_p(dir)
      run['ticks'].each_with_index do |idx, i|
        File.binwrite(File.join(dir, format('%06d.jpg', i + 1)), Base64.decode64(run['frames'][[ idx, 0 ].max]))
      end
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

      File.write(File.join(out_dir, 'taps.json'), JSON.pretty_generate(WalkthroughDevice.ripple_path(phone, by_name['phone']['cursor'])))
    end

    def report(runs)
      raw = runs.flat_map { |r| Array(r['lint']) } + WalkthroughDevice.frame_findings(@layout)
      overlays = runs.map { |r| r['overlays'] || {} }.reduce({}) { |acc, o| o.merge(acc) }
      PrototypeUxLint.scene_report(@scene['id'], raw, overlays: overlays, devices: runs.flat_map { |r| Array(r['devices']) })
                     .merge('aim' => 'safe', 'live' => true)
    end

    def container(path) = File.join('/work', path.delete_prefix("#{@work}/"))

    # JPEG screencast frames become PNGs on the board canvas in the pinned
    # FFmpeg container, offline.
    def composite!(dirs, out_dir)
      inputs = dirs.flat_map { |d| [ '-start_number', '1', '-i', File.join(container(d), '%06d.jpg') ] }
      args = [ '-hide_banner', '-nostdin', '-y', *inputs, '-filter_complex', WalkthroughDevice.filter(@layout), '-map', '[out]',
               '-start_number', '1', File.join(container(out_dir), '%06d.png') ]
      argv = ChangeDocker.run_command(network: 'none', image: ChangeDocker::FFMPEG_IMAGE, args: args, mounts: { @work => '/work' }, workdir: '/work')
      out, status = @docker.call(argv)
      raise CaptureError, "ffmpeg frame composite failed:\n#{out.to_s.lines.last(10).join}" unless status.success?
    end
  end
end
