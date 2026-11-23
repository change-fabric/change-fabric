# frozen_string_literal: true

require_relative "pulse_helper"
require_relative "../scripts/pulse_store"
require_relative "../scripts/pulse_scope"
require_relative "../scripts/pulse_integrity"

# The C5 acceptance matrix: each fixture is a minimal run artifact set, and the
# deterministic checks must flag exactly the expected findings with no model.
class PulseIntegrityTest < Minitest::Test
  include PulseHome

  FIXTURES = File.expand_path("fixtures/pulse", __dir__)

  def load_fixture(name, result: nil)
    plan = File.join(@home, "plan")
    FileUtils.mkdir_p([ plan, File.join(@dir, "pulse_results") ])
    FileUtils.cp(File.join(FIXTURES, name, "goal.md"), File.join(plan, "goal.md"))
    File.write(File.join(@dir, "pulse_results", "result.json"), result || File.read(File.join(FIXTURES, name, "result.json")))
    PulseScope.new(session: @session, project: @home, plan_dir: plan).resolve
  end

  Dir.children(FIXTURES).sort.each do |name|
    define_method("test_matrix_#{name}") do
      load_fixture(name)
      expected = JSON.parse(File.read(File.join(FIXTURES, name, "expected.json")))
      found = PulseIntegrity.new(@session).run
      assert_equal expected, found.map { |f| f.slice("check", "severity", "route") }
      found.each { |f| assert_includes File.read(File.join(FIXTURES, name, "goal.md")), f.dig("serves", "quote") }
    end
  end

  def test_findings_validate_and_store_as_authorizable_with_the_fixture_quote
    load_fixture("zero_row_pass")
    stored = PulseStore.new(@session).append(PulseIntegrity.new(@session).run.first)
    assert_equal "stored", stored["status"]
    assert stored["authorizable"]
  end

  GATED = '"head_sha":"a","gate":{"sha":"a"}'

  def checks(result)
    load_fixture("legit_pass", result: result)
    PulseIntegrity.new(@session).run.map { |f| f["check"] }
  end

  def test_skipped_excluded_from_passed_is_legitimate_under_either_ran_convention
    assert_empty checks(%({"id":"s","verdict":"PASS","expected":40,"ran":40,"skipped":4,"passed":36,"rows":40,#{GATED}}))
    assert_empty checks(%({"id":"s","verdict":"PASS","expected":40,"ran":36,"skipped":4,"passed":36,"rows":36,#{GATED}}))
  end

  def test_verdict_vocabulary_and_whitespace_do_not_evade_the_checks
    [ "pass ", "OK", "success", "green", "Passing" ].each do |verdict|
      assert_equal [ "vacuous-pass" ], checks(%({"id":"s","verdict":"#{verdict}","rows":0,"expected":3,#{GATED}}))
    end
  end

  def test_missing_verdict_is_an_evidence_gap
    assert_equal [ "evidence-gap-verdict-unknown" ], checks(%({"id":"s","rows":3,"expected":3,#{GATED}}))
  end

  def test_missing_denominator_is_an_evidence_gap_not_healthy
    assert_equal [ "evidence-gap-denominator-unknown" ], checks(%({"id":"s","verdict":"PASS","ran":3,"passed":3,"rows":3,#{GATED}}))
  end

  def test_passing_result_without_gate_or_head_is_an_evidence_gap
    assert_equal [ "evidence-gap-gate-unknown" ], checks('{"id":"s","verdict":"PASS","expected":3,"ran":3,"passed":3,"rows":3}')
  end

  def test_comprehensive_label_with_skips_filling_the_count_is_narrowed
    assert_equal [ "narrowed-comprehensive" ], checks(%({"id":"s","verdict":"PASS","expected":40,"ran":40,"skipped":30,"passed":10,"rows":40,"scope_label":"full suite",#{GATED}}))
    assert_empty checks(%({"id":"s","verdict":"PASS","expected":40,"ran":12,"passed":12,"rows":12,"scope_label":"not all, smoke subset",#{GATED}}))
  end

  def test_malformed_result_is_an_evidence_gap
    assert_equal [ "evidence-gap-unreadable" ], checks("{nope")
  end

  def test_commit_skips_appended_results_and_a_failed_append_is_retried
    load_fixture("zero_row_pass")
    findings = PulseIntegrity.new(@session).run
    refute_empty PulseIntegrity.new(@session).run, "no commit, so the next pass still sees it"
    PulseIntegrity.new(@session).commit(findings)
    assert_empty PulseIntegrity.new(@session).run
    File.write(File.join(@dir, "pulse_results", "result.json"), '{"id":"s","verdict":"PASS","rows":0,"expected":4}')
    refute_empty PulseIntegrity.new(@session).run, "a changed result is checked again"
  end

  def test_commit_forgets_results_whose_file_is_gone
    load_fixture("zero_row_pass")
    PulseIntegrity.new(@session).commit(PulseIntegrity.new(@session).run)
    File.delete(File.join(@dir, "pulse_results", "result.json"))
    PulseIntegrity.new(@session).commit([])
    assert_empty PulseStore.new(@session).cursor["integrity_digests"]
  end

  def test_no_scope_yields_a_finding_without_serves_and_still_appends_as_system
    load_fixture("zero_row_pass")
    File.delete(File.join(@dir, "pulse_scope.json"))
    finding = PulseIntegrity.new(@session).run.first
    assert_nil finding["serves"]
    assert_equal "stored", PulseStore.new(@session).append_system(finding)["status"]
  end
end
