#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "json"
require_relative "../scripts/plan_check"
require_relative "../scripts/thread_history"

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
    "each agent can find and remove its own worktree" => 'worktree add \\"$d\\" " + headSha +',
    "evaluate sees the rest of the run" => "Other unresolved threads in this run",
    "evaluate reads earlier per-instance fixes" => "already fixed per instance",
    "evaluate fixes sibling instances" => "fix every instance of the class you found",
    "regression test covers the class" => "enumerate the class's variants",
    "root cause only on recurrence" => "recurrence.fired ? (recurrence.threadIds",
    "root cause sizes the fix" => '[ "in_run", "plan" ]',
    "cluster lands as one commit" => "Create exactly one commit for the whole cluster",
    "plan clusters seed cf:plan" => "seededGoal",
    "empty systemic diff converts the cluster to plan" => 'c.size = "plan"',
    "unaccounted candidates join a generic plan cluster" => "unidentified root cause"
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

  # Every member mix a clustered thread can carry, and the size the cluster
  # must end up with: only an all-fix in_run cluster may land unattended.
  CLUSTER_SIZES = {
    "in_run, all fix" => [ "in_run", %w[fix fix], "in_run" ],
    "in_run, one needs_human" => [ "in_run", %w[fix needs_human], "plan" ],
    "in_run, only needs_human" => [ "in_run", %w[needs_human], "plan" ],
    "in_run, a wont_fix" => [ "in_run", %w[fix wont_fix], "plan" ],
    "in_run, a missing verdict" => [ "in_run", [ "fix", nil ], "plan" ],
    "in_run, no members" => [ "in_run", [], "plan" ],
    "plan, all fix" => [ "plan", %w[fix], "plan" ],
    "plan, needs_human" => [ "plan", %w[needs_human], "plan" ]
  }.freeze

  def test_only_all_fix_clusters_run_unattended
    skip "node not installed" unless system("node", "--version", out: File::NULL)
    assert_includes workflow, "size: clusterSize(c.size, ids.map((id) => byId.get(id)))"
    definition = workflow[/^const clusterSize = .*$/] or flunk("workflow lost clusterSize")
    cases = CLUSTER_SIZES.transform_values { |size, actions, _| [ size, actions.map { |a| a && { action: a } } ] }
    js = "#{definition}\nconst c = #{JSON.generate(cases)}\n" \
         "console.log(JSON.stringify(Object.fromEntries(Object.entries(c).map(([k, [s, m]]) => [k, clusterSize(s, m)]))))"
    out, status = Open3.capture2("node", "-e", js)
    assert status.success?, "node failed to evaluate clusterSize"
    assert_equal CLUSTER_SIZES.transform_values(&:last), JSON.parse(out)
  end

  # A recurrenceOf claim from Evaluate counts only for a prior thread the same
  # reviewer opened on the same path, at an earlier time and a different
  # reviewed commit: thread_history.rb#returned_to?. Each fixture varies one
  # field of that predicate, and both copies are checked against it.
  OPEN_AT = "2026-01-02T00:00:00Z"
  OPEN = { path: "a.rb", reviewer: "codex", reviewedCommit: "c2", openedAt: OPEN_AT }.freeze
  def self.prior(id, path: "a.rb", reviewer: "codex", commit: "c1", at: "2026-01-01T00:00:00Z")
    { threadId: id, path: path, reviewer: reviewer, reviewedCommit: commit, openedAt: at, fixSha: "1111111" }.compact
  end
  PRIOR = [
    prior("P_own"),
    prior("P_other", reviewer: "human"),
    prior("P_elsewhere", path: "b.rb"),
    prior("P_newer", at: "2026-01-03T00:00:00Z"),
    prior("P_same_time", at: OPEN_AT),
    prior("P_same_commit", commit: "c2"),
    prior("P_no_time", at: nil),
    prior("P_no_commit", commit: nil),
    prior("P_no_path", path: nil),
    prior("P_no_reviewer", reviewer: nil)
  ].freeze

  RECURRENCE_CLAIMS = {
    "own prior on the same path" => [ %w[P_own], %w[P_own] ],
    "another reviewer's prior on the same path" => [ %w[P_other], [] ],
    "own prior on another path" => [ %w[P_elsewhere], [] ],
    "own prior opened after the open thread" => [ %w[P_newer], [] ],
    "own prior opened at the same time" => [ %w[P_same_time], [] ],
    "own prior on the same reviewed commit" => [ %w[P_same_commit], [] ],
    "own prior missing openedAt" => [ %w[P_no_time], [] ],
    "own prior missing reviewedCommit" => [ %w[P_no_commit], [] ],
    "prior missing path" => [ %w[P_no_path], [] ],
    "prior missing reviewer" => [ %w[P_no_reviewer], [] ],
    "unknown id" => [ %w[P_missing], [] ],
    "mixed claims keep only the own one" => [ %w[P_other P_newer P_own P_elsewhere], %w[P_own] ],
    "no claim" => [ nil, [] ]
  }.freeze

  def recurrence_helpers
    %w[returnedTo priorFor ownRecurrence].map do |name|
      workflow[/^const #{name} = .*(?:\n  .*)*$/] or flunk("workflow lost #{name}")
    end
  end

  def test_recurrence_claims_follow_returned_to
    skip "node not installed" unless system("node", "--version", out: File::NULL)
    verdicts = RECURRENCE_CLAIMS.transform_values { |(claim, _)| OPEN.merge(recurrenceOf: claim).compact }
    js = "const priorThreads = #{JSON.generate(PRIOR)}\n#{recurrence_helpers.join("\n")}\n" \
         "const c = #{JSON.generate(verdicts)}\n" \
         "console.log(JSON.stringify(Object.fromEntries(Object.entries(c).map(([k, v]) => [k, ownRecurrence(v)]))))"
    out, status = Open3.capture2("node", "-e", js)
    assert status.success?, "node failed to evaluate the helpers"
    assert_equal RECURRENCE_CLAIMS.transform_values(&:last), JSON.parse(out)
    # Every consumer goes through priorFor; no inline copy of the predicate.
    assert_includes workflow, "const prior = priorFor(t)"
    assert_includes workflow, "priorFor(byId.get(t.threadId))"
    assert_equal 1, workflow.scan("p.reviewer === t.reviewer").size, "recurrence predicate copied outside returnedTo"
  end

  # The JS copy and the Ruby original agree on every fixture, so a field added
  # to one and not the other fails here instead of in review.
  def test_returned_to_matches_thread_history
    skip "node not installed" unless system("node", "--version", out: File::NULL)
    js = "#{recurrence_helpers.first}\nconst open = #{JSON.generate(OPEN)}\n" \
         "console.log(JSON.stringify(#{JSON.generate(PRIOR)}.map((p) => returnedTo(open, p))))"
    out, status = Open3.capture2("node", "-e", js)
    assert status.success?, "node failed to evaluate returnedTo"
    history = ThreadHistory.allocate
    ruby = PRIOR.map do |p|
      history.send(:returned_to?, JSON.parse(JSON.generate(OPEN)), JSON.parse(JSON.generate(p)))
    end
    assert_equal ruby, JSON.parse(out)
  end

  def test_replying_states_the_reply_contracts
    text = File.read(REPLYING)
    assert_includes text, "`Fixed in <sha>.`"
    assert_includes text, "`Deferred to plan <slug>.`"
  end

  # Every way a deferral can name a plan other than the one that lands, keyed
  # by the text that closes it. The slug and the pending pointer are settled
  # in step 6 before any `Deferred to plan` reply is written.
  PLAN_SETTLED = {
    "slug collides with an existing plan" => "plan_paths.rb resolve --slug <plan.slug>",
    "collision takes the free suffix" => "`suggested_slug` as `plan.slug`",
    "seeded goal carries the settled slug" => "`Use slug <old>.` to match",
    "abandoned or unstarted interview keeps a record" => "in every mode, pipe",
    "nested caller reads the settled plan" => "step 6's settled `plan` object",
    "completed plan clears the pending pointer" => "ctx_store.rb archive"
  }.freeze

  def test_plan_slug_is_settled_before_any_deferral_reply
    text = skill_md
    PLAN_SETTLED.each { |failure, guard| assert_includes text, guard, failure }
    settle = text.index("plan_paths.rb resolve --slug")
    assert settle < text.index("Deferred to") && settle < text.index("plan-pending-<plan.slug>"),
           "the slug must be settled before a reply or pointer names it"
    assert_includes File.read(REPLYING), "settled `plan.slug`"
    drive = File.read(File.expand_path("../skills/drive/SKILL.md", __dir__))
    assert_includes drive, "The block's `plan` is already settled"
    refute_includes drive, "do not start it: pipe the seeded"
  end

  def test_skill_defaults_to_full_auto_and_reads_history
    assert_includes skill_md, "--signoff"
    assert_includes skill_md, "thread_history.rb"
    assert_includes skill_md, "nested under cf:drive"
    refute_includes skill_md, "proceed automatically"
  end
  # Every path that could post `Fixed in <sha>` or resolve a fixed thread
  # must hold it until the commit is pushed, or fall back to an unpushed
  # reply that leaves the thread open.
  PUSH_GATED_MUTATIONS = {
    "standalone holds fixes for step 7" => [ :skill, "Standalone, step 7 posts them once\n   its push lands" ],
    "standalone posts only after push" => [ :skill, "once the push lands, post step 6's held `fixed` and cluster" ],
    "standalone withheld push leaves threads open" => [ :skill, "reply on those threads instead that the fix is committed locally but\n   unpushed, and leave them unresolved" ],
    "nested returns held mutations" => [ :skill, "\"truncated\": false, \"pendingReplies\": []}" ],
    "nested posts no commit-citing reply" => [ :skill, "commit-citing ones are only returned in `pendingReplies`" ],
    "gate row exists" => [ :skill, "| RT-6 | Post a `Fixed in <sha>` reply" ],
    "drive posts held replies after push" => [ :drive, "Once the push lands, post every held `pendingReplies` entry" ],
    "drive no-push paths leave threads open" => [ :drive, "reply on those threads that the fix is committed\n   locally but unpushed and leave them unresolved" ]
  }.freeze

  def test_fixed_thread_mutations_wait_for_the_push
    drive = File.read(File.expand_path("../skills/drive/SKILL.md", __dir__))
    docs = { skill: skill_md, drive: drive }
    missing = PUSH_GATED_MUTATIONS.reject { |_, (doc, text)| docs[doc].include?(text) }
    assert_empty missing.keys, "a fixed-thread reply can reach GitHub before its push"
    refute_match(/Replies and resolutions still happen in a nested run\./, skill_md)
  end
end
