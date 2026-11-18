#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'date'
require_relative 'change_lane'
require_relative 'change_docker'
require_relative 'change_lane_browserless'
require_relative 'change_findings'
require_relative 'change_flow_compiler'
require_relative 'change_suite'
require_relative 'change_acceptance_grader'
require_relative 'change_testcases_personas'

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
#
# A genuinely flaky case can be time-boxed out of the gate with `quarantined:`,
# a required reason, and a required expiry date. It keeps running and keeps
# reporting; only its power to fail the run is suspended, and only until the
# date, at which point the shield lapses on its own. The reason and the date are
# rendered inline beside the case for the same reason the acceptance prose is:
# debt nobody can see is debt nobody pays.
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
  # A case's call budget, when it sets no `timeout_ms`: the sum of its steps'
  # timeouts plus this much per navigation, never below the default
  # browserless call limit, the same floor a walkthrough live capture uses.
  NAVIGATION_OVERHEAD_MS = 5_000
  CASE_BUDGET_FLOOR_MS = ChangeDocker::Browserless::FUNCTION_TIMEOUT_MS
  DEFAULT_PARALLEL = 1
  # Seconds to wait before each retry of a call the container's queue
  # rejected. A rejection never started the case, so it is not an attempt and
  # consumes no `retries`.
  QUEUE_BACKOFF_S = [ 1, 2, 4, 8, 16 ].freeze
  # The steps a case may replay after its persona logs in again: navigations,
  # waits, reads and assertions. Anything else (click, fill, select, press,
  # eval) may already have taken effect server side, so replaying it needs the
  # case's `safe_retry: true`.
  REPLAYABLE_VERBS = ChangeFlowCompiler::RUNTIME_VERBS.values_at(
    'goto', 'wait_for', 'screenshot', 'capture', *ChangeFlowCompiler::ASSERTIONS
  ).freeze

  # `grader` is the seam a test drives; a real run builds the default one, which
  # resolves its command from the environment and reports itself unavailable
  # rather than raising when nothing is reachable. `today` is the second seam,
  # for the same reason: a quarantine expiry is a date comparison, and a test
  # that could only assert it by waiting is not a test.
  # `sleeper` is the backoff seam, so a queue-rejection test does not wait.
  def initialize(config, context, grader: nil, today: nil, sleeper: nil)
    super(config, context)
    @grader = grader || ChangeAcceptanceGrader.new
    @today = today
    @sleeper = sleeper || ->(seconds) { sleep(seconds) }
  end

  # Each run case's timing and attempt record, in case order: `started_at_ms`
  # (offset from the lane's first call), `duration_ms`, and `attempts`, one
  # entry per call the container accepted with its outcome and duration.
  def case_results
    Array(@results).map do |result|
      { key: result[:case].qualified_id, status: result[:outcome], persona: result[:case].persona_name,
        started_at_ms: result[:started_at_ms],
        duration_ms: result[:duration_ms], attempts: result[:attempt_log] }
    end
  end

  # The call budget for one case, in ms. An explicit `cases[].timeout_ms`
  # wins; otherwise every step's timeout plus a navigation allowance per
  # `goto`, floored so a short case keeps the default call limit.
  def case_budget_ms(item)
    return item.timeout_ms if item.timeout_ms

    derived = item.steps.sum do |step|
      step_timeout(step) + (step.key?('goto') ? NAVIGATION_OVERHEAD_MS : 0)
    end
    [ derived, CASE_BUDGET_FLOOR_MS ].max
  end

  def run
    session = @context.browserless
    return [ unavailable ] unless session

    errors = load_errors
    selected = suite_set.selected(tags, selectors: selectors)
    return errors + [ nothing_to_run ] if selected.empty?

    errors + case_findings(selected, session) + acceptance_findings + quarantine_findings(selected)
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
              '| Case | Tags | Steps | Acceptance | Attempts | Duration | Criterion | Grader note | Quarantine |',
              '| --- | --- | --- | --- | --- | --- | --- | --- | --- |' ]
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
              duration_cell(result[:duration_ms]), flatten(item.acceptance), flatten(verdict&.rationale), quarantine_cell(item) ]
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

  # The quarantine, rendered inline beside the case it shields rather than
  # collected in a footnote. A muted case whose mute is only recorded somewhere
  # else is how quarantine debt becomes invisible.
  def quarantine_cell(item)
    item.quarantine ? flatten(item.quarantine.summary(today)) : '-'
  end

  def flatten(text) = text.to_s.gsub(/\s+/, ' ').strip

  def duration_cell(ms) = ms ? format('%.1f s', ms / 1000.0) : '-'

  def interactive? = ChangeAcceptanceGrader.interactive?

  def today = @today || Date.today

  # --- quarantine ---------------------------------------------------------------

  # Whether a failure of this case may fail the run. Two separate reasons it may
  # not: no tag of the case is listed in `gate_tags` (staged adoption of a whole
  # suite), or the case carries a live quarantine (one known-flaky case, time
  # boxed). They are kept apart because the report has to say which one applied;
  # "not gated" without a reason is a soft failure nobody chose.
  def gated?(item) = item.gates?(gate_tags) && !item.quarantined?(today)

  # A quarantine whose date has passed gets its own warn finding, whatever the
  # case itself did. The case is gating again and the suite file still says it is
  # muted, so somebody is reading a shield that is not there. It stays a warn:
  # the gate signal belongs to the case's own verdict, and stale bookkeeping is
  # not a regression.
  def quarantine_findings(selected)
    selected.select { |item| item.quarantine_expired?(today) }.map do |item|
      finding(check: "#{item.qualified_id} quarantine", status: 'warn', severity: 'medium',
              detail: "quarantine expired #{item.quarantine.until_on.iso8601} " \
                      "(#{flatten(item.quarantine.reason)}); this case gates again, " \
                      'so either fix it or re-quarantine it with a new date')
    end
  end

  # Named on a passing case too, so the debt does not become invisible the
  # moment the flake happens not to fire.
  def quarantine_note(item)
    item.quarantine ? " (quarantined #{flatten(item.quarantine.summary(today))})" : ''
  end

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

  # Extra Chromium flags (lanes.testcases.launch_args) for the browser the
  # cases run in, e.g. --disable-features=LocalNetworkAccessChecks so a
  # code_source fetch from the page can reach a private address.
  def launch_args = list('launch_args')

  def list(key) = Array(@config[key]).map(&:to_s).reject(&:empty?)

  def viewport
    raw = @config['viewport']
    return DEFAULT_VIEWPORT unless raw.is_a?(Hash)

    DEFAULT_VIEWPORT.merge(raw.slice('name', 'width', 'height'))
  end

  def timeout_ms = Integer(@config.fetch('timeout_ms', DEFAULT_TIMEOUT_MS))

  # A step's own timeout, beside the verb or inside its mapping, else the
  # lane's, mirroring how the compiler resolves it.
  def step_timeout(step)
    inner = step.values.find { |value| value.is_a?(Hash) && value.key?('timeout_ms') }
    Integer(step['timeout_ms'] || inner&.fetch('timeout_ms') || timeout_ms)
  end

  # How many cases run at once (lanes.testcases.parallel, validated 1..10).
  def parallel = Integer(@config.fetch('parallel', DEFAULT_PARALLEL))

  # A persona's login flow, in exactly the shape the browserless lane's
  # `auth:` block already has. Shared rather than restated: a repo that has
  # already written its login once should not write a second dialect of it to
  # run a test case behind that login. `default` is the lane's `auth:` (no
  # login when there is none), `anonymous` is never a login, and a name the
  # lane does not define is :unknown.
  def persona_auth(name)
    return nil if name == 'anonymous'

    raw = name == 'default' ? @config['auth'] : personas_config[name]
    return ChangeLaneBrowserless::AuthConfig.new(raw) if raw.is_a?(Hash)

    name == 'default' ? nil : :unknown
  end

  def personas_config = @config['personas'].is_a?(Hash) ? @config['personas'].transform_keys(&:to_s) : {}

  # The persona a case logs in as, or nil when it runs without a login.
  def login_persona(item)
    auth = persona_auth(item.persona_name)
    auth.is_a?(ChangeLaneBrowserless::AuthConfig) ? item.persona_name : nil
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

  # One browserless call per case attempt, through a pool of `parallel`
  # threads against the one container. Every case compiles before the first
  # call, so a compile error stops the run before anything has acted. Results
  # come back in case order whatever order the pool finished them in.
  def case_findings(selected, session)
    compiled = js_cases(selected)
    @personas = PersonaCache.new { |name| log_in(session, name) }
    @run_started = clock
    warm_personas(selected)
    runs = run_pool(selected.size) { |index| run_case(session, selected[index], compiled[index]) }
    @results = selected.each_with_index.map { |item, index| graded(item, runs[index]) }
    @results.map { |graded| case_finding(graded) }
  end

  def run_pool(count)
    results = Array.new(count)
    queue = Queue.new
    count.times { |index| queue << index }
    queue.close
    workers = Array.new([ parallel, count ].min) do
      Thread.new do
        while (index = queue.pop)
          results[index] = yield(index)
        end
      end
    end
    workers.each(&:join)
    results
  end

  # One login per persona the selection uses, before any case runs, so the
  # first cases of a persona do not all race to be the one that logs in. A
  # failed login is remembered by the cache and fails each of its cases.
  def warm_personas(selected)
    selected.filter_map { |item| login_persona(item) }.uniq.each do |name|
      @personas.fetch(name)
    rescue PersonaCache::LoginError
      next
    end
  end

  # The login call for one persona: its auth steps in a fresh context, then
  # that context's cookies and localStorage, which every case of the persona
  # is seeded with.
  def log_in(session, name)
    auth = persona_auth(name)
    result = call_function(session, login_module(auth), login_budget_ms(auth))
    return result['state'] if result && result['ok']

    reason = result && (result['authError'] || result['callError'])
    raise PersonaCache::LoginError, reason || 'the login call returned no result'
  end

  def login_budget_ms(auth)
    derived = auth.steps.sum { |step| Integer(step[:timeout_ms]) + NAVIGATION_OVERHEAD_MS }
    [ derived, CASE_BUDGET_FLOOR_MS ].max
  end

  # The attempt lifecycle. An attempt is one call the container accepted. A
  # whole-case rerun after a failure happens only within `retries`, which the
  # loader allows only beside `safe_rerun: true`. The last attempt's record
  # supplies the verdict.
  def run_case(session, item, compiled)
    started = clock
    attempts = []
    record = nil
    (item.retries + 1).times do |number|
      attempt_started = clock
      record = attempt(session, item, compiled, number + 1)
      # Nothing ran (no usable payload, a queue that never freed, or a
      # persona that could not log in): not an attempt, and no reason to
      # spend a rerun on it.
      break if record.nil? || record['queueFull'] || record['notAttempted']

      attempts << { number: number + 1, outcome: attempt_outcome(record),
                    duration_ms: elapsed_ms(attempt_started) }
      break if record['ok']
    end
    { record: record, attempts: attempts, started_at_ms: elapsed_ms(@run_started, started),
      duration_ms: elapsed_ms(started) }
  end

  def attempt_outcome(record)
    return 'auth_interrupted' if record['authInterrupted']

    record['ok'] ? 'pass' : 'fail'
  end

  # One attempt of a case, seeded with its persona's session. Auth recovery
  # happens inside the attempt: when the case sees its session end, the
  # persona logs in again (once, however many cases saw it) and the case
  # resumes at the interrupted step, unless that step may already have changed
  # something server side.
  def attempt(session, item, compiled, number)
    return unknown_persona(item) if persona_auth(item.persona_name) == :unknown

    persona = login_persona(item)
    state, generation = persona ? @personas.fetch(persona) : [ nil, 0 ]
    record = call_function(session, case_module(compiled, number, persona_js(item, state)), case_budget_ms(item))
    return record unless persona && record.is_a?(Hash) && record['authExpired']

    resume_after_expiry(session, item, compiled, number, persona, generation, record)
  rescue PersonaCache::LoginError => e
    { 'ok' => false, 'notAttempted' => true, 'steps' => [],
      'authError' => "persona '#{item.persona_name}' could not log in: #{e.message}" }
  end

  def unknown_persona(item)
    { 'ok' => false, 'notAttempted' => true, 'steps' => [],
      'authError' => "the case names persona '#{item.persona_name}', which lanes.testcases.personas does not define" }
  end

  def resume_after_expiry(session, item, compiled, number, persona, generation, record)
    expired = record['authExpired']
    begin
      state, = @personas.refresh(persona, generation)
    rescue PersonaCache::LoginError => e
      return record.merge('ok' => false, 'authError' => "the session ended and persona '#{persona}' could not log in again: #{e.message}")
    end
    return record.merge('ok' => false, 'authInterrupted' => true) unless replayable?(item, expired['verb'])

    resume = { startAt: Integer(expired['index']), vars: record['vars'] || {}, url: expired['url'].to_s }
    second = call_function(session, case_module(compiled, number, persona_js(item, state), resume: resume),
                           case_budget_ms(item))
    merge_resumed(record, second, resume[:startAt])
  end

  def replayable?(item, verb) = item.safe_retry || REPLAYABLE_VERBS.include?(verb.to_s)

  # The resumed call's record, carrying the first call's steps before the
  # interrupted one. A second session end in the same attempt fails the case.
  def merge_resumed(first, second, start_at)
    return first.merge('ok' => false, 'callError' => 'the resumed call after a re-login returned no result') unless second.is_a?(Hash)

    earlier = Array(first['steps']).select { |step| step['index'].to_i < start_at }
    merged = second.merge('steps' => earlier + Array(second['steps']), 'resumed' => true)
    return merged unless second['authExpired']

    merged.merge('ok' => false, 'authError' => 'the session ended again after a re-login in the same attempt')
  end

  # One accepted call. A queue rejection is retried with backoff and is not an
  # attempt; a queue that never frees is a call error with no attempt made.
  # Any other failure (timeout, transport, browser crash) is a failed attempt.
  def call_function(session, code, timeout_ms)
    rejections = 0
    begin
      result = session.run_function(code, launch_args: launch_args, timeout_ms: timeout_ms)
      result.is_a?(Hash) ? result : nil
    rescue ChangeDocker::Browserless::QueueRejected => e
      rejections += 1
      return queue_full(e) if rejections > QUEUE_BACKOFF_S.size

      @sleeper.call(QUEUE_BACKOFF_S[rejections - 1])
      retry
    rescue StandardError => e
      { 'ok' => false, 'callError' => e.message, 'steps' => [] }
    end
  end

  def queue_full(error)
    { 'ok' => false, 'queueFull' => true, 'steps' => [],
      'callError' => "browserless queue stayed full after #{QUEUE_BACKOFF_S.size} retries: #{error.message}" }
  end

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def elapsed_ms(from, to = clock) = ((to - from) * 1000).round

  # Decides the verdict for one case from its last record. A case with no
  # record at all (the call returned nothing usable) fails: an unexplained
  # absence is not a pass.
  def graded(item, run)
    record = run[:record]
    status = status_for(item, record)
    outcome = record&.dig('authInterrupted') ? 'auth_interrupted' : status
    { case: item, record: record, status: status, outcome: outcome,
      attempts: [ run[:attempts].size, 1 ].max, attempt_log: run[:attempts],
      started_at_ms: run[:started_at_ms], duration_ms: run[:duration_ms] }
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

  # Grading that did not happen is never reported as a pass: it is either
  # a warn (an interactive `--signoff` run, where a human is present to decide
  # what an unjudged criterion means) or a fail (full auto, Decision 8: an
  # unattended run cannot launder unjudged prose into a passed gate by simply
  # having no grader installed).
  def grading_unavailable(reason)
    @grading_note = reason
    finding(check: 'acceptance grading', status: signoff? ? 'warn' : 'fail', severity: 'medium', detail: reason)
  end

  def signoff? = @context.respond_to?(:signoff?) && @context.signoff?

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
    return unclear_status(item) unless verdict&.fail? || verdict&.pass?
    return 'pass' if verdict.pass?

    gated?(item) ? 'fail' : 'warn'
  end

  # Decision 8: an `unclear` verdict (the grader could not decide) fails the
  # gate under full auto and only warns under `--signoff`, the same rule as a
  # missing grader. `gate_tags` staged adoption
  # still softens it to warn either way, exactly as it softens a real `fail`.
  def unclear_status(item)
    return 'warn' if signoff? || !gated?(item)

    'fail'
  end

  def acceptance_detail(item, verdict, status)
    rationale = flatten(verdict&.rationale)
    rationale = 'the grader returned no rationale' if rationale.empty?
    note = status == 'warn' && verdict&.fail? ? ungated_note_for(item) : ''
    "criterion: #{flatten(item.acceptance)} | verdict: #{verdict&.verdict || 'unclear'} | #{rationale}#{note}"
  end

  def status_for(item, record)
    return 'pass' if record && record['ok']

    gated?(item) ? 'fail' : 'warn'
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
    return "step #{step['index'].to_i + 1}: #{step['label']}" if step

    record['callError'] ? 'browserless call' : 'login'
  end

  def detail_for(graded)
    record = graded[:record]
    return "case did not run: #{graded[:case].qualified_id} produced no result" if record.nil?
    return "#{graded[:case].acceptance}#{quarantine_note(graded[:case])}" if record['ok']

    "#{failure_reason(record)}#{ungated_note(graded)}"
  end

  def failure_reason(record)
    return auth_interrupted_reason(record) if record['authInterrupted']
    return "login failed before the case ran: #{record['authError']}" if record['notAttempted']
    return "auth: #{record['authError']}" if record['authError']
    return "the case's browserless call failed: #{record['callError']}" if record['callError']

    step = Array(record['steps']).find { |entry| entry['ok'] == false }
    step ? step['error'].to_s : 'case failed with no step-level error recorded'
  end

  def auth_interrupted_reason(record)
    expired = record['authExpired'] || {}
    "auth_interrupted: the session ended at step #{expired['index'].to_i + 1} (#{expired['verb']}), which may " \
      'already have taken effect server side, so it was not replayed; the persona logged in again for later ' \
      'cases. Set safe_retry: true (suite_version 3) on the case if replaying that step is safe'
  end

  # A failing case that nothing gates still reports; it just cannot fail the
  # run. Saying WHY in the finding keeps that from reading as a soft failure
  # nobody chose, and keeps a one-case time-boxed quarantine distinguishable
  # from a whole suite still being adopted.
  def ungated_note(graded)
    return '' if graded[:status] == 'fail'

    ungated_note_for(graded[:case])
  end

  def ungated_note_for(item)
    " (reported, not gated: #{ungated_reason(item)})"
  end

  def ungated_reason(item)
    return "quarantined #{flatten(item.quarantine.summary(today))}" if item.quarantined?(today)

    'no tag of this case is listed in gate_tags'
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
      { index: index, id: item.qualified_id, steps: compiler.compile }
    end
  end

  # What a case module knows about its persona: the seeded storage state, how
  # to tell its session has ended (the login page or the login form's fields
  # reappearing), and whether a mutating step may be replayed. nil for a case
  # that runs without a login.
  def persona_js(item, state)
    persona = login_persona(item)
    return nil unless persona

    first = persona_auth(persona).steps.first
    { name: persona, seed: state, safeRetry: item.safe_retry == true,
      detect: { loginUrl: first[:url].to_s.empty? ? nil : ChangeFlowCompiler.absolute_url(first[:url], base_url),
                loginSelectors: first[:fields].map { |field| field[:selector] }.reject(&:empty?) } }
  end

  # The browser context and page every module opens: a fresh context so
  # cookies, storage and scroll position never carry from one call into the
  # next. Puppeteer renamed the call (createIncognitoBrowserContext ->
  # createBrowserContext); both names are probed so the lane is not pinned to
  # one puppeteer major beyond the browserless image pin itself.
  def session_js
    <<~JS
      const basicAuth = #{JSON.generate(basic_auth)};
      const viewport = #{JSON.generate(viewport)};
      const deviceScaleFactor = #{JSON.generate(DEVICE_SCALE_FACTOR)};

      async function newBrowserContext(browser) {
        if (typeof browser.createBrowserContext === "function") return browser.createBrowserContext();
        if (typeof browser.createIncognitoBrowserContext === "function") return browser.createIncognitoBrowserContext();
        return null;
      }

      async function openSession(page) {
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
    JS
  end

  # One login for one persona, in its own context, returning that context's
  # cookies and the localStorage of the page the login ended on. The state is
  # credentials in effect, so like a compiled `fill` it goes back into case
  # modules and nowhere else: it is never logged or written to a report.
  def login_module(auth)
    <<~JS
      export default async function ({ page }) {
        const auth = #{JSON.generate(ChangeFlowCompiler.compile_auth(auth.steps, base_url: base_url))};
        #{session_js}
        #{ChangeFlowCompiler.auth_runtime_js}

        const session = await openSession(page);
        try {
          for (const step of auth.steps) await runAuthStep(session, step);
          let cookies = [];
          try {
            const client = await session.page.target().createCDPSession();
            cookies = (await client.send("Network.getAllCookies")).cookies;
          } catch (err) {
            cookies = await session.page.cookies();
          }
          let origins = [];
          try {
            const origin = new URL(session.page.url()).origin;
            const items = await session.page.evaluate(() => Object.entries(window.localStorage));
            origins = [{ origin: origin, items: items }];
          } catch (err) { void err; }
          return { data: { ok: true, state: { cookies: cookies, origins: origins } }, type: "application/json" };
        } catch (err) {
          return { data: { ok: false, authError: String(err) }, type: "application/json" };
        } finally {
          await closeSession(session);
        }
      }
    JS
  end

  # One module per case attempt: it runs that one case in its own browser
  # context, seeded with its persona's session, and returns its record.
  # Retries are decided in Ruby (#run_case), so each attempt is its own call
  # with its own budget, and a long suite never shares one call's time limit.
  # `resume` restarts a case at the step its expired session interrupted,
  # after the persona logged in again.
  def case_module(compiled, attempt, persona = nil, resume: nil)
    <<~JS
      export default async function ({ page }) {
        const testCase = #{JSON.generate(compiled)};
        const attempt = #{Integer(attempt)};
        const persona = #{JSON.generate(persona)};
        const resume = #{JSON.generate(resume)};
        #{session_js}
        #{ChangeFlowCompiler.flow_runtime_js}

        // The persona's login, seeded rather than replayed: its cookies, and
        // its localStorage written on each new document of the same origin
        // unless the case has already set that key itself.
        async function seedStorage(casePage, seed) {
          if (!seed) return;
          const cookies = (seed.cookies || []).map((c) => {
            const out = { name: c.name, value: c.value, domain: c.domain, path: c.path,
                          httpOnly: c.httpOnly === true, secure: c.secure === true };
            if (typeof c.expires === "number" && c.expires > 0) out.expires = c.expires;
            if (c.sameSite) out.sameSite = c.sameSite;
            return out;
          });
          if (cookies.length > 0) await casePage.setCookie(...cookies);
          const origins = seed.origins || [];
          if (origins.length === 0) return;
          await casePage.evaluateOnNewDocument((list) => {
            try {
              const entry = list.find((o) => o.origin === window.location.origin);
              if (!entry) return;
              for (const [key, value] of entry.items) {
                if (window.localStorage.getItem(key) === null) window.localStorage.setItem(key, value);
              }
            } catch (err) { void err; }
          }, origins);
        }

        // A 401 on a main-frame document response. XHR 401s are left to the
        // case's own assertions: an API answering 401 is often the behaviour
        // under test, not a lost session.
        function watchSession(casePage) {
          const watch = { doc401: false };
          casePage.on("response", (response) => {
            try {
              if (response.status() === 401 && response.request().resourceType() === "document" &&
                  response.frame() === casePage.mainFrame()) watch.doc401 = true;
            } catch (err) { void err; }
          });
          return watch;
        }

        function samePath(a, b) {
          try {
            const x = new URL(a);
            const y = new URL(b);
            return x.origin === y.origin && x.pathname.replace(/\\/$/, "") === y.pathname.replace(/\\/$/, "");
          } catch (err) {
            return false;
          }
        }

        async function sessionEnded(casePage, watch) {
          if (!persona || !persona.detect) return false;
          if (watch.doc401) return true;
          if (persona.detect.loginUrl && samePath(casePage.url(), persona.detect.loginUrl)) return true;
          const selectors = persona.detect.loginSelectors || [];
          if (selectors.length === 0) return false;
          for (const selector of selectors) {
            try { if (!(await casePage.$(selector))) return false; } catch (err) { return false; }
          }
          return true;
        }

        // What the page ended up being, for the acceptance grader to judge the
        // case's prose criterion against. Read before the context closes and
        // bounded here rather than on the host, and best-effort: a page that
        // cannot be read still yields a verdict from the steps, so a broken
        // observation degrades the grading rather than the run.
        async function observe(casePage) {
          try {
            return {
              url: casePage.url(),
              title: await casePage.title(),
              text: await casePage.evaluate(
                (limit) => (document.body ? document.body.innerText || "" : "").slice(0, limit),
                #{OBSERVED_TEXT_LIMIT}
              ),
            };
          } catch (err) {
            return { url: "", title: "", text: "", error: String(err) };
          }
        }

        async function runOnce(testCase) {
          const session = await openSession(page);
          try {
            if (persona) await seedStorage(session.page, persona.seed);
            const watch = watchSession(session.page);
            if (resume && resume.url && /^https?:/.test(resume.url)) {
              await session.page.goto(resume.url, { waitUntil: "domcontentloaded" });
            }
            let expired = null;
            let beforeUrl = "";
            const steps = await cfRunFlow(session.page, testCase.steps, {
              startAt: resume ? resume.startAt : 0,
              vars: resume ? resume.vars : {},
              beforeStep: async () => { watch.doc401 = false; beforeUrl = session.page.url(); },
              afterStep: async (step) => {
                if (!(await sessionEnded(session.page, watch))) return false;
                expired = { index: step.index, verb: step.verb, url: beforeUrl };
                return true;
              },
            });
            const ok = !expired && steps.every((step) => step.ok);
            return { ok: ok, steps: steps, vars: steps.vars, authExpired: expired,
                     observation: ok ? await observe(session.page) : null };
          } finally {
            await closeSession(session);
          }
        }

        const result = await runOnce(testCase);
        return {
          data: { index: testCase.index, id: testCase.id, attempt: attempt, ok: result.ok, authError: null,
                  authExpired: result.authExpired, vars: result.vars, steps: result.steps,
                  observation: result.observation },
          type: "application/json",
        };
      }
    JS
  end
end
