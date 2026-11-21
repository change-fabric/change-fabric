# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "tempfile"
require "json"
require "date"
require_relative "../scripts/change_config"
require_relative "../scripts/change_run"
require_relative "../scripts/change_lane_testcases"
require_relative "../scripts/change_acceptance_grader"

# The testcases lane: suite loading and its refusals, tag filtering, what
# gate_tags does and does not soften, and the compiled payload. The browser JS
# itself is exercised by a real docker run, not here; what this covers is the
# Ruby deciding what that JS is handed and how a returned record becomes a
# verdict.
class ChangeLaneTestcasesTest < Minitest::Test
  # Mirrors ChangeRun::Context's shape, including `suite_select`, which is how
  # `--suite` reaches the lane. Named with the prefix for the same reason the
  # real one is: a Struct member called `select` would be shadowed by
  # Enumerable#select and the lane would read the member list as a filter.
  Ctx = Struct.new(:network, :target_url, :browserless, :suite_select, :signoff) do
    def log(_message) = nil
    def signoff? = signoff == true
  end

  # A grader whose verdicts the test dictates. Every lane in this file gets one,
  # so no test can reach for a real LLM: a suite whose result depends on a model
  # being installed is exactly the non-reproducibility this lane exists to end.
  class FakeGrader
    attr_reader :observations

    def initialize(verdicts: {}, reason: nil)
      @verdicts = verdicts
      @reason = reason
    end

    def unavailable_reason = @reason

    def reported_model = @model

    def with_model(model)
      @model = model
      self
    end

    def grade(observations)
      @observations = observations
      observations.map do |observation|
        verdict, rationale = @verdicts.fetch(observation[:id], [ "pass", "looks right" ])
        ChangeAcceptanceGrader::Verdict.new(id: observation[:id], verdict: verdict, rationale: rationale)
      end
    end
  end

  # A stand-in browserless session. Each call carries one case's module; the
  # fake reads the case index the module embeds and returns that case's record
  # from `records`. A record that is an Array is one entry per successive
  # attempt, and an entry that is an Exception is raised instead. `code` joins
  # every module it was handed, so a test can assert on what reached the
  # container across all calls.
  class FakeSession
    attr_reader :codes, :launch_args, :timeouts, :max_in_flight

    def initialize(records, delay: 0)
      @records = records
      @delay = delay
      @codes = []
      @timeouts = []
      @lock = Mutex.new
      @in_flight = 0
      @max_in_flight = 0
    end

    def code = @codes.join("\n")

    def calls = @codes.size

    def run_function(code, launch_args: [], timeout_ms: nil)
      index = code[/const testCase = \{"index":(\d+)/, 1].to_i
      entry = @lock.synchronize do
        @codes << code
        @timeouts << timeout_ms
        @launch_args = launch_args
        @in_flight += 1
        @max_in_flight = [ @max_in_flight, @in_flight ].max
        next_entry(index)
      end
      sleep(@delay) if @delay.positive?
      raise entry if entry.is_a?(Exception)

      entry
    ensure
      @lock.synchronize { @in_flight -= 1 }
    end

    private

    def next_entry(index)
      record = @records[index] if @records[index].is_a?(Array)
      record ||= @records.find { |item| item.is_a?(Hash) && item["index"] == index }
      return record unless record.is_a?(Array)

      record.size > 1 ? record.shift : record.first
    end
  end

  SUITE = <<~YAML
    suite: checkout
    suite_version: 2
    cases:
      - id: happy-path
        tags: [checkout, smoke]
        acceptance: A guest can reach the confirmation page.
        steps:
          - goto: /products/widget
          - click: "[data-test=add-to-cart]"
          - expect_url: { contains: "/confirmation" }
      - id: empty-cart
        tags: [checkout]
        acceptance: An empty cart says so.
        retries: 1
        safe_rerun: true
        steps:
          - goto: /cart
          - expect_visible: "[data-test=empty]"
  YAML

  def with_suite(body = SUITE)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "checkout.cf-testcases.yml"), body)
      yield dir
    end
  end

  def lane(dir, raw = {}, session: nil, select: [], grader: FakeGrader.new, today: nil, signoff: false, sleeper: nil)
    config = ChangeConfig::LaneConfig.new("testcases", { "suites" => [ "*.cf-testcases.yml" ] }.merge(raw), dir)
    ChangeLaneTestcases.new(config, Ctx.new("net", "https://app.example.org", session, select, signoff),
                            grader: grader, today: today, sleeper: sleeper || ->(_seconds) { })
  end

  # Only findings about the cases' steps, not the acceptance gradings that now
  # accompany them, so the assertions each test already made keep meaning what
  # they meant.
  def step_findings(findings) = findings.reject { |finding| finding.check.end_with?("acceptance") }

  def acceptance_findings(findings) = findings.select { |finding| finding.check.end_with?("acceptance") }

  def ok_result(count)
    (0...count).map do |i|
      { "index" => i, "attempts" => 1, "ok" => true, "steps" => [],
        "observation" => { "url" => "https://app.example.org/confirmation", "title" => "Order confirmed",
                           "text" => "Thanks for your order" } }
    end
  end

  def failed_result(index, steps)
    { "index" => index, "attempts" => 1, "ok" => false, "authError" => nil, "steps" => steps }
  end

  # --- registration -------------------------------------------------------------

  def test_the_lane_is_registered_everywhere_a_lane_has_to_be
    assert_includes ChangeSchema::LANES, "testcases"
    assert_equal ChangeLaneTestcases, ChangeRun::LANE_CLASSES.fetch("testcases")
    assert_includes ChangeRun::BROWSER_LANES, "testcases"
    assert_includes ChangeConfig::BROWSER_LANES, "testcases"
    assert_includes ChangeConfig::AUTH_LANES, "testcases"
  end

  # The lane reads no targets block, so it stays out of the zap-only list; a
  # scope list nothing reads is worse than no scope list.
  def test_the_lane_is_not_a_target_lane
    refute_includes ChangeConfig::TARGET_LANES, "testcases"
  end

  # --- verdicts -----------------------------------------------------------------

  def test_every_passing_case_reports_its_acceptance_criterion
    with_suite do |dir|
      findings = step_findings(lane(dir, {}, session: FakeSession.new(ok_result(2))).run)

      assert_equal 2, findings.size
      assert findings.all?(&:pass?)
      assert_equal %w[checkout/happy-path checkout/empty-cart], findings.map(&:check)
      assert_equal "A guest can reach the confirmation page.", findings.first.detail
    end
  end

  def test_a_failing_step_fails_the_case_and_names_the_step
    with_suite do |dir|
      result = ok_result(2)
      result[0] = failed_result(0, [ { "index" => 1, "label" => "click [data-test=add-to-cart]", "ok" => false,
                                       "error" => "Error: waiting for selector failed" } ])
      findings = step_findings(lane(dir, {}, session: FakeSession.new(result)).run)

      assert findings.first.fail?
      assert_includes findings.first.location, "step 2: click [data-test=add-to-cart]"
      assert_includes findings.first.detail, "waiting for selector failed"
    end
  end

  # gate_tags is the staged-adoption valve: a failing case no gate tag covers
  # still reports, it just cannot fail the run.
  def test_launch_args_reach_the_browserless_launch
    with_suite do |dir|
      session = FakeSession.new(ok_result(2))
      lane(dir, { "launch_args" => [ "--disable-features=LocalNetworkAccessChecks" ] }, session: session).run
      assert_equal [ "--disable-features=LocalNetworkAccessChecks" ], session.launch_args
    end
  end

  def test_no_launch_args_launches_with_none
    with_suite do |dir|
      session = FakeSession.new(ok_result(2))
      lane(dir, {}, session: session).run
      assert_equal [], session.launch_args
    end
  end

  def test_gate_tags_softens_only_the_cases_no_gate_tag_covers
    with_suite do |dir|
      result = [ failed_result(0, []), failed_result(1, []) ]
      findings = step_findings(lane(dir, { "gate_tags" => [ "smoke" ] }, session: FakeSession.new(result)).run)

      assert_equal %w[fail warn], findings.map(&:status)
      assert_includes findings.last.detail, "not gated"
    end
  end

  def test_a_gate_tag_no_case_carries_is_a_failing_finding
    with_suite do |dir|
      findings = lane(dir, { "gate_tags" => [ "smoek" ] }, session: FakeSession.new(ok_result(2))).run

      gate = findings.find { |finding| finding.check == "gate_tags" }
      assert gate.fail?
      assert_includes gate.detail, "smoek"
    end
  end

  def test_tags_select_which_cases_run
    with_suite do |dir|
      session = FakeSession.new(ok_result(1))
      findings = step_findings(lane(dir, { "tags" => [ "smoke" ] }, session: session).run)

      assert_equal [ "checkout/happy-path" ], findings.map(&:check)
      refute_includes session.code, "/cart"
    end
  end

  def test_a_case_that_only_passed_on_a_retry_is_recorded_flaky
    with_suite do |dir|
      result = ok_result(2)
      result[1] = [ failed_result(1, []), { "index" => 1, "ok" => true, "steps" => [] } ]
      session = FakeSession.new(result)
      findings = step_findings(lane(dir, {}, session: session).run)

      assert_equal 3, session.calls
      assert findings.last.pass?
      assert findings.last.flaky
      assert_equal 2, findings.last.attempts
    end
  end

  def test_a_case_with_no_returned_record_fails_rather_than_passing_silently
    with_suite do |dir|
      findings = step_findings(lane(dir, {}, session: FakeSession.new([ ok_result(1).first, nil ])).run)

      assert findings.last.fail?
      assert_includes findings.last.detail, "produced no result"
    end
  end

  # --- refusals -----------------------------------------------------------------

  def test_a_glob_matching_nothing_fails_the_lane
    with_suite do |dir|
      findings = lane(dir, { "suites" => [ "nope/*.yml" ] }, session: FakeSession.new([])).run

      assert findings.any? { |finding| finding.fail? && finding.detail.include?("matched no readable file") }
    end
  end

  def test_an_enabled_lane_with_no_suites_at_all_fails
    with_suite do |dir|
      findings = lane(dir, { "suites" => nil }, session: FakeSession.new([])).run

      assert findings.any? { |finding| finding.fail? && finding.detail.include?("no suites") }
    end
  end

  def test_a_suite_with_no_cases_is_refused
    with_suite("suite: empty\ncases: []\n") do |dir|
      findings = lane(dir, {}, session: FakeSession.new([])).run

      assert findings.any? { |finding| finding.detail.include?("has no cases") }
    end
  end

  def test_a_duplicate_case_id_is_refused
    body = SUITE.sub("id: empty-cart", "id: happy-path")
    with_suite(body) do |dir|
      findings = lane(dir, {}, session: FakeSession.new([])).run

      assert findings.any? { |finding| finding.detail.include?("more than once") }
    end
  end

  def test_an_unknown_step_verb_is_refused
    body = SUITE.sub("- goto: /cart", "- got0: /cart")
    with_suite(body) do |dir|
      findings = lane(dir, {}, session: FakeSession.new([])).run

      assert findings.any? { |finding| finding.detail.include?("unknown step verb(s): got0") }
    end
  end

  def test_a_case_with_no_acceptance_is_refused
    body = SUITE.sub("    acceptance: An empty cart says so.\n", "")
    with_suite(body) do |dir|
      findings = lane(dir, {}, session: FakeSession.new([])).run

      assert findings.any? { |finding| finding.detail.include?("no acceptance criterion") }
    end
  end

  def test_no_browserless_session_is_a_failing_finding_not_a_crash
    with_suite do |dir|
      findings = lane(dir).run

      assert_equal 1, findings.size
      assert findings.first.fail?
    end
  end

  # --- the compiled payload ------------------------------------------------------

  def test_each_case_is_compiled_into_the_module_with_its_own_context
    with_suite do |dir|
      session = FakeSession.new(ok_result(2))
      lane(dir, {}, session: session).run

      assert_includes session.code, "https://app.example.org/products/widget"
      assert_includes session.code, "newBrowserContext"
      assert_includes session.code, "cfRunFlow"
      # One shared code_source helper, not one per embedded runtime: an ES
      # module rejects the duplicate declaration outright.
      assert(session.codes.all? { |code| code.scan("async function resolveCodeSource").size == 1 })
    end
  end

  def test_the_configured_viewport_reaches_the_payload
    with_suite do |dir|
      session = FakeSession.new(ok_result(2))
      lane(dir, { "viewport" => { "name" => "mobile", "width" => 390, "height" => 844 } }, session: session).run

      assert_includes session.code, '"width":390'
    end
  end

  # --- the report section --------------------------------------------------------

  def test_the_acceptance_section_pairs_each_criterion_with_its_verdict
    with_suite do |dir|
      instance = lane(dir, {}, session: FakeSession.new(ok_result(2)))
      instance.run

      assert_includes instance.acceptance_section,
                      "| checkout/happy-path | checkout smoke | PASS | PASS | 1 | " \
                      "#{instance.case_results.first[:duration_ms].then { |ms| format('%.1f s', ms / 1000.0) }} | " \
                      "A guest can reach the confirmation page. | looks right |"
    end
  end

  def test_there_is_no_acceptance_section_before_a_run
    with_suite { |dir| assert_nil lane(dir).acceptance_section }
  end

  # --- --suite selection ----------------------------------------------------------

  def test_a_suite_selector_runs_that_suite_by_name
    with_suite do |dir|
      session = FakeSession.new(ok_result(2))
      findings = step_findings(lane(dir, {}, session: session, select: [ "checkout" ]).run)

      assert_equal %w[checkout/happy-path checkout/empty-cart], findings.map(&:check)
    end
  end

  # One flag, either meaning: "the checkout ones" is how a rerun is asked for,
  # and whether checkout is the suite or a tag is filing, not intent.
  def test_a_suite_selector_also_matches_a_tag
    with_suite do |dir|
      session = FakeSession.new(ok_result(1))
      findings = step_findings(lane(dir, {}, session: session, select: [ "smoke" ]).run)

      assert_equal [ "checkout/happy-path" ], findings.map(&:check)
    end
  end

  # An explicit selection is the person narrowing the run themselves; silently
  # re-applying the config's own tags on top would answer a different question.
  def test_a_suite_selector_wins_over_the_configured_tags
    with_suite do |dir|
      session = FakeSession.new(ok_result(2))
      findings = step_findings(lane(dir, { "tags" => [ "smoke" ] }, session: session, select: [ "checkout" ]).run)

      assert_equal 2, findings.size
    end
  end

  def test_a_suite_selector_matching_nothing_fails_rather_than_running_nothing
    with_suite do |dir|
      findings = lane(dir, {}, session: FakeSession.new([]), select: [ "chekout" ]).run

      assert findings.any? { |finding| finding.fail? && finding.detail.include?("chekout") }
    end
  end

  # --- graded acceptance -----------------------------------------------------------

  def test_a_failed_acceptance_verdict_fails_the_gate_rather_than_capping_at_warn
    with_suite do |dir|
      grader = FakeGrader.new(verdicts: { "checkout/happy-path" => [ "fail", "it charged the card twice" ] })
      findings = acceptance_findings(lane(dir, {}, session: FakeSession.new(ok_result(2)), grader: grader).run)

      failed = findings.find { |finding| finding.check == "checkout/happy-path acceptance" }
      assert failed.fail?
      assert_includes failed.detail, "charged the card twice"
      assert_includes failed.detail, "A guest can reach the confirmation page."
    end
  end

  def test_a_passing_acceptance_verdict_is_a_passing_finding
    with_suite do |dir|
      findings = acceptance_findings(lane(dir, {}, session: FakeSession.new(ok_result(2))).run)

      assert_equal 2, findings.size
      assert findings.all?(&:pass?)
    end
  end

  # Decision 8: a grader that declined to decide has not found a defect, but an
  # unattended run cannot treat that as a free pass either, so full auto
  # (the default) fails the gate on it.
  def test_an_unclear_verdict_fails_under_full_auto
    with_suite do |dir|
      grader = FakeGrader.new(verdicts: { "checkout/happy-path" => [ "unclear", "no confirmation text visible" ] })
      findings = acceptance_findings(lane(dir, {}, session: FakeSession.new(ok_result(2)), grader: grader).run)

      assert_equal "fail", findings.first.status
    end
  end

  # Under --signoff a human is present to read the report and judge for
  # themselves, so an unclear verdict only warns.
  def test_an_unclear_verdict_warns_under_signoff
    with_suite do |dir|
      grader = FakeGrader.new(verdicts: { "checkout/happy-path" => [ "unclear", "no confirmation text visible" ] })
      findings = acceptance_findings(
        lane(dir, {}, session: FakeSession.new(ok_result(2)), grader: grader, signoff: true).run
      )

      assert_equal "warn", findings.first.status
    end
  end

  # gate_tags staged adoption softens an unclear verdict to warn even under
  # full auto, exactly as it softens a real `fail`.
  def test_an_unclear_verdict_is_softened_by_gate_tags_under_full_auto
    with_suite do |dir|
      grader = FakeGrader.new(verdicts: { "checkout/empty-cart" => [ "unclear", "no confirmation text visible" ] })
      findings = acceptance_findings(
        lane(dir, { "gate_tags" => [ "smoke" ] }, session: FakeSession.new(ok_result(2)), grader: grader).run
      )

      softened = findings.find { |finding| finding.check == "checkout/empty-cart acceptance" }
      assert_equal "warn", softened.status
    end
  end

  # gate_tags softens a graded verdict exactly as it softens a step failure, so
  # staged adoption works the same way for both halves of a case.
  def test_gate_tags_softens_a_failed_acceptance_verdict_too
    with_suite do |dir|
      grader = FakeGrader.new(verdicts: { "checkout/empty-cart" => [ "fail", "the cart still shows an item" ] })
      findings = acceptance_findings(
        lane(dir, { "gate_tags" => [ "smoke" ] }, session: FakeSession.new(ok_result(2)), grader: grader).run
      )

      softened = findings.find { |finding| finding.check == "checkout/empty-cart acceptance" }
      assert_equal "warn", softened.status
      assert_includes softened.detail, "not gated"
    end
  end

  def test_the_report_names_the_model_that_graded
    with_suite do |dir|
      lane_under_test = lane(dir, {}, session: FakeSession.new(ok_result(2)), grader: FakeGrader.new.with_model("opus-x"))
      lane_under_test.run

      assert_includes lane_under_test.acceptance_section, "Acceptance criteria graded by model: opus-x."
    end
  end

  def test_the_report_omits_the_model_line_when_no_model_is_known
    with_suite do |dir|
      lane_under_test = lane(dir, {}, session: FakeSession.new(ok_result(2)))
      lane_under_test.run

      refute_includes lane_under_test.acceptance_section, "graded by model"
    end
  end

  # A case whose steps already failed has a named, deterministic failure; a
  # second opinion on a settled question is noise, not evidence.
  def test_only_cases_whose_steps_passed_are_graded
    with_suite do |dir|
      result = ok_result(2)
      result[0] = failed_result(0, [ { "index" => 0, "label" => "goto /products/widget", "ok" => false,
                                       "error" => "Error: navigation failed" } ])
      grader = FakeGrader.new
      lane(dir, {}, session: FakeSession.new(result), grader: grader).run

      assert_equal [ "checkout/empty-cart" ], grader.observations.map { |item| item[:id] }
    end
  end

  def test_captured_values_with_their_read_time_reach_the_grader
    with_suite do |dir|
      result = ok_result(2)
      result[0] = result[0].merge(
        "vars" => { "header_total" => "69" },
        "steps" => [ { "index" => 1, "verb" => "capture", "ok" => true, "captured" => "header_total", "found" => "69",
                       "kind" => "number", "readAt" => "2026-11-20T10:00:00.000Z" } ]
      )
      grader = FakeGrader.new
      lane(dir, {}, session: FakeSession.new(result), grader: grader).run
      first = grader.observations.find { |item| item[:id] == "checkout/happy-path" }

      assert_equal [ { var: "header_total", value: "69", kind: "number", read_at: "2026-11-20T10:00:00.000Z" } ],
                   first[:captured]
    end
  end

  def test_a_variable_captured_twice_reaches_the_grader_as_two_readings
    with_suite do |dir|
      result = ok_result(2)
      reads = [ [ "10", "2026-11-20T10:00:00.000Z" ], [ "20", "2026-11-20T10:00:05.000Z" ] ]
      result[0] = result[0].merge(
        "vars" => { "total" => "20" },
        "steps" => reads.each_with_index.map do |(value, at), index|
          { "index" => index, "verb" => "capture", "ok" => true, "captured" => "total", "found" => value,
            "kind" => "number", "readAt" => at }
        end
      )
      grader = FakeGrader.new
      lane(dir, {}, session: FakeSession.new(result), grader: grader).run
      first = grader.observations.find { |item| item[:id] == "checkout/happy-path" }

      assert_equal %w[10 20], first[:captured].map { |entry| entry[:value] }
    end
  end

  def test_a_live_quarantine_is_recorded_on_the_case_result
    with_suite(quarantined_suite("2026-09-30")) do |dir|
      runner = lane(dir, {}, session: FakeSession.new(ok_result(2)), today: TODAY)
      runner.run
      records = runner.case_records.to_h { |record| [ record.id, record ] }

      assert records["happy-path"].quarantined?
      assert_equal "the sandbox gateway drops a redirect", records["happy-path"].quarantine_reason
      refute records["empty-cart"].quarantined?
    end
  end

  def test_the_observation_reaches_the_grader
    with_suite do |dir|
      grader = FakeGrader.new
      lane(dir, {}, session: FakeSession.new(ok_result(2)), grader: grader).run

      assert_equal "https://app.example.org/confirmation", grader.observations.first[:url]
      assert_equal "Thanks for your order", grader.observations.first[:text]
    end
  end

  # Grading that could not run is never a pass: a pass would launder unjudged
  # prose into a checked criterion. Decision 8: full auto (the default) fails
  # the gate on it instead, since nobody is watching to read the warn.
  def test_an_unreachable_grader_fails_under_full_auto
    with_suite do |dir|
      grader = FakeGrader.new(reason: "acceptance grading did not run: no grader is reachable")
      findings = lane(dir, {}, session: FakeSession.new(ok_result(2)), grader: grader).run
      grading = findings.find { |finding| finding.check == "acceptance grading" }

      assert_equal "fail", grading.status
      assert_includes grading.detail, "no grader is reachable"
      assert_nil grader.observations
    end
  end

  # Under --signoff a human reads the report, so a missing grader only warns.
  def test_an_unreachable_grader_warns_under_signoff
    with_suite do |dir|
      grader = FakeGrader.new(reason: "acceptance grading did not run: no grader is reachable")
      findings = lane(dir, {}, session: FakeSession.new(ok_result(2)), grader: grader, signoff: true).run
      grading = findings.find { |finding| finding.check == "acceptance grading" }

      assert_equal "warn", grading.status
    end
  end

  def test_the_module_captures_an_observation_for_the_grader
    with_suite do |dir|
      session = FakeSession.new(ok_result(2))
      lane(dir, {}, session: session).run

      assert_includes session.code, "async function observe(casePage)"
      assert_includes session.code, "observation: ok ? await observe(session.page) : null"
    end
  end

  # --- quarantine -------------------------------------------------------------------

  TODAY = Date.new(2026, 8, 22)

  # `happy-path` quarantined until the date the caller names, so every expiry
  # boundary is one string substitution away from the same suite.
  def quarantined_suite(until_on)
    SUITE.sub("    acceptance: A guest can reach the confirmation page.\n",
              "    acceptance: A guest can reach the confirmation page.\n" \
              "    quarantined: true\n" \
              "    quarantine_reason: the sandbox gateway drops a redirect\n" \
              "    quarantine_until: #{until_on}\n")
  end

  def quarantined_failure(dir, today: TODAY)
    result = ok_result(2)
    result[0] = failed_result(0, [ { "index" => 0, "label" => "goto /products/widget", "ok" => false,
                                     "error" => "Error: navigation failed" } ])
    lane(dir, {}, session: FakeSession.new(result), today: today).run
  end

  # The whole point: a quarantined case still runs and still reports, it just
  # cannot fail the run while the quarantine is live.
  def test_a_quarantined_case_reports_its_failure_without_failing_the_gate
    with_suite(quarantined_suite("2026-09-30")) do |dir|
      findings = step_findings(quarantined_failure(dir))
      quarantined = findings.find { |finding| finding.check == "checkout/happy-path" }

      assert_equal "warn", quarantined.status
      assert_includes quarantined.detail, "navigation failed"
      assert_includes quarantined.detail, "quarantined until 2026-09-30"
      assert_includes quarantined.detail, "the sandbox gateway drops a redirect"
    end
  end

  # An unquarantined case in the same suite is untouched: quarantine is per
  # case, never a property the suite catches.
  def test_quarantine_shields_only_the_case_that_carries_it
    with_suite(quarantined_suite("2026-09-30")) do |dir|
      result = [ failed_result(0, []), failed_result(1, []) ]
      findings = step_findings(lane(dir, {}, session: FakeSession.new(result), today: TODAY).run)

      assert_equal %w[warn fail], findings.map(&:status)
    end
  end

  # Well clear of the window: shielded, and nothing warns about it yet.
  def test_a_quarantine_that_is_not_yet_expiring_shields_and_stays_quiet
    with_suite(quarantined_suite("2026-12-01")) do |dir|
      findings = quarantined_failure(dir)

      assert_equal "warn", step_findings(findings).first.status
      refute findings.any? { |finding| finding.check.end_with?("quarantine") }
    end
  end

  # Inside the warning window it still shields: coming due is a prompt to act,
  # not a lapse.
  def test_a_quarantine_expiring_soon_still_shields
    with_suite(quarantined_suite("2026-08-27")) do |dir|
      assert_equal "warn", step_findings(quarantined_failure(dir)).first.status
    end
  end

  # The date is the day the quarantine ENDS, so it has already lapsed on it.
  # Erring early is the safe direction: an early expiry is a red gate somebody
  # reads, a late one is a regression nobody sees.
  def test_a_quarantine_expiring_today_no_longer_shields
    with_suite(quarantined_suite("2026-08-22")) do |dir|
      findings = quarantined_failure(dir)

      assert_equal "fail", step_findings(findings).first.status
      expiry = findings.find { |finding| finding.check == "checkout/happy-path quarantine" }
      assert_equal "warn", expiry.status
      assert_includes expiry.detail, "quarantine expired 2026-08-22"
    end
  end

  def test_an_expired_quarantine_lets_the_case_fail_again
    with_suite(quarantined_suite("2026-07-01")) do |dir|
      findings = quarantined_failure(dir)

      assert_equal "fail", step_findings(findings).first.status
      assert findings.any? { |finding| finding.check == "checkout/happy-path quarantine" }
    end
  end

  # A passing quarantined case is exactly where the debt would otherwise
  # disappear, so the note is on it too.
  def test_a_passing_quarantined_case_still_names_its_quarantine
    with_suite(quarantined_suite("2026-09-30")) do |dir|
      instance = lane(dir, {}, session: FakeSession.new(ok_result(2)), today: TODAY)
      findings = step_findings(instance.run)

      assert findings.first.pass?
      assert_includes findings.first.detail, "quarantined until 2026-09-30"
      assert_includes instance.acceptance_section, "| until 2026-09-30: the sandbox gateway drops a redirect |"
      assert_includes instance.acceptance_section, "| checkout/empty-cart |"
    end
  end

  # A graded acceptance verdict is softened by a quarantine exactly as a step
  # failure is: quarantine shields the case, not one half of it.
  def test_a_quarantine_softens_a_failed_acceptance_verdict_too
    with_suite(quarantined_suite("2026-09-30")) do |dir|
      grader = FakeGrader.new(verdicts: { "checkout/happy-path" => [ "fail", "it charged the card twice" ] })
      findings = acceptance_findings(
        lane(dir, {}, session: FakeSession.new(ok_result(2)), grader: grader, today: TODAY).run
      )
      softened = findings.find { |finding| finding.check == "checkout/happy-path acceptance" }

      assert_equal "warn", softened.status
      assert_includes softened.detail, "quarantined until 2026-09-30"
    end
  end

  # --- quarantine refusals -------------------------------------------------------------

  def test_a_quarantine_with_no_reason_is_refused
    body = quarantined_suite("2026-09-30").sub("    quarantine_reason: the sandbox gateway drops a redirect\n", "")
    with_suite(body) do |dir|
      findings = lane(dir, {}, session: FakeSession.new([])).run

      assert findings.any? { |finding| finding.fail? && finding.detail.include?("no `quarantine_reason`") }
    end
  end

  def test_a_quarantine_with_no_date_is_refused
    body = quarantined_suite("2026-09-30").sub("    quarantine_until: 2026-09-30\n", "")
    with_suite(body) do |dir|
      findings = lane(dir, {}, session: FakeSession.new([])).run

      assert findings.any? { |finding| finding.fail? && finding.detail.include?("no `quarantine_until` date") }
    end
  end

  # A reason or a date without the flag reads to its author as a live
  # quarantine and is not one, which is the worst of both states.
  def test_quarantine_keys_without_the_flag_are_refused
    body = quarantined_suite("2026-09-30").sub("    quarantined: true\n", "")
    with_suite(body) do |dir|
      findings = lane(dir, {}, session: FakeSession.new([])).run

      assert findings.any? { |finding| finding.detail.include?("without `quarantined: true`") }
    end
  end

  def test_a_quarantine_date_that_is_not_a_date_is_refused
    with_suite(quarantined_suite('"next friday"')) do |dir|
      findings = lane(dir, {}, session: FakeSession.new([])).run

      assert findings.any? { |finding| finding.detail.include?("not an ISO-8601 date") }
    end
  end

  # The escape hatch for a wrong verdict is the sha-scoped override the repo
  # already has, in both branches. Nothing here records one, and nothing here
  # invents a second mechanism.
  def test_a_failed_verdict_carries_the_existing_override_as_its_escape_hatch
    with_suite do |dir|
      grader = FakeGrader.new(verdicts: { "checkout/happy-path" => [ "fail", "wrong page" ] })
      instance = lane(dir, {}, session: FakeSession.new(ok_result(2)), grader: grader)
      failed = acceptance_findings(instance.run).find(&:fail?)

      assert_includes failed.help, "change_override.rb"
      assert_includes instance.acceptance_section, "change_override.rb"
    end
  end

  # --- per-case calls, budget, pool (suite v2) ---------------------------------------

  def many_cases(count, extra = "")
    cases = (0...count).map do |i|
      "  - id: case-#{i}\n    acceptance: Case #{i} works.\n#{extra}    steps:\n      - goto: /p/#{i}\n"
    end
    "suite: long\nsuite_version: 2\ncases:\n#{cases.join}"
  end

  def test_each_case_is_its_own_call
    with_suite do |dir|
      session = FakeSession.new(ok_result(2))
      lane(dir, {}, session: session).run

      assert_equal 2, session.calls
      assert_includes session.codes[0], "/products/widget"
      refute_includes session.codes[0], "/cart"
      assert_includes session.codes[1], "/cart"
    end
  end

  # The acceptance target, stubbed: 40 cases of 60 s each would never fit one
  # 115 s call, and each now gets its own call and its own duration.
  def test_forty_long_cases_all_run_with_a_duration_each
    with_suite(many_cases(40, "    timeout_ms: 60000\n")) do |dir|
      session = FakeSession.new(ok_result(40))
      instance = lane(dir, {}, session: session)
      findings = step_findings(instance.run)

      assert_equal 40, session.calls
      assert_equal [ 60_000 ] * 40, session.timeouts
      assert findings.all?(&:pass?)
      assert(instance.case_results.all? { |result| result[:duration_ms].is_a?(Integer) && result[:attempts].size == 1 })
    end
  end

  def test_an_explicit_case_timeout_is_the_budget
    with_suite(many_cases(1, "    timeout_ms: 300000\n")) do |dir|
      instance = lane(dir)
      assert_equal 300_000, instance.case_budget_ms(instance.send(:suite_set).cases.first)
    end
  end

  def test_a_short_case_budget_is_floored_at_the_default_call_limit
    with_suite do |dir|
      instance = lane(dir)
      assert_equal 115_000, instance.case_budget_ms(instance.send(:suite_set).cases.first)
    end
  end

  def test_a_long_case_budget_sums_step_timeouts_and_navigation
    body = "suite: s\ncases:\n  - id: slow\n    acceptance: ok\n    steps:\n" \
           "      - goto: /a\n        timeout_ms: 60000\n" \
           "      - wait_for: { selector: '#x', timeout_ms: 50000 }\n" \
           "      - click: '#y'\n"
    with_suite(body) do |dir|
      instance = lane(dir, { "timeout_ms" => 20_000 })
      # 60000 + 5000 (goto) + 50000 + 20000 (lane default for the click)
      assert_equal 135_000, instance.case_budget_ms(instance.send(:suite_set).cases.first)
    end
  end

  def test_the_pool_never_exceeds_parallel_and_keeps_case_order
    with_suite(many_cases(12)) do |dir|
      session = FakeSession.new(ok_result(12), delay: 0.01)
      findings = step_findings(lane(dir, { "parallel" => 3 }, session: session).run)

      assert_operator session.max_in_flight, :<=, 3
      assert_operator session.max_in_flight, :>, 1
      assert_equal (0...12).map { |i| "long/case-#{i}" }, findings.map(&:check)
    end
  end

  def test_serial_is_the_default
    with_suite(many_cases(4)) do |dir|
      session = FakeSession.new(ok_result(4), delay: 0.005)
      lane(dir, {}, session: session).run
      assert_equal 1, session.max_in_flight
    end
  end

  # A full queue never started the case: it is retried with backoff, consumes
  # no retry, and is not counted as an attempt.
  def test_a_queue_rejection_is_not_an_attempt
    rejected = ChangeDocker::Browserless::QueueRejected.new("429 queue full")
    with_suite(many_cases(1)) do |dir|
      waits = []
      session = FakeSession.new([ [ rejected, rejected, ok_result(1).first ] ])
      instance = lane(dir, {}, session: session, sleeper: ->(seconds) { waits << seconds })
      findings = step_findings(instance.run)

      assert findings.first.pass?
      assert_equal 1, findings.first.attempts
      assert_equal [ 1, 2 ], waits
      assert_equal 1, instance.case_results.first[:attempts].size
    end
  end

  def test_a_call_that_fails_outright_fails_the_case_by_name
    with_suite(many_cases(1)) do |dir|
      session = FakeSession.new([ [ ChangeDocker::Browserless::TimedOut.new("408 Request has timed out") ] ])
      finding = step_findings(lane(dir, {}, session: session).run).first

      assert finding.fail?
      assert_equal "browserless call", finding.location
      assert_includes finding.detail, "408"
    end
  end

  # The earlier mutation of a failed attempt is never replayed without
  # authorization: `retries` with no `safe_rerun` is refused before any call.
  def test_retries_without_safe_rerun_is_refused_before_anything_runs
    body = SUITE.sub("    safe_rerun: true\n", "")
    with_suite(body) do |dir|
      session = FakeSession.new(ok_result(2))
      findings = lane(dir, {}, session: session).run

      assert(findings.any? { |finding| finding.fail? && finding.detail.include?("without `safe_rerun: true`") })
      refute(session.codes.any? { |code| code.include?("/cart") })
    end
  end

  def test_an_unknown_case_key_is_refused
    body = SUITE.sub("    safe_rerun: true\n", "    safe_rerun: true\n    retires: 2\n")
    with_suite(body) do |dir|
      findings = lane(dir, {}, session: FakeSession.new([])).run
      assert(findings.any? { |finding| finding.detail.include?("unknown key(s): retires") })
    end
  end

  def test_a_too_new_suite_names_the_update_in_the_lane
    with_suite(SUITE.sub("suite_version: 2", "suite_version: 99")) do |dir|
      findings = lane(dir, {}, session: FakeSession.new([])).run
      assert(findings.any? { |finding| finding.fail? && finding.detail.include?("pull and run ruby install.rb") })
    end
  end

  def test_a_queue_that_never_frees_fails_without_counting_an_attempt
    rejected = ChangeDocker::Browserless::QueueRejected.new("429 queue full")
    body = many_cases(1, "    retries: 2\n    safe_rerun: true\n")
    with_suite(body) do |dir|
      session = FakeSession.new([ [ rejected ] ])
      instance = lane(dir, {}, session: session)
      finding = step_findings(instance.run).first

      assert finding.fail?
      assert_includes finding.detail, "queue stayed full"
      assert_equal 6, session.calls
      assert_empty instance.case_results.first[:attempts]
    end
  end

  # --- personas (0.22.0, suite_version 3) -------------------------------------------

  # A session that answers persona login calls itself and counts them by the
  # persona's login url, and hands case calls to FakeSession.
  class PersonaSession < FakeSession
    attr_reader :logins

    def initialize(records, login_ok: true)
      super(records)
      @logins = Hash.new(0)
      @login_ok = login_ok
    end

    def run_function(code, launch_args: [], timeout_ms: nil)
      return super unless code.include?("Network.getAllCookies")

      url = code[%r{"url":"https://app\.example\.org(/[a-z-]+)"}, 1]
      @lock.synchronize { @logins[url] += 1 }
      return { "ok" => false, "authError" => "wrong password" } unless @login_ok

      { "ok" => true, "state" => { "cookies" => [ { "name" => "sid", "value" => "s#{@logins[url]}" } ], "origins" => [] } }
    end

    def case_codes = @codes
  end

  PERSONAS = {
    "auth" => { "login_url" => "/login", "email_env" => "E", "password_env" => "P" },
    "personas" => { "admin" => { "login_url" => "/admin-login", "email_env" => "AE", "password_env" => "AP" } }
  }.freeze

  PERSONA_SUITE = <<~YAML
    suite: roles
    suite_version: 3
    cases:
      - id: as-default
        acceptance: The default user sees the dashboard.
        steps:
          - goto: /dashboard
      - id: as-admin
        acceptance: An admin sees the admin page.
        persona: admin
        steps:
          - goto: /admin
          - click: "#save"
          - expect_visible: ".saved"
      - id: as-admin-too
        acceptance: An admin sees the users page.
        persona: admin
        steps:
          - goto: /admin/users
      - id: as-nobody
        acceptance: A visitor sees the landing page.
        persona: anonymous
        steps:
          - goto: /
  YAML

  def persona_lane(dir, session, config = PERSONAS)
    lane(dir, config, session: session)
  end

  def test_each_persona_logs_in_once_and_seeds_every_case
    with_suite(PERSONA_SUITE) do |dir|
      session = PersonaSession.new(ok_result(4))
      persona_lane(dir, session).run

      assert_equal({ "/login" => 1, "/admin-login" => 1 }, session.logins)
      admin = session.case_codes.find { |code| code.include?('"id":"roles/as-admin"') }
      assert_includes admin, '"name":"admin","seed":{"cookies":[{"name":"sid"'
      nobody = session.case_codes.find { |code| code.include?('"id":"roles/as-nobody"') }
      assert_includes nobody, "const persona = null;"
    end
  end

  def test_a_case_naming_an_undefined_persona_fails_without_a_call
    body = PERSONA_SUITE.sub("persona: admin\n    steps:\n      - goto: /admin\n", "persona: ghost\n    steps:\n      - goto: /admin\n")
    with_suite(body) do |dir|
      session = PersonaSession.new(ok_result(4))
      lane_under_test = persona_lane(dir, session)
      findings = step_findings(lane_under_test.run)
      ghost = findings.find { |finding| finding.check == "roles/as-admin" }
      assert_equal "fail", ghost.status
      assert_includes ghost.detail, "persona 'ghost'"
      refute(session.case_codes.any? { |code| code.include?('"id":"roles/as-admin"') })
    end
  end

  def test_a_failed_persona_login_fails_its_cases_by_name
    with_suite(PERSONA_SUITE) do |dir|
      session = PersonaSession.new(ok_result(4), login_ok: false)
      findings = step_findings(persona_lane(dir, session).run)
      admin = findings.find { |finding| finding.check == "roles/as-admin" }
      assert_equal "fail", admin.status
      assert_includes admin.detail, "could not log in: wrong password"
      assert_equal 1, session.logins["/admin-login"]
    end
  end

  def expired_record(index, verb, ok_steps)
    steps = (0...ok_steps).map { |i| { "index" => i, "label" => "s#{i}", "ok" => true } }
    { "index" => 1, "ok" => false, "steps" => steps, "vars" => {},
      "authExpired" => { "index" => index, "verb" => verb } }
  end

  def pass_record(index) = { "index" => index, "ok" => true, "steps" => [] }

  # The save went through server side, then the 401 showed up. Replaying it
  # would save twice, so the case fails auth_interrupted and is not resumed,
  # though the persona does log in again for the cases after it.
  def test_a_mutation_before_its_401_is_auth_interrupted_and_not_replayed
    with_suite(PERSONA_SUITE) do |dir|
      records = ok_result(4)
      records[1] = [ expired_record(1, "click", 2), pass_record(1) ]
      session = PersonaSession.new(records)
      under_test = persona_lane(dir, session)
      findings = step_findings(under_test.run)

      admin = findings.find { |finding| finding.check == "roles/as-admin" }
      assert_equal "fail", admin.status
      assert_includes admin.detail, "auth_interrupted"
      assert_equal 1, session.case_codes.count { |code| code.include?('"id":"roles/as-admin"') }
      assert_equal 2, session.logins["/admin-login"]
      result = under_test.case_results.find { |entry| entry[:key] == "roles/as-admin" }
      assert_equal "auth_interrupted", result[:status]
      assert_equal "auth_interrupted", result[:attempts].last[:outcome]
    end
  end

  def test_safe_retry_replays_the_interrupted_mutation_after_the_re_login
    body = PERSONA_SUITE.sub("persona: admin\n    steps:\n      - goto: /admin\n",
                             "persona: admin\n    safe_retry: true\n    steps:\n      - goto: /admin\n")
    with_suite(body) do |dir|
      records = ok_result(4)
      records[1] = [ expired_record(1, "click", 2), pass_record(1) ]
      session = PersonaSession.new(records)
      under_test = persona_lane(dir, session)
      findings = step_findings(under_test.run)

      assert_equal "pass", findings.find { |finding| finding.check == "roles/as-admin" }.status
      calls = session.case_codes.select { |code| code.include?('"id":"roles/as-admin"') }
      assert_equal 2, calls.size
      assert_includes calls.last, '"startAt":0', "restarts at the goto before the click, rebuilding the page"
      assert_includes calls.last, '"value":"s2"'
      result = under_test.case_results.find { |entry| entry[:key] == "roles/as-admin" }
      assert_equal 1, result[:attempts].size, "auth recovery stays inside one attempt"
    end
  end

  # A 401 on a navigation is safe to replay: re-login, then the case resumes
  # at that goto with the new session.
  def test_a_401_on_a_navigation_re_logs_in_and_resumes
    with_suite(PERSONA_SUITE) do |dir|
      records = ok_result(4)
      records[2] = [ expired_record(0, "goto", 0), pass_record(2) ]
      session = PersonaSession.new(records)
      findings = step_findings(persona_lane(dir, session).run)

      assert_equal "pass", findings.find { |finding| finding.check == "roles/as-admin-too" }.status
      assert_equal 2, session.logins["/admin-login"]
    end
  end

  def test_a_second_session_end_in_one_attempt_fails_the_case
    with_suite(PERSONA_SUITE) do |dir|
      records = ok_result(4)
      records[2] = [ expired_record(0, "goto", 0), expired_record(0, "goto", 0) ]
      session = PersonaSession.new(records)
      findings = step_findings(persona_lane(dir, session).run)

      case_finding = findings.find { |finding| finding.check == "roles/as-admin-too" }
      assert_equal "fail", case_finding.status
      assert_includes case_finding.detail, "ended again after a re-login"
    end
  end

  def test_two_files_with_one_suite_id_fail_to_load
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.cf-testcases.yml"), SUITE)
      File.write(File.join(dir, "b.cf-testcases.yml"), SUITE)
      set = ChangeSuiteSet.load([ "*.cf-testcases.yml" ], dir)
      assert(set.errors.any? { |error| error.include?("suite id 'checkout' is declared by more than one file") })
    end
  end

  # Both generated modules must parse as ES modules; a Ruby heredoc escape
  # that eats a backslash only shows up as a 400 from the container.
  def test_the_case_and_login_modules_are_valid_javascript
    skip "node not installed" unless system("command -v node >/dev/null 2>&1")
    with_suite(PERSONA_SUITE) do |dir|
      session = PersonaSession.new(ok_result(4))
      persona_lane(dir, session).run
      login = ChangeLaneTestcases.new(ChangeConfig::LaneConfig.new("testcases", PERSONAS, dir), Ctx.new("net", "https://app.example.org"),
                                      grader: FakeGrader.new).send(:login_module, ChangeLaneBrowserless::AuthConfig.new(PERSONAS["auth"]))
      [ session.case_codes.first, login ].each do |code|
        Tempfile.create([ "cf-module", ".mjs" ]) do |file|
          file.write(code)
          file.flush
          output = IO.popen([ "node", "--check", file.path ], err: [ :child, :out ], &:read)
          assert $?.success?, output
        end
      end
    end
  end

  # An assertion after a fill cannot be resumed on a fresh page without
  # retyping the field, and the fill is not a step that may be repeated
  # unasked, so the case is auth_interrupted.
  def test_a_safe_step_after_a_fill_is_not_resumed_without_safe_retry
    body = PERSONA_SUITE.sub("      - click: \"#save\"\n      - expect_visible: \".saved\"\n",
                             "      - fill: { selector: \"#name\", value: x }\n      - expect_visible: \".saved\"\n")
    with_suite(body) do |dir|
      records = ok_result(4)
      records[1] = [ expired_record(2, "expectVisible", 2), pass_record(1) ]
      session = PersonaSession.new(records)
      under_test = persona_lane(dir, session)
      under_test.run
      assert_equal "auth_interrupted", under_test.case_results.find { |entry| entry[:key] == "roles/as-admin" }[:status]
    end
  end

  def test_a_seeded_case_starts_on_the_login_landing_page
    with_suite(PERSONA_SUITE) do |dir|
      session = PersonaSession.new(ok_result(4))
      persona_lane(dir, session).run
      login = ChangeLaneTestcases.new(ChangeConfig::LaneConfig.new("testcases", PERSONAS, dir), Ctx.new("net", "https://app.example.org"),
                                      grader: FakeGrader.new).send(:login_module, ChangeLaneBrowserless::AuthConfig.new(PERSONAS["auth"]))
      assert_includes login, "landing: landing"
      assert_includes session.case_codes.first, 'first.verb !== "goto"'
    end
  end

  # A hidden login form on an authenticated page is not a logout.
  def test_session_end_detection_ignores_hidden_forms
    skip "node not installed" unless system("command -v node >/dev/null 2>&1")
    with_suite(PERSONA_SUITE) do |dir|
      session = PersonaSession.new(ok_result(4))
      persona_lane(dir, session).run
      code = session.case_codes.first
      assert_includes code, "node.getClientRects().length > 0"
      assert_includes code, 'window.sessionStorage.getItem("__cf_seeded") === "1"'
    end
  end

  SELECTOR_PERSONAS = PERSONAS.merge(
    "personas" => { "admin" => PERSONAS["personas"]["admin"].merge("expired_when" => { "selector" => "#signed-out" }) }
  ).freeze

  PROBE_PERSONAS = PERSONAS.merge(
    "personas" => { "admin" => PERSONAS["personas"]["admin"].merge(
      "expired_when" => { "probe_url" => "/api/me", "expect_status" => 401 }
    ) }
  ).freeze

  # Runs the generated sessionEnded helper in node against a fake page and
  # returns what it answered for each page.
  def session_ended_answers(code, pages_js)
    helper = code[/^( *)async function sessionEnded\b.*?^\1\}\n/m]
    script = <<~JS
      const getComputedStyle = () => ({ visibility: "visible", display: "block" });
      const persona = #{code[/const persona = (\{.*?\}|null);\n/, 1]};
      #{helper}
      const pages = #{pages_js};
      (async () => { const out = []; for (const p of pages) out.push(await sessionEnded(p)); console.log(JSON.stringify(out)); })();
    JS
    JSON.parse(IO.popen([ "node", "-e", script ], &:read))
  end

  def admin_code(body, config)
    with_suite(body) do |dir|
      session = PersonaSession.new(ok_result(4))
      persona_lane(dir, session, config).run
      return session.case_codes.find { |entry| entry.include?('"id":"roles/as-admin"') }
    end
  end

  VISIBLE = "({ evaluate: async (fn) => fn({ getClientRects: () => [ 1 ] }) })"

  def test_a_declared_selector_detects_expiry_only_when_visible
    skip "node not installed" unless system("command -v node >/dev/null 2>&1")
    code = admin_code(PERSONA_SUITE, SELECTOR_PERSONAS)
    assert_includes code, '"expiredWhen":{"selector":"#signed-out"}'
    pages = "[ { url: () => '', $: async () => #{VISIBLE} }, { url: () => '', $: async () => null } ]"
    assert_equal [ true, false ], session_ended_answers(code, pages)
  end

  def test_a_declared_probe_url_detects_expiry_by_status
    skip "node not installed" unless system("command -v node >/dev/null 2>&1")
    code = admin_code(PERSONA_SUITE, PROBE_PERSONAS)
    assert_includes code, '"expiredWhen":{"probeUrl":"https://app.example.org/api/me","expectStatus":[401]}'
    pages = "[401, 200].map((s) => ({ url: () => '', $: async () => null, evaluate: async () => s }))"
    assert_equal [ true, false ], session_ended_answers(code, pages)
  end

  # No expired_when: no mid-case detection, no re-login, and a failing case
  # says how to opt in.
  def test_no_declaration_means_no_recovery_and_a_clear_failure
    with_suite(PERSONA_SUITE) do |dir|
      records = ok_result(4)
      records[1] = { "index" => 1, "ok" => false, "steps" => [ { "index" => 0, "label" => "goto /admin", "ok" => false, "error" => "no .saved" } ] }
      session = PersonaSession.new(records)
      findings = step_findings(persona_lane(dir, session).run)
      admin = findings.find { |finding| finding.check == "roles/as-admin" }
      assert_equal "fail", admin.status
      assert_includes admin.detail, "expired_when"
      assert_equal 1, session.logins["/admin-login"]
      code = session.case_codes.find { |entry| entry.include?('"id":"roles/as-admin"') }
      assert_includes code, '"expiredWhen":null'
      refute_includes code, "doc401"
      next unless system("command -v node >/dev/null 2>&1")

      assert_equal [ false ], session_ended_answers(code, "[ { url: () => '', $: async () => #{VISIBLE}, evaluate: async () => 401 } ]")
    end
  end

  # A logout test asserts the logged-out page; its own logout is not expiry.
  def test_expects_logout_skips_detection
    skip "node not installed" unless system("command -v node >/dev/null 2>&1")
    body = PERSONA_SUITE.sub("persona: admin\n    steps:\n      - goto: /admin\n",
                             "persona: admin\n    expects_logout: true\n    steps:\n      - goto: /admin\n")
    code = admin_code(body, SELECTOR_PERSONAS)
    assert_includes code, '"expectsLogout":true'
    assert_equal [ false ], session_ended_answers(code, "[ { url: () => '', $: async () => #{VISIBLE} } ]")
  end

  # An app that serves its login at / and stays at / once signed in: the url
  # and a visible login form never read as expiry without a declared probe.
  def test_a_login_url_equal_to_the_landing_url_is_not_expiry_without_a_probe
    skip "node not installed" unless system("command -v node >/dev/null 2>&1")
    config = PERSONAS.merge("personas" => { "admin" => PERSONAS["personas"]["admin"].merge("login_url" => "/") })
    code = admin_code(PERSONA_SUITE, config)
    page = "[ { url: () => 'https://app.example.org/', $: async () => #{VISIBLE}, evaluate: async () => 401 } ]"
    assert_equal [ false ], session_ended_answers(code, page)
  end

  # --- evidence (P4) ------------------------------------------------------------------

  EvidenceCtx = Struct.new(:network, :target_url, :browserless, :suite_select, :signoff, :evidence_dir, :run_id) do
    def log(_message) = nil
    def signoff? = false
  end

  # Plays the container's part: whatever a module would checkpoint is written
  # into the mounted dir before the scripted outcome happens.
  class EvidenceSession < FakeSession
    def initialize(records, root, checkpoints: 1)
      super(records)
      @root = root
      @checkpoints = checkpoints
    end

    def run_function(code, launch_args: [], timeout_ms: nil)
      dir = code[%r{const evidence = \{"dir":"/cf-run/([^"]+)"\}}, 1]
      if dir
        host = File.join(@root, dir)
        @checkpoints.times do |i|
          File.write(File.join(host, format("step-%04d-a.json", i + 1)),
                     JSON.generate("record" => { "index" => i, "label" => "step #{i + 1}", "ok" => true }))
        end
      end
      super
    end
  end

  def evidence_lane(dir, root, session, raw = {})
    config = ChangeConfig::LaneConfig.new("testcases", { "suites" => [ "*.cf-testcases.yml" ] }.merge(raw), dir)
    ChangeLaneTestcases.new(config, EvidenceCtx.new("net", "https://app.example.org", session, [], false, root, "run-1"),
                            grader: FakeGrader.new, sleeper: ->(_seconds) { })
  end

  def attempt_dir(root, id, number) = File.join(root, "cases", "checkout", id, "attempt-#{number}")

  def test_each_attempt_gets_a_start_and_result_and_the_run_gets_case_records
    with_suite do |dir|
      Dir.mktmpdir do |out|
        root = ChangeTestcasesEvidence.prepare(out, "run-1")
        evidence_lane(dir, root, EvidenceSession.new(ok_result(2), root)).run

        attempt = attempt_dir(root, "happy-path", 1)
        start = JSON.parse(File.read(File.join(attempt, "start.json")))
        assert_equal [ "checkout/happy-path", 1 ], start.values_at("case", "attempt")
        assert File.exist?(File.join(attempt, "result.json"))
        assert File.exist?(File.join(attempt, "step-0001-a.json"))
        records = File.readlines(File.join(root, "case-results.jsonl")).map { |line| ChangeCaseResult.from_h(JSON.parse(line)) }
        assert_equal %w[checkout/happy-path checkout/empty-cart], records.map(&:key)
        assert_equal [ "pass", "run-1", attempt ], [ records.first.status, records.first.run_id, records.first.evidence_dir ]
        refute_nil records.first.started_at
      end
    end
  end

  def test_a_killed_call_is_partial_evidence_with_its_checkpointed_steps
    with_suite do |dir|
      Dir.mktmpdir do |out|
        root = ChangeTestcasesEvidence.prepare(out, "run-1")
        records = ok_result(2)
        records[0] = [ RuntimeError.new("browserless /function failed: 408 timed out") ]
        under_test = evidence_lane(dir, root, EvidenceSession.new(records, root, checkpoints: 2))
        finding = step_findings(under_test.run).find { |entry| entry.check == "checkout/happy-path" }

        assert_equal "fail", finding.status
        assert_includes finding.detail, "partial_evidence"
        assert_includes finding.detail, "2 step(s) were checkpointed"
        attempt = attempt_dir(root, "happy-path", 1)
        assert File.exist?(File.join(attempt, "start.json"))
        refute File.exist?(File.join(attempt, "result.json"))
        assert_includes File.read(File.join(attempt, "termination.json")), "408 timed out"
        record = under_test.case_records.first
        assert_equal "partial_evidence", record.status
        assert record.failure?
      end
    end
  end

  def test_a_fail_then_pass_retry_keeps_both_attempts_and_is_flaky
    with_suite do |dir|
      Dir.mktmpdir do |out|
        root = ChangeTestcasesEvidence.prepare(out, "run-1")
        records = ok_result(2)
        records[1] = [ failed_result(1, [ { "index" => 0, "label" => "goto", "ok" => false, "error" => "boom" } ]), records[1] ]
        under_test = evidence_lane(dir, root, EvidenceSession.new(records, root))
        under_test.run

        assert File.exist?(File.join(attempt_dir(root, "empty-cart", 1), "result.json"))
        assert File.exist?(File.join(attempt_dir(root, "empty-cart", 2), "result.json"))
        record = under_test.case_records.last
        assert record.flaky?
        assert_equal [ attempt_dir(root, "empty-cart", 1), attempt_dir(root, "empty-cart", 2) ],
                     record.attempts.map { |entry| entry[:evidence_dir] }
      end
    end
  end

  def test_a_queue_rejection_leaves_no_attempt_dir
    with_suite do |dir|
      Dir.mktmpdir do |out|
        root = ChangeTestcasesEvidence.prepare(out, "run-1")
        records = ok_result(2)
        rejected = ChangeDocker::Browserless::QueueRejected.new("429")
        records[0] = Array.new(ChangeLaneTestcases::QUEUE_BACKOFF_S.size + 1) { rejected }
        evidence_lane(dir, root, EvidenceSession.new(records, root)).run
        refute Dir.exist?(attempt_dir(root, "happy-path", 1))
      end
    end
  end

  def test_the_module_checkpoints_each_step_into_the_attempt_dir
    with_suite do |dir|
      Dir.mktmpdir do |out|
        root = ChangeTestcasesEvidence.prepare(out, "run-1")
        session = EvidenceSession.new(ok_result(2), root)
        evidence_lane(dir, root, session).run
        assert_includes session.code, '"dir":"/cf-run/cases/checkout/happy-path/attempt-1"'
        assert_includes session.code, "await writer.step(record, log.take());"
        assert_includes session.code, "Browser.setDownloadBehavior"
      end
    end
  end

  def test_parallel_cases_share_the_evidence_tree_without_racing
    with_suite do |dir|
      Dir.mktmpdir do |out|
        root = ChangeTestcasesEvidence.prepare(out, "run-1")
        under_test = evidence_lane(dir, root, EvidenceSession.new(ok_result(2), root), "parallel" => 2)
        20.times do
          FileUtils.rm_rf(File.join(root, "cases"))
          assert(step_findings(under_test.run).all? { |finding| finding.status == "pass" })
        end
      end
    end
  end

  def test_a_failed_acceptance_verdict_makes_the_case_record_fail
    with_suite do |dir|
      Dir.mktmpdir do |out|
        root = ChangeTestcasesEvidence.prepare(out, "run-1")
        config = ChangeConfig::LaneConfig.new("testcases", { "suites" => [ "*.cf-testcases.yml" ] }, dir)
        grader = FakeGrader.new(verdicts: { "checkout/happy-path" => [ "fail", "wrong page" ] })
        under_test = ChangeLaneTestcases.new(config, EvidenceCtx.new("net", "https://app.example.org",
                                                                     EvidenceSession.new(ok_result(2), root), [], false, root, "run-1"),
                                             grader: grader, sleeper: ->(_seconds) { })
        under_test.run
        records = File.readlines(File.join(root, "case-results.jsonl")).map { |line| JSON.parse(line) }
        assert_equal [ %w[fail fail], %w[pass pass] ], records.map { |entry| entry.values_at("status", "acceptance_verdict") }
      end
    end
  end

  def record_statuses(grader)
    with_suite do |dir|
      Dir.mktmpdir do |out|
        root = ChangeTestcasesEvidence.prepare(out, "run-1")
        config = ChangeConfig::LaneConfig.new("testcases", { "suites" => [ "*.cf-testcases.yml" ] }, dir)
        ctx = EvidenceCtx.new("net", "https://app.example.org", EvidenceSession.new(ok_result(2), root), [], false, root, "run-1")
        ChangeLaneTestcases.new(config, ctx, grader: grader, sleeper: ->(_seconds) { }).run
        return File.readlines(File.join(root, "case-results.jsonl")).map { |line| JSON.parse(line)["status"] }
      end
    end
  end

  # Unattended, a missing grader or an unclear verdict fails the run, so the
  # record cannot call those cases passed.
  def test_unjudged_acceptance_is_not_recorded_as_a_pass
    assert_equal %w[fail fail], record_statuses(FakeGrader.new(reason: "no grader"))
    assert_equal %w[fail pass], record_statuses(FakeGrader.new(verdicts: { "checkout/happy-path" => [ "unclear", "?" ] }))
  end

  def test_a_screenshot_step_is_checkpointed_with_its_image
    with_suite do |dir|
      Dir.mktmpdir do |out|
        root = ChangeTestcasesEvidence.prepare(out, "run-1")
        session = EvidenceSession.new(ok_result(2), root)
        evidence_lane(dir, root, session).run
        assert_includes session.code, "write(`shot-${String(record.index + 1).padStart(4, \"0\")}-${shot}.png`, record.screenshot, true);"
      end
    end
  end

  def test_ids_that_sanitize_alike_get_distinct_evidence_dirs
    refute_equal ChangeTestcasesEvidence.slug("a/b"), ChangeTestcasesEvidence.slug("a_b")
    assert_equal "a_b", ChangeTestcasesEvidence.slug("a_b")
  end

  def test_a_rejected_resume_keeps_the_first_calls_evidence
    Dir.mktmpdir do |out|
      root = ChangeTestcasesEvidence.prepare(out, "run-1")
      evidence = ChangeTestcasesEvidence.new(root)
      item = Struct.new(:suite, :id).new("s", "c")
      attempt = evidence.open_attempt(item, 1, { case: "s/c" })
      first = { "ok" => false, "steps" => [ { "index" => 0, "ok" => true } ], "authExpired" => { "index" => 0 } }
      merged = ChangeLaneTestcases.allocate.send(:merge_resumed, first, { "ok" => false, "queueFull" => true, "callError" => "429" }, 0)
      evidence.close_attempt(attempt, merged)
      assert File.exist?(File.join(attempt.host_dir, "start.json"))
      assert File.exist?(File.join(attempt.host_dir, "result.json"))
    end
  end

  def test_a_resumed_call_that_dies_is_partial_evidence_with_both_segments
    Dir.mktmpdir do |out|
      root = ChangeTestcasesEvidence.prepare(out, "run-1")
      evidence = ChangeTestcasesEvidence.new(root)
      attempt = evidence.open_attempt(Struct.new(:suite, :id).new("s", "c"), 1, { case: "s/c" })
      File.write(File.join(attempt.host_dir, "step-0001-a.json"), JSON.generate("record" => { "index" => 0, "ok" => true }))
      File.write(File.join(attempt.host_dir, "step-0002-r.json"), JSON.generate("record" => { "index" => 1, "ok" => true }))
      first = { "ok" => false, "steps" => [ { "index" => 0, "ok" => true } ], "authExpired" => { "index" => 0 } }
      merged = ChangeLaneTestcases.allocate.send(:merge_resumed, first, { "ok" => false, "callError" => "408", "steps" => [] }, 0)
      record = evidence.close_attempt(attempt, merged)
      assert record["partialEvidence"]
      assert_equal [ 0, 1 ], record["steps"].map { |step| step["index"] }
      assert File.exist?(File.join(attempt.host_dir, "termination.json"))
    end
  end

  def test_dot_ids_never_navigate_out_of_the_evidence_root
    %w[. .. ...].each { |id| refute_includes [ ".", "..", "" ], ChangeTestcasesEvidence.slug(id) }
  end

  def test_case_records_use_the_runners_commit_when_given
    ctx = Struct.new(:commit).new("abc123")
    lane = ChangeLaneTestcases.allocate
    lane.instance_variable_set(:@context, ctx)
    assert_equal "abc123", lane.send(:commit)
  end

  # --- suite_version 6: warn, blocked_precondition, relations ---------------------------

  # The context a v6 run carries: the two gate flags and the reference hosts.
  Ctx6 = Struct.new(:network, :target_url, :browserless, :suite_select, :signoff, :fail_on_warn, :fail_on_blocked,
                    :reference_hosts) do
    def log(_message) = nil
    def signoff? = signoff == true
  end

  def lane6(dir, session, fail_on_warn: false, fail_on_blocked: false, reference_hosts: [], raw: {}, grader: FakeGrader.new)
    config = ChangeConfig::LaneConfig.new("testcases", { "suites" => [ "*.cf-testcases.yml" ] }.merge(raw), dir)
    ChangeLaneTestcases.new(config, Ctx6.new("net", "https://app.example.org", session, [], false, fail_on_warn, fail_on_blocked,
                                             reference_hosts), grader: grader, sleeper: ->(_seconds) { })
  end

  V6_SUITE = <<~YAML
    suite: members
    suite_version: 6
    cases:
      - id: counts-agree
        acceptance: The badge and the table agree.
        steps:
          - goto: /admin
          - capture: { var: badge, selector: ".badge", kind: number }
          - goto: /admin/members
          - capture: { var: rows, selector: "tbody tr", kind: count }
          - expect_relation:
              relation: equal
              reads: { a: badge, b: rows }
              settle: { reread: 1, freshness_selector: ".updated" }
      - id: needs-login
        acceptance: The members page lists the members.
        retries: 2
        safe_rerun: true
        preconditions:
          - goto: /admin
          - expect_visible: ".user-menu"
        steps:
          - goto: /admin/members
  YAML

  DRIFT_STEPS = [
    { "index" => 1, "verb" => "capture", "ok" => true, "captured" => "badge", "found" => 70, "kind" => "number",
      "url" => "https://app.example.org/admin", "selector" => ".badge", "readAt" => "2026-11-21T10:00:00.000Z",
      "freshness" => { ".updated" => "10:00" } },
    { "index" => 3, "verb" => "capture", "ok" => true, "captured" => "rows", "found" => 70, "kind" => "count",
      "url" => "https://app.example.org/admin/members", "selector" => "tbody tr", "readAt" => "2026-11-21T10:00:04.000Z" },
    { "index" => 4, "verb" => "expectRelation", "ok" => true, "status" => "warn", "drift" => true, "relation" => "equal",
      "label" => "expect_relation equal of badge, rows",
      "firstMessage" => "expected badge = 70 to equal rows = 69 within 0",
      "firstReads" => [ { "var" => "badge", "value" => 70, "readAt" => "2026-11-21T10:00:00.000Z" },
                        { "var" => "rows", "value" => 69, "readAt" => "2026-11-21T10:00:01.000Z" } ],
      "reads" => [ { "var" => "badge", "value" => 70, "readAt" => "2026-11-21T10:00:03.000Z" },
                   { "var" => "rows", "value" => 70, "readAt" => "2026-11-21T10:00:04.000Z" } ] }
  ].freeze

  def drift_results
    ok_result(2).tap { |list| list[0] = list[0].merge("steps" => DRIFT_STEPS) }
  end

  def blocked_precondition_record(index)
    { "index" => index, "ok" => false, "steps" => [],
      "blocked" => { "kind" => "precondition", "index" => 1, "label" => "expect_visible .user-menu", "error" => "Error: not visible" } }
  end

  def test_a_drift_passes_the_gate_as_a_warning_and_records_both_value_sets
    with_suite(V6_SUITE) do |dir|
      runner = lane6(dir, FakeSession.new(drift_results))
      findings = step_findings(runner.run)
      drift = findings.find { |finding| finding.check == "members/counts-agree" }
      assert_equal "warn", drift.status
      assert_includes drift.detail, "drift:"
      assert_includes drift.detail, "passed on re-read"
      record = runner.case_records.find { |item| item.id == "counts-agree" }
      assert_equal "warn", record.status
      relation = record.relations.first
      assert relation["drift"]
      assert_equal [ 70, 69 ], relation["first_reads"].map { |read| read["value"] }
      assert_equal [ 70, 70 ], relation["reads"].map { |read| read["value"] }
      assert_equal [ "badge", "rows" ], record.vars.map { |figure| figure["var"] }
      assert_equal "https://app.example.org/admin", record.vars.first["url"]
      assert_equal "10:00", record.vars.first["freshness"]
    end
  end

  def test_fail_on_warn_makes_a_drift_fail_the_gate
    with_suite(V6_SUITE) do |dir|
      findings = step_findings(lane6(dir, FakeSession.new(drift_results), fail_on_warn: true).run)
      assert_equal "fail", findings.find { |finding| finding.check == "members/counts-agree" }.status
    end
  end

  def test_a_drift_case_is_still_graded_and_a_failed_criterion_makes_it_fail
    with_suite(V6_SUITE) do |dir|
      grader = FakeGrader.new(verdicts: { "members/counts-agree" => [ "fail", "badge says 70" ] })
      runner = lane6(dir, FakeSession.new(drift_results), grader: grader)
      runner.run
      assert_includes grader.observations.map { |item| item[:id] }, "members/counts-agree"
      assert_equal "fail", runner.case_records.find { |item| item.id == "counts-agree" }.status
      relations = grader.observations.find { |item| item[:id] == "members/counts-agree" }[:relations]
      assert_equal "warn", relations.first["status"]
    end
  end

  def test_a_failing_precondition_blocks_the_case_which_is_neither_pass_nor_fail
    with_suite(V6_SUITE) do |dir|
      results = ok_result(2).tap { |list| list[1] = blocked_precondition_record(1) }
      session = FakeSession.new(results)
      runner = lane6(dir, session)
      findings = step_findings(runner.run)
      blocked = findings.find { |finding| finding.check == "members/needs-login" }
      assert_equal "warn", blocked.status, "blocked passes the gate by default"
      assert_includes blocked.detail, "blocked_precondition: precondition: expect_visible .user-menu"
      assert_equal "precondition 2: expect_visible .user-menu", blocked.location
      refute blocked.pass?
      refute blocked.fail?
      record = runner.case_records.find { |item| item.id == "needs-login" }
      assert_equal "blocked_precondition", record.status
      assert_equal "precondition: expect_visible .user-menu: Error: not visible", record.blocked_reason
      assert_equal 1, session.calls - 1, "retries: 2 is not spent on a block (one call for the other case)"
    end
  end

  def test_fail_on_blocked_makes_a_block_fail_the_gate
    with_suite(V6_SUITE) do |dir|
      results = ok_result(2).tap { |list| list[1] = blocked_precondition_record(1) }
      findings = step_findings(lane6(dir, FakeSession.new(results), fail_on_blocked: true).run)
      assert_equal "fail", findings.find { |finding| finding.check == "members/needs-login" }.status
      assert_equal "pass", findings.find { |finding| finding.check == "members/counts-agree" }.status
    end
  end

  def test_a_blocked_case_is_not_graded
    with_suite(V6_SUITE) do |dir|
      results = ok_result(2).tap { |list| list[1] = blocked_precondition_record(1) }
      grader = FakeGrader.new
      lane6(dir, FakeSession.new(results), grader: grader).run
      assert_equal [ "members/counts-agree" ], grader.observations.map { |item| item[:id] }
    end
  end

  def test_a_blocked_reference_step_blocks_the_case_without_a_failure
    steps = [ { "index" => 2, "verb" => "referenceGet", "ok" => false, "blocked" => true, "label" => "reference_get $.total",
                "error" => "Error: reference skew: read at x is 9000 ms from its page read" } ]
    results = ok_result(2).tap { |list| list[0] = { "index" => 0, "ok" => false, "steps" => steps } }
    with_suite(V6_SUITE) do |dir|
      findings = step_findings(lane6(dir, FakeSession.new(results)).run)
      blocked = findings.find { |finding| finding.check == "members/counts-agree" }
      assert_equal "warn", blocked.status
      assert_includes blocked.detail, "reference: reference_get $.total: Error: reference skew"
    end
  end

  def test_a_lost_persona_login_blocks_a_v6_suite_but_still_fails_an_older_one
    body = PERSONA_SUITE
    with_suite(body.sub("suite_version: 3", "suite_version: 6")) do |dir|
      findings = step_findings(persona_lane(dir, PersonaSession.new(ok_result(4), login_ok: false)).run)
      admin = findings.find { |finding| finding.check == "roles/as-admin" }
      assert_equal "warn", admin.status
      assert_includes admin.detail, "blocked_precondition: login: persona 'admin' could not log in: wrong password"
    end
    with_suite(body) do |dir|
      findings = step_findings(persona_lane(dir, PersonaSession.new(ok_result(4), login_ok: false)).run)
      assert_equal "fail", findings.find { |finding| finding.check == "roles/as-admin" }.status
    end
  end

  def test_an_undefined_persona_is_still_a_failure_in_a_v6_suite
    body = PERSONA_SUITE.sub("suite_version: 3", "suite_version: 6")
                        .sub("persona: admin\n    steps:\n      - goto: /admin\n", "persona: ghost\n    steps:\n      - goto: /admin\n")
    with_suite(body) do |dir|
      findings = step_findings(persona_lane(dir, PersonaSession.new(ok_result(4))).run)
      assert_equal "fail", findings.find { |finding| finding.check == "roles/as-admin" }.status
    end
  end

  def test_the_case_module_carries_preconditions_the_bridge_and_the_new_record_fields
    with_suite(V6_SUITE) do |dir|
      session = FakeSession.new(ok_result(2))
      lane6(dir, session).run
      needs_login = session.codes.find { |code| code.include?('"id":"members/needs-login"') }
      assert_includes needs_login, '"preconditions":[{"url":"https://app.example.org/admin"'
      assert_includes needs_login, "const bridge = null;"
      assert_includes needs_login, 'blocked = { kind: "precondition"'
      assert_includes needs_login, "preconditions: pre"
      plain = session.codes.find { |code| code.include?('"id":"members/counts-agree"') }
      assert_includes plain, '"preconditions":[]'
    end
  end

  # A reference_get case gets a token-guarded host bridge, and only when a host is allowlisted.
  REFERENCE_SUITE = <<~YAML
    suite: api
    suite_version: 6
    cases:
      - id: total-matches
        acceptance: The badge matches the API.
        steps:
          - goto: /admin
          - capture: { var: badge, selector: ".badge", kind: number }
          - reference_get: { var: api, url: "https://api.example.org/members", json_path: "$.total", pair: badge }
          - expect_relation: { relation: equal, reads: { a: badge, b: api } }
  YAML

  def test_a_reference_case_gets_a_bridge_endpoint_only_with_an_allowlisted_host
    with_suite(REFERENCE_SUITE) do |dir|
      with_host = FakeSession.new(ok_result(1))
      lane6(dir, with_host, reference_hosts: [ "api.example.org" ]).run
      assert_match %r{const bridge = \{"url":"http://host\.docker\.internal:\d+/","token":"[0-9a-f]{32}"\};}, with_host.code

      without = FakeSession.new(ok_result(1))
      lane6(dir, without).run
      assert_includes without.code, "const bridge = null;"
    end
  end

  def test_a_malformed_reference_host_flag_is_a_run_error_not_a_silent_ignore
    with_suite(REFERENCE_SUITE) do |dir|
      findings = lane6(dir, FakeSession.new(ok_result(1)), reference_hosts: [ "api.example.org=everything" ]).run
      assert(findings.any? { |finding| finding.fail? && finding.detail.include?("unknown flag") })
    end
  end

  def test_figures_from_a_reference_are_scrubbed_of_env_secrets
    suite = <<~YAML
      suite: api
      suite_version: 6
      cases:
        - id: leaks
          acceptance: Nothing secret appears in the report.
          steps:
            - goto: /admin
            - fill: { selector: "#pw", env: LEAK_PW }
            - capture: { var: badge, selector: ".badge", kind: text }
    YAML
    steps = [ { "index" => 2, "verb" => "capture", "ok" => true, "captured" => "badge", "found" => "pw is hunter2", "kind" => "text",
                "readAt" => "2026-11-21T10:00:00.000Z", "url" => "https://app.example.org/admin" } ]
    with_suite(suite) do |dir|
      ENV["LEAK_PW"] = "hunter2"
      runner = lane6(dir, FakeSession.new([ ok_result(1).first.merge("steps" => steps) ]))
      runner.run
      assert_equal "pw is [redacted]", runner.case_records.first.vars.first["value"]
    ensure
      ENV.delete("LEAK_PW")
    end
  end

  def test_preconditions_can_feed_the_steps_and_start_the_bridge
    suite = <<~YAML
      suite: api
      suite_version: 6
      cases:
        - id: pre
          acceptance: The badge matches the API.
          preconditions:
            - goto: /admin
            - capture: { var: badge, selector: ".badge", kind: number }
            - reference_get: { var: api, url: "https://api.example.org/m", json_path: "$.total", pair: badge }
          steps:
            - expect_relation: { relation: equal, reads: { a: badge, b: api } }
    YAML
    with_suite(suite) do |dir|
      session = FakeSession.new(ok_result(1))
      lane6(dir, session, reference_hosts: [ "api.example.org" ]).run
      assert_match(/const bridge = \{"url"/, session.code)
    end
  end

  def test_a_drift_in_a_precondition_is_reported_and_preconditions_count_toward_the_budget
    with_suite(V6_SUITE) do |dir|
      results = ok_result(2).tap { |list| list[0] = list[0].merge("preconditions" => DRIFT_STEPS) }
      runner = lane6(dir, FakeSession.new(results))
      findings = step_findings(runner.run)
      assert_equal "warn", findings.find { |finding| finding.check == "members/counts-agree" }.status
      assert runner.case_records.first.relations.first["drift"]
      item = runner.send(:suite_set).cases.find { |entry| entry.id == "needs-login" }
      assert_operator runner.case_budget_ms(item.dup.tap { |copy| copy.timeout_ms = nil }), :>=, 115_000
      big = item.dup.tap { |copy| copy.timeout_ms = nil; copy.preconditions = Array.new(10) { { "wait_for_text" => "x", "timeout_ms" => 60_000 } } }
      assert_operator runner.case_budget_ms(big), :>=, 600_000
    end
  end
end
