#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'change_flow_selector'

# Compiles a declarative list of browser steps into one browserless /function
# payload. Pure Ruby, deterministic, and it never calls an LLM: the same steps
# at the same commit compile to the same JS, so a browser check is a fact that
# can be repeated rather than a script re-derived from scratch on every run.
#
# This is an extraction, not an invention. The browserless lane already carried
# a declarative multi-step flow compiled to JS: `browserless.auth.steps[]`, with
# a field's value coming from an env var or from a `code_source` polled live
# inside the container. That compiler and its JS runtime moved here verbatim
# (`compile_auth`, `auth_runtime_js`), so the lane's login behaves exactly as
# it did, and the general vocabulary below grew around it.
#
# Two entry points, deliberately distinct:
#
# - `ChangeFlowCompiler.compile_auth(steps, base_url:)` is the login flow the
#   browserless lane has always emitted, in the shape its runtime has always
#   consumed. Its output is a compatibility contract, not a design.
# - `ChangeFlowCompiler.new(steps, base_url:)` is the general vocabulary:
#   actions `goto`, `click`, `fill`, `select`, `press`, `wait_for`,
#   `screenshot`, `capture`; assertions `expect_visible`, `expect_hidden`,
#   `expect_text`, `expect_url`, `expect_status`, `expect_count`,
#   `expect_equal`; and `eval` as an escape hatch for raw JS. Any selector
#   may use the text/nth forms ChangeFlowSelector parses.
#
# `eval` is supported and marked. A compiled `eval` step carries `raw: true`
# and a label naming it as raw JS, so a report can show a reader exactly where
# the declarative contract was abandoned instead of presenting hand-written JS
# as though it were a checked assertion.
#
# Secrets: a `fill` whose value comes from `env` reads that value on the host
# and it reaches the container, because that is the only place it can be typed
# into a form. It must never travel anywhere else. `#redacted` is the only
# shape that may be written to a report, a log, or a payload dump; `#compile`
# and `#function_module` carry real credentials and are for the container
# alone. A `code_source` value is never read on the host at all: only its url
# is compiled, and the runtime polls it from inside the container.
class ChangeFlowCompiler
  Error = Class.new(StandardError)

  REDACTED = '[redacted]'
  DEFAULT_TIMEOUT_MS = 15_000
  DEFAULT_CODE_SOURCE_TIMEOUT_MS = 20_000
  DEFAULT_CODE_SOURCE_POLL_INTERVAL_MS = 1_000
  DEFAULT_WAIT_UNTIL = 'domcontentloaded'

  ACTIONS = %w[goto click fill select press wait_for screenshot capture].freeze
  ASSERTIONS = %w[expect_visible expect_hidden expect_text expect_url expect_status expect_count
                  expect_equal].freeze
  ESCAPE_HATCH = 'eval'
  VERBS = (ACTIONS + ASSERTIONS + [ ESCAPE_HATCH ]).freeze

  # Every compiled step carries a `verb` in this camelCase runtime spelling, so
  # the JS runtime switches on one token while the flow file keeps snake_case.
  RUNTIME_VERBS = VERBS.to_h { |verb| [ verb, verb.gsub(/_(.)/) { Regexp.last_match(1).upcase } ] }.freeze

  # Step-level keys that are options rather than the verb itself.
  OPTION_KEYS = %w[timeout_ms].freeze

  # What capture and expect_equal read from a selector.
  READ_KINDS = %w[text number count].freeze
  VAR_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

  # --- the JS runtime ---------------------------------------------------------

  # Polls a code_source url until its body matches. Shared by the auth flow and
  # the general vocabulary, because an OTP is an OTP whichever one asked for it.
  CODE_SOURCE_JS = <<~JS
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
  JS

  # The auth flow's runtime, moved here from the browserless lane unchanged. It
  # takes the lane's `session` (its own page plus the last main-frame response)
  # rather than a bare page, because the lane's auth diagnostics read that
  # response when a login fails.
  AUTH_JS = <<~JS
    async function fillField(session, field, timeoutMs) {
      await session.page.waitForSelector(field.selector, { timeout: timeoutMs });
      const value = field.codeSource ? await resolveCodeSource(field.codeSource) : field.value;
      await session.page.type(field.selector, value);
    }

    async function runAuthStep(session, step) {
      if (step.url) {
        session.lastAuthResponse = await session.page.goto(step.url, { waitUntil: "domcontentloaded", timeout: step.timeoutMs });
      }
      for (const field of step.fields) await fillField(session, field, step.timeoutMs);
      if (step.submitSelector) {
        const [navResponse] = await Promise.all([
          session.page.waitForNavigation({ waitUntil: "domcontentloaded", timeout: step.timeoutMs }).catch(() => null),
          session.page.click(step.submitSelector),
        ]);
        if (navResponse) session.lastAuthResponse = navResponse;
      }
      if (step.waitForSelector) await session.page.waitForSelector(step.waitForSelector, { timeout: step.timeoutMs });
    }
  JS

  # The general vocabulary's runtime. One switch, one record per step, and the
  # walk stops at the first failing step: everything after a failed assertion
  # runs against a page that is no longer in the state the flow described, so
  # continuing would report noise as evidence.
  FLOW_JS = <<~JS
    function cfFail(message) { throw new Error(message); }

    // Resolves a compiled text/nth locator (see ChangeFlowSelector) inside
    // the page. Self-contained, because Puppeteer serializes it into the page.
    // mode is one of "attached", "visible", "hidden", "count".
    const cfLocate = (loc, mode) => {
      const norm = (s) => String(s || "").replace(/\\s+/g, " ").trim();
      const textOf = (el) => norm(el.innerText || el.textContent);
      let els = Array.from(document.querySelectorAll(loc.css || "*"));
      if (loc.textIs !== null) els = els.filter((el) => textOf(el) === loc.textIs);
      if (loc.hasText !== null) els = els.filter((el) => textOf(el).indexOf(loc.hasText) !== -1);
      if (!loc.css) els = els.filter((el) => !els.some((other) => other !== el && el.contains(other)));
      const picked = loc.nth === null ? els[0] : els[loc.nth < 0 ? els.length + loc.nth : loc.nth];
      if (mode === "count") return loc.nth === null ? els.length : (picked ? 1 : 0);
      const visible = (el) => {
        const style = getComputedStyle(el);
        const rect = el.getBoundingClientRect();
        return style.visibility !== "hidden" && style.display !== "none" && rect.width > 0 && rect.height > 0;
      };
      if (mode === "hidden") return !picked || !visible(picked);
      if (!picked) return null;
      if (mode === "visible" && !visible(picked)) return null;
      return picked;
    };

    // Waits for a step's target: through Puppeteer's own selector engine for
    // a plain selector, through cfLocate for a text/nth one. Returns the
    // element handle, or null for mode "hidden".
    async function cfWait(page, step, timeoutMs, mode = "attached") {
      if (!step.locator) {
        const options = { timeout: timeoutMs };
        if (mode === "visible") options.visible = true;
        if (mode === "hidden") options.hidden = true;
        return page.waitForSelector(step.selector, options);
      }
      const handle = await page.waitForFunction(cfLocate, { timeout: timeoutMs }, step.locator, mode);
      return mode === "hidden" ? null : handle.asElement();
    }

    async function cfCount(page, step) {
      if (step.locator) return page.evaluate(cfLocate, step.locator, "count");
      return page.$$eval(step.selector, (els) => els.length);
    }

    async function cfText(page, step, timeoutMs) {
      const el = await cfWait(page, step, timeoutMs);
      return el.evaluate((node) => (node.innerText || node.textContent || "").trim());
    }

    // Reads a value for capture and expect_equal: the element's text, the
    // first number in that text, or the count of matching elements.
    async function cfRead(page, step, timeoutMs) {
      if (step.kind === "count") return cfCount(page, step);
      const text = await cfText(page, step, timeoutMs);
      if (step.kind === "text") return text;
      const match = text.replace(/,/g, "").match(/-?\\d+(\\.\\d+)?/);
      if (!match) cfFail(`expected a number in the text of ${step.selector}, found ${JSON.stringify(text)}`);
      return Number(match[0]);
    }

    function cfVar(state, name) {
      if (!Object.prototype.hasOwnProperty.call(state.vars, name)) cfFail(`variable ${name} was never captured`);
      return state.vars[name];
    }

    // A step-level viewport applies to this capture only; the flow's own
    // viewport is restored after it.
    async function cfScreenshot(page, step) {
      const previous = step.viewport ? page.viewport() : null;
      if (step.viewport) await page.setViewport(step.viewport);
      try {
        return { screenshot: await page.screenshot({ encoding: "base64", fullPage: step.fullPage === true }), name: step.name };
      } finally {
        if (previous) await page.setViewport(previous);
      }
    }

    async function cfRunStep(page, step, state) {
      const timeout = step.timeoutMs;
      switch (step.verb) {
        case "goto":
          state.lastResponse = await page.goto(step.url, { waitUntil: step.waitUntil, timeout: timeout });
          return null;
        case "click":
          await (await cfWait(page, step, timeout)).click();
          return null;
        case "fill": {
          const el = await cfWait(page, step, timeout);
          const value = step.codeSource ? await resolveCodeSource(step.codeSource) : step.value;
          await el.type(value);
          return null;
        }
        case "select":
          await (await cfWait(page, step, timeout)).select(step.value);
          return null;
        case "press":
          if (step.selector) await (await cfWait(page, step, timeout)).focus();
          await page.keyboard.press(step.key);
          return null;
        case "waitFor":
          if (step.selector) await cfWait(page, step, timeout);
          else if (step.urlContains) {
            await page.waitForFunction((needle) => window.location.href.indexOf(needle) !== -1, { timeout: timeout }, step.urlContains);
          } else {
            const response = await page.waitForNavigation({ waitUntil: step.state, timeout: timeout });
            if (response) state.lastResponse = response;
          }
          return null;
        case "screenshot":
          return cfScreenshot(page, step);
        case "capture": {
          const value = await cfRead(page, step, timeout);
          state.vars[step.as] = value;
          return { captured: step.as, found: value };
        }
        case "expectVisible":
          await cfWait(page, step, timeout, "visible");
          return null;
        case "expectHidden":
          await cfWait(page, step, timeout, "hidden");
          return null;
        case "expectText": {
          const text = await cfText(page, step, timeout);
          if (step.equals !== null && text !== step.equals) cfFail(`expected text ${JSON.stringify(step.equals)}, found ${JSON.stringify(text)}`);
          if (step.contains !== null && text.indexOf(step.contains) === -1) cfFail(`expected text containing ${JSON.stringify(step.contains)}, found ${JSON.stringify(text)}`);
          return { found: text };
        }
        case "expectUrl": {
          const url = page.url();
          if (step.equals !== null && url !== step.equals) cfFail(`expected url ${JSON.stringify(step.equals)}, found ${JSON.stringify(url)}`);
          if (step.contains !== null && url.indexOf(step.contains) === -1) cfFail(`expected url containing ${JSON.stringify(step.contains)}, found ${JSON.stringify(url)}`);
          return { found: url };
        }
        case "expectStatus": {
          if (!state.lastResponse) cfFail("expect_status has no navigation response to read; the flow never performed a goto");
          const status = state.lastResponse.status();
          if (status !== step.equals) cfFail(`expected status ${step.equals}, found ${status}`);
          return { found: status };
        }
        case "expectCount": {
          const count = await cfCount(page, step);
          if (count !== step.equals) cfFail(`expected ${step.equals} element(s) matching ${step.selector}, found ${count}`);
          return { found: count };
        }
        case "expectEqual": {
          const expected = cfVar(state, step.var);
          const actual = step.equalsVar !== null ? cfVar(state, step.equalsVar) : await cfRead(page, step, timeout);
          const source = step.equalsVar !== null ? step.equalsVar : step.selector;
          if (String(actual) !== String(expected)) cfFail(`expected ${source} = ${JSON.stringify(actual)} to equal ${step.var} = ${JSON.stringify(expected)}`);
          return { found: actual, expected: expected };
        }
        case "eval":
          return { value: await page.evaluate("(async () => {" + step.script + "})()") };
        default:
          return cfFail("unknown flow verb: " + step.verb);
      }
    }

    async function cfRunFlow(page, steps) {
      const state = { lastResponse: null, vars: {} };
      const results = [];
      for (const step of steps) {
        const record = { index: step.index, verb: step.verb, label: step.label, raw: step.raw === true, ok: true, error: null };
        try {
          const detail = await cfRunStep(page, step, state);
          if (detail) Object.assign(record, detail);
        } catch (err) {
          record.ok = false;
          record.error = String(err);
        }
        results.push(record);
        if (!record.ok) break;
      }
      return results;
    }
  JS

  # --- the auth flow (extracted verbatim from ChangeLaneBrowserless) ----------

  class << self
    def auth_runtime_js = [ CODE_SOURCE_JS, AUTH_JS ].join("\n")

    def flow_runtime_js = [ CODE_SOURCE_JS, FLOW_JS ].join("\n")

    # Both runtimes in one module, for a lane that logs in and then walks a
    # declarative flow in the same page (the testcases lane). Emitting
    # `auth_runtime_js` and `flow_runtime_js` side by side would declare
    # `resolveCodeSource` twice, which an ES module rejects outright, so the
    # shared helper is emitted once here instead.
    def auth_and_flow_runtime_js = [ CODE_SOURCE_JS, AUTH_JS, FLOW_JS ].join("\n")

    # A login url in the config may be absolute or site-relative; the lane has
    # always resolved a relative one against the target's base url.
    def absolute_url(url, base_url)
      return url.to_s if url.to_s =~ %r{\Ahttps?://}

      path = url.to_s
      "#{base_url}#{path.start_with?('/') ? path : "/#{path}"}"
    end

    # The browserless lane's `auth:` block, already normalized by its own
    # AuthConfig into `{ url:, fields:, submit_selector:, wait_for_selector:,
    # timeout_ms: }` steps, compiled into the payload its runtime consumes.
    # Exactly the shape the lane emitted before this file existed.
    def compile_auth(steps, base_url:)
      return nil unless steps

      { steps: steps.map { |step| compile_auth_step(step, base_url) } }
    end

    def compile_auth_step(step, base_url)
      {
        url: step[:url] && !step[:url].empty? ? absolute_url(step[:url], base_url) : nil,
        fields: step[:fields].map { |field| compile_auth_field(field) },
        submitSelector: step[:submit_selector],
        waitForSelector: step[:wait_for_selector],
        timeoutMs: step[:timeout_ms]
      }
    end

    def compile_auth_field(field)
      return { selector: field[:selector], codeSource: compile_code_source(field[:code_source]) } if field[:code_source]

      { selector: field[:selector], value: field[:value].to_s }
    end

    def compile_code_source(code_source)
      {
        url: code_source[:url],
        pattern: code_source[:pattern],
        timeoutMs: code_source[:timeout_ms],
        pollIntervalMs: code_source[:poll_interval_ms]
      }
    end
  end

  # --- the general vocabulary -------------------------------------------------

  attr_reader :base_url, :timeout_ms

  # `viewport` ({ width:, height: }) sizes the page before the first step;
  # without it the page keeps Puppeteer's default.
  def initialize(steps, base_url: nil, timeout_ms: DEFAULT_TIMEOUT_MS, viewport: nil, env: ENV)
    @raw_steps = Array(steps)
    @base_url = base_url.to_s
    @timeout_ms = Integer(timeout_ms)
    @viewport = viewport && compile_viewport(viewport, 'flow')
    @env = env
  end

  # The compiled steps, credentials included. Hand this to the container and
  # nowhere else.
  def compile
    @compile ||= begin
      captured = []
      @raw_steps.each_with_index.map do |raw, index|
        step = compile_step(raw, index, captured.dup)
        captured << step[:as] if step[:verb] == 'capture'
        step
      end
    end
  end

  # The only shape that may be written to a report, a log, or a dump: every
  # value that came from an env var is replaced by a fixed marker, so a
  # password cannot ride a compiled-payload dump into an artifact.
  def redacted = compile.map { |step| step[:secret] ? step.merge(value: REDACTED) : step }

  # A pretty JSON dump of the redacted steps, for a report or a review.
  def dump = JSON.pretty_generate(redacted)

  def labels = compile.map { |step| step[:label] }

  def eval_steps = compile.select { |step| step[:raw] }

  def uses_eval? = eval_steps.any?

  # One browserless /function module running the whole flow and returning a
  # per-step result record. Carries real credentials: never log it.
  def function_module
    <<~JS
      #{self.class.flow_runtime_js}
      export default async ({ page }) => {
        const steps = #{JSON.generate(compile)};
        const viewport = #{JSON.generate(@viewport)};
        if (viewport) await page.setViewport(viewport);
        const results = await cfRunFlow(page, steps);
        return { data: { steps: results }, type: "application/json" };
      };
    JS
  end

  private

  # `captured` names the variables earlier steps captured, so expect_equal can
  # refuse one that nothing set.
  def compile_step(raw, index, captured)
    verb, value, timeout = split_step(raw, index)
    compiled = with_locator(send(:"compile_#{verb}", value, captured))
    compiled.merge(verb: RUNTIME_VERBS.fetch(verb), index: index, timeoutMs: Integer(timeout || @timeout_ms))
  end

  # A text/nth selector carries a locator the runtime resolves in the page; a
  # plain one carries none, so its compiled step is unchanged.
  def with_locator(compiled)
    return compiled unless compiled[:selector]

    locator = ChangeFlowSelector.locator(compiled[:selector])
    locator ? compiled.merge(locator: locator) : compiled
  rescue ChangeFlowSelector::Error => e
    raise Error, e.message
  end

  # A step is a mapping carrying exactly one verb key, plus optional
  # step-level options. Two verbs in one mapping is an authoring mistake with
  # no defensible ordering, so it is refused rather than silently resolved.
  def split_step(raw, index)
    raise Error, "step #{index + 1} must be a mapping, got #{raw.class}" unless raw.is_a?(Hash)

    keyed = raw.to_h { |key, value| [ key.to_s, value ] }
    verbs = keyed.keys & VERBS
    unknown = keyed.keys - VERBS - OPTION_KEYS
    raise Error, "step #{index + 1} has unknown key(s): #{unknown.sort.join(', ')}" if unknown.any?
    raise Error, "step #{index + 1} names no known verb (expected one of: #{VERBS.join(', ')})" if verbs.empty?
    raise Error, "step #{index + 1} names more than one verb: #{verbs.sort.join(', ')}" if verbs.size > 1

    value = keyed.fetch(verbs.first)
    [ verbs.first, value, keyed['timeout_ms'] || inner_timeout(value) ]
  end

  # A step-level `timeout_ms` wins over one inside the verb's own mapping
  # (`wait_for: { selector:, timeout_ms: }`); the flow default comes last.
  def inner_timeout(value)
    return nil unless value.is_a?(Hash)

    value['timeout_ms']
  end

  # --- actions ---------------------------------------------------------------

  def compile_goto(value, _captured)
    spec = spec_for(value, 'url')
    url = self.class.absolute_url(require_string(spec, 'url', 'goto'), @base_url)
    { url: url, waitUntil: (spec['wait_until'] || DEFAULT_WAIT_UNTIL).to_s, label: "goto #{url}" }
  end

  def compile_click(value, _captured)
    selector = selector_for(value, 'click')
    { selector: selector, label: "click #{selector}" }
  end

  # The one step that can carry a secret. Exactly one value source: an env var
  # read on the host, a literal already visible in the flow file, or a
  # code_source resolved inside the container.
  def compile_fill(value, _captured)
    spec = spec_for(value, 'selector')
    selector = require_string(spec, 'selector', 'fill')
    sources = spec.slice('env', 'value', 'code_source').keys
    raise Error, "fill #{selector} needs one of env, value, or code_source" if sources.empty?
    raise Error, "fill #{selector} names more than one value source: #{sources.sort.join(', ')}" if sources.size > 1

    fill_source(selector, spec)
  end

  def fill_source(selector, spec)
    if spec['code_source']
      source = flow_code_source(spec['code_source'], selector)
      return { selector: selector, codeSource: source, label: "fill #{selector} from code_source #{source[:url]}" }
    end
    if spec.key?('env')
      name = spec['env'].to_s
      return { selector: selector, value: @env[name].to_s, secret: true, label: "fill #{selector} from env #{name}" }
    end

    { selector: selector, value: spec['value'].to_s, label: "fill #{selector} with #{spec['value'].to_s.inspect}" }
  end

  def flow_code_source(raw, selector)
    raise Error, "fill #{selector} code_source must be a mapping" unless raw.is_a?(Hash)

    spec = raw.to_h { |key, value| [ key.to_s, value ] }
    raise Error, "fill #{selector} code_source.url is not set" if spec['url'].to_s.empty?

    {
      url: spec['url'].to_s,
      pattern: spec['pattern']&.to_s,
      timeoutMs: Integer(spec['timeout_ms'] || DEFAULT_CODE_SOURCE_TIMEOUT_MS),
      pollIntervalMs: Integer(spec['poll_interval_ms'] || DEFAULT_CODE_SOURCE_POLL_INTERVAL_MS)
    }
  end

  def compile_select(value, _captured)
    spec = spec_for(value, 'selector')
    selector = require_string(spec, 'selector', 'select')
    raise Error, "select #{selector} needs a value" unless spec.key?('value')

    option = spec['value'].to_s
    { selector: selector, value: option, label: "select #{option.inspect} in #{selector}" }
  end

  def compile_press(value, _captured)
    spec = spec_for(value, 'key')
    key = require_string(spec, 'key', 'press')
    selector = spec['selector']&.to_s
    { key: key, selector: selector, label: selector ? "press #{key} in #{selector}" : "press #{key}" }
  end

  # The readiness contract in step form: wait for a selector, for the url to
  # contain a fragment, or for a navigation to reach a load state. The wait is
  # the contract; the timeout is only the failure mode.
  def compile_wait_for(value, _captured)
    spec = spec_for(value, 'selector')
    conditions = spec.slice('selector', 'url_contains', 'state').keys
    raise Error, 'wait_for needs one of selector, url_contains, or state' if conditions.empty?
    raise Error, "wait_for names more than one condition: #{conditions.sort.join(', ')}" if conditions.size > 1

    { selector: spec['selector']&.to_s, urlContains: spec['url_contains']&.to_s, state: spec['state']&.to_s,
      label: "wait_for #{conditions.first} #{spec.fetch(conditions.first)}" }
  end

  # `full_page: true` captures the whole scrollable page; `viewport:` resizes
  # for this capture only.
  def compile_screenshot(value, _captured)
    spec = spec_for(value, 'name')
    name = (spec['name'] || 'screenshot').to_s
    full_page = spec['full_page'] == true
    viewport = spec['viewport'] && compile_viewport(spec['viewport'], "screenshot #{name}")
    label = [ "screenshot #{name}", full_page ? 'full page' : nil,
              viewport ? "at #{viewport[:width]}x#{viewport[:height]}" : nil ].compact.join(' ')
    { name: name, fullPage: full_page, viewport: viewport, label: label }
  end

  # Reads a value into a named variable a later expect_equal compares against,
  # so a count on one page can be checked against a list on another.
  def compile_capture(value, _captured)
    spec = spec_for(value, 'selector')
    selector = require_string(spec, 'selector', 'capture')
    name = var_name(spec['as'], 'capture', 'as')
    kind = read_kind(spec, 'capture')
    { selector: selector, as: name, kind: kind, label: "capture #{kind} of #{selector} as #{name}" }
  end

  # --- assertions -------------------------------------------------------------

  def compile_expect_visible(value, _captured) = expect_selector(value, 'expect_visible')

  def compile_expect_hidden(value, _captured) = expect_selector(value, 'expect_hidden')

  def expect_selector(value, verb)
    selector = selector_for(value, verb)
    { selector: selector, label: "#{verb} #{selector}" }
  end

  def compile_expect_text(value, _captured)
    spec = spec_for(value, 'selector')
    selector = require_string(spec, 'selector', 'expect_text')
    match = match_for(spec, 'expect_text')
    { selector: selector, equals: match[:equals], contains: match[:contains],
      label: "expect_text #{selector} #{match[:description]}" }
  end

  def compile_expect_url(value, _captured)
    match = match_for(spec_for(value, 'contains'), 'expect_url')
    { equals: match[:equals], contains: match[:contains], label: "expect_url #{match[:description]}" }
  end

  # Reads the status of the last navigation this flow performed, so a route
  # that answers 500 with a rendered body is still a failure.
  def compile_expect_status(value, _captured)
    spec = spec_for(value, 'equals')
    raise Error, 'expect_status needs an expected status code' unless spec.key?('equals')

    status = Integer(spec['equals'])
    { equals: status, label: "expect_status #{status}" }
  end

  def compile_expect_count(value, _captured)
    spec = spec_for(value, 'selector')
    selector = require_string(spec, 'selector', 'expect_count')
    raise Error, "expect_count #{selector} needs an expected count" unless spec.key?('equals')

    count = Integer(spec['equals'])
    { selector: selector, equals: count, label: "expect_count #{selector} equals #{count}" }
  end

  # Compares a captured variable with a live read of a selector, or with a
  # second captured variable. Both sides compare as strings, so a captured
  # number matches a count.
  def compile_expect_equal(value, captured)
    spec = spec_for(value, 'var')
    name = captured_var(spec['var'], 'var', captured)
    sources = spec.slice('selector', 'equals_var').keys
    raise Error, 'expect_equal needs one of selector or equals_var' if sources.empty?
    raise Error, 'expect_equal names both selector and equals_var' if sources.size > 1

    if spec.key?('equals_var')
      other = captured_var(spec['equals_var'], 'equals_var', captured)
      return { var: name, equalsVar: other, selector: nil, kind: nil, label: "expect_equal #{other} equals #{name}" }
    end

    selector = require_string(spec, 'selector', 'expect_equal')
    kind = read_kind(spec, 'expect_equal')
    { var: name, equalsVar: nil, selector: selector, kind: kind,
      label: "expect_equal #{kind} of #{selector} equals #{name}" }
  end

  def captured_var(raw, key, captured)
    name = var_name(raw, 'expect_equal', key)
    raise Error, "expect_equal #{key} #{name} is not captured by an earlier step" unless captured.include?(name)

    name
  end

  def var_name(raw, verb, key)
    name = raw.to_s
    raise Error, "#{verb} needs #{key}: a variable name (letters, digits, underscore)" unless name.match?(VAR_NAME)

    name
  end

  def read_kind(spec, verb)
    kind = (spec['kind'] || 'text').to_s
    raise Error, "#{verb} kind must be one of #{READ_KINDS.join(', ')}, got #{kind}" unless READ_KINDS.include?(kind)

    kind
  end

  def compile_viewport(raw, where)
    raise Error, "#{where} viewport must be a mapping of width and height" unless raw.is_a?(Hash)

    spec = raw.to_h { |key, inner| [ key.to_s, inner ] }
    width = Integer(spec['width'], exception: false)
    height = Integer(spec['height'], exception: false)
    raise Error, "#{where} viewport needs positive integer width and height" unless width&.positive? && height&.positive?

    { width: width, height: height }
  end

  # --- the escape hatch --------------------------------------------------------

  # Raw JS, run as-is in the page. Marked `raw: true` and labeled as raw JS so
  # every reader of a report can see that this step is not a checked assertion
  # but hand-written code the declarative vocabulary did not cover.
  def compile_eval(value, _captured)
    script = require_string(spec_for(value, 'script'), 'script', 'eval')
    { script: script, raw: true, label: "eval raw JS (declarative contract bypassed): #{script}" }
  end

  # --- shared parsing -----------------------------------------------------------

  # Every verb takes either a scalar shorthand (`click: "#go"`) or a full
  # mapping (`click: { selector: "#go" }`); the shorthand fills the verb's
  # primary key.
  def spec_for(value, primary_key)
    return { primary_key => value } unless value.is_a?(Hash)

    value.to_h { |key, inner| [ key.to_s, inner ] }
  end

  def selector_for(value, verb) = require_string(spec_for(value, 'selector'), 'selector', verb)

  def require_string(spec, key, verb)
    found = spec[key].to_s
    raise Error, "#{verb} needs a #{key}" if found.empty?

    found
  end

  def match_for(spec, verb)
    modes = spec.slice('equals', 'contains').keys
    raise Error, "#{verb} needs equals or contains" if modes.empty?
    raise Error, "#{verb} names both equals and contains" if modes.size > 1

    mode = modes.first
    expected = spec.fetch(mode).to_s
    { equals: mode == 'equals' ? expected : nil, contains: mode == 'contains' ? expected : nil,
      description: "#{mode} #{expected.inspect}" }
  end
end
