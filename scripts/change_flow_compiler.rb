#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

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
#   `screenshot`; assertions `expect_visible`, `expect_hidden`, `expect_text`,
#   `expect_url`, `expect_status`, `expect_count`; and `eval` as an escape
#   hatch for raw JS.
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

  ACTIONS = %w[goto click fill select press wait_for screenshot].freeze
  ASSERTIONS = %w[expect_visible expect_hidden expect_text expect_url expect_status expect_count].freeze
  ESCAPE_HATCH = 'eval'
  VERBS = (ACTIONS + ASSERTIONS + [ ESCAPE_HATCH ]).freeze

  # Every compiled step carries a `verb` in this camelCase runtime spelling, so
  # the JS runtime switches on one token while the flow file keeps snake_case.
  RUNTIME_VERBS = VERBS.to_h { |verb| [ verb, verb.gsub(/_(.)/) { Regexp.last_match(1).upcase } ] }.freeze

  # Step-level keys that are options rather than the verb itself.
  OPTION_KEYS = %w[timeout_ms].freeze

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

    async function cfText(page, selector, timeoutMs) {
      await page.waitForSelector(selector, { timeout: timeoutMs });
      return page.$eval(selector, (el) => (el.innerText || el.textContent || "").trim());
    }

    async function cfRunStep(page, step, state) {
      const timeout = step.timeoutMs;
      switch (step.verb) {
        case "goto":
          state.lastResponse = await page.goto(step.url, { waitUntil: step.waitUntil, timeout: timeout });
          return null;
        case "click":
          await page.waitForSelector(step.selector, { timeout: timeout });
          await page.click(step.selector);
          return null;
        case "fill": {
          await page.waitForSelector(step.selector, { timeout: timeout });
          const value = step.codeSource ? await resolveCodeSource(step.codeSource) : step.value;
          await page.type(step.selector, value);
          return null;
        }
        case "select":
          await page.waitForSelector(step.selector, { timeout: timeout });
          await page.select(step.selector, step.value);
          return null;
        case "press":
          if (step.selector) {
            await page.waitForSelector(step.selector, { timeout: timeout });
            await page.focus(step.selector);
          }
          await page.keyboard.press(step.key);
          return null;
        case "waitFor":
          if (step.selector) await page.waitForSelector(step.selector, { timeout: timeout });
          else if (step.urlContains) {
            await page.waitForFunction((needle) => window.location.href.indexOf(needle) !== -1, { timeout: timeout }, step.urlContains);
          } else {
            const response = await page.waitForNavigation({ waitUntil: step.state, timeout: timeout });
            if (response) state.lastResponse = response;
          }
          return null;
        case "screenshot":
          return { screenshot: await page.screenshot({ encoding: "base64" }), name: step.name };
        case "expectVisible":
          await page.waitForSelector(step.selector, { visible: true, timeout: timeout });
          return null;
        case "expectHidden":
          await page.waitForSelector(step.selector, { hidden: true, timeout: timeout });
          return null;
        case "expectText": {
          const text = await cfText(page, step.selector, timeout);
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
          const count = await page.$$eval(step.selector, (els) => els.length);
          if (count !== step.equals) cfFail(`expected ${step.equals} element(s) matching ${step.selector}, found ${count}`);
          return { found: count };
        }
        case "eval":
          return { value: await page.evaluate("(async () => {" + step.script + "})()") };
        default:
          return cfFail("unknown flow verb: " + step.verb);
      }
    }

    async function cfRunFlow(page, steps) {
      const state = { lastResponse: null };
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

  def initialize(steps, base_url: nil, timeout_ms: DEFAULT_TIMEOUT_MS, env: ENV)
    @raw_steps = Array(steps)
    @base_url = base_url.to_s
    @timeout_ms = Integer(timeout_ms)
    @env = env
  end

  # The compiled steps, credentials included. Hand this to the container and
  # nowhere else.
  def compile = @compile ||= @raw_steps.each_with_index.map { |raw, index| compile_step(raw, index) }

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
        const results = await cfRunFlow(page, steps);
        return { data: { steps: results }, type: "application/json" };
      };
    JS
  end

  private

  def compile_step(raw, index)
    verb, value, options = split_step(raw, index)
    compiled = send(:"compile_#{verb}", value, options)
    compiled.merge(verb: RUNTIME_VERBS.fetch(verb), index: index, timeoutMs: step_timeout(options))
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

    [ verbs.first, keyed.fetch(verbs.first), keyed.slice(*OPTION_KEYS) ]
  end

  def step_timeout(options) = Integer(options['timeout_ms'] || @timeout_ms)

  # --- actions ---------------------------------------------------------------

  def compile_goto(value, _options)
    spec = spec_for(value, 'url')
    url = self.class.absolute_url(require_string(spec, 'url', 'goto'), @base_url)
    { url: url, waitUntil: (spec['wait_until'] || DEFAULT_WAIT_UNTIL).to_s, label: "goto #{url}" }
  end

  def compile_click(value, _options)
    selector = selector_for(value, 'click')
    { selector: selector, label: "click #{selector}" }
  end

  # The one step that can carry a secret. Exactly one value source: an env var
  # read on the host, a literal already visible in the flow file, or a
  # code_source resolved inside the container.
  def compile_fill(value, _options)
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

  def compile_select(value, _options)
    spec = spec_for(value, 'selector')
    selector = require_string(spec, 'selector', 'select')
    raise Error, "select #{selector} needs a value" unless spec.key?('value')

    option = spec['value'].to_s
    { selector: selector, value: option, label: "select #{option.inspect} in #{selector}" }
  end

  def compile_press(value, _options)
    spec = spec_for(value, 'key')
    key = require_string(spec, 'key', 'press')
    selector = spec['selector']&.to_s
    { key: key, selector: selector, label: selector ? "press #{key} in #{selector}" : "press #{key}" }
  end

  # The readiness contract in step form: wait for a selector, for the url to
  # contain a fragment, or for a navigation to reach a load state. The wait is
  # the contract; the timeout is only the failure mode.
  def compile_wait_for(value, _options)
    spec = spec_for(value, 'selector')
    conditions = spec.slice('selector', 'url_contains', 'state').keys
    raise Error, 'wait_for needs one of selector, url_contains, or state' if conditions.empty?
    raise Error, "wait_for names more than one condition: #{conditions.sort.join(', ')}" if conditions.size > 1

    { selector: spec['selector']&.to_s, urlContains: spec['url_contains']&.to_s, state: spec['state']&.to_s,
      label: "wait_for #{conditions.first} #{spec.fetch(conditions.first)}" }
  end

  def compile_screenshot(value, _options)
    name = (spec_for(value, 'name')['name'] || 'screenshot').to_s
    { name: name, label: "screenshot #{name}" }
  end

  # --- assertions -------------------------------------------------------------

  def compile_expect_visible(value, _options) = expect_selector(value, 'expect_visible')

  def compile_expect_hidden(value, _options) = expect_selector(value, 'expect_hidden')

  def expect_selector(value, verb)
    selector = selector_for(value, verb)
    { selector: selector, label: "#{verb} #{selector}" }
  end

  def compile_expect_text(value, _options)
    spec = spec_for(value, 'selector')
    selector = require_string(spec, 'selector', 'expect_text')
    match = match_for(spec, 'expect_text')
    { selector: selector, equals: match[:equals], contains: match[:contains],
      label: "expect_text #{selector} #{match[:description]}" }
  end

  def compile_expect_url(value, _options)
    match = match_for(spec_for(value, 'contains'), 'expect_url')
    { equals: match[:equals], contains: match[:contains], label: "expect_url #{match[:description]}" }
  end

  # Reads the status of the last navigation this flow performed, so a route
  # that answers 500 with a rendered body is still a failure.
  def compile_expect_status(value, _options)
    spec = spec_for(value, 'equals')
    raise Error, 'expect_status needs an expected status code' unless spec.key?('equals')

    status = Integer(spec['equals'])
    { equals: status, label: "expect_status #{status}" }
  end

  def compile_expect_count(value, _options)
    spec = spec_for(value, 'selector')
    selector = require_string(spec, 'selector', 'expect_count')
    raise Error, "expect_count #{selector} needs an expected count" unless spec.key?('equals')

    count = Integer(spec['equals'])
    { selector: selector, equals: count, label: "expect_count #{selector} equals #{count}" }
  end

  # --- the escape hatch --------------------------------------------------------

  # Raw JS, run as-is in the page. Marked `raw: true` and labeled as raw JS so
  # every reader of a report can see that this step is not a checked assertion
  # but hand-written code the declarative vocabulary did not cover.
  def compile_eval(value, _options)
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
