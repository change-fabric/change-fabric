# frozen_string_literal: true

require_relative "pulse_helper"
require_relative "../scripts/pulse_store"
require_relative "../scripts/pulse_scope"

class PulseScopeTest < Minitest::Test
  include PulseHome

  def test_conflicting_overrides_fall_back_to_ctx_doc
    project = File.join(@home, "proj")
    ctx = File.join(@home, ".claude", "cf", "ctx", project.gsub("/", "-"))
    FileUtils.mkdir_p([ project, File.join(ctx, "truth") ])
    File.write(File.join(project, "AGENTS.md"), "pulse.goal: a.md\n")
    File.write(File.join(project, "CLAUDE.md"), "pulse.goal: b.md\n")
    File.write(File.join(ctx, "truth", "goal.md"), "Project goal.\n")
    result = PulseScope.new(session: @session, project: project).resolve
    assert_equal [ "scope-conflict" ], result["conflicts"]
    assert_equal [ "~/.claude/cf/ctx/#{project.gsub('/', '-')}/truth/goal.md" ], result["sources"].map { |s| s["source_path"] }
  end

  def test_unresolved_scope_is_report_only
    assert PulseScope.new(session: @session, project: @home).resolve["report_only"]
  end

  def test_run_sources_carry_revisions_and_a_changed_source_gets_a_new_one
    plan = File.join(@home, "plan")
    FileUtils.mkdir_p(plan)
    File.write(File.join(plan, "goal.md"), "One.\n")
    first = PulseScope.new(session: @session, project: @home, plan_dir: plan).resolve["sources"].first
    File.write(File.join(plan, "goal.md"), "Two.\n")
    second = PulseScope.new(session: @session, project: @home, plan_dir: plan).resolve["sources"].first
    assert_equal "run_goal", first["role"]
    refute_equal first["revision"], second["revision"]
  end

  def test_tilde_only_replaces_a_whole_home_segment
    scope = PulseScope.new(session: @session, project: @home, home: "/Users/pst")
    assert_equal "~/x", scope.send(:tilde, "/Users/pst/x")
    assert_equal "/Users/pstx/x", scope.send(:tilde, "/Users/pstx/x")
  end
end
