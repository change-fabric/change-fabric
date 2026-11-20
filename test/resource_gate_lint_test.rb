# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{File.expand_path('../scripts', __dir__)}/resource_gate_lint"

class ResourceGateLintTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/resource_gate_lint", __dir__)
  TEMPLATE = File.expand_path("../skills/plan/reference/workflow-template.js", __dir__)

  def violations(name)
    ResourceGateLint.check(File.read(File.join(FIXTURES, name)))
  end

  def rules(name)
    violations(name).map { |v| v[/\A\w+/] }.uniq
  end

  def test_good_fixture_is_clean
    assert_empty violations("good.js")
  end

  def test_commented_parallel_needs_no_gate
    assert_empty violations("parallel_commented_ok.js")
  end

  def test_template_is_clean
    assert_empty ResourceGateLint.check(File.read(TEMPLATE))
  end

  def test_template_calls_the_installed_gate_not_a_repo_script
    text = File.read(TEMPLATE)
    assert_includes text, "ruby ~/.claude/cf/bin/resource_gate.rb check --json --reclaim-safe"
    refute_includes text, "ruby scripts/resource_gate.rb"
  end

  def test_template_gate_schema_accepts_a_measurement_error
    schema = File.read(TEMPLATE)[/const GATE_SCHEMA = \{.*?\n\}\n/m]
    assert_includes schema, 'ram_available_mb: { type: [ "number", "null" ] }'
    assert_includes schema, 'need: { type: [ "object", "null" ] }'
    assert_includes schema, 'required: [ "ok" ]'
  end

  def test_phase0_without_gate_fails
    assert_equal [ "phase0" ], rules("phase0_missing.js")
  end

  def test_phase0_late_gate_fails
    assert_equal [ "phase0" ], rules("phase0_late.js")
  end

  def test_phase0_commented_gate_fails
    assert_equal [ "phase0" ], rules("phase0_commented.js")
  end

  def test_phase0_gate_text_in_a_string_fails
    assert_equal [ "phase0" ], rules("phase0_in_string.js")
  end

  def test_phase0_gate_after_a_return_fails
    assert_includes rules("phase0_dead_after_return.js"), "phase0"
  end

  def test_loop_without_gate_fails
    assert_equal [ "loop" ], rules("loop_missing.js")
  end

  def test_loop_late_gate_fails
    assert_equal [ "loop" ], rules("loop_late.js")
  end

  def test_loop_gate_after_continue_fails
    assert_equal [ "loop" ], rules("loop_dead_after_continue.js")
  end

  def test_loop_gate_inside_if_false_fails
    assert_equal [ "loop" ], rules("loop_dead_if_false.js")
  end

  def test_parallel_without_gate_fails
    assert_equal [ "parallel" ], rules("parallel_missing.js")
  end

  def test_parallel_with_work_between_gate_and_call_fails
    assert_equal [ "parallel" ], rules("parallel_late_gate.js")
  end

  def test_parallel_gate_inside_if_false_fails
    assert_equal [ "parallel" ], rules("parallel_dead_if_false.js")
  end

  def test_no_phase_calls_at_all_fails
    assert_includes ResourceGateLint.check("const x = 1\n").first, "phase0"
  end

  def test_run_reports_each_file_and_exit_code
    out = StringIO.new
    code = ResourceGateLint.run([ File.join(FIXTURES, "good.js"), File.join(FIXTURES, "loop_late.js") ], out: out)
    assert_equal 1, code
    assert_match(/loop_late\.js: loop:/, out.string)
    assert_equal 0, ResourceGateLint.run([ File.join(FIXTURES, "good.js") ], out: StringIO.new)
  end
end
