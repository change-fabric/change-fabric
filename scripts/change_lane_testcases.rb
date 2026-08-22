#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'change_lane'
require_relative 'change_lane_browserless'
require_relative 'change_findings'
require_relative 'change_flow_compiler'
require_relative 'change_suite'

# The deterministic regression lane. Runs committed test cases (suite files
# referenced from CHANGE.md by glob) inside the same browserless Chromium
# container the other browser lanes already use, and grades each case pass or
# fail.
#
# Nothing here is generated at run time. A case's steps are compiled to JS by
# ChangeFlowCompiler, in pure Ruby, with no LLM in the loop, so the same case at
# the same commit gives the same verdict. That is the whole point of the lane:
# ad hoc exploratory QA can tell you something broke, but only a case written
# down once and replayed the same way forever can tell you it broke again.
#
# No new Docker image. Each case gets its own browser context inside the shared
# container, for the same reason the browserless lane isolates its matrix cells:
# a case whose verdict depends on the case before it is not a regression check,
# it is an ordering accident.
#
# Every case also carries an `acceptance` sentence, the human-prose statement of
# what "working" means for it. This phase parses it, requires it, and renders it
# beside the verdict in the report; grading that prose against the observed run
# is a later phase's job.
class ChangeLaneTestcases < ChangeLane
  LANE = 'testcases'
  DEFAULT_VIEWPORT = { 'name' => 'desktop', 'width' => 1440, 'height' => 900 }.freeze
  DEFAULT_TIMEOUT_MS = ChangeFlowCompiler::DEFAULT_TIMEOUT_MS
  # Pinned, not read from the host: a screenshot or a media query that depends
  # on the device pixel ratio of whoever happened to run the sweep is not a
  # fact two runs can agree on.
  DEVICE_SCALE_FACTOR = 1

  def run
    session = @context.browserless
    return [ unavailable ] unless session

    errors = load_errors
    selected = suite_set.selected(tags)
    return errors + [ nothing_to_run ] if selected.empty?

    errors + case_findings(selected, session)
  rescue ChangeFlowCompiler::Error => e
    [ finding(check: 'step compile', status: 'fail', severity: 'high',
              detail: "a case's steps could not be compiled: #{e.message}") ]
  rescue StandardError => e
    [ finding(check: 'testcases run', status: 'fail', severity: 'high', detail: "run error: #{e.message}") ]
  end

  # A Markdown table of each case's acceptance criterion beside the verdict the
  # steps produced, rendered as its own report section (the same way the
  # browserless lane contributes its timing table). A reader sees what a human
  # meant by "working" and what the machine actually observed in one place,
  # which is the pairing the next phase grades.
  def acceptance_section
    return nil if @results.nil? || @results.empty?

    lines = [ '### Test cases and their acceptance criteria', '',
              '| Case | Tags | Verdict | Attempts | Acceptance |', '| --- | --- | --- | --- | --- |' ]
    @results.each { |result| lines << acceptance_row(result) }
    lines.join("\n")
  end

  private

  def acceptance_row(result)
    item = result[:case]
    "| #{item.qualified_id} | #{item.tags.join(' ')} | #{result[:status].upcase} | " \
      "#{result[:attempts]} | #{item.acceptance.gsub(/\s+/, ' ')} |"
  end

  # --- config ------------------------------------------------------------------

  def suite_set = @suite_set ||= ChangeSuiteSet.load(@config['suites'], @config.dir)

  def tags = list('tags')

  # The tags whose cases may fail the gate. Empty (the default) means every
  # case gates, which is what a test case is for; naming tags here is the
  # staged-adoption valve for a suite still being trusted, and it is deliberately
  # visible in the report rather than silent.
  def gate_tags = list('gate_tags')

  def list(key) = Array(@config[key]).map(&:to_s).reject(&:empty?)

  def viewport
    raw = @config['viewport']
    return DEFAULT_VIEWPORT unless raw.is_a?(Hash)

    DEFAULT_VIEWPORT.merge(raw.slice('name', 'width', 'height'))
  end

  def timeout_ms = Integer(@config.fetch('timeout_ms', DEFAULT_TIMEOUT_MS))

  # The login flow, in exactly the shape the browserless lane's `auth:` block
  # already has. Shared rather than restated: a repo that has already written
  # its login once should not write a second dialect of it to run a test case
  # behind that login.
  def auth_config
    raw = @config['auth']
    raw.is_a?(Hash) ? ChangeLaneBrowserless::AuthConfig.new(raw) : nil
  end

  # --- findings ----------------------------------------------------------------

  def load_errors
    suite_set.errors.map do |message|
      finding(check: 'suite file', status: 'fail', severity: 'high', detail: message)
    end + unmatched_gate_tag_findings
  end

  def unmatched_gate_tag_findings
    suite_set.unmatched_gate_tags(gate_tags).map do |tag|
      finding(check: 'gate_tags', status: 'fail', severity: 'high',
              detail: "gate_tags names '#{tag}', which no loaded case carries; " \
                      'the tag gates nothing, so a case an author believes is gating is not.')
    end
  end

  # An enabled lane with nothing to run is a failure, not a quiet pass. A gate
  # that checks zero cases reports green for exactly the same reason a gate
  # that checks everything does, and nothing in the report distinguishes them.
  def nothing_to_run
    detail = if @config['suites'].nil?
      'the testcases lane is enabled but sets no suites: globs, so it has no cases to run'
    else
      "no case matched the configured tags (#{tags.join(', ')})"
    end
    finding(check: 'suite selection', status: 'fail', severity: 'high', detail: detail)
  end

  def case_findings(selected, session)
    result = session.run_function(scan_module(selected))
    @results = graded(selected, Array(result))
    @results.map { |graded| case_finding(graded) }
  end

  # Pairs each returned record back with the case that produced it, by index,
  # and decides the verdict. A case with no record at all (the module returned
  # short) fails: an unexplained absence is not a pass.
  def graded(selected, records)
    selected.each_with_index.map do |item, index|
      record = records.find { |entry| entry['index'] == index }
      { case: item, record: record, status: status_for(item, record),
        attempts: record ? record['attempts'].to_i : 1 }
    end
  end

  def status_for(item, record)
    return 'pass' if record && record['ok']

    item.gates?(gate_tags) ? 'fail' : 'warn'
  end

  def case_finding(graded)
    item = graded[:case]
    Finding.new(lane: LANE, check: item.qualified_id, status: graded[:status],
                severity: graded[:status] == 'pass' ? 'info' : 'high',
                target: base_url, location: failure_location(graded),
                detail: detail_for(graded),
                attempts: graded[:attempts], flaky: graded[:status] == 'pass' && graded[:attempts] > 1)
  end

  def failure_location(graded)
    record = graded[:record]
    return '' if record.nil? || record['ok']

    step = Array(record['steps']).find { |entry| entry['ok'] == false }
    step ? "step #{step['index'].to_i + 1}: #{step['label']}" : 'login'
  end

  def detail_for(graded)
    record = graded[:record]
    return "case did not run: #{graded[:case].qualified_id} produced no result" if record.nil?
    return graded[:case].acceptance if record['ok']

    "#{failure_reason(record)}#{ungated_note(graded)}"
  end

  def failure_reason(record)
    return "login failed before the case ran: #{record['authError']}" if record['authError']

    step = Array(record['steps']).find { |entry| entry['ok'] == false }
    step ? step['error'].to_s : 'case failed with no step-level error recorded'
  end

  # A failing case that no gate_tag covers still reports; it just cannot fail
  # the run. Saying so in the finding keeps that from reading as a soft failure
  # nobody chose.
  def ungated_note(graded)
    return '' if graded[:status] == 'fail'

    " (reported, not gated: no tag of this case is listed in gate_tags)"
  end

  def finding(check:, status:, severity:, detail:)
    Finding.new(lane: LANE, check: check, status: status, severity: severity,
                target: base_url, detail: detail)
  end

  def unavailable
    finding(check: 'browserless', status: 'fail', severity: 'high',
            detail: 'browserless session unavailable; cannot run test cases')
  end

  # --- the compiled payload -----------------------------------------------------

  # Each case's steps, compiled once on the host. The compiled form carries any
  # value a `fill` read from an env var, so it goes to the container and
  # nowhere else: #js_cases is never logged, and the report renders the case's
  # acceptance prose and step labels, never this.
  def js_cases(selected)
    selected.each_with_index.map do |item, index|
      compiler = ChangeFlowCompiler.new(item.steps, base_url: base_url, timeout_ms: timeout_ms)
      { index: index, id: item.qualified_id, retries: item.retries, steps: compiler.compile }
    end
  end

  def js_auth
    auth = auth_config
    auth ? ChangeFlowCompiler.compile_auth(auth.steps, base_url: base_url) : nil
  end

  # One module runs every selected case, each in its own browser context, and
  # returns one record per case. A case with its own `retries:` budget is
  # retried inside the same walk; the attempt count travels back with the
  # record so a pass bought by a retry is recorded as `flaky` rather than
  # laundered into a clean first-run pass.
  def scan_module(selected)
    <<~JS
      export default async function ({ page }) {
        const cases = #{JSON.generate(js_cases(selected))};
        const auth = #{JSON.generate(js_auth)};
        const basicAuth = #{JSON.generate(basic_auth)};
        const viewport = #{JSON.generate(viewport)};
        const deviceScaleFactor = #{JSON.generate(DEVICE_SCALE_FACTOR)};

        #{ChangeFlowCompiler.auth_and_flow_runtime_js}

        // A case's own browser context, so cookies, storage and scroll
        // position never carry from one case into the next. Puppeteer renamed
        // this call (createIncognitoBrowserContext -> createBrowserContext);
        // both names are probed so the lane is not pinned to one puppeteer
        // major beyond the browserless image pin itself.
        async function newBrowserContext(browser) {
          if (typeof browser.createBrowserContext === "function") return browser.createBrowserContext();
          if (typeof browser.createIncognitoBrowserContext === "function") return browser.createIncognitoBrowserContext();
          return null;
        }

        async function openSession() {
          const browser = page.browser();
          const context = await newBrowserContext(browser);
          const casePage = context ? await context.newPage() : await browser.newPage();
          await casePage.setViewport({
            width: Number(viewport.width), height: Number(viewport.height),
            deviceScaleFactor: deviceScaleFactor,
          });
          if (basicAuth) {
            await casePage.authenticate({ username: basicAuth.username, password: basicAuth.password });
            // page.authenticate() only fires on a WWW-Authenticate challenge,
            // which some gates never send. Sending the header unconditionally
            // works either way. btoa, not Buffer: this module runs inside
            // browserless's function sandbox, which has no Node globals.
            await casePage.setExtraHTTPHeaders({
              Authorization: "Basic " + btoa(`${basicAuth.username}:${basicAuth.password}`),
            });
          }
          return { context, page: casePage, lastAuthResponse: null };
        }

        async function closeSession(session) {
          if (!session) return;
          try { await session.page.close(); } catch (err) { void err; }
          try { if (session.context) await session.context.close(); } catch (err) { void err; }
        }

        async function runOnce(testCase) {
          const session = await openSession();
          try {
            if (auth) {
              try {
                for (const step of auth.steps) await runAuthStep(session, step);
              } catch (err) {
                return { ok: false, authError: String(err), steps: [] };
              }
            }
            const steps = await cfRunFlow(session.page, testCase.steps);
            return { ok: steps.every((step) => step.ok), authError: null, steps: steps };
          } finally {
            await closeSession(session);
          }
        }

        const out = [];
        for (const testCase of cases) {
          let attempts = 0;
          let result = null;
          while (attempts <= testCase.retries) {
            attempts += 1;
            result = await runOnce(testCase);
            if (result.ok) break;
          }
          out.push({ index: testCase.index, id: testCase.id, attempts: attempts, ok: result.ok,
                     authError: result.authError, steps: result.steps });
        }
        return { data: out, type: "application/json" };
      }
    JS
  end
end
