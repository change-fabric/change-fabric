# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../scripts/overnight_plan"

# The capability manifest (precedence, provenance, denials), the policy hash
# and invalidation, unit adoption, the schedule per merge mode, and the
# byte-stable dry-run snapshot over test/fixtures/overnight/repo. Discovery
# is a fake that fails on anything outside the read-only allowlist.
class OvernightPlanTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  REPO = "test/fixtures/overnight/repo"
  PLAN = "test/fixtures/overnight/plan"
  SNAPSHOT = File.join(ROOT, "test/fixtures/overnight/dry_run.txt")
  SCRIPT = File.join(ROOT, "scripts/overnight_plan.rb")

  # Answers the allowlisted read-only commands from canned output and fails
  # the test on any other command: a mutation, an enrollment or a paid call.
  class FakeDiscovery < OvernightPlan::ReadOnlyDiscovery
    attr_reader :calls

    def initialize(prs: [], worktrees: [])
      super(".", runner: ->(argv) { raise "fake discovery reached a runner: #{argv.join(' ')}" })
      @prs = prs
      @trees = worktrees
      @calls = []
    end

    def open_prs = (@calls << :open_prs) && @prs
    def worktrees = (@calls << :worktrees) && @trees
  end

  def setup
    @tmp = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def manifest = Dir.chdir(ROOT) { OvernightPlan.manifest(REPO) }

  def repo_with(files)
    files.each do |name, text|
      path = File.join(@tmp, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
    end
    @tmp
  end

  def dry_run(**opts)
    Dir.chdir(ROOT) { OvernightPlan.dry_run(repo: REPO, plan_dir: PLAN, discovery: FakeDiscovery.new, **opts) }
  end

  def test_change_md_outranks_docs_with_provenance
    trunk = manifest["fields"]["trunk_model"]
    assert_equal "main", trunk["value"]
    assert_equal "CHANGE.md:15", trunk["source"]
    assert_equal 1, trunk["rank"]
  end

  def test_agents_outranks_claude_for_a_plain_field
    repo = repo_with("AGENTS.md" => "overnight.staging_workflow: a.yml\n",
                     "CLAUDE.md" => "overnight.staging_workflow: b.yml\n")
    field = OvernightPlan.manifest(repo)["fields"]["staging_workflow"]
    assert_equal "a.yml", field["value"]
    assert_equal "AGENTS.md:1", field["source"]
  end

  def test_production_lanes_come_from_the_tag_rule_profile
    field = manifest["fields"]["production_lanes"]
    assert_equal %w[browserless testcases], field["value"], "a disabled lane is left out"
  end

  def test_conflicting_safety_field_is_a_denial_not_a_guess
    m = manifest
    assert_nil m["fields"]["migration_command"]["value"]
    denial = m["denials"].find { |d| d["field"] == "migration_command" }
    assert_match(/conflict: AGENTS.md:8=bin\/migrate vs CLAUDE.md:3=/, denial["reason"])
    assert m["capabilities"]["migrations"]
  end

  def test_missing_safety_field_is_a_denial
    m = manifest
    assert_includes m["denials"], { "field" => "maintenance_command", "reason" => "missing" }
    assert_includes m["capabilities"]["destructive"], "maintenance_command missing"
    assert_equal "default", m["fields"]["maintenance_command"]["source"]
  end

  def test_invalid_safety_field_is_a_denial
    repo = repo_with("AGENTS.md" => "overnight.agent_tags_allowed: sometimes\n")
    denial = OvernightPlan.manifest(repo)["denials"].find { |d| d["field"] == "agent_tags_allowed" }
    assert_match(/invalid/, denial["reason"])
  end

  def test_no_credential_isolation_denies_destructive
    assert_includes manifest["capabilities"]["destructive"], "no credential isolation inside the executor"
  end

  def test_risky_production_lanes_or_forbidden_tags_force_staging_only
    repo = repo_with("AGENTS.md" => "overnight.agent_tags_allowed: no\novernight.production_lanes: browserless, zap\n")
    m = OvernightPlan.manifest(repo)
    reasons = m["capabilities"]["production-tag"]
    assert_includes reasons, "repo forbids agent tags"
    assert_includes reasons, "production profile runs zap"
    steps = OvernightPlan.schedule({ "id" => "p1", "origin" => "new" }, m, "admin-bypass", false)
    assert_equal "production-tag", steps.last[0]
    assert_match(/staging-only/, steps.last[3])
  end

  def test_policy_hash_change_invalidates_only_undispatched_dependents
    m = manifest
    old = OvernightPlan.policy(m, {})
    changed = Marshal.load(Marshal.dump(old))
    changed["fields"]["version_endpoint"] = "https://other.example.test/version"
    refute_equal OvernightPlan.policy_hash(old), OvernightPlan.policy_hash(changed)
    fields = OvernightPlan.changed_fields(old, changed)
    assert_equal [ "version_endpoint" ], fields
    steps = [
      { "unit" => "p1", "step" => "staging-version", "dispatched" => true },
      { "unit" => "p2", "step" => "staging-version", "dispatched" => false },
      { "unit" => "p2", "step" => "build", "dispatched" => false }
    ]
    assert_equal [ steps[1] ], OvernightPlan.invalidated(steps, fields)
  end

  def test_units_follow_phase_order_or_declared_depends_on
    units = Dir.chdir(ROOT) { OvernightPlan.plan_units(PLAN) }
    assert_equal({ "p1" => [], "p2" => [ "p1" ], "p3" => [ "p1" ] }, units.to_h { |u| [ u["id"], u["depends_on"] ] })
  end

  def test_adopts_in_flight_pr_and_worktree_never_rebuilds
    prs = [ { "number" => 41, "title" => "Show exports in the dashboard", "headRefName" => "exports-ui", "body" => "" },
            { "number" => 42, "title" => "Unrelated", "headRefName" => "misc", "body" => "" },
            { "number" => 43, "title" => "Docs", "headRefName" => "exports-docs", "body" => "plan: a/b#Phase 3" } ]
    trees = [ { "path" => "/w/exports-ui", "branch" => "exports-ui" } ]
    out = Dir.chdir(ROOT) do
      OvernightPlan.dry_run(repo: REPO, plan_dir: PLAN, mode: "admin-bypass",
                            discovery: FakeDiscovery.new(prs: prs, worktrees: trees))
    end
    assert_includes out, "p2 Show exports in the dashboard (adopted PR #41 exports-ui worktree /w/exports-ui)"
    assert_includes out, "p3 Document exports (adopted PR #43 exports-docs)"
    assert_includes out, "in-flight, not adopted: PR #42 misc"
    assert_includes out, "1. build: adopt exports-ui (never rebuilt)"
  end

  def test_local_only_schedules_build_and_tests_only
    steps = OvernightPlan.schedule({ "id" => "p1", "origin" => "new" }, manifest, "local-only", false)
    assert_equal %w[build local-ci], steps.map(&:first)
  end

  def test_merge_ready_hands_the_merge_to_stack_watch
    steps = OvernightPlan.schedule({ "id" => "p1", "origin" => "new" }, manifest, "merge-ready", false)
    assert_match(/stack_watch\.rb/, steps.find { |s| s[0] == "merge" }[1])
  end

  def test_yolo_refused_when_trunk_is_protected
    steps = OvernightPlan.schedule({ "id" => "p1", "origin" => "new" }, manifest, "yolo", true)
    assert_equal "refused", steps.last[0]
  end

  def test_dry_run_matches_snapshot_and_is_byte_stable
    first = dry_run(mode: "admin-bypass")
    assert_equal first, dry_run(mode: "admin-bypass")
    assert_equal File.read(SNAPSHOT), first
  end

  def test_dry_run_masks_secrets
    out = dry_run(mode: "admin-bypass")
    refute_includes out, "fixture-not-a-secret"
    assert_includes out, "FLAGS_TOKEN=****"
    assert_equal "x ****", OvernightPlan.mask("x ghp_abcDEF123")
  end

  def test_dry_run_never_builds_an_executor_and_states_execution_disabled
    out = dry_run
    refute Object.const_defined?(:OvernightExecutor)
    assert_includes out, "execution: disabled (OVERNIGHT_EXECUTE_ENABLED is false)"
  end

  def test_over_budget_reservation_is_refused
    assert_includes dry_run(budget: 1.0), "reserve 3.00 USD (refused: over budget)"
  end

  def test_discovery_allowlist_refuses_mutations
    calls = []
    discovery = OvernightPlan::ReadOnlyDiscovery.new(@tmp, runner: ->(argv) { calls << argv; [ "", nil ] })
    [ %w[git push origin main], %w[gh pr merge 1], %w[gh pr create], %w[ruby cf_keys.rb enroll],
      %w[git tag v1], %w[gh api -X POST repos] ].each do |argv|
      assert_raises(OvernightPlan::ReadOnlyDiscovery::Refused) { discovery.run(argv) }
    end
    assert_empty calls
    discovery.run(%w[git ls-remote origin])
    assert_equal [ %w[git ls-remote origin] ], calls
  end

  def test_discovery_skips_a_directory_that_is_not_a_repo_root
    discovery = OvernightPlan::ReadOnlyDiscovery.new(@tmp, runner: ->(argv) { flunk "ran #{argv.join(' ')}" })
    assert_empty discovery.open_prs
    assert_empty discovery.worktrees
  end

  def test_cli_refuses_execution_and_runs_the_verify_command
    _out, err, status = Open3.capture3("ruby", SCRIPT, "--repo", REPO, chdir: ROOT)
    assert_equal 3, status.exitstatus
    assert_match(/OVERNIGHT_EXECUTE_ENABLED is false/, err)
    out, _err, status = Open3.capture3("ruby", SCRIPT, "--dry-run", "--repo", REPO, chdir: ROOT)
    assert status.success?
    assert_includes out, "mode: local-only"
  end

  def test_cli_snapshot_command_matches
    out, _err, status = Open3.capture3("ruby", SCRIPT, "--dry-run", "--repo", REPO, "--plan", PLAN,
                                       "--mode", "admin-bypass", chdir: ROOT)
    assert status.success?
    assert_equal File.read(SNAPSHOT), out
  end
end
