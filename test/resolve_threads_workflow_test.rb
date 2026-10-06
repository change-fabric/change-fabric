#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "json"
require_relative "../scripts/plan_check"

# Guards the cf:resolve-threads Workflow against losing the root-cause pass.
# Fixing only the reported line is how a PR ends up with four review rounds;
# each guard below is text the script must keep so Evaluate probes the whole
# bug class and recurring feedback reaches the Root cause phase.
class ResolveThreadsWorkflowTest < Minitest::Test
  SKILL = File.expand_path("../skills/resolve-threads", __dir__)
  WORKFLOW = File.join(SKILL, "reference", "workflow.js")
  REPLYING = File.join(SKILL, "reference", "replying.md")

  # Each guard is text the workflow must keep, keyed by the failure it prevents.
  GUARDS = {
    "evaluate names the bug class" => "concernClass",
    "evaluate sees the rest of the run" => "Other unresolved threads in this run",
    "evaluate reads earlier per-instance fixes" => "already fixed per instance",
    "evaluate fixes sibling instances" => "fix every instance of the class you found",
    "regression test covers the class" => "enumerate the class's variants",
    "root cause only on recurrence" => "recurrence.fired ? (recurrence.threadIds",
    "root cause sizes the fix" => '[ "in_run", "plan" ]',
    "cluster lands as one commit" => "Create exactly one commit for the whole cluster",
    "plan clusters seed cf:plan" => "seededGoal",
    "empty systemic diff dissolves the cluster" => "dissolved"
  }.freeze

  def workflow = File.read(WORKFLOW)

  def skill_md = File.read(File.join(SKILL, "SKILL.md"))

  def test_workflow_keeps_every_guard
    missing = GUARDS.reject { |_, text| workflow.include?(text) }
    assert_empty missing.keys, "workflow lost guards"
  end

  def test_phase_calls_match_meta_titles
    titles = workflow[/export const meta = \{.*?\n\}/m].scan(/title: "([^"]+)"/).flatten
    calls = workflow.scan(/phase\("([^"]+)"\)/).flatten.uniq
    options = workflow.scan(/phase: "([^"]+)"/).flatten.uniq
    assert_equal titles.sort, calls.sort, "phase() calls must match meta.phases"
    assert_empty options - titles, "phase options missing from meta.phases"
  end

  def test_workflow_passes_the_contract_checks
    lines = []
    assert PlanCheck.check_determinism(workflow, lines), lines.join("\n")
    refute_match PlanCheck::GLYPHS, workflow
  end

  def test_workflow_carries_the_cf_name
    refute_match(/pst:|pst-/, workflow)
    assert_equal "cf-resolve-threads-scope", workflow[/^\s*name: "([^"]+)"/, 1]
  end

  # Every apply result shape the Apply phase can produce, and whether it may
  # be replied to as `Fixed in <sha>.` and resolved. Anything short of an
  # applied commit with a sha must route to conflicts.
  APPLY_RESULTS = {
    "applied with sha" => [ { applied: true, commitSha: "abc1234", note: "ok" }, true ],
    "applied with no sha" => [ { applied: true, note: "committed?" }, false ],
    "applied with empty sha" => [ { applied: true, commitSha: "", note: "x" }, false ],
    "apply failed" => [ { applied: false, note: "patch conflict" }, false ],
    "apply failed with a stray sha" => [ { applied: false, commitSha: "abc1234", note: "x" }, false ],
    "agent returned nothing" => [ { applied: false, note: "apply agent did not return a result" }, false ]
  }.freeze

  def test_one_landed_predicate_routes_threads_and_clusters
    assert_includes workflow, "const fixed = applied.filter(landed)"
    assert_includes workflow, "const conflicts = applied.filter((a) => !landed(a))"
    assert_includes workflow, "const inRunClusters = clusterApplied\n  .filter(landed)"
    assert_includes workflow, ".filter((c) => !landed(c))"
  end

  def test_landed_predicate_accepts_only_a_committed_fix
    skip "node not installed" unless system("node", "--version", out: File::NULL)
    definition = workflow[/^const landed = .*$/] or flunk("workflow lost the landed predicate")
    cases = APPLY_RESULTS.transform_values(&:first)
    js = "#{definition}\nconst c = #{JSON.generate(cases)}\n" \
         "console.log(JSON.stringify(Object.fromEntries(Object.entries(c).map(([k, v]) => [k, landed(v)]))))"
    out, status = Open3.capture2("node", "-e", js)
    assert status.success?, "node failed to evaluate the predicate"
    assert_equal APPLY_RESULTS.transform_values(&:last), JSON.parse(out)
  end

  def test_replying_states_the_reply_contracts
    text = File.read(REPLYING)
    assert_includes text, "`Fixed in <sha>.`"
    assert_includes text, "`Deferred to plan <slug>.`"
  end

  def test_skill_defaults_to_full_auto_and_reads_history
    assert_includes skill_md, "--signoff"
    assert_includes skill_md, "thread_history.rb"
    assert_includes skill_md, "nested under cf:drive"
    refute_includes skill_md, "proceed automatically"
  end
end
