#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'change_lane'
require_relative 'change_findings'
require_relative 'change_figma'

# The browserless UX/responsive lane. Loads each route at each configured
# viewport in the shared browserless Chromium container and asserts the baseline
# responsive-health checks a manual multi-viewport pass would look for: the page
# navigated without an error status, and it does not overflow horizontally (a
# body wider than the viewport is the classic responsive break). A navigation
# error or horizontal overflow is a fail; page console errors are a warn.
#
# Two further capabilities layer on top of that baseline, both real (no stubs,
# no bypass logic):
#
# - Authenticated routes: `routes[]` entries can be a mapping with `auth: true`
#   plus a lane-level `auth:` block. The shorthand shape is a single-form login
#   (login url, selectors, credentials read from env vars), still supported and
#   normalized internally into a one-step flow. An explicit `auth.steps:` list
#   supports a login that needs more than one form, the OTP case: submit an
#   email on step one, then submit a code on step two, where that code is
#   resolved live by polling a `code_source.url` reachable on the run network
#   (a Mailpit/MailHog dev inbox API) rather than ever landing in the config or
#   the host environment. The single browserless /function call logs in once,
#   walking every step in the same page, before checking any auth-required
#   route, so the same session cookies carry into the rest of the matrix. A
#   route needing auth is only ever checked authenticated for real; if auth is
#   not configured or a credential is missing, those routes are skipped with a
#   named failing finding rather than silently graded unauthenticated.
# - Figma visual alignment: a route entry's `figma:` block (file key + node id)
#   fetches a rendered reference PNG from the real Figma REST API
#   (ChangeFigma), then diffs it against browserless's own screenshot of that
#   route/viewport using a pure Canvas 2D pixel comparison run inside the same
#   Chromium page (no new dependency: the browserless image already has a real
#   browser canvas, so decode-and-diff happens there rather than in Ruby, which
#   has no image-decoding library in this repo's Gemfile).
#
# This is the deterministic, config-driven counterpart to a prior client's
# apps/e2e/src/smoke.ts / full.ts Playwright-over-CDP harness: same ephemeral
# browserless container, but a fixed responsive/auth/visual-alignment rubric
# across a viewport matrix rather than hand-authored flow assertions.
class ChangeLaneBrowserless < ChangeLane
  # Per-cell timing (F6 step 1): the run's own report reads this after #run to
  # render a timing table, purely additive instrumentation to make real
  # duration data visible before any decision to raise FUNCTION_TIMEOUT_MS or
  # split the scan per viewport is made from measurement instead of a guess.
  attr_reader :timed_cells

  DEFAULT_VIEWPORTS = [
    { 'name' => 'mobile', 'width' => 390, 'height' => 844 },
    { 'name' => 'tablet', 'width' => 768, 'height' => 1024 },
    { 'name' => 'desktop', 'width' => 1440, 'height' => 900 }
  ].freeze

  DEFAULT_EMAIL_SELECTOR = 'input[name="email"]'
  DEFAULT_PASSWORD_SELECTOR = 'input[type="password"]'
  DEFAULT_SUBMIT_SELECTOR = 'button[type="submit"]'
  DEFAULT_TIMEOUT_MS = 15_000
  DEFAULT_MAX_DIFF_PERCENT = 10.0
  DEFAULT_CODE_SOURCE_TIMEOUT_MS = 20_000
  DEFAULT_CODE_SOURCE_POLL_INTERVAL_MS = 1_000

  def run
    session = @context.browserless
    return [ unavailable ] unless session

    findings = []
    entries = route_entries
    auth = auth_config

    auth_ready, auth_finding = resolve_auth(entries, auth)
    findings << auth_finding if auth_finding

    usable = auth_ready ? entries : entries.reject { |e| e[:auth] }
    (entries - usable).each { |entry| findings << auth_skip_finding(entry) }

    figma_refs, figma_findings = resolve_figma_refs(usable)
    findings.concat(figma_findings)

    begin
      result = session.run_function(scan_module(usable, auth_ready ? auth : nil, figma_refs))
      cells(result).each do |check|
        findings << check_finding(check)
        findings << figma_diff_finding(check) if check['figmaDiff']
      end
      @timed_cells = cells(result)
      findings.concat(capture_media(result))
    rescue StandardError => e
      findings << Finding.new(lane: 'browserless', check: 'viewport scan', status: 'fail', severity: 'high',
                               detail: "scan error: #{e.message}")
    end
    findings
  end

  # A Markdown table of #run's own per-cell timing (F6 step 1), or nil when
  # #run has not populated @timed_cells (browserless unavailable, or the
  # scan errored before returning any cell). The run report renders this as
  # an extra section alongside the k6 narrative, so real duration numbers
  # are visible in report output instead of only inferred from a timeout.
  def timing_section
    return nil if timed_cells.nil? || timed_cells.empty?

    lines = [ '### Browserless per-cell timing (ms)', '',
              '| Viewport | Route | Nav | Eval | Screenshot | Total |', '| --- | --- | --- | --- | --- | --- |' ]
    timed_cells.each { |cell| lines << timing_row(cell) }
    lines.join("\n")
  end

  private

  def timing_row(cell)
    ms = ->(field) { cell[field].nil? ? '-' : cell[field].to_i.to_s }
    "| #{cell['viewport']} | #{cell['route']} | #{ms.call('navMs')} | #{ms.call('evalMs')} | " \
      "#{ms.call('shotMs')} | #{ms.call('totalMs')} |"
  end

  def viewports = (@config['viewports'] || DEFAULT_VIEWPORTS)

  # Route entries as a normalized array of { path:, auth:, figma: }. A plain
  # string route is `{ path: it, auth: false, figma: nil }`; a mapping route can
  # add `auth: true` and a `figma: { file_key:, node_id:, viewport: }` block.
  # Overrides the string-only ChangeLane#routes (still available via `routes`,
  # derived below) so the shared redirect-detection helper keeps working
  # unchanged for this lane.
  def route_entries
    list = Array(@config['routes']).map { |item| normalize_route(item) }.reject { |e| e[:path].empty? }
    return list unless list.empty?

    self.class::DEFAULT_ROUTES.map { |path| { path: path, auth: false, figma: nil } }
  end

  def routes = route_entries.map { |e| e[:path] }

  def normalize_route(item)
    if item.is_a?(Hash)
      { path: item['path'].to_s, auth: item['auth'] == true, figma: normalize_figma(item['figma']) }
    else
      { path: item.to_s, auth: false, figma: nil }
    end
  end

  def normalize_figma(figma)
    return nil unless figma.is_a?(Hash)

    file_key = figma['file_key'].to_s
    node_id = figma['node_id'].to_s
    return nil if file_key.empty? || node_id.empty?

    { file_key: file_key, node_id: node_id, viewport: figma['viewport']&.to_s }
  end

  # --- auth -----------------------------------------------------------------

  def auth_config
    raw = @config['auth']
    raw.is_a?(Hash) ? AuthConfig.new(raw) : nil
  end

  # Decides whether the auth-required routes can actually be checked
  # authenticated. Real credentials only: no test-mode bypass header, no fake
  # session. When auth is missing or incomplete, the caller skips just the
  # auth-required routes and this returns a named finding explaining why, per
  # the platform rule that a real blocker is reported, never silently absorbed.
  # A code_source field is not checked here: its value is resolved live inside
  # the browserless container, not on the host, so there is nothing to read
  # from this process's environment; only that its own url is configured.
  def resolve_auth(entries, auth)
    return [ true, nil ] unless entries.any? { |e| e[:auth] }
    return [ false, auth_blocker("route(s) are marked auth: true but lanes.browserless.auth is not configured") ] unless auth

    steps = auth.steps
    return [ false, auth_blocker('auth.login_url is not set') ] if steps.first[:url].to_s.empty?

    detail = missing_auth_field_detail(steps)
    return [ false, auth_blocker(detail) ] if detail

    [ true, nil ]
  end

  def missing_auth_field_detail(steps)
    steps.each do |step|
      step[:fields].each do |field|
        if field[:code_source]
          return "a field's code_source.url is not set (selector #{field[:selector].inspect})" if field[:code_source][:url].empty?
        elsif field[:value].to_s.empty?
          return "auth env var #{field[:env].inspect} (selector #{field[:selector].inspect}) is unset or empty in this process's environment"
        end
      end
    end
    nil
  end

  def auth_blocker(detail)
    Finding.new(lane: 'browserless', check: 'auth login', target: base_url, status: 'fail', severity: 'high',
                detail: "cannot run authenticated checks: #{detail}")
  end

  def auth_skip_finding(entry)
    Finding.new(lane: 'browserless', check: 'auth-required route skipped', target: base_url,
                location: entry[:path], status: 'fail', severity: 'high',
                detail: 'skipped because the login flow could not run; see the "auth login" finding for the reason')
  end

  # --- figma ------------------------------------------------------------------

  def figma_token_env = (@config['figma'] || {}).fetch('token_env', 'FIGMA_ACCESS_TOKEN').to_s
  def figma_token = ENV[figma_token_env].to_s
  def figma_max_diff_percent = Float((@config['figma'] || {}).fetch('max_diff_percent', DEFAULT_MAX_DIFF_PERCENT))

  # Fetches every configured route's Figma reference PNG up front (base64,
  # keyed by route path) so the single browserless call can embed them as
  # literals and diff in-page. A fetch failure (no token, bad file/node id, API
  # error) is a named finding for that route; the route's ordinary responsive
  # checks still run, only the visual diff for it is skipped.
  def resolve_figma_refs(entries)
    refs = {}
    findings = []
    token = figma_token
    entries.each do |entry|
      next unless entry[:figma]

      if token.empty?
        findings << figma_blocker(entry[:path], "no Figma access token: set lanes.browserless.figma.token_env " \
                                                 "(default #{figma_token_env}) in the environment")
        next
      end

      begin
        refs[entry[:path]] = ChangeFigma.fetch_reference_png_base64(
          file_key: entry[:figma][:file_key], node_id: entry[:figma][:node_id], token: token
        )
      rescue ChangeFigma::FigmaError => e
        findings << figma_blocker(entry[:path], e.message)
      end
    end
    [ refs, findings ]
  end

  def figma_blocker(path, detail)
    Finding.new(lane: 'browserless', check: 'figma reference fetch', target: base_url, location: path,
                status: 'fail', severity: 'high', detail: detail)
  end

  # --- grading ----------------------------------------------------------------

  def check_finding(check)
    status, severity, detail = grade(check)
    Finding.new(lane: 'browserless', check: "#{check['viewport']} #{check['width']}x#{check['height']}",
                target: base_url, status: status, severity: severity,
                location: check['route'].to_s, detail: detail)
  end

  def grade(check)
    return [ 'fail', 'high', "navigation error: #{check['error']}" ] if check['error']
    return auth_failed_grade(check) if check['authBlocked']
    return [ 'fail', 'high', "http #{check['httpStatus']}" ] if bad_status?(check['httpStatus'])

    served = redirected_path(check['route'], check['finalUrl'])
    if served
      return [ 'warn', 'low',
               "requested #{check['route']}, redirected to #{served}; the viewport checks reflect that page, not the requested route" ]
    end

    return [ 'fail', 'medium', "horizontal overflow: scrollWidth #{check['scrollWidth']} > #{check['width']}" ] if check['overflow']
    return [ 'warn', 'low', "#{check['consoleErrors']} console error(s)" ] if check['consoleErrors'].to_i.positive?

    [ 'pass', 'info', 'no responsive break' ]
  end

  # When the login flow failed, the route is still navigated (see #run) and
  # its real response is what gets graded here - a bad status is still a
  # fail, reusing the same bad_status? threshold as an ungated route - rather
  # than every auth-required route collapsing into one generic "auth failed"
  # finding without ever being visited. Every branch still names the login
  # failure in its detail so the reader never mistakes an unauthenticated
  # page for the real gated content, mirroring the redirect idiom's "reflects
  # that page, not the requested route" wording.
  def auth_failed_grade(check)
    note = "auth login failed before this route could be reached: #{check['authError']}#{auth_diagnostics_detail(check)}"
    return [ 'fail', 'high', note ] if check['httpStatus'].nil?
    return [ 'fail', 'high', "http #{check['httpStatus']}; #{note}" ] if bad_status?(check['httpStatus'])

    [ 'warn', 'moderate',
      "the viewport checks reflect the page served without a successful login (http #{check['httpStatus']}), " \
      "not the requested gated route; #{note}" ]
  end

  # Renders the auth-failure diagnostics module (F2) captured at the moment
  # the login flow failed - the url it actually landed on, the last
  # main-frame response status, the page title, and a body-text snippet - so
  # a failure reads as a real diagnosis instead of a bare Puppeteer timeout
  # message. The screenshot in the same payload is attached as media
  # evidence (see capture_media), not text, so it is not repeated here.
  def auth_diagnostics_detail(check)
    diag = check['authDiagnostics']
    return '' unless diag.is_a?(Hash)

    parts = []
    parts << "landed on #{diag['url']}" if diag['url'].to_s != ''
    parts << "http #{diag['status']}" if diag['status']
    parts << "title #{diag['title'].to_s.inspect}" if diag['title'].to_s != ''
    parts << "body: #{diag['bodyText'].to_s.inspect}" if diag['bodyText'].to_s != ''
    parts.empty? ? '' : " (#{parts.join(', ')})"
  end

  # Grades the pixel-diff percentage against the configured (or default)
  # threshold. Below the threshold but nonzero is a warn, not a pass: the
  # number is the "iterate until aligned" signal the report should keep
  # surfacing even once it is small enough not to gate, so a rerun after each
  # fix visibly shows it moving toward zero.
  def figma_diff_finding(check)
    diff = check['figmaDiff']
    percent = diff['diffPercent'].to_f
    threshold = figma_max_diff_percent
    status, severity =
      if percent > threshold
        [ 'fail', 'high' ]
      elsif percent.positive?
        [ 'warn', 'low' ]
      else
        [ 'pass', 'info' ]
      end
    detail = format('%.2f%% pixel difference vs the Figma reference (fail above %.1f%%); compared %dx%d ' \
                     '(screenshot %dx%d, reference %dx%d)',
                     percent, threshold, diff['comparedWidth'].to_i, diff['comparedHeight'].to_i,
                     diff['shotWidth'].to_i, diff['shotHeight'].to_i, diff['refWidth'].to_i, diff['refHeight'].to_i)
    Finding.new(lane: 'browserless', check: "#{check['viewport']} figma diff", target: base_url,
                location: check['route'].to_s, status: status, severity: severity, detail: detail)
  end

  def bad_status?(status) = status && status.to_i >= 400

  def unavailable
    Finding.new(lane: 'browserless', check: 'browserless', status: 'fail', severity: 'high',
                detail: 'browserless session unavailable; cannot run viewport checks')
  end

  def resolve_login_url(login_url)
    return login_url if login_url =~ %r{\Ahttps?://}

    "#{base_url}#{login_url.start_with?('/') ? login_url : "/#{login_url}"}"
  end

  # --- media ------------------------------------------------------------------

  # The run's media sink, or nil. A sink exists only when the repo carries a
  # `contributors_team.artifacts:` block, so a repo without one captures
  # nothing and this lane behaves exactly as it did before media existed. The
  # respond_to? guard keeps every existing caller that builds its own lane
  # context (the lane unit tests do) working unchanged.
  def media = @context.respond_to?(:media) ? @context.media : nil

  def capture_screenshots? = !media.nil? && media.screenshots?
  def capture_video? = !media.nil? && media.video?

  # The scan payload's route/viewport cells. The module returns a bare array
  # when nothing is being captured (the shape every prior version returned) and
  # a `{ cells:, videos: }` mapping when it is, so an existing stub or an older
  # module response still reads correctly.
  def cells(result)
    return Array(result['cells']) if result.is_a?(Hash)

    Array(result)
  end

  # Moves the captured base64 out of the scan payload and onto disk, returning
  # a finding only for a recording that failed. A screenshot or a recording is
  # evidence attached to the report, never a gate signal: a missing one is a
  # warn, so an artifact-only problem can never turn a passing audit red.
  def capture_media(result)
    sink = media
    return [] unless sink

    cells(result).each do |cell|
      sink.add_screenshot(viewport: cell['viewport'], route: cell['route'], data: cell['shot']) if cell['shot']
      auth_screenshot = auth_screenshot_for(cell)
      if auth_screenshot
        sink.add_screenshot(viewport: cell['viewport'], route: "#{cell['route']} (auth failure)", data: auth_screenshot)
      end
    end
    videos(result).map { |video| record_video(sink, video) }.compact
  end

  # The auth-failure diagnostic screenshot (F2), captured at the moment the
  # login flow failed, or nil for every ordinary cell.
  def auth_screenshot_for(cell)
    diag = cell['authDiagnostics']
    diag.is_a?(Hash) ? diag['screenshot'] : nil
  end

  def videos(result) = result.is_a?(Hash) ? Array(result['videos']) : []

  def record_video(sink, video)
    sink.add_video(viewport: video['viewport'], data: video['webm'], error: video['error'])
    return nil if video['webm'].to_s != ''

    Finding.new(lane: 'browserless', check: "#{video['viewport']} recording", target: base_url,
                status: 'warn', severity: 'low',
                detail: "no video recorded for this viewport: #{video['error'] || 'unknown reason'}")
  end

  def capture_options
    { screenshots: capture_screenshots?, video: capture_video?, fps: media ? media.video_fps : 0 }
  end

  # --- the browserless module --------------------------------------------------

  # One module walks the viewport-by-route matrix in a single page, so an
  # authenticated login (when configured) happens once and its cookies carry
  # into every later navigation on the same page. For each cell it sets the
  # viewport, navigates, records the response status, counts page console
  # errors, measures horizontal overflow, and (when a Figma reference was
  # fetched for that route/viewport) screenshots and pixel-diffs against it,
  # returning one flat entry per cell.
  #
  # When the run is building a findings artifact (`capture`), the same walk
  # also collects the evidence that artifact renders: a full-page JPEG per
  # cell, and one recording per viewport covering that viewport's entire route
  # walk. The recording is assembled inside Chromium rather than on the host:
  # CDP's `Page.startScreencast` streams live frames of the page being walked,
  # a second page in the same browser draws each frame onto a canvas whose
  # `captureStream()` feeds a `MediaRecorder`, and the resulting WebM comes
  # back base64 in this same response. That indirection is forced, not
  # stylistic: the browserless container shares no filesystem or network path
  # with the host, so a recorder writing a file inside the container would
  # produce a video nothing on the host could ever read.
  def scan_module(entries, auth, figma_refs)
    <<~JS
      export default async function ({ page }) {
        const baseUrl = #{JSON.generate(base_url)};
        const routeEntries = #{JSON.generate(js_route_entries(entries, figma_refs))};
        const viewports = #{JSON.generate(viewports)};
        const auth = #{JSON.generate(js_auth(auth))};
        const figmaRefs = #{JSON.generate(figma_refs)};
        const basicAuth = #{JSON.generate(basic_auth)};
        const capture = #{JSON.generate(capture_options)};
        if (basicAuth) {
          await page.authenticate({ username: basicAuth.username, password: basicAuth.password });
          // page.authenticate() only fires on a WWW-Authenticate challenge,
          // which some gates never send (an ALB fixed-response 401 has no
          // mechanism to set arbitrary response headers - confirmed against
          // terraform/cms_signoz_basic_auth.tf's own "KNOWN GAP" comment).
          // Sending the header unconditionally works regardless of whether
          // the target's 401 carries a real challenge.
          // btoa, not Buffer: this module runs inside browserless's function
          // sandbox, a browser-like context with no Node globals.
          const encoded = btoa(`${basicAuth.username}:${basicAuth.password}`);
          await page.setExtraHTTPHeaders({ Authorization: `Basic ${encoded}` });
        }

        #{recorder_js}

        let authOk = null;
        let authError = null;
        let authDiagnostics = null;
        let lastAuthResponse = null;

        // Polls a code_source url (an HTTP endpoint reachable on the run
        // network, e.g. a Mailpit/MailHog dev inbox API) with Node's own
        // fetch until its body matches, so an out-of-band OTP is read live
        // rather than ever landing in CHANGE.md or the host environment.
        async function resolveCodeSource(codeSource) {
          const deadline = Date.now() + codeSource.timeoutMs;
          let lastErr = null;
          while (Date.now() < deadline) {
            try {
              const res = await fetch(codeSource.url);
              const text = await res.text();
              if (codeSource.pattern) {
                const match = text.match(new RegExp(codeSource.pattern));
                if (match) return match[1] || match[0];
              } else if (text.trim()) {
                return text.trim();
              }
            } catch (err) {
              lastErr = err;
            }
            await new Promise((resolve) => setTimeout(resolve, codeSource.pollIntervalMs));
          }
          throw new Error(
            `code_source did not yield a value within ${codeSource.timeoutMs}ms: ${codeSource.url}` +
              (lastErr ? ` (last error: ${lastErr})` : "")
          );
        }

        async function fillField(field, timeoutMs) {
          await page.waitForSelector(field.selector, { timeout: timeoutMs });
          const value = field.codeSource ? await resolveCodeSource(field.codeSource) : field.value;
          await page.type(field.selector, value);
        }

        async function runAuthStep(step) {
          if (step.url) lastAuthResponse = await page.goto(step.url, { waitUntil: "networkidle2", timeout: step.timeoutMs });
          for (const field of step.fields) await fillField(field, step.timeoutMs);
          if (step.submitSelector) {
            const [navResponse] = await Promise.all([
              page.waitForNavigation({ waitUntil: "networkidle2", timeout: step.timeoutMs }).catch(() => null),
              page.click(step.submitSelector),
            ]);
            if (navResponse) lastAuthResponse = navResponse;
          }
          if (step.waitForSelector) await page.waitForSelector(step.waitForSelector, { timeout: step.timeoutMs });
        }

        // Captures a real diagnosis of an auth failure - the url actually
        // landed on, the last main-frame response status, the page title,
        // and a body-text snippet - so a reader sees why the login failed
        // instead of a bare Puppeteer timeout message. Every read is
        // wrapped so a diagnostics failure (a closed page, a weird DOM)
        // never masks the real auth error it is describing.
        async function captureAuthDiagnostics() {
          const diag = {};
          try { diag.url = page.url(); } catch (err) { diag.url = null; }
          try { diag.status = lastAuthResponse ? lastAuthResponse.status() : null; } catch (err) { diag.status = null; }
          try { diag.title = await page.title(); } catch (err) { diag.title = null; }
          try {
            diag.bodyText = await page.evaluate(() => (document.body ? document.body.innerText : "").slice(0, 500));
          } catch (err) {
            diag.bodyText = null;
          }
          try { diag.screenshot = await page.screenshot({ encoding: "base64" }); } catch (err) { diag.screenshot = null; }
          return diag;
        }

        // Runs every configured step in order, in the same page, so a
        // multi-step login (submit an email, then submit a code from a
        // second form) carries its session cookies from one step into the
        // next exactly as a single-form login always has.
        async function ensureAuth() {
          if (!auth || authOk !== null) return authOk;
          try {
            for (const step of auth.steps) await runAuthStep(step);
            authOk = true;
          } catch (err) {
            authOk = false;
            authError = String(err);
            authDiagnostics = await captureAuthDiagnostics();
          }
          return authOk;
        }

        async function diffAgainstReference(shotBase64, refBase64) {
          return page.evaluate(async (a, b) => {
            function loadImage(base64) {
              return new Promise((resolve, reject) => {
                const img = new Image();
                img.onload = () => resolve(img);
                img.onerror = reject;
                img.src = "data:image/png;base64," + base64;
              });
            }
            function toImageData(img) {
              const canvas = document.createElement("canvas");
              canvas.width = img.width;
              canvas.height = img.height;
              const ctx = canvas.getContext("2d");
              ctx.drawImage(img, 0, 0);
              return { imageData: ctx.getImageData(0, 0, canvas.width, canvas.height), width: canvas.width, height: canvas.height };
            }
            const shotImg = await loadImage(a);
            const refImg = await loadImage(b);
            const shot = toImageData(shotImg);
            const ref = toImageData(refImg);
            const width = Math.min(shot.width, ref.width);
            const height = Math.min(shot.height, ref.height);
            const threshold = 32;
            let diffCount = 0;
            for (let y = 0; y < height; y++) {
              for (let x = 0; x < width; x++) {
                const si = (y * shot.width + x) * 4;
                const ri = (y * ref.width + x) * 4;
                const dr = shot.imageData.data[si] - ref.imageData.data[ri];
                const dg = shot.imageData.data[si + 1] - ref.imageData.data[ri + 1];
                const db = shot.imageData.data[si + 2] - ref.imageData.data[ri + 2];
                if (Math.sqrt(dr * dr + dg * dg + db * db) > threshold) diffCount += 1;
              }
            }
            const totalPixels = width * height;
            return {
              diffPercent: totalPixels ? (diffCount / totalPixels) * 100 : 100,
              comparedWidth: width,
              comparedHeight: height,
              shotWidth: shot.width,
              shotHeight: shot.height,
              refWidth: ref.width,
              refHeight: ref.height,
            };
          }, shotBase64, refBase64);
        }

        const out = [];
        const videos = [];
        for (const vp of viewports) {
          const recorder = await startRecording(vp);
          for (const entry of routeEntries) {
            const cell = { viewport: vp.name, width: vp.width, height: vp.height, route: entry.path };
            if (entry.auth) {
              const ok = await ensureAuth();
              if (!ok) {
                // Still navigated below and graded on its real response
                // (F3): an auth-required route no longer collapses into an
                // identical generic finding for every route without ever
                // being visited.
                cell.authBlocked = true;
                cell.authError = authError;
                cell.authDiagnostics = authDiagnostics;
              }
            }
            let consoleErrors = 0;
            const onError = (msg) => { if (msg.type() === "error") consoleErrors += 1; };
            page.on("console", onError);
            // F6 step 1: lightweight Date.now() deltas around this cell's
            // three real costs, purely additive instrumentation so a future
            // decision to raise FUNCTION_TIMEOUT_MS or split the scan per
            // viewport can be made from real numbers instead of a guess.
            const cellStart = Date.now();
            try {
              await page.setViewport({ width: vp.width, height: vp.height });
              const navStart = Date.now();
              const resp = await page.goto(baseUrl + entry.path, { waitUntil: "networkidle2", timeout: 30000 });
              cell.navMs = Date.now() - navStart;
              cell.httpStatus = resp ? resp.status() : null;
              cell.finalUrl = page.url();
              const evalStart = Date.now();
              const scrollWidth = await page.evaluate(() => document.documentElement.scrollWidth);
              cell.evalMs = Date.now() - evalStart;
              cell.scrollWidth = scrollWidth;
              cell.overflow = scrollWidth > vp.width + 1;
              cell.consoleErrors = consoleErrors;

              // Suppressed for an auth-failed cell (F3): the screenshot is
              // of the wrong (unauthenticated) page, so a pixel diff
              // against the gated route's Figma reference would be
              // meaningless noise, not a real design-alignment signal.
              const refBase64 = !cell.authBlocked && entry.figmaViewport === vp.name ? figmaRefs[entry.path] : null;
              if (refBase64) {
                const shotBase64 = await page.screenshot({ encoding: "base64" });
                cell.figmaDiff = await diffAgainstReference(shotBase64, refBase64);
              }
              if (capture.screenshots) {
                const shotStart = Date.now();
                cell.shot = await page.screenshot({ encoding: "base64", type: "jpeg", quality: 72, fullPage: true });
                cell.shotMs = Date.now() - shotStart;
              }
            } catch (err) {
              cell.error = String(err);
            } finally {
              page.off("console", onError);
            }
            cell.totalMs = Date.now() - cellStart;
            out.push(cell);
          }
          const video = await stopRecording(recorder, vp);
          if (video) videos.push(video);
        }
        return { data: { cells: out, videos: videos }, type: "application/json" };
      }
    JS
  end

  # The in-Chromium recorder, injected into the scan module above.
  #
  # `startRecording` opens a second page in the same browser, gives it a canvas
  # fed to a MediaRecorder, and attaches a CDP screencast on the page actually
  # being walked; every screencast frame is drawn onto that canvas, so the
  # recording is a real moving picture of the route walk rather than a slide
  # show assembled after the fact. `stopRecording` stops both ends and returns
  # the WebM base64.
  #
  # Every failure path here is caught and reported as a per-viewport `error`
  # string rather than thrown: a browser that cannot record (no MediaRecorder,
  # a screencast that never attaches) must not take down an audit run whose
  # actual job is the findings.
  def recorder_js
    <<~JS
      async function startRecording(vp) {
        if (!capture.video) return null;
        try {
          const recorderPage = await page.browser().newPage();
          await recorderPage.setViewport({ width: vp.width, height: vp.height });
          await recorderPage.setContent(#{JSON.generate(recorder_page_html)});
          await recorderPage.evaluate((w, h, fps) => window.__cfStart(w, h, fps), vp.width, vp.height, capture.fps);
          const client = await page.createCDPSession();
          const state = { page: recorderPage, client: client, stopped: false, error: null };
          client.on("Page.screencastFrame", async (frame) => {
            if (state.stopped) return;
            try {
              await recorderPage.evaluate((data) => window.__cfPush(data), frame.data);
            } catch (err) {
              state.error = String(err);
            }
            try {
              await client.send("Page.screencastFrameAck", { sessionId: frame.sessionId });
            } catch (err) {
              state.error = String(err);
            }
          });
          await client.send("Page.startScreencast", {
            format: "jpeg",
            quality: 60,
            maxWidth: vp.width,
            maxHeight: vp.height,
            everyNthFrame: 1,
          });
          return state;
        } catch (err) {
          return { page: null, client: null, stopped: true, error: String(err) };
        }
      }

      async function stopRecording(state, vp) {
        if (!capture.video) return null;
        if (!state) return { viewport: vp.name, error: "recording was not started" };
        state.stopped = true;
        try {
          if (state.client) {
            await state.client.send("Page.stopScreencast");
            await state.client.detach();
          }
          if (!state.page) return { viewport: vp.name, error: state.error || "no recorder page" };
          const webm = await state.page.evaluate(() => window.__cfStop());
          await state.page.close();
          if (!webm) return { viewport: vp.name, error: state.error || "recorder produced no data" };
          return { viewport: vp.name, webm: webm };
        } catch (err) {
          try { if (state.page) await state.page.close(); } catch (closeErr) { void closeErr; }
          return { viewport: vp.name, error: String(err) };
        }
      }
    JS
  end

  # The recorder page: a canvas, a MediaRecorder over its captured stream, and
  # the three globals the module drives it with. Self-contained and asset-free
  # (no remote font, no CDN script), so it renders identically wherever the
  # browserless image runs.
  def recorder_page_html
    <<~HTML
      <!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;background:#000}</style></head>
      <body><canvas id="cf-canvas"></canvas><script>
        let ctx = null, recorder = null, chunks = [], queue = Promise.resolve();
        window.__cfStart = function (width, height, fps) {
          const canvas = document.getElementById("cf-canvas");
          canvas.width = width;
          canvas.height = height;
          ctx = canvas.getContext("2d");
          ctx.fillStyle = "#000";
          ctx.fillRect(0, 0, width, height);
          const stream = canvas.captureStream(fps);
          const preferred = "video/webm;codecs=vp9";
          const mimeType = window.MediaRecorder && MediaRecorder.isTypeSupported(preferred) ? preferred : "video/webm";
          recorder = new MediaRecorder(stream, { mimeType: mimeType });
          chunks = [];
          recorder.ondataavailable = function (event) { if (event.data && event.data.size) chunks.push(event.data); };
          recorder.start(1000);
          return true;
        };
        window.__cfPush = function (base64) {
          queue = queue.then(function () {
            return new Promise(function (resolve) {
              const image = new Image();
              image.onload = function () {
                const canvas = ctx.canvas;
                const scale = Math.min(canvas.width / image.width, canvas.height / image.height);
                const width = image.width * scale;
                const height = image.height * scale;
                ctx.fillStyle = "#000";
                ctx.fillRect(0, 0, canvas.width, canvas.height);
                ctx.drawImage(image, (canvas.width - width) / 2, 0, width, height);
                resolve();
              };
              image.onerror = function () { resolve(); };
              image.src = "data:image/jpeg;base64," + base64;
            });
          });
          return queue;
        };
        window.__cfStop = function () {
          if (!recorder) return Promise.resolve(null);
          return queue.then(function () {
            return new Promise(function (resolve) {
              recorder.onstop = function () {
                const blob = new Blob(chunks, { type: recorder.mimeType });
                const reader = new FileReader();
                reader.onloadend = function () { resolve(String(reader.result).split(",")[1] || null); };
                reader.onerror = function () { resolve(null); };
                reader.readAsDataURL(blob);
              };
              recorder.stop();
            });
          });
        };
      </script></body></html>
    HTML
  end

  def js_route_entries(entries, figma_refs)
    entries.map do |e|
      figma_viewport = e[:figma] && figma_refs.key?(e[:path]) ? (e[:figma][:viewport] || viewports.first['name']) : nil
      { path: e[:path], auth: e[:auth], figmaViewport: figma_viewport }
    end
  end

  def js_auth(auth)
    return nil unless auth

    { steps: auth.steps.map { |step| js_step(step) } }
  end

  def js_step(step)
    {
      url: step[:url] && !step[:url].empty? ? resolve_login_url(step[:url]) : nil,
      fields: step[:fields].map { |field| js_field(field) },
      submitSelector: step[:submit_selector],
      waitForSelector: step[:wait_for_selector],
      timeoutMs: step[:timeout_ms]
    }
  end

  def js_field(field)
    return { selector: field[:selector], codeSource: js_code_source(field[:code_source]) } if field[:code_source]

    { selector: field[:selector], value: field[:value].to_s }
  end

  def js_code_source(code_source)
    {
      url: code_source[:url],
      pattern: code_source[:pattern],
      timeoutMs: code_source[:timeout_ms],
      pollIntervalMs: code_source[:poll_interval_ms]
    }
  end

  # Typed view over the lane's `auth:` block. Two shapes: the original
  # single-form login (`login_url`/`email_env`/`password_env`/selectors),
  # normalized here into a one-step `steps` list so the rest of the lane
  # never branches on which shape a project used; or an explicit multi-step
  # `steps:` list for a login that needs more than one form (an OTP flow:
  # submit an email, then submit a code from a second form).
  #
  # A field's value comes from one of two places, and every field carries at
  # most one: `env` names an environment variable read on the host, exactly
  # like the legacy shape (never a raw secret literal in CHANGE.md itself); a
  # `code_source` is resolved live, in the browserless container, by polling
  # an HTTP endpoint reachable on the run network (e.g. a Mailpit/MailHog dev
  # inbox API) until a value matches, so an out-of-band OTP is never read,
  # stored, or logged on the host at all. Resolving it in-page rather than on
  # the host is a real architectural constraint, not a style choice: the
  # login session lives entirely inside one browserless /function call and
  # its one Puppeteer `page`, so a step that needs the code has to fetch it
  # from the same running page rather than pausing for a second, separate
  # host-to-container call that would lose that page and its cookies.
  class AuthConfig
    def initialize(raw) = @raw = raw

    def login_url = @raw['login_url'].to_s
    def email_env_name = @raw['email_env'].to_s
    def password_env_name = @raw['password_env'].to_s
    def email = ENV[email_env_name].to_s
    def password = ENV[password_env_name].to_s
    def email_selector = (@raw['email_selector'] || DEFAULT_EMAIL_SELECTOR).to_s
    def password_selector = (@raw['password_selector'] || DEFAULT_PASSWORD_SELECTOR).to_s
    def submit_selector = (@raw['submit_selector'] || DEFAULT_SUBMIT_SELECTOR).to_s
    def wait_for_selector = @raw['wait_for_selector']&.to_s
    def timeout_ms = Integer(@raw['timeout_ms'] || DEFAULT_TIMEOUT_MS)

    # The login as an ordered list of steps, each `{ url:, fields:, submit_selector:,
    # wait_for_selector:, timeout_ms: }`. Built from `steps:` when present,
    # else synthesized as a single step from the legacy top-level fields so
    # every existing CHANGE.md keeps behaving exactly as it did.
    def steps
      raw_steps = @raw['steps']
      return raw_steps.map { |step| normalize_step(step) } if raw_steps.is_a?(Array) && !raw_steps.empty?

      [ legacy_step ]
    end

    private

    def legacy_step
      {
        url: login_url,
        fields: [
          { selector: email_selector, env: email_env_name, value: email, code_source: nil },
          { selector: password_selector, env: password_env_name, value: password, code_source: nil }
        ],
        submit_selector: submit_selector,
        wait_for_selector: wait_for_selector,
        timeout_ms: timeout_ms
      }
    end

    def normalize_step(raw_step)
      {
        url: raw_step['url']&.to_s,
        fields: Array(raw_step['fields']).map { |field| normalize_field(field) },
        submit_selector: (raw_step['submit_selector'] || DEFAULT_SUBMIT_SELECTOR).to_s,
        wait_for_selector: raw_step['wait_for_selector']&.to_s,
        timeout_ms: Integer(raw_step['timeout_ms'] || DEFAULT_TIMEOUT_MS)
      }
    end

    def normalize_field(raw_field)
      code_source = raw_field['code_source']
      env_name = raw_field['env']&.to_s
      {
        selector: raw_field['selector'].to_s,
        env: env_name,
        value: env_name ? ENV[env_name].to_s : nil,
        code_source: code_source.is_a?(Hash) ? normalize_code_source(code_source) : nil
      }
    end

    def normalize_code_source(raw)
      {
        url: raw['url'].to_s,
        pattern: raw['pattern']&.to_s,
        timeout_ms: Integer(raw['timeout_ms'] || DEFAULT_CODE_SOURCE_TIMEOUT_MS),
        poll_interval_ms: Integer(raw['poll_interval_ms'] || DEFAULT_CODE_SOURCE_POLL_INTERVAL_MS)
      }
    end
  end
end
