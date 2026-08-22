#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'change_lane'
require_relative 'change_lane_browserless'
require_relative 'change_findings'
require_relative 'change_flow_compiler'
require_relative 'change_suite'
require_relative 'change_acceptance_grader'

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
# what "working" means for it. Each case's steps produce a deterministic verdict,
# and that sentence is then graded against what the run observed
# (ChangeAcceptanceGrader), because a page can satisfy every selector assertion
# and still do the wrong thing. Both verdicts can fail the gate, and both are
# rendered beside the criterion so a reader sees what was meant and what was
# judged in one place.
class ChangeLaneTestcases < ChangeLane
  LANE = 'testcases'
  DEFAULT_VIEWPORT = { 'name' => 'desktop', 'width' => 1440, 'height' => 900 }.freeze
  DEFAULT_TIMEOUT_MS = ChangeFlowCompiler::DEFAULT_TIMEOUT_MS
  # Pinned, not read from the host: a screenshot or a media query that depends
  # on the device pixel ratio of whoever happened to run the sweep is not a
  # fact two runs can agree on.
  DEVICE_SCALE_FACTOR = 1
  # How much of the observed page text travels back from the container, for the
  # acceptance grader to judge the criterion against. Bounded in the browser
  # rather than on the host so a page with a megabyte of text does not make the
  # returned payload a function of the app's own verbosity.
  OBSERVED_TEXT_LIMIT = 4_000

  # `grader` is the seam a test drives; a real run builds the default one, which
  # resolves its command from the environment and reports itself unavailable
  # rather than raising when nothing is reachable.
  def initialize(config, context, grader: nil)
    super(config, context)
    @grader = grader || ChangeAcceptanceGrader.new
  end

  def run
    session = @context.browserless
    return [ unavailable ] unless session

    errors = load_errors
    selected = suite_set.selected(tags, selectors: selectors)
    return errors + [ nothing_to_run ] if selected.empty?

    errors + case_findings(selected, session) + acceptance_findings
  rescue ChangeFlowCompiler::Error => e
    [ finding(check: 'step compile', status: 'fail', severity: 'high',
              detail: "a case's steps could not be compiled: #{e.message}") ]
  rescue StandardError => e
    [ finding(check: 'testcases run', status: 'fail', severity: 'high', detail: "run error: #{e.message}") ]
  end

  # A Markdown table of each case's acceptance criterion beside BOTH verdicts:
  # what its steps did, and how the criterion itself was graded against what the
  # run observed. The pairing is the point. A steps column alone says a
  # selector matched; a verdict column alone says a judgment was made about
  # something the reader cannot see. Side by side they are readable as one fact,
  # which is what makes a red gate worth opening.
  def acceptance_section
    return nil if @results.nil? || @results.empty?

    lines = [ '### Test cases and their acceptance criteria', '',
              '| Case | Tags | Steps | Acceptance | Attempts | Criterion | Grader note |',
              '| --- | --- | --- | --- | --- | --- | --- |' ]
    @results.each { |result| lines << acceptance_row(result) }
    lines.concat(acceptance_footnotes)
    lines.join("\n")
  end

  private

  def acceptance_row(result)
    item = result[:case]
    verdict = result[:verdict]
    cells = [ item.qualified_id, item.tags.join(' '), result[:status].upcase,
              verdict ? verdict.verdict.upcase : 'NOT GRADED', result[:attempts],
              flatten(item.acceptance), flatten(verdict&.rationale) ]
    "| #{cells.map { |cell| cell.to_s.gsub('|', '\\|') }.join(' | ')} |"
  end

  # What the reader has to do about a failed acceptance verdict, stated once
  # under the table rather than repeated per row. Which branch applies (record
  # the existing sha-scoped override here, or go and record it from a real
  # terminal) is the only thing the interactive-vs-CI distinction changes.
  def acceptance_footnotes
    return [ '', grading_note ] if grading_note

    return [] if @results.none? { |result| result[:verdict]&.fail? }

    [ '', ChangeAcceptanceGrader.override_guidance(interactive: interactive?) ]
  end

  def flatten(text) = text.to_s.gsub(/\s+/, ' ').strip

  def interactive? = ChangeAcceptanceGrader.interactive?

  # --- config ------------------------------------------------------------------

  def suite_set = @suite_set ||= ChangeSuiteSet.load(@config['suites'], @config.dir)

  def tags = list('tags')

  # The `--suite <suite-or-tag>` selectors, which arrive on the run context
  # rather than in the lane config on purpose: they are an invocation-time
  # narrowing (this is what `cf:qa --suite` runs), not a property of the repo,
  # and putting them in CHANGE.md would make a one-off rerun a config edit.
  def selectors
    return [] unless @context.respond_to?(:suite_select)

    Array(@context.suite_select).map(&:to_s).reject(&:empty?)
  end

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
    end + unmatched_gate_tag_findings + unmatched_selector_findings
  end

  # A `--suite` selector naming nothing is a failing finding, not an empty run.
  # Somebody asked for a suite by name and got silence; treating that as "those
  # cases passed" is how a typo turns into a green regression gate.
  def unmatched_selector_findings
    suite_set.unmatched_selectors(selectors).map do |selector|
      finding(check: 'suite selection', status: 'fail', severity: 'high',
              detail: "--suite names '#{selector}', which matches no loaded suite id and no case tag")
    end
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
    elsif !selectors.empty?
      "no case matched the requested --suite selection (#{selectors.join(', ')})"
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

  # --- graded acceptance --------------------------------------------------------

  # Grades every case whose steps passed, and emits one finding per case beside
  # the step finding. Only the passing ones: a case whose steps already failed
  # has a named, deterministic failure, and asking an LLM to also opine on it
  # would add a second opinion about a settled question. The interesting case is
  # the one where every assertion matched and the flow still did not do what a
  # person meant, which is exactly what a selector cannot see.
  def acceptance_findings
    return [] if @results.nil? || @results.empty?

    reason = @grader.unavailable_reason
    return [ grading_unavailable(reason) ] if reason

    gradable = @results.select { |result| result[:status] == 'pass' }
    return [] if gradable.empty?

    verdicts = @grader.grade(gradable.map { |result| observation(result) })
    gradable.each_with_index { |result, index| result[:verdict] = verdicts[index] }
    gradable.map { |result| acceptance_finding(result) }
  end

  # Grading that did not happen is reported as a warn, never as a pass and never
  # as a fail. A pass would launder unjudged prose into a checked criterion; a
  # fail would break every run on a machine that simply has no grader installed.
  # A warn is the honest reading: the criteria in this run are unjudged, and the
  # report says so.
  def grading_unavailable(reason)
    @grading_note = reason
    finding(check: 'acceptance grading', status: 'warn', severity: 'medium', detail: reason)
  end

  def grading_note = @grading_note

  def observation(result)
    record = result[:record] || {}
    observed = record['observation'] || {}
    { id: result[:case].qualified_id, acceptance: result[:case].acceptance, ok: true,
      steps: Array(record['steps']), url: observed['url'], title: observed['title'], text: observed['text'] }
  end

  # The verdict-to-status mapping, and the one place the "can fail the gate"
  # decision lives. A `fail` verdict is a real fail, not a capped warn: a
  # criterion whose failure cannot fail anything is a comment. `gate_tags`
  # softens it exactly as it softens a step failure, so staged adoption works
  # the same way for both halves of a case. `unclear` is a warn, because a
  # grader that declined to decide has not found a defect.
  def acceptance_finding(result)
    item = result[:case]
    verdict = result[:verdict]
    status = acceptance_status(item, verdict)
    Finding.new(lane: LANE, check: "#{item.qualified_id} acceptance", status: status,
                severity: status == 'pass' ? 'info' : 'high', target: base_url,
                location: 'acceptance criterion', detail: acceptance_detail(item, verdict, status),
                help: status == 'pass' ? '' : ChangeAcceptanceGrader.override_guidance(interactive: interactive?))
  end

  def acceptance_status(item, verdict)
    return 'warn' unless verdict&.fail? || verdict&.pass?
    return 'pass' if verdict.pass?

    item.gates?(gate_tags) ? 'fail' : 'warn'
  end

  def acceptance_detail(item, verdict, status)
    rationale = flatten(verdict&.rationale)
    rationale = 'the grader returned no rationale' if rationale.empty?
    note = status == 'warn' && verdict&.fail? ? ungated_acceptance_note : ''
    "criterion: #{flatten(item.acceptance)} | verdict: #{verdict&.verdict || 'unclear'} | #{rationale}#{note}"
  end

  def ungated_acceptance_note
    ' (reported, not gated: no tag of this case is listed in gate_tags)'
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

        // What the page ended up being, for the acceptance grader to judge the
        // case's prose criterion against. Read before the context closes and
        // bounded here rather than on the host, and best-effort: a page that
        // cannot be read still yields a verdict from the steps, so a broken
        // observation degrades the grading rather than the run.
        async function observe(page) {
          try {
            return {
              url: page.url(),
              title: await page.title(),
              text: await page.evaluate(
                (limit) => (document.body ? document.body.innerText || "" : "").slice(0, limit),
                #{OBSERVED_TEXT_LIMIT}
              ),
            };
          } catch (err) {
            return { url: "", title: "", text: "", error: String(err) };
          }
        }

        async function runOnce(testCase) {
          const session = await openSession();
          try {
            if (auth) {
              try {
                for (const step of auth.steps) await runAuthStep(session, step);
              } catch (err) {
                return { ok: false, authError: String(err), steps: [], observation: null };
              }
            }
            const steps = await cfRunFlow(session.page, testCase.steps);
            const ok = steps.every((step) => step.ok);
            return { ok: ok, authError: null, steps: steps, observation: ok ? await observe(session.page) : null };
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
                     authError: result.authError, steps: result.steps, observation: result.observation });
        }
        return { data: out, type: "application/json" };
      }
    JS
  end
end
