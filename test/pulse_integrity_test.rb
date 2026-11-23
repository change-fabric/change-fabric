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

  def integrity = PulseIntegrity.new(@session)

  def result_path = File.join(@dir, "pulse_results", "result.json")

  def load_fixture(name, result: nil)
    plan = File.join(@home, "plan")
    FileUtils.mkdir_p([ plan, File.join(@dir, "pulse_results") ])
    FileUtils.cp(File.join(FIXTURES, name, "goal.md"), File.join(plan, "goal.md"))
    File.write(result_path, result || File.read(File.join(FIXTURES, name, "result.json")))
    PulseScope.new(session: @session, project: @home, plan_dir: plan).resolve
  end

  Dir.children(FIXTURES).sort.each do |name|
    define_method("test_matrix_#{name}") do
      load_fixture(name)
      expected = JSON.parse(File.read(File.join(FIXTURES, name, "expected.json")))
      found = integrity.run
      assert_equal expected, found.map { |f| f.slice("check", "severity", "route") }
      found.each { |f| assert_includes File.read(File.join(FIXTURES, name, "goal.md")), f.dig("serves", "quote") }
    end
  end

  def test_findings_validate_and_store_as_authorizable_with_the_fixture_quote
    load_fixture("zero_row_pass")
    stored = PulseStore.new(@session).append(integrity.run.first)
    assert_equal "stored", stored["status"]
    assert stored["authorizable"]
  end

  GATED = '"head_sha":"a","gate":{"sha":"a"}'

  def checks(result)
    load_fixture("legit_pass", result: result)
    integrity.run.map { |f| f["check"] }
  end

  def test_skipped_excluded_from_passed_is_legitimate_under_either_ran_convention
    assert_empty checks(%({"id":"s","verdict":"PASS","expected":40,"ran":40,"skipped":4,"passed":36,"rows":40,#{GATED}}))
    assert_empty checks(%({"id":"s","verdict":"PASS","expected":40,"ran":36,"skipped":4,"passed":36,"rows":36,#{GATED}}))
  end

  def test_passed_beyond_the_executed_subset_is_skipped_counted_as_pass
    assert_includes checks(%({"id":"s","verdict":"PASS","expected":100,"ran":10,"skipped":5,"passed":15,"rows":10,"scope_label":"smoke subset",#{GATED}})), "skipped-as-pass"
  end

  def test_verdict_vocabulary_and_whitespace_do_not_evade_the_checks
    [ "pass ", "OK", "success", "green", "Passing" ].each do |verdict|
      assert_equal [ "vacuous-pass" ], checks(%({"id":"s","verdict":"#{verdict}","rows":0,"expected":3,#{GATED}}))
    end
  end

  def test_passing_result_with_no_execution_counts_is_an_evidence_gap
    assert_equal [ "evidence-gap-execution-unknown" ], checks(%({"id":"s","verdict":"PASS","expected":100,#{GATED}}))
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

  def test_zero_passed_with_no_rows_or_ran_is_a_vacuous_pass
    assert_equal [ "vacuous-pass" ], checks(%({"id":"s","verdict":"PASS","passed":0,"expected":3,#{GATED}}))
    assert_equal [ "vacuous-pass" ], checks(%({"id":"s","verdict":"PASS","judged":0,"expected":3,#{GATED}}))
    assert_equal [ "vacuous-pass" ], checks(%({"id":"s","verdict":"PASS","rows":3.0,"passed":0.0,"expected":3,#{GATED}}))
  end

  def test_malformed_counters_are_one_evidence_gap_and_never_crash
    [ "false", "true", '"4"', "-1", "1.5", "[1]", '{"n":1}', "1e999" ].each do |bad|
      found = checks(%({"id":"s","verdict":"PASS","expected":3,"ran":3,"passed":3,"rows":3,"skipped":#{bad},#{GATED}}))
      assert_equal [ "evidence-gap-counter-malformed" ], found, "skipped: #{bad}"
    end
  end

  def test_malformed_counter_never_makes_a_pass_healthy
    assert_equal %w[evidence-gap-counter-malformed evidence-gap-execution-unknown],
                 checks(%({"id":"s","verdict":"PASS","expected":3,"rows":"3","ran":false,"passed":-2,#{GATED}})).sort
    assert_equal [ "evidence-gap-counter-malformed" ], checks(%({"id":"s","verdict":"FAIL","rows":null,"ran":"x"}))
  end

  def test_null_counters_read_as_absent
    assert_equal [ "evidence-gap-execution-unknown" ], checks(%({"id":"s","verdict":"PASS","expected":3,"rows":null,"ran":null,"passed":null,#{GATED}}))
  end

  def test_nested_and_wrongly_typed_fields_do_not_crash
    shapes = [ '"id":{"a":1}', '"verdict":["PASS"]', '"scope_label":{"x":1}', '"head_sha":7', '"gate":[1]', '"gate":{"sha":{"x":1}}' ]
    shapes.each do |shape|
      found = checks(%({#{shape},"expected":3,"ran":3,"passed":3,"rows":3}))
      refute_empty found, shape
      assert(found.all? { |check| check.start_with?("evidence-gap") }, shape)
    end
  end

  def test_empty_truncated_and_non_object_json_are_evidence_gaps
    [ "", '{"id":"s","verdict":"PA', "[]", "3", "null", ("[" * 500) + ("]" * 500), "\xff\xfe{}".b ].each do |text|
      assert_equal [ "evidence-gap-unreadable" ], checks(text)
    end
  end

  def test_a_huge_result_is_an_evidence_gap_without_being_parsed
    load_fixture("legit_pass")
    File.write(result_path, %({"id":"s","verdict":"PASS","pad":"#{"x" * (PulseIntegrity::MAX_BYTES + 1)}"}))
    assert_equal [ "evidence-gap-unreadable" ], integrity.run.map { |f| f["check"] }
  end

  def test_a_duplicate_id_is_flagged_and_the_second_file_is_still_checked
    load_fixture("legit_pass")
    File.write(File.join(@dir, "pulse_results", "other.json"), %({"id":"legit","verdict":"PASS","rows":0,"expected":3,#{GATED}}))
    File.write(result_path, File.read(File.join(FIXTURES, "legit_pass", "result.json")).sub(/"id":"[^"]*"/, '"id":"legit"'))
    assert_equal %w[evidence-gap-duplicate-record vacuous-pass], integrity.run.map { |f| f["check"] }.sort
  end

  def test_invalid_utf8_inside_a_value_does_not_abort_the_scan
    assert_equal [ "vacuous-pass" ], checks(%({"id":"a\xff","verdict":"pass","rows":0,"expected":3,"scope_label":"\xff",#{GATED}}).b)
  end

  def test_an_unrecognized_verdict_is_an_evidence_gap_and_a_known_fail_is_not
    assert_equal [ "evidence-gap-verdict-unrecognized" ], checks(%({"id":"s","verdict":"passed with warnings","rows":0,"expected":3}))
    assert_empty checks(%({"id":"s","verdict":"FAIL","rows":0,"expected":3,"ran":0,"passed":0}))
  end

  def test_an_explicit_judged_count_is_checked_without_ran
    assert_equal [ "narrowed-comprehensive" ], checks(%({"id":"s","verdict":"PASS","expected":100,"judged":10,"rows":10,"scope_label":"comprehensive",#{GATED}}))
  end

  def test_a_non_string_scope_label_still_reads_as_comprehensive
    assert_equal [ "narrowed-comprehensive" ], checks(%({"id":"s","verdict":"PASS","expected":10,"ran":5,"judged":5,"passed":5,"rows":5,"scope_label":["full"],#{GATED}}))
  end

  def test_contradictory_counts_on_a_pass_are_an_evidence_gap
    [ '"ran":5,"passed":99', '"ran":5,"passed":5,"failed":3', '"ran":50,"passed":50' ].each do |counts|
      assert_equal [ "evidence-gap-counts-inconsistent" ], checks(%({"id":"s","verdict":"PASS","expected":5,"rows":5,#{counts},#{GATED}})), counts
    end
  end

  def test_commit_skips_appended_results_and_a_failed_append_is_retried
    load_fixture("zero_row_pass")
    findings = integrity.run
    refute_empty integrity.run, "no commit, so the next pass still sees it"
    integrity.commit(findings)
    assert_empty integrity.run
    File.write(result_path, '{"id":"s","verdict":"PASS","rows":0,"expected":4}')
    refute_empty integrity.run, "a changed result is checked again"
  end

  def test_a_partial_append_leaves_the_whole_result_pending
    load_fixture("zero_row_pass", result: %({"id":"s","verdict":"PASS","rows":0,"ran":0,"expected":10,"scope_label":"full",#{GATED}}))
    found = integrity.run
    assert_equal %w[narrowed-comprehensive vacuous-pass], found.map { |f| f["check"] }.sort
    integrity.commit([ found.first ])
    assert_equal 2, integrity.run.size
    integrity.commit(found)
    assert_empty integrity.run
  end

  def test_commit_forgets_results_whose_file_is_gone
    load_fixture("zero_row_pass")
    integrity.commit(integrity.run)
    File.delete(result_path)
    integrity.commit([])
    assert_empty PulseStore.new(@session).cursor["integrity_digests"]
  end

  def test_no_scope_yields_a_finding_without_serves_and_still_appends_as_system
    load_fixture("zero_row_pass")
    File.delete(File.join(@dir, "pulse_scope.json"))
    finding = integrity.run.first
    assert_nil finding["serves"]
    assert_equal "stored", PulseStore.new(@session).append_system(finding)["status"]
  end
end
