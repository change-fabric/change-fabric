# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"

require_relative "#{File.expand_path('../scripts', __dir__)}/plan_check"

class PlanCheckTest < Minitest::Test
  # Built from a codepoint, not a literal, so this file never carries the
  # glyph it exists to test for (glyph_guard.rb would otherwise deny writing it).
  EM = [ 0x2014 ].pack("U")

  # The smallest script that satisfies every workflow.js check, so a test that
  # exercises one failure can vary exactly that one thing.
  GOOD_WORKFLOW = <<~JS
    export const meta = {
      name: "example-plan",
      description: "Build the example",
      phases: [ { title: "Build" } ]
    }

    phase("Build")
    const built = await agent("Build it", { phase: "Build" })
    return { built }
  JS

  def with_pair(goal:, plan:, workflow: nil)
    Dir.mktmpdir do |dir|
      goal_path = File.join(dir, "goal.md")
      plan_path = File.join(dir, "plan.md")
      File.write(goal_path, goal) unless goal.nil?
      File.write(plan_path, plan) unless plan.nil?
      File.write(File.join(dir, "workflow.js"), workflow) unless workflow.nil?
      yield goal_path, plan_path
    end
  end

  def with_workflow(source)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "workflow.js")
      File.write(path, source) unless source.nil?
      yield path
    end
  end

  def workflow_lines(source)
    with_workflow(source) do |path|
      lines = []
      ok = PlanCheck.check_workflow(path, lines)
      return [ ok, lines ]
    end
  end

  def thick_plan(lines: 80)
    ([ "## Section" ] + Array.new(lines - 1, "a real line of plan content")).join("\n")
  end

  def test_goal_at_exactly_the_cap_passes
    with_pair(goal: "a" * 4000, plan: thick_plan) do |goal_path, plan_path|
      result = PlanCheck.run(goal_path, plan_path)
      assert result.ok?
      assert_includes result.lines, "goal.md: 4000/4000 characters OK"
    end
  end

  def test_goal_one_over_the_cap_fails
    with_pair(goal: "a" * 4001, plan: thick_plan) do |goal_path, plan_path|
      result = PlanCheck.run(goal_path, plan_path)
      refute result.ok?
      assert_includes result.lines, "goal.md: 4001/4000 characters OVER CAP"
    end
  end

  def test_multibyte_characters_count_as_one_character_each
    with_pair(goal: "\u{1F600}" * 4000, plan: thick_plan) do |goal_path, plan_path|
      result = PlanCheck.run(goal_path, plan_path)
      assert result.ok?
      assert_includes result.lines, "goal.md: 4000/4000 characters OK"
    end
  end

  def test_missing_plan_md_fails
    with_pair(goal: "short goal", plan: nil) do |goal_path, plan_path|
      result = PlanCheck.run(goal_path, plan_path)
      refute result.ok?
      assert_includes result.lines, "plan.md: MISSING or empty (#{plan_path})"
    end
  end

  def test_empty_plan_md_fails
    with_pair(goal: "short goal", plan: "") do |goal_path, plan_path|
      result = PlanCheck.run(goal_path, plan_path)
      refute result.ok?
      assert_includes result.lines, "plan.md: MISSING or empty (#{plan_path})"
    end
  end

  def test_missing_goal_md_fails
    with_pair(goal: nil, plan: thick_plan) do |goal_path, plan_path|
      result = PlanCheck.run(goal_path, plan_path)
      refute result.ok?
      assert_includes result.lines, "goal.md: MISSING or empty (#{goal_path})"
    end
  end

  def test_glyph_in_goal_fails_and_names_the_file
    with_pair(goal: "the plan#{EM}in short", plan: thick_plan) do |goal_path, plan_path|
      result = PlanCheck.run(goal_path, plan_path)
      refute result.ok?
      assert_includes result.lines, "goal.md: contains a banned AI-slop glyph"
    end
  end

  def test_glyph_in_plan_fails_and_names_the_file
    with_pair(goal: "short goal", plan: "#{thick_plan}#{EM}trailing") do |goal_path, plan_path|
      result = PlanCheck.run(goal_path, plan_path)
      refute result.ok?
      assert_includes result.lines, "plan.md: contains a banned AI-slop glyph"
    end
  end

  def test_checker_uses_glyph_guards_own_pattern_constant
    source = File.read(File.expand_path("../scripts/plan_check.rb", __dir__))
    assert_match(/GlyphGuard::PATTERN/, source)
    refute_match(/BANNED\s*=/, source)
  end

  def test_thin_plan_warns_but_still_exits_zero
    with_pair(goal: "short goal", plan: "## Heading\nonly a couple lines") do |goal_path, plan_path|
      result = PlanCheck.run(goal_path, plan_path)
      assert result.ok?
      assert_includes result.warnings.join, "under 60 lines"
    end
  end

  def test_plan_with_no_heading_warns_but_still_exits_zero
    with_pair(goal: "short goal", plan: Array.new(80, "line with no heading marker").join("\n")) do |goal_path, plan_path|
      result = PlanCheck.run(goal_path, plan_path)
      assert result.ok?
      assert_includes result.warnings.join, 'no "## " heading'
    end
  end

  def test_thick_plan_with_heading_has_no_warnings
    with_pair(goal: "short goal", plan: thick_plan) do |goal_path, plan_path|
      result = PlanCheck.run(goal_path, plan_path)
      assert result.ok?
      assert_empty result.warnings
    end
  end

  def test_a_well_formed_workflow_script_passes
    ok, lines = workflow_lines(GOOD_WORKFLOW)
    assert ok, lines.join("\n")
    assert_includes lines, "workflow.js: export const meta = { literal header present"
    assert_includes lines, "workflow.js: at least one phase() call present"
    assert_includes lines, "workflow.js: no nondeterministic calls"
  end

  def test_missing_workflow_script_fails
    ok, lines = workflow_lines(nil)
    refute ok
    assert_includes lines.join, "workflow.js: MISSING or empty"
  end

  # A meta assigned some other way (a variable, a spread) is not the literal
  # header the tool parses statically before the script ever runs.
  def test_workflow_without_a_literal_meta_header_fails
    ok, lines = workflow_lines(GOOD_WORKFLOW.sub("export const meta = {", "const m = {"))
    refute ok
    assert_includes lines, "workflow.js: MISSING export const meta = { literal header"
  end

  def test_workflow_with_no_phase_call_fails
    ok, lines = workflow_lines(GOOD_WORKFLOW.gsub(/^phase\("Build"\)\n/, ""))
    refute ok
    assert_includes lines, "workflow.js: MISSING at least one phase() call"
  end

  def test_workflow_using_date_now_fails
    ok, lines = workflow_lines("#{GOOD_WORKFLOW}\nconst t = Date.now()\n")
    refute ok
    assert_includes lines, "workflow.js: nondeterministic call(s) Date.now()"
  end

  def test_workflow_using_math_random_fails
    ok, lines = workflow_lines("#{GOOD_WORKFLOW}\nconst r = Math.random()\n")
    refute ok
    assert_includes lines, "workflow.js: nondeterministic call(s) Math.random()"
  end

  def test_workflow_naming_every_nondeterministic_call_at_once
    ok, lines = workflow_lines("#{GOOD_WORKFLOW}\nconst t = Date.now() + Math.random()\nnew Date()\n")
    refute ok
    assert_includes lines, "workflow.js: nondeterministic call(s) Date.now(), Math.random(), new Date()"
  end

  def test_glyph_in_workflow_fails
    ok, lines = workflow_lines("#{GOOD_WORKFLOW}\n// a comment#{EM}with a glyph\n")
    refute ok
    assert_includes lines, "workflow.js: contains a banned AI-slop glyph"
  end

  def test_directory_mode_requires_a_workflow_script
    with_pair(goal: "short goal", plan: thick_plan) do |goal_path, _plan_path|
      out = StringIO.new
      ex = assert_raises(SystemExit) { PlanCheck::CLI.run([ File.dirname(goal_path) ], out:) }
      assert_equal 1, ex.status
      assert_includes out.string, "workflow.js: MISSING or empty"
    end
  end

  def test_directory_mode_passes_with_all_three_files
    with_pair(goal: "short goal", plan: thick_plan, workflow: GOOD_WORKFLOW) do |goal_path, _plan_path|
      out = StringIO.new
      ex = assert_raises(SystemExit) { PlanCheck::CLI.run([ File.dirname(goal_path) ], out:) }
      assert_equal 0, ex.status, out.string
    end
  end

  # A writing agent verifies the pair before it has authored the script; flag
  # mode without --workflow must not fail it for a file it has not written yet.
  def test_flag_mode_skips_the_workflow_check_when_not_named
    with_pair(goal: "short goal", plan: thick_plan) do |goal_path, plan_path|
      result = PlanCheck.run(goal_path, plan_path)
      assert result.ok?
      refute_includes result.lines.join, "workflow.js"
    end
  end

  def test_cli_bad_usage_exits_2
    out = StringIO.new
    ex = assert_raises(SystemExit) { PlanCheck::CLI.run([], out:) }
    assert_equal 2, ex.status
  end

  def test_cli_exits_zero_on_a_passing_pair
    with_pair(goal: "short goal", plan: thick_plan, workflow: GOOD_WORKFLOW) do |goal_path, plan_path|
      dir = File.dirname(goal_path)
      out = StringIO.new
      ex = assert_raises(SystemExit) { PlanCheck::CLI.run([ dir ], out:) }
      assert_equal 0, ex.status
    end
  end

  def test_cli_exits_one_on_a_failing_pair
    with_pair(goal: "a" * 4001, plan: thick_plan) do |goal_path, plan_path|
      dir = File.dirname(goal_path)
      out = StringIO.new
      ex = assert_raises(SystemExit) { PlanCheck::CLI.run([ dir ], out:) }
      assert_equal 1, ex.status
    end
  end

  def test_cli_accepts_explicit_goal_and_plan_flags
    with_pair(goal: "short goal", plan: thick_plan) do |goal_path, plan_path|
      out = StringIO.new
      ex = assert_raises(SystemExit) do
        PlanCheck::CLI.run([ "--goal", goal_path, "--plan", plan_path ], out:)
      end
      assert_equal 0, ex.status
    end
  end
end
