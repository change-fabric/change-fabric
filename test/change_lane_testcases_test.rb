# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require_relative "../scripts/change_config"
require_relative "../scripts/change_run"
require_relative "../scripts/change_lane_testcases"

# The testcases lane: suite loading and its refusals, tag filtering, what
# gate_tags does and does not soften, and the compiled payload. The browser JS
# itself is exercised by a real docker run, not here; what this covers is the
# Ruby deciding what that JS is handed and how a returned record becomes a
# verdict.
class ChangeLaneTestcasesTest < Minitest::Test
  Ctx = Struct.new(:network, :target_url, :browserless) do
    def log(_message) = nil
  end

  # A stand-in browserless session that records the module it was handed and
  # returns whatever the test wants back.
  class FakeSession
    attr_reader :code

    def initialize(result) = @result = result

    def run_function(code)
      @code = code
      @result
    end
  end

  SUITE = <<~YAML
    suite: checkout
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

  def lane(dir, raw = {}, session: nil)
    config = ChangeConfig::LaneConfig.new("testcases", { "suites" => [ "*.cf-testcases.yml" ] }.merge(raw), dir)
    ChangeLaneTestcases.new(config, Ctx.new("net", "https://app.example.org", session))
  end

  def ok_result(count) = (0...count).map { |i| { "index" => i, "attempts" => 1, "ok" => true, "steps" => [] } }

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
      findings = lane(dir, {}, session: FakeSession.new(ok_result(2))).run

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
      findings = lane(dir, {}, session: FakeSession.new(result)).run

      assert findings.first.fail?
      assert_includes findings.first.location, "step 2: click [data-test=add-to-cart]"
      assert_includes findings.first.detail, "waiting for selector failed"
    end
  end

  # gate_tags is the staged-adoption valve: a failing case no gate tag covers
  # still reports, it just cannot fail the run.
  def test_gate_tags_softens_only_the_cases_no_gate_tag_covers
    with_suite do |dir|
      result = [ failed_result(0, []), failed_result(1, []) ]
      findings = lane(dir, { "gate_tags" => [ "smoke" ] }, session: FakeSession.new(result)).run

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
      findings = lane(dir, { "tags" => [ "smoke" ] }, session: session).run

      assert_equal [ "checkout/happy-path" ], findings.map(&:check)
      refute_includes session.code, "/cart"
    end
  end

  def test_a_case_that_only_passed_on_a_retry_is_recorded_flaky
    with_suite do |dir|
      result = ok_result(2)
      result[1] = { "index" => 1, "attempts" => 2, "ok" => true, "steps" => [] }
      findings = lane(dir, {}, session: FakeSession.new(result)).run

      assert findings.last.pass?
      assert findings.last.flaky
      assert_equal 2, findings.last.attempts
    end
  end

  def test_a_case_with_no_returned_record_fails_rather_than_passing_silently
    with_suite do |dir|
      findings = lane(dir, {}, session: FakeSession.new([ ok_result(1).first ])).run

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
      assert_equal 1, session.code.scan("async function resolveCodeSource").size
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
      section = instance.acceptance_section

      assert_includes section, "| checkout/happy-path | checkout smoke | PASS | 1 | A guest can reach the confirmation page. |"
    end
  end

  def test_there_is_no_acceptance_section_before_a_run
    with_suite { |dir| assert_nil lane(dir).acceptance_section }
  end
end
