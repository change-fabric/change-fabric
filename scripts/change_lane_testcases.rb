#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'date'
require 'uri'
require 'time'
require_relative 'change_lane'
require_relative 'change_docker'
require_relative 'change_lane_browserless'
require_relative 'change_findings'
require_relative 'change_flow_compiler'
require_relative 'change_suite'
require_relative 'change_acceptance_grader'
require_relative 'change_testcases_personas'
require_relative 'change_testcases_evidence'
require_relative 'change_case_result'
require_relative 'change_testcases_video'
require_relative 'change_reference_read'

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
    'goto', 'wait_for', 'screenshot', 'capture', *ChangeFlowCompiler::STATE_WAITS,
    *ChangeFlowCompiler::EVENT_WAITS, *ChangeFlowCompiler::ASSERTIONS, *ChangeFlowCompiler::REFERENCE_VERBS
  ).freeze

  # `grader` is the seam a test drives; a real run builds the default one, which
  # resolves its command from the environment and reports itself unavailable
  # rather than raising when nothing is reachable. `today` is the second seam,
  # for the same reason: a quarantine expiry is a date comparison, and a test
  # that could only assert it by waiting is not a test.
  # `sleeper` is the backoff seam, so a queue-rejection test does not wait.
  # `video_runner` and `free_space` are the --export video seams: the FFmpeg
  # call and the free-bytes probe.
  def initialize(config, context, grader: nil, today: nil, sleeper: nil, video_runner: nil, free_space: nil)
    super(config, context)
    @video_runner = video_runner
    @free_space = free_space || ->(dir) { ChangeTestcasesVideo.free_bytes(dir) }
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

  # One ChangeCaseResult per run case, in case order: the record every report
  # and the history ledger read. A failure gate_tags or a quarantine kept off
  # the gate is still a failure here; the record says what happened.
  def case_records
    Array(@results).map do |result|
      item = result[:case]
      ChangeCaseResult.new(
        key: item.qualified_id, suite: item.suite, id: item.id, persona: item.persona_name,
        status: record_status(result), attempts: result[:attempt_log],
        duration_ms: result[:duration_ms], started_at: result[:started_at], commit: commit,
        run_id: run_id, evidence_dir: result[:record]&.dig('evidenceDir'),
        acceptance_verdict: result[:verdict]&.verdict, step_durations: step_durations(result[:record]),
        quarantined: item.quarantined?(today), quarantine_reason: item.quarantined?(today) ? item.quarantine.reason : nil,
        vars: figures(item, result[:record]), relations: relation_results(item, result[:record]),
        blocked_reason: blocked_reason(item, result[:record])
      )
    end
  end

  # `{index, verb, label, started_at_ms, duration_ms}` per step the final
  # attempt ran. `label` is the author's own name for the step when it has one.
  def step_durations(record)
    Array(record&.dig('steps')).filter_map do |step|
      next unless step['durationMs']

      { 'index' => step['index'], 'verb' => step['verb'], 'label' => step['tag'] || step['label'],
        'started_at_ms' => step['startedAtMs'], 'duration_ms' => step['durationMs'] }
    end
  end

  # A case whose steps passed is a pass only when its acceptance criterion was
  # graded `pass`. A `fail` or `unclear` verdict, or no grading at all, is not
  # a pass: the record says what happened, whatever the gate made of it. A case
  # that needed a re-read to agree with itself (drift) is a `warn` on the same
  # terms: its criterion must still be graded `pass`.
  def record_status(result)
    outcome = result[:outcome]
    return 'fail' if outcome == 'warn'
    return result[:verdict]&.pass? ? 'warn' : 'fail' if outcome == 'drift'
    return 'fail' if outcome == 'pass' && !result[:verdict]&.pass?

    outcome
  end

  # (suite_version 6) The figures a case read, one entry per read in step
  # order, with where and when each was read, and what each said (a value an
  # env var supplied never travels: it is masked here like in the grader).
  def figures(item, record)
    secrets = secret_values(item)
    walked_steps(record).filter_map do |step|
      next unless step['captured']

      { 'var' => step['captured'], 'value' => scrub_value(step['found'], secrets), 'kind' => step['kind'], 'url' => step['url'],
        'selector' => step['selector'], 'read_at' => step['readAt'], 'freshness' => freshness_text(step['freshness']),
        'source' => step['source'] || 'page', 'pair' => step['pair'] }.compact
    end
  end

  def freshness_text(map)
    return nil unless map.is_a?(Hash)

    map.values.compact.map { |text| flatten(text) }.reject(&:empty?).join(' | ').then { |text| text.empty? ? nil : text }
  end

  def scrub_value(value, secrets)
    return value.map { |item| scrub_value(item, secrets) } if value.is_a?(Array)
    return value unless value.is_a?(String) && !secrets.empty?

    value.gsub(Regexp.union(secrets.sort_by { |secret| -secret.length }), ChangeFlowCompiler::REDACTED)
  end

  # Each relation check the case made: what it compared, how it came out, and
  # for a drift or a failure, the first reads beside the re-reads.
  def relation_results(item, record)
    secrets = secret_values(item)
    walked_steps(record).filter_map do |step|
      next unless step['verb'] == 'expectRelation'

      { 'label' => step['label'], 'relation' => step['relation'],
        'status' => step['ok'] ? step['status'] || 'pass' : 'fail', 'drift' => step['drift'] == true,
        'reads' => relation_reads(step['reads'], secrets), 'first_reads' => relation_reads(step['firstReads'], secrets),
        'message' => scrub_value(step['error'] || step['firstMessage'], secrets) }.compact
    end
  end

  def relation_reads(reads, secrets)
    return nil unless reads.is_a?(Array)

    reads.map do |read|
      { 'var' => read['var'], 'value' => scrub_value(read['value'], secrets), 'url' => read['url'], 'read_at' => read['readAt'],
        'freshness' => freshness_text(read['freshness']), 'source' => read['source'] }.compact
    end
  end

  # The call budget for one case, in ms. An explicit `cases[].timeout_ms`
  # wins; otherwise every step's timeout plus a navigation allowance per
  # `goto`, floored so a short case keeps the default call limit.
  def case_budget_ms(item)
    return item.timeout_ms if item.timeout_ms

    derived = (item.preconditions + item.steps).sum do |step|
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

    findings = errors + case_findings(selected, session) + acceptance_findings + quarantine_findings(selected)
    evidence&.write_records(case_records)
    findings
  rescue ChangeFlowCompiler::Error, ChangeReferenceRead::Error => e
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

    lines = grader_model_lines
    return lines if @results.none? { |result| result[:verdict]&.fail? }

    [ *lines, '', ChangeAcceptanceGrader.override_guidance(interactive: interactive?) ]
  end

  # One line naming the model that graded, so a verdict that differs between a
  # local override and CI is visible rather than silent.
  def grader_model_lines
    model = @grader.respond_to?(:reported_model) ? @grader.reported_model : nil
    return [] unless model && @results.any? { |result| result[:verdict] }

    [ '', "Acceptance criteria graded by model: #{model}." ]
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

  # `--fail-on-warn` and `--fail-on-blocked` ride the run context like
  # `--suite`: a property of this invocation. By default a drift warning and a
  # blocked precondition pass the gate (they are reported, not hidden); each
  # flag makes its status fail it.
  def fail_on_warn? = @context.respond_to?(:fail_on_warn) && @context.fail_on_warn == true

  def fail_on_blocked? = @context.respond_to?(:fail_on_blocked) && @context.fail_on_blocked == true

  # The reference hosts `--reference-host` allowlisted, parsed. Until
  # lanes.testcases.reference_hosts exists, this flag is the only source, so a
  # suite cannot allowlist its own reference.
  def reference_hosts
    return [] unless @context.respond_to?(:reference_hosts)

    Array(@context.reference_hosts).map { |text| ChangeReferenceRead.parse_host(text) }
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
    start_video(selected.size)
    start_reference_bridge(compiled, selected)
    runs = run_pool(selected.size) do |index|
      run_case(session, selected[index], compiled[index]).tap { |run| queue_video(selected[index], run) }
    end
    finish_video
    @results = selected.each_with_index.map { |item, index| graded(item, runs[index]) }
    @results.map { |graded| case_finding(graded) }
  ensure
    @bridge&.close
  end

  # A case with a `reference_get` step reaches its reference through a
  # token-guarded host socket (ChangeReferenceBridge), started only when some
  # case needs it and a host is allowlisted. Without an allowlisted host the
  # step has no bridge and blocks the case with the flag to pass.
  def start_reference_bridge(compiled, selected)
    return unless compiled.any? { |entry| (entry[:preconditions] + entry[:steps]).any? { |step| step[:verb] == 'referenceGet' } }

    hosts = reference_hosts
    return if hosts.empty?

    @bridge = ChangeReferenceBridge.new(ChangeReferenceRead.new(hosts: hosts))
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

  # --- --export video ------------------------------------------------------------

  def exports = @context.respond_to?(:exports) ? Array(@context.exports).map(&:to_s) : []

  def video? = exports.include?('video') && !evidence.nil?

  def video_budget_mb
    value = @context.respond_to?(:video_budget_mb) ? @context.video_budget_mb : nil
    Integer(value || ChangeTestcasesVideo::DEFAULT_BUDGET_MB)
  end

  # Below this a case's share records too little to be worth a video.
  MIN_RECORDING_BYTES = 256 * 1024

  def start_video(case_count)
    return unless video?

    root = evidence.root
    @video_bytes = ChangeTestcasesVideo.per_case_bytes(free_bytes: @free_space.call(root), case_count: case_count,
                                                       budget_mb: video_budget_mb)
    @recording_open = case_count
    @video_lock = Mutex.new
    options = { reserve: ChangeTestcasesVideo.reserve_bytes(case_count), free: -> { @free_space.call(root) },
                outstanding: -> { @recording_open * @video_bytes } }
    options[:runner] = @video_runner if @video_runner
    @encoder = ChangeTestcasesVideo::Encoder.new(**options)
  end

  # What a case module needs to record: its byte share and the title card.
  # `used` is what an earlier segment of the same attempt already recorded,
  # so a resumed case shares one allowance rather than getting a second.
  def video_js(item, used = 0)
    return nil unless @encoder && @video_bytes - used >= MIN_RECORDING_BYTES

    { maxBytes: @video_bytes - used, fps: ChangeTestcasesVideo::FPS, maxWidth: ChangeTestcasesVideo::MAX_WIDTH,
      maxHeight: ChangeTestcasesVideo::MAX_HEIGHT, title: item.qualified_id, acceptance: item.acceptance }
  end

  # Once a case is final: keep only its last attempt's frames and queue its
  # encode, which runs beside the remaining cases.
  def queue_video(item, run)
    return unless @encoder

    @video_lock.synchronize { @recording_open -= 1 }
    return @encoder.failed(item.qualified_id, 'not enough free disk to record above the evidence reserve') if @video_bytes < MIN_RECORDING_BYTES

    dirs = run[:attempts].filter_map { |entry| entry[:evidence_dir] }
    return @encoder.failed(item.qualified_id, 'the case made no attempt to record') if dirs.empty?

    dirs[0...-1].each { |dir| ChangeTestcasesVideo.drop_frames(dir) }
    video = run[:record].is_a?(Hash) ? run[:record]['video'] || {} : {}
    @encoder.add(key: item.qualified_id, attempt_dir: dirs.last, marks: video['marks'], stopped: video['stopped'],
                 out: File.join(evidence.root, 'cases', ChangeTestcasesEvidence.slug(item.suite),
                                ChangeTestcasesEvidence.slug(item.id), 'video.mp4'))
  end

  def finish_video
    return unless @encoder

    evidence.write_exports('video' => @encoder.finish)
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
    started_at = Time.now.utc.iso8601(3)
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
                    duration_ms: elapsed_ms(attempt_started), evidence_dir: record['evidenceDir'] }
      break if record['ok'] || record['blocked']

      # A rerun follows; this attempt's frames will not be encoded, so they
      # give their disk back before the next attempt records.
      ChangeTestcasesVideo.drop_frames(record['evidenceDir']) if @encoder && record['evidenceDir'] && number < item.retries
    end
    { record: record, attempts: attempts, started_at_ms: elapsed_ms(@run_started, started),
      started_at: started_at, duration_ms: elapsed_ms(started) }
  end

  def attempt_outcome(record)
    special_outcome(record) || (record['blocked'] ? 'blocked_precondition' : (record['ok'] ? 'pass' : 'fail'))
  end

  def special_outcome(record)
    return 'partial_evidence' if record&.dig('partialEvidence')

    'auth_interrupted' if record&.dig('authInterrupted')
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
    dir = evidence&.open_attempt(item, number, start_record(item, number, persona))
    record = call_function(session, case_module(compiled, number, persona_js(item, state), evidence: dir&.js,
                                                                                         video: dir && video_js(item)),
                           case_budget_ms(item))
    if persona && record.is_a?(Hash) && record['authExpired']
      record = resume_after_expiry(session, item, compiled, number, persona, generation, record, dir)
    end
    dir ? evidence.close_attempt(dir, record) : record
  rescue PersonaCache::LoginError => e
    { 'ok' => false, 'notAttempted' => true, 'loginFailed' => true, 'steps' => [],
      'authError' => "persona '#{item.persona_name}' could not log in: #{e.message}" }
  end

  def unknown_persona(item)
    { 'ok' => false, 'notAttempted' => true, 'steps' => [],
      'authError' => "the case names persona '#{item.persona_name}', which lanes.testcases.personas does not define" }
  end

  def start_record(item, number, persona)
    { case: item.qualified_id, attempt: number, persona: persona || item.persona_name,
      budget_ms: case_budget_ms(item), started_at: Time.now.utc.iso8601(3) }
  end

  # The run-scoped evidence dir from the run context, or nil when the run
  # gives none (a caller driving the lane directly).
  def evidence
    return @evidence if defined?(@evidence)

    root = @context.respond_to?(:evidence_dir) ? @context.evidence_dir : nil
    @evidence = root ? ChangeTestcasesEvidence.new(root) : nil
  end

  def run_id = @context.respond_to?(:run_id) ? @context.run_id : nil

  # The runner's resolved commit (a schedule's base sha) when it gives one,
  # else the checkout's HEAD.
  def commit
    return @commit if defined?(@commit)

    given = @context.respond_to?(:commit) ? @context.commit.to_s : ''
    return @commit = given unless given.empty?

    out = IO.popen([ 'git', '-C', @config.dir.to_s, 'rev-parse', 'HEAD' ], err: File::NULL, &:read).to_s.strip
    @commit = out.empty? ? nil : out
  rescue SystemCallError
    @commit = nil
  end

  def resume_after_expiry(session, item, compiled, number, persona, generation, record, dir = nil)
    expired = record['authExpired']
    begin
      state, = @personas.refresh(persona, generation)
    rescue PersonaCache::LoginError => e
      return record.merge('ok' => false, 'authError' => "the session ended and persona '#{persona}' could not log in again: #{e.message}")
    end
    restart = restart_index(compiled[:steps], Integer(expired['index']))
    unless replayable?(item, compiled[:steps], restart, Integer(expired['index']))
      return record.merge('ok' => false, 'authInterrupted' => true)
    end

    resume = { startAt: restart, vars: record['vars'] || {}, reads: record['reads'] || {} }
    second = call_function(session, case_module(compiled, number, persona_js(item, state), resume: resume,
                                                                                           evidence: dir&.js,
                                                                                           video: dir && video_js(item, record.dig('video', 'bytes').to_i)),
                           case_budget_ms(item))
    merge_resumed(record, second, resume[:startAt])
  end

  # A resumed case restarts at the last navigation at or before the
  # interrupted step, because a fresh context has none of the page state
  # (typed fields, client-side state) the steps after that navigation built.
  # Without one it restarts at the first step, on the persona's landing page.
  def restart_index(steps, interrupted)
    steps.select { |step| step[:index] <= interrupted && step[:verb] == 'goto' }.map { |step| step[:index] }.max || 0
  end

  # Every step from the restart to the interrupted one is replayed, so all of
  # them must be safe to repeat, unless the case says replay is safe.
  def replayable?(item, steps, from, to)
    return true if item.safe_retry

    steps.select { |step| step[:index].between?(from, to) }.all? { |step| REPLAYABLE_VERBS.include?(step[:verb]) }
  end

  # The resumed call's record, carrying the first call's steps before the
  # interrupted one. A second session end in the same attempt fails the case.
  def merge_resumed(first, second, start_at)
    return first.merge('ok' => false, 'callError' => 'the resumed call after a re-login returned no result') unless second.is_a?(Hash)
    if second['queueFull']
      return first.merge('ok' => false, 'resumed' => true, 'queueFull' => true,
                         'callError' => "the resumed call after a re-login was not accepted: #{second['callError']}")
    end

    earlier = Array(first['steps']).select { |step| step['index'].to_i < start_at }
    merged = second.merge('steps' => earlier + Array(second['steps']), 'resumed' => true,
                          'preconditions' => Array(first['preconditions']),
                          'video' => merged_video(first['video'], second['video']))
    return merged unless second['authExpired']

    merged.merge('ok' => false, 'authError' => 'the session ended again after a re-login in the same attempt')
  end

  # Both segments of a resumed recording: frames are already on disk in order
  # (frame-a* then frame-r*), so only the caption marks need joining, the
  # second segment's shifted to follow the first.
  def merged_video(first, second)
    return second || first unless first.is_a?(Hash) && second.is_a?(Hash)

    offset = (first['frames'].to_i * 1000) / ChangeTestcasesVideo::FPS
    marks = Array(first['marks']) + Array(second['marks']).map { |mark| mark.merge('ms' => mark['ms'].to_i + offset) }
    { 'frames' => first['frames'].to_i + second['frames'].to_i, 'marks' => marks,
      'stopped' => second['stopped'] || first['stopped'] }
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
    outcome = special_outcome(record) || status
    { case: item, record: record, status: status, outcome: outcome,
      attempts: [ run[:attempts].size, 1 ].max, attempt_log: run[:attempts],
      started_at_ms: run[:started_at_ms], started_at: run[:started_at], duration_ms: run[:duration_ms] }
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

    gradable = @results.select { |result| %w[pass drift].include?(result[:status]) }
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
      steps: Array(record['steps']), url: observed['url'], title: observed['title'], text: observed['text'],
      captured: captured_values(record), relations: relation_results(result[:case], record),
      secrets: secret_values(result[:case]) }
  end

  # The figures a case's `capture` steps read, in step order, each with the
  # value and time of that very read: a variable captured twice reports both
  # readings, never the later value under the earlier time.
  def captured_values(record)
    Array(record['steps']).filter_map do |step|
      next unless step['captured']

      { var: step['captured'], value: step['found'], kind: step['kind'], read_at: step['readAt'], url: step['url'],
        source: step['source'] }.compact
    end
  end

  # The values the case read from env vars: the lane's redaction rule says
  # they travel to the container only, so the grader's payload masks them.
  def secret_values(item)
    before = ChangeFlowCompiler.new(item.preconditions, base_url: base_url, timeout_ms: timeout_ms).compile
    after = ChangeFlowCompiler.new(item.steps, base_url: base_url, timeout_ms: timeout_ms, before: before).compile
    (before + after).filter_map { |step| step[:value] if step[:secret] }
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

  # `drift` and `blocked_precondition` are the suite_version 6 outcomes: a case
  # that passed after a re-read, and a case that could not be verified. Neither
  # is a failure, so neither takes the gated-or-not branch below.
  def status_for(item, record)
    return 'blocked_precondition' if blocked_reason(item, record)
    return (drift?(record) ? 'drift' : 'pass') if record && record['ok']

    gated?(item) ? 'fail' : 'warn'
  end

  # Every step record the call returned: the preconditions' and the case's own.
  def walked_steps(record) = Array(record&.dig('preconditions')) + Array(record&.dig('steps'))

  def drift?(record) = walked_steps(record).any? { |step| step['ok'] && step['status'] == 'warn' }

  # Why a case could not be verified, or nil. A failing precondition or a
  # reference that could not be read always blocks; a persona that could not
  # log in blocks only in a suite_version 6 file, so a v4 or v5 suite keeps
  # failing the gate on a lost login exactly as it did.
  def blocked_reason(item, record)
    return nil unless record.is_a?(Hash)

    blocked = record['blocked']
    return "#{blocked['kind']}: #{flatten(blocked['label'])}: #{flatten(blocked['error'])}" if blocked.is_a?(Hash)
    return "login: #{flatten(record['authError'])}" if record['loginFailed'] && item.blocks_on_login?

    step = Array(record['steps']).find { |entry| entry['blocked'] }
    step ? "reference: #{flatten(step['label'])}: #{flatten(step['error'])}" : nil
  end

  def case_finding(graded)
    item = graded[:case]
    status = finding_status(item, graded[:status])
    Finding.new(lane: LANE, check: item.qualified_id, status: status,
                severity: status == 'pass' ? 'info' : 'high',
                target: base_url, location: failure_location(graded),
                detail: detail_for(graded),
                attempts: graded[:attempts], flaky: graded[:status] == 'pass' && graded[:attempts] > 1)
  end

  # The gate signal for a case: warn and blocked pass the gate unless the run
  # asked otherwise with --fail-on-warn or --fail-on-blocked. A case the gate
  # does not cover (gate_tags, a quarantine) stays a warn either way.
  def finding_status(item, status)
    case status
    when 'drift' then fail_on_warn? && gated?(item) ? 'fail' : 'warn'
    when 'blocked_precondition' then fail_on_blocked? && gated?(item) ? 'fail' : 'warn'
    else status
    end
  end

  def failure_location(graded)
    record = graded[:record]
    return '' if record.nil? || (record['ok'] && graded[:status] != 'blocked_precondition')

    step = Array(record['steps']).find { |entry| entry['ok'] == false }
    return "step #{step['index'].to_i + 1}: #{step['label']}" if step
    return "precondition #{record['blocked']['index'].to_i + 1}: #{record['blocked']['label']}" if record['blocked'].is_a?(Hash) && record['blocked']['kind'] == 'precondition'

    record['callError'] ? 'browserless call' : 'login'
  end

  def detail_for(graded)
    record = graded[:record]
    return "case did not run: #{graded[:case].qualified_id} produced no result" if record.nil?
    return "blocked_precondition: #{blocked_reason(graded[:case], record)} (not verified; not counted as a pass or a failure)" if graded[:status] == 'blocked_precondition'
    return "drift: #{drift_detail(record)} (passed on re-read; reported as a warning)" if graded[:status] == 'drift'
    return "#{graded[:case].acceptance}#{quarantine_note(graded[:case])}" if record['ok']

    "#{failure_reason(record)}#{expiry_hint(graded[:case], record)}#{ungated_note(graded)}"
  end

  def drift_detail(record)
    walked_steps(record).select { |step| step['ok'] && step['status'] == 'warn' }
                          .map { |step| "#{flatten(step['label'])}: first #{flatten(step['firstMessage'])}" }.join('; ')
  end

  def failure_reason(record)
    return partial_evidence_reason(record) if record['partialEvidence']
    return auth_interrupted_reason(record) if record['authInterrupted']
    return "login failed before the case ran: #{record['authError']}" if record['notAttempted']
    return "auth: #{record['authError']}" if record['authError']
    return "the case's browserless call failed: #{record['callError']}" if record['callError']

    step = Array(record['steps']).find { |entry| entry['ok'] == false }
    step ? step['error'].to_s : 'case failed with no step-level error recorded'
  end

  # A step failure in a login persona that declares no `expired_when` may be
  # a session that ended mid-case, which the lane cannot tell without a probe.
  def expiry_hint(item, record)
    persona = login_persona(item)
    return '' unless persona && !record['authError'] && !record['callError'] && !record['authInterrupted']
    return '' if persona_raw(persona).is_a?(Hash) && persona_raw(persona).key?('expired_when')

    " (if persona '#{persona}' lost its session mid-case, declare expired_when on it so the lane " \
      'logs in again and resumes)'
  end

  def partial_evidence_reason(record)
    steps = Array(record['steps'])
    last = steps.last ? ", the last was step #{steps.last['index'].to_i + 1}: #{steps.last['label']}" : ''
    "partial_evidence: the call ended before the case returned (#{record['callError']}); " \
      "#{steps.size} step(s) were checkpointed#{last}; evidence in #{record['evidenceDir']}"
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
      preconditions = ChangeFlowCompiler.new(item.preconditions, base_url: base_url, timeout_ms: timeout_ms).compile
      compiler = ChangeFlowCompiler.new(item.steps, base_url: base_url, timeout_ms: timeout_ms, before: preconditions)
      { index: index, id: item.qualified_id, steps: compiler.compile, preconditions: preconditions }
    end
  end

  # Checkpoints to the mounted attempt dir. The function sandbox has no file
  # system, so each file is a download from the function's own blank page into
  # a download path on the mount, which Chrome writes as it goes. A file is on
  # disk once its download completes, whatever happens to the call after.
  EVIDENCE_JS = <<~JS
    async function cfEvidenceWriter(page, evidence, tag) {
      const none = { tag: tag, write: async () => {}, step: async () => {}, screenshot: async () => {}, flush: async () => {} };
      if (!evidence) return none;
      let issued = 0;
      let finished = 0;
      try {
        const client = await page.target().createCDPSession();
        client.on("Browser.downloadProgress", (event) => { if (event.state !== "inProgress") finished += 1; });
        await client.send("Browser.setDownloadBehavior", { behavior: "allow", downloadPath: evidence.dir, eventsEnabled: true });
      } catch (err) {
        return none;
      }
      async function write(name, content, base64) {
        issued += 1;
        try {
          await page.evaluate((fileName, body, isBase64) => {
            const bytes = isBase64 ? Uint8Array.from(atob(body), (ch) => ch.charCodeAt(0)) : body;
            const link = document.createElement("a");
            const url = URL.createObjectURL(new Blob([bytes]));
            link.href = url;
            link.download = fileName;
            document.body.appendChild(link);
            link.click();
            link.remove();
            // Chrome has the blob once the click returns; revoke it after the
            // download has had time to start so a long recording does not
            // keep every frame alive in the page.
            setTimeout(() => URL.revokeObjectURL(url), 10000);
          }, name, content, base64 === true);
        } catch (err) {
          issued -= 1;
        }
      }
      return {
        tag: tag,
        write: write,
        step: (record, log) => {
          const name = `step-${String(record.index + 1).padStart(4, "0")}-${tag}.json`;
          const entry = Object.assign({}, record);
          delete entry.screenshot;
          // A screenshot step's image is checkpointed too, so a call that
          // dies later still leaves it.
          if (record.screenshot) {
            const shot = String(record.name || "screenshot").replace(/[^A-Za-z0-9._-]/g, "_");
            write(`shot-${String(record.index + 1).padStart(4, "0")}-${shot}.png`, record.screenshot, true);
          }
          return write(name, JSON.stringify({ record: entry, console: log.console, failedRequests: log.failedRequests }));
        },
        screenshot: async (casePage, name) => {
          try { await write(`${tag === "r" ? "resumed-" : ""}${name}`, await casePage.screenshot({ encoding: "base64" }), true); } catch (err) { void err; }
        },
        flush: async () => {
          const deadline = Date.now() + 5000;
          while (finished < issued && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 50));
        },
      };
    }

    async function cfTitleCard(page, writer, video) {
      const card = await page.browser().newPage();
      try {
        await card.setViewport({ width: video.maxWidth, height: video.maxHeight });
        await card.setContent("<body style='margin:0;display:flex;flex-direction:column;justify-content:center;" +
          "align-items:center;height:100vh;font-family:sans-serif;background:#fff;color:#111'><h1></h1><p></p></body>");
        await card.evaluate((title, text) => {
          document.querySelector("h1").textContent = title;
          document.querySelector("p").textContent = text;
        }, video.title, video.acceptance);
        await writer.write("title.jpg", await card.screenshot({ type: "jpeg", quality: 80, encoding: "base64" }), true);
      } finally {
        await card.close();
      }
    }

    // --export video: keeps only the latest screencast frame and writes one
    // JPEG per tick into the attempt dir, stopping at the case's byte share.
    // The title card is a screenshot of a page of its own.
    async function cfRecorder(page, writer, casePage, video) {
      const idle = { mark: () => {}, stop: async () => null };
      if (!video) return idle;
      let started = Date.now();
      const marks = [];
      let latest = null;
      let written = 0;
      let bytes = 0;
      let stopped = null;
      let client = null;
      try {
        if (writer.tag === "a") await cfTitleCard(page, writer, video);
        client = await casePage.target().createCDPSession();
        client.on("Page.screencastFrame", (frame) => {
          client.send("Page.screencastFrameAck", { sessionId: frame.sessionId }).catch(() => {});
          latest = frame.data;
        });
        await client.send("Page.startScreencast", { format: "jpeg", quality: 70, maxWidth: video.maxWidth, maxHeight: video.maxHeight, everyNthFrame: 1 });
      } catch (err) {
        return { mark: () => {}, stop: async () => ({ frames: 0, marks: [], stopped: "recording could not start: " + String(err) }) };
      }
      // Captions are timed from the first recorded tick, not from the title
      // card and screencast setup, which add no frames.
      started = Date.now();
      const timer = setInterval(() => {
        if (stopped || latest === null) return;
        const size = Math.floor((latest.length * 3) / 4);
        if (bytes + size > video.maxBytes) { stopped = "byte budget reached"; return; }
        bytes += size;
        written += 1;
        writer.write(`frame-${writer.tag}${String(written).padStart(6, "0")}.jpg`, latest, true);
      }, Math.round(1000 / video.fps));
      return {
        mark: (label) => marks.push({ ms: Date.now() - started, label: label }),
        stop: async () => {
          clearInterval(timer);
          try { await client.send("Page.stopScreencast"); } catch (err) { void err; }
          // The end state is always the last frame, even for a case faster
          // than one tick, unless the byte share is spent.
          if (!stopped) {
            // A fresh capture, since the last screencast frame can predate
            // the final step's change; the frame is the fallback.
            let last = latest;
            try {
              last = await casePage.screenshot({ type: "jpeg", quality: 70, encoding: "base64" });
            } catch (err) { void err; }
            const size = last === null ? 0 : Math.floor((last.length * 3) / 4);
            if (last !== null && bytes + size <= video.maxBytes) {
              bytes += size;
              written += 1;
              await writer.write(`frame-${writer.tag}${String(written).padStart(6, "0")}.jpg`, last, true);
            }
          }
          return { frames: written, bytes: bytes, marks: marks, stopped: stopped };
        },
      };
    }

    // Console errors and failed requests, collected per step so each step's
    // trace says what went wrong while it ran.
    function cfStepLog(casePage) {
      let current = { console: [], failedRequests: [] };
      casePage.on("console", (message) => { if (message.type() === "error") current.console.push(message.text()); });
      casePage.on("pageerror", (err) => current.console.push(String(err)));
      casePage.on("requestfailed", (request) => {
        current.failedRequests.push({ url: request.url(), error: (request.failure() || {}).errorText || "failed" });
      });
      casePage.on("response", (response) => {
        if (response.status() >= 400) current.failedRequests.push({ url: response.url(), status: response.status() });
      });
      return { take: () => { const taken = current; current = { console: [], failedRequests: [] }; return taken; } };
    }
  JS

  # What a case module knows about its persona: the seeded storage state, the
  # persona's declared `expired_when` probe (nil when it declares none, which
  # turns mid-case detection off), and whether a mutating step may be
  # replayed. nil for a case that runs without a login.
  def persona_js(item, state)
    persona = login_persona(item)
    return nil unless persona

    { name: persona, seed: state, safeRetry: item.safe_retry == true,
      expectsLogout: item.expects_logout == true, expiredWhen: expired_when_js(persona) }
  end

  def persona_raw(name) = name == 'default' ? @config['auth'] : personas_config[name]

  # The persona's `expired_when`, compiled: a selector as given, or a probe
  # url resolved against the base url with its statuses as a list.
  def expired_when_js(persona)
    rule = persona_raw(persona)&.dig('expired_when')
    return nil unless rule.is_a?(Hash)
    return { selector: rule['selector'].to_s } if rule['selector']

    { probeUrl: URI.join(base_url, rule['probe_url'].to_s).to_s,
      expectStatus: Array(rule['expect_status']).map { |status| Integer(status) } }
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
          const landing = /^https?:/.test(session.page.url()) ? session.page.url() : null;
          return { data: { ok: true, state: { cookies: cookies, origins: origins, landing: landing } }, type: "application/json" };
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
  # `evidence` names the attempt's dir in the container; the module
  # checkpoints into it as it goes.
  def case_module(compiled, attempt, persona = nil, resume: nil, evidence: nil, video: nil)
    <<~JS
      export default async function ({ page }) {
        const testCase = #{JSON.generate(compiled)};
        const attempt = #{Integer(attempt)};
        const persona = #{JSON.generate(persona)};
        const resume = #{JSON.generate(resume)};
        const evidence = #{JSON.generate(evidence)};
        const video = #{JSON.generate(video)};
        const bridge = #{JSON.generate(@bridge&.endpoint)};
        #{session_js}
        #{ChangeFlowCompiler.flow_runtime_js}
        #{EVIDENCE_JS}

        // The persona's login, seeded rather than replayed: its cookies, and
        // its localStorage written on the first document of each origin.
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
              // Once per origin per case: the marker lives in sessionStorage,
              // which survives reloads in this tab, so a key the case deletes
              // stays deleted.
              if (!entry || window.sessionStorage.getItem("__cf_seeded") === "1") return;
              window.sessionStorage.setItem("__cf_seeded", "1");
              for (const [key, value] of entry.items) {
                if (window.localStorage.getItem(key) === null) window.localStorage.setItem(key, value);
              }
            } catch (err) { void err; }
          }, origins);
        }

        // The session has ended only when the persona's declared probe says
        // so: its `selector` is visible, or a GET of its `probe_url` answers
        // one of `expect_status` (a redirect counts as any 3xx listed). No
        // declaration, or a case that logs out on purpose, means no check.
        async function sessionEnded(casePage) {
          if (!persona || !persona.expiredWhen || persona.expectsLogout) return false;
          const rule = persona.expiredWhen;
          try {
            if (rule.selector) {
              const el = await casePage.$(rule.selector);
              if (!el) return false;
              return await el.evaluate((node) => {
                const style = getComputedStyle(node);
                return style.visibility !== "hidden" && style.display !== "none" && node.getClientRects().length > 0;
              });
            }
            const status = await casePage.evaluate(async (url) => {
              const response = await fetch(url, { credentials: "include", redirect: "manual", cache: "no-store" });
              return response.type === "opaqueredirect" ? "redirect" : response.status;
            }, rule.probeUrl);
            if (status === "redirect") return rule.expectStatus.some((code) => code >= 300 && code < 400);
            return rule.expectStatus.includes(status);
          } catch (err) {
            return false;
          }
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
          const writer = await cfEvidenceWriter(page, evidence, resume ? "r" : "a");
          const session = await openSession(page);
          try {
            if (persona) await seedStorage(session.page, persona.seed);
            const log = cfStepLog(session.page);
            const recorder = await cfRecorder(page, writer, session.page, video);
            // (suite_version 6) Reference reads go to the host, which owns the
            // allowlist and the address checks; without a bridge there is none.
            const reference = bridge ? async (request) => {
              const response = await fetch(bridge.url, { method: "POST", body: JSON.stringify(Object.assign({ token: bridge.token }, request)) });
              return response.json();
            } : null;
            // A seeded case starts where its persona's login landed, as it
            // did when every case logged in on its own page, unless its first
            // step navigates anyway. Preconditions, which run before the
            // case's own steps (and not again on a resumed call), come first.
            const preconditions = resume ? [] : (testCase.preconditions || []);
            const first = preconditions[0] || testCase.steps.find((step) => step.index >= (resume ? resume.startAt : 0));
            if (persona && persona.seed && persona.seed.landing && first && first.verb !== "goto") {
              await cfInstallMeasure(session.page, testCase.steps);
              await session.page.goto(persona.seed.landing, { waitUntil: "domcontentloaded" });
            }
            let blocked = null;
            let pre = [];
            if (preconditions.length > 0) {
              // The recorder must be on the page before the precondition's own
              // navigation, or the steps' expect_stable has no first paint.
              await cfInstallMeasure(session.page, testCase.steps);
              pre = await cfRunFlow(session.page, preconditions, { reference: reference });
              const unmet = pre.find((step) => !step.ok);
              if (unmet) blocked = { kind: "precondition", index: unmet.index, label: unmet.label, error: unmet.error };
              if (unmet) await writer.screenshot(session.page, "failure.png");
            }
            let expired = null;
            // Captions mark each step as it starts: the first here, the rest
            // from the step before it, since cfRunFlow has no pre-step hook.
            if (first) recorder.mark(first.label);
            const steps = blocked ? [] : await cfRunFlow(session.page, testCase.steps, {
              startAt: resume ? resume.startAt : 0,
              vars: resume ? resume.vars : (pre.vars || {}),
              reads: resume ? resume.reads : (pre.reads || {}),
              reference: reference,
              afterStep: async (step, record) => {
                await writer.step(record, log.take());
                if (!record.ok) await writer.screenshot(session.page, "failure.png");
                if (!(await sessionEnded(session.page))) {
                  // The caption moves on only when the flow does.
                  const following = testCase.steps.find((other) => other.index > step.index);
                  if (record.ok && following) recorder.mark(following.label);
                  return false;
                }
                expired = { index: step.index, verb: step.verb };
                return true;
              },
            });
            const stuck = steps.find((step) => step.blocked);
            if (stuck && !blocked) blocked = { kind: "reference", index: stuck.index, label: stuck.label, error: stuck.error };
            const ok = !blocked && !expired && steps.every((step) => step.ok);
            const recording = await recorder.stop();
            await writer.screenshot(session.page, "final.png");
            return { ok: ok, steps: steps, vars: steps.vars || pre.vars, reads: steps.reads || pre.reads, authExpired: expired,
                     video: recording, blocked: blocked, preconditions: pre,
                     observation: ok ? await observe(session.page) : null };
          } finally {
            await closeSession(session);
            await writer.flush();
          }
        }

        const result = await runOnce(testCase);
        return {
          data: { index: testCase.index, id: testCase.id, attempt: attempt, ok: result.ok, authError: null,
                  authExpired: result.authExpired, vars: result.vars, reads: result.reads, steps: result.steps, video: result.video,
                  blocked: result.blocked, preconditions: result.preconditions, observation: result.observation },
          type: "application/json",
        };
      }
    JS
  end
end
