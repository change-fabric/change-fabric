# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require "yaml"
require_relative "../scripts/change_merge_guard"
require_relative "../scripts/change_gate_store"
require_relative "../scripts/change_override_store"

# A guard with the two shell-backed lookups stubbed, so the decision logic can be
# exercised without a real repo or gh. The CHANGE.md policy read and the gate
# store read stay real (they read files under the stubbed root and HOME).
class StubMergeGuard < ChangeMergeGuard
  # base_policy: :same_as_root (default) makes the base read behave as if
  # the base branch's CHANGE.md were identical to the working tree's, so the
  # large existing suite below keeps exercising the policy-interpretation
  # logic unchanged. Pass an explicit ChangePolicy, nil, or :unreadable to
  # exercise the #553 base-vs-working-tree read itself.
  def initialize(event, root:, pr:, base_policy: :same_as_root)
    super(event)
    @root = root
    @pr = pr
    @stub_base_policy = base_policy
  end

  private

  def repo_root = @root
  def pr_facts = @pr

  def base_policy(root, _base, _repo = nil)
    @stub_base_policy == :same_as_root ? ChangePolicy.for_repo(root) : @stub_base_policy
  end
end

class ChangeMergeGuardTest < Minitest::Test
  SHA = "deadbeefcafe0000"

  def setup
    @home = Dir.mktmpdir
    @prev = Dir.home
    ENV["HOME"] = @home
    ENV.delete("CF_ALLOW_UNGATED_MERGE")
    @root = Dir.mktmpdir
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
    FileUtils.remove_entry(@root)
  end

  def write_change_md(admin_allowed:, staging_profile: nil)
    profile_line = staging_profile ? ", profile: #{staging_profile}" : ""
    front = <<~YAML
      change_policy:
        promotion:
          staging: { require_change_pass: true#{profile_line} }
          production: { require_change_pass: true }
        admin_bypass:
          allowed: #{admin_allowed}
          require_change_pass: true
    YAML
    File.write(File.join(@root, "CHANGE.md"), "---\n#{front}---\n\nbody\n")
  end

  def record_pass(profile: nil)
    ChangeGateStore.new(SHA, profile: profile).record(
      scope: "all", status: "pass", project: "app", lanes: {}, report: "r.md"
    )
  end

  def decision(command, base:, admin_allowed: false, staging_profile: nil)
    write_change_md(admin_allowed: admin_allowed, staging_profile: staging_profile)
    event = { "tool_name" => "Bash", "tool_input" => { "command" => command } }
    io = StringIO.new
    StubMergeGuard.new(event, root: @root, pr: [ base, SHA ]).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string).dig("hookSpecificOutput", "permissionDecision")
  end

  def test_escape_hatch_suppresses_the_guard
    ENV["CF_ALLOW_UNGATED_MERGE"] = "1"
    assert_nil decision("gh pr merge 12 --squash", base: "production")
  end

  def test_non_merge_command_ignored
    assert_nil decision("gh pr view 12", base: "production")
  end

  def test_ignores_merge_phrase_inside_quoted_pr_body
    command = 'gh pr edit 5 --body "mentions gh pr merge in prose"'
    assert_nil decision(command, base: "production")
  end

  def test_unprotected_base_merges_freely
    assert_nil decision("gh pr merge 12 --squash", base: "development")
  end

  def test_protected_merge_without_gate_is_denied
    assert_equal "deny", decision("gh pr merge 12 --squash", base: "staging")
  end

  def test_protected_merge_with_comprehensive_pass_allowed
    record_pass
    assert_nil decision("gh pr merge 12 --squash", base: "staging")
  end

  def test_admin_bypass_denied_when_repo_forbids_it
    record_pass
    assert_equal "deny", decision("gh pr merge 12 --squash --admin", base: "production", admin_allowed: false)
  end

  def test_admin_bypass_allowed_still_needs_the_gate
    assert_equal "deny", decision("gh pr merge 12 --admin", base: "production", admin_allowed: true)
  end

  def test_admin_bypass_allowed_with_gate_passes
    record_pass
    assert_nil decision("gh pr merge 12 --admin", base: "production", admin_allowed: true)
  end

  def test_profile_scoped_promotion_checks_that_profiles_gate_not_the_default
    record_pass
    assert_equal "deny", decision("gh pr merge 12 --squash", base: "staging", staging_profile: "staging")
  end

  def test_profile_scoped_promotion_passes_once_that_profile_recorded
    record_pass(profile: "staging")
    assert_nil decision("gh pr merge 12 --squash", base: "staging", staging_profile: "staging")
  end

  # --- base-branch policy read (#553) --------------------------------------

  def base_decision(command, base_policy:)
    write_change_md(admin_allowed: false)
    event = { "tool_name" => "Bash", "tool_input" => { "command" => command } }
    io = StringIO.new
    StubMergeGuard.new(event, root: @root, pr: [ "staging", SHA ], base_policy: base_policy).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string).dig("hookSpecificOutput", "permissionDecision")
  end

  def test_pr_weakening_its_own_change_md_is_still_gated_by_the_base_policy
    # Working tree declares no promotion rules at all (a PR that removed its
    # own gate). Base still requires the gate for staging, and no pass is
    # recorded, so this must deny: the base, not the PR's own copy, decides.
    base = ChangePolicy.new({ "promotion" => { "staging" => { "require_change_pass" => true } } }, "base")
    assert_equal "deny", base_decision("gh pr merge 12 --squash", base_policy: base)
  end

  def test_pr_weakening_its_own_change_md_still_allows_once_the_base_gate_is_satisfied
    base = ChangePolicy.new({ "promotion" => { "staging" => { "require_change_pass" => true } } }, "base")
    record_pass
    assert_nil base_decision("gh pr merge 12 --squash", base_policy: base)
  end

  def test_unreadable_base_denies_when_a_working_tree_change_md_exists
    assert_equal "deny", base_decision("gh pr merge 12 --squash", base_policy: :unreadable)
  end

  def test_unreadable_base_allows_when_no_change_md_exists_anywhere
    FileUtils.rm_f(File.join(@root, "CHANGE.md"))
    event = { "tool_name" => "Bash", "tool_input" => { "command" => "gh pr merge 12 --squash" } }
    io = StringIO.new
    StubMergeGuard.new(event, root: @root, pr: [ "staging", SHA ], base_policy: :unreadable).emit(io)
    assert_empty io.string
  end

  def test_base_without_a_change_md_at_all_merges_freely
    write_change_md(admin_allowed: false)
    assert_nil base_decision("gh pr merge 12 --squash", base_policy: nil)
  end

  # The reachable substitute for CF_ALLOW_UNGATED_MERGE=1 (unreachable from
  # inside an agent session, since the guard reads that var from its own
  # process, fixed at harness launch): a human-recorded file the guard checks
  # instead, scoped to this exact (sha, profile).
  def test_recorded_override_suppresses_a_normal_gate_denial
    ChangeOverrideStore.new(SHA).record(reason: "urgent", recorded_by: "cf")
    assert_nil decision("gh pr merge 12 --squash", base: "staging")
  end

  def test_recorded_override_suppresses_an_admin_bypass_denial
    ChangeOverrideStore.new(SHA).record(reason: "urgent", recorded_by: "cf")
    assert_nil decision("gh pr merge 12 --squash --admin", base: "production", admin_allowed: false)
  end

  def test_override_scoped_to_a_different_profile_does_not_suppress
    ChangeOverrideStore.new(SHA, profile: "production").record(reason: "urgent", recorded_by: "cf")
    assert_equal "deny", decision("gh pr merge 12 --squash", base: "staging", staging_profile: "staging")
  end

  def test_override_scoped_to_the_right_profile_suppresses
    ChangeOverrideStore.new(SHA, profile: "staging").record(reason: "urgent", recorded_by: "cf")
    assert_nil decision("gh pr merge 12 --squash", base: "staging", staging_profile: "staging")
  end

  def write_multi_app_change_md(promotion_apps: nil)
    FileUtils.mkdir_p(File.join(@root, "apps/portal"))
    FileUtils.mkdir_p(File.join(@root, "apps/scattergram"))
    File.write(File.join(@root, "apps/portal/CHANGE.app.yml"),
               YAML.dump("change_config" => { "project" => "portal", "lanes" => { "k6" => { "enabled" => true } } }))
    File.write(File.join(@root, "apps/scattergram/CHANGE.app.yml"),
               YAML.dump("change_config" => { "project" => "scattergram", "lanes" => { "k6" => { "enabled" => true } } }))

    apps_clause = promotion_apps ? ", apps: [#{promotion_apps.join(', ')}]" : ""
    front = <<~YAML
      change_config:
        project: my-repo
        apps:
          portal: { config: apps/portal/CHANGE.app.yml }
          scattergram: { config: apps/scattergram/CHANGE.app.yml }
      change_policy:
        promotion:
          production: { require_change_pass: true#{apps_clause} }
    YAML
    File.write(File.join(@root, "CHANGE.md"), "---\n#{front}---\n\nbody\n")
  end

  def multi_app_decision(command, base: "production")
    event = { "tool_name" => "Bash", "tool_input" => { "command" => command } }
    io = StringIO.new
    StubMergeGuard.new(event, root: @root, pr: [ base, SHA ]).emit(io)
    return nil if io.string.empty?

    parsed = JSON.parse(io.string).dig("hookSpecificOutput")
    [ parsed["permissionDecision"], parsed["permissionDecisionReason"] ]
  end

  def record_app_pass(app)
    ChangeGateStore.new(SHA).record(scope: "all", status: "pass", project: "my-repo", lanes: {}, report: "r.md", app: app)
  end

  def test_denies_when_one_of_two_required_apps_has_no_pass
    write_multi_app_change_md
    record_app_pass("portal")
    decision, = multi_app_decision("gh pr merge 12 --squash")
    assert_equal "deny", decision
  end

  def test_allows_when_every_required_app_passed
    write_multi_app_change_md
    record_app_pass("portal")
    record_app_pass("scattergram")
    assert_nil multi_app_decision("gh pr merge 12 --squash")
  end

  def test_allows_when_the_policy_apps_list_excludes_the_unpassed_app
    write_multi_app_change_md(promotion_apps: [ "portal" ])
    record_app_pass("portal")
    assert_nil multi_app_decision("gh pr merge 12 --squash")
  end

  def test_deny_reason_names_the_missing_app_and_the_rerun_command
    write_multi_app_change_md
    record_app_pass("portal")
    _decision, reason = multi_app_decision("gh pr merge 12 --squash")
    assert_match(/app\(s\): scattergram/, reason)
    assert_match(/--app scattergram/, reason)
  end

  def test_fails_open_when_the_registry_cannot_be_read
    front = <<~YAML
      change_config:
        project: my-repo
        apps:
          portal: { config: apps/portal/CHANGE.app.yml }
      change_policy:
        promotion:
          production: { require_change_pass: true }
    YAML
    File.write(File.join(@root, "CHANGE.md"), "---\n#{front}---\n\nbody\n")

    record_pass
    assert_nil multi_app_decision("gh pr merge 12 --squash")
  end

  # --- trunk + tag releases (0.9.0) regression -----------------

  def test_a_change_md_carrying_only_tag_rules_does_not_change_any_merge_decision
    # "main" is deliberately not in DEFAULT_PROTECTED, so this exercises the
    # tag-only-rules path without also exercising the (correct, separately
    # tested) DEFAULT_PROTECTED fallback for staging/production.
    front = <<~YAML
      change_policy:
        promotion:
          tag:staging/v*: { require_change_pass: true, profile: staging }
          tag:production/v*: { require_change_pass: true }
        admin_bypass:
          allowed: false
          require_change_pass: true
    YAML
    File.write(File.join(@root, "CHANGE.md"), "---\n#{front}---\n\nbody\n")

    event = { "tool_name" => "Bash", "tool_input" => { "command" => "gh pr merge 12 --squash" } }
    io = StringIO.new
    StubMergeGuard.new(event, root: @root, pr: [ "main", SHA ]).emit(io)
    assert_empty io.string
  end

  def scoped_decision(command, base:, require_on: nil)
    gate = require_on ? "  gate: { require_on: #{require_on} }\n" : ""
    front = "change_policy:\n#{gate}  protected_branches: [main, staging, production]\n" \
            "  admin_bypass: { allowed: true, require_change_pass: true }\n"
    File.write(File.join(@root, "CHANGE.md"), "---\n#{front}---\n\nbody\n")
    event = { "tool_name" => "Bash", "tool_input" => { "command" => command } }
    io = StringIO.new
    StubMergeGuard.new(event, root: @root, pr: [ base, SHA ]).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string).dig("hookSpecificOutput")
  end

  def test_absent_gate_scope_gates_a_trunk_merge_as_before
    assert_equal "deny", scoped_decision("gh pr merge 12 --admin", base: "main")&.dig("permissionDecision")
  end

  def test_promotion_scope_lets_an_admin_bypass_into_trunk_through
    assert_nil scoped_decision("gh pr merge 12 --admin", base: "main", require_on: "promotion")
    assert_nil scoped_decision("gh pr merge 12 --squash", base: "main", require_on: "promotion")
  end

  def test_promotion_scope_still_gates_a_branch_promotion
    out = scoped_decision("gh pr merge 12 --squash", base: "production", require_on: "promotion")
    assert_equal "deny", out["permissionDecision"]
    assert_match(/gate\.require_on: promotion/, out["permissionDecisionReason"])
  end
  # --- owning repo of the PR, not origin (fork checkouts) ---------------------

  def test_base_policy_reads_the_owning_repo_not_a_fork_origin
    Dir.mktmpdir do |dir|
      upstream = make_policy_repo(File.join(dir, "up", "proj"), "staging: { require_change_pass: true }")
      fork = make_policy_repo(File.join(dir, "fork", "proj"), "staging: { require_change_pass: false }")
      clone = File.join(dir, "clone")
      git_ok(dir, "clone", "-q", fork, clone)
      git_ok(clone, "remote", "add", "upstream", "git@github.com:up/proj.git")
      git_ok(clone, "config", "url.#{upstream}.insteadOf", "git@github.com:up/proj.git")

      guard = ChangeMergeGuard.new({})
      policy = guard.send(:base_policy, clone, "staging", "https://github.com/up/proj/pull/1")
      assert policy.require_change_pass?("staging")
      refute guard.send(:base_policy, clone, "staging", nil).require_change_pass?("staging")
    end
  end

  def git_ok(repo, *args)
    out, status = Open3.capture2e("git", "-C", repo, *args)
    raise out unless status.success?
  end

  def make_policy_repo(path, rule)
    FileUtils.mkdir_p(path)
    git_ok(path, "init", "-q", "-b", "staging")
    File.write(File.join(path, "CHANGE.md"), "---\nchange_policy:\n  promotion:\n    #{rule}\n---\n")
    git_ok(path, "add", "CHANGE.md")
    git_ok(path, "-c", "user.email=t@t.test", "-c", "user.name=t", "commit", "-q", "-m", "p")
    path
  end
end

require_relative "support/phone_console"

# Carve-out classification and the exact-head merge (P4): the real console in
# process mints the passkey receipts; gh is a fake runner.
class ChangeMergeGuardCarveOutTest < Minitest::Test
  include PhoneConsole

  PR_URL = "https://github.com/acme/widgets/pull/612"
  REPO = "repo:github.com/acme/widgets"
  HEAD = "b" * 40
  CARVE = [ "scripts/change_merge_guard.rb" ].freeze

  # The guard with gh's file list and the proof store supplied.
  class Guard < StubMergeGuard
    def initialize(event, files:, proof_store:, **opts)
      super(event, **opts)
      @files = files
      @proof_store = proof_store
    end

    private

    def changed_files(url) = @files.respond_to?(:call) ? @files.call(url) : @files
    def proof_store = @proof_store
  end

  def setup
    @home = File.realpath(Dir.mktmpdir)
    @prev = ENV["HOME"]
    ENV["HOME"] = @home
    ENV.delete("CF_ALLOW_UNGATED_MERGE")
    @root = Dir.mktmpdir
    start_phone_console
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
    FileUtils.remove_entry(@root)
  end

  def policy(paths: [ "scripts/*guard*.rb", "CHANGE.md" ])
    ChangePolicy.new({ "approval_pins" => authoritative_pins, "admin_bypass" => { "carve_out_paths" => paths },
                       "promotion" => { "main" => { "require_change_pass" => false } } }, nil)
  end

  def attrs(files: CARVE, base: "main", sha: HEAD)
    { "type" => "carve-out", "repo" => REPO, "sha" => sha, "profile" => nil, "summary" => "merge #612", "pr_url" => PR_URL,
      "pr_title" => "Guard change", "base" => base, "files" => files }
  end

  def approve(files: CARVE, base: "main", sha: HEAD)
    proof = phone_proof(attrs(files: files, base: base, sha: sha))
    ChangeCarveOutStore.new.record(repo: REPO, pr: "612", sha: sha, proof: proof, policy_sha: POLICY_SHA, recorded_by: "t")
  end

  def verdict(command = "gh pr merge 612 --squash --match-head-commit #{HEAD}", files: CARVE, head: HEAD, base: "main")
    event = { "tool_name" => "Bash", "tool_input" => { "command" => command } }
    io = StringIO.new
    Guard.new(event, root: @root, pr: [ base, head, PR_URL ], base_policy: policy, files: files, proof_store: @store).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string).dig("hookSpecificOutput", "permissionDecisionReason")
  end

  def test_a_carve_out_without_a_record_is_denied
    assert_match(/no phone-approved carve-out is recorded for head #{HEAD[0, 12]}/, verdict)
  end

  def test_a_carve_out_at_the_approved_head_with_match_head_commit_is_allowed
    approve
    assert_nil verdict
    assert_nil verdict("gh pr merge 612 --squash --match-head-commit=#{HEAD}")
  end

  def test_a_new_head_needs_a_new_approval
    approve
    new_head = "d" * 40
    assert_match(/no phone-approved carve-out is recorded for head #{new_head[0, 12]}/,
                 verdict("gh pr merge 612 --squash --match-head-commit #{new_head}", head: new_head))
  end

  def test_a_stale_receipt_is_denied_at_use
    @now -= 90_000
    approve
    assert_match(/24h old or older/, verdict)
  end

  def test_signed_files_must_equal_the_recomputed_list
    approve
    assert_match(/files does not match/, verdict(files: CARVE + [ "README.md" ]))
  end

  def test_signed_base_must_equal_the_prs_base
    approve(base: "release")
    assert_match(/base does not match/, verdict)
  end

  def test_a_merge_without_match_head_commit_is_denied_even_with_a_record
    approve
    assert_match(/must carry --match-head-commit #{HEAD}/, verdict("gh pr merge 612 --squash"))
    assert_match(/must carry --match-head-commit/, verdict("gh pr merge 612 --squash --match-head-commit #{'d' * 40}"))
  end

  def test_a_deferred_auto_merge_is_denied_even_with_a_record
    approve
    assert_match(/not with --auto/, verdict("gh pr merge 612 --squash --auto --match-head-commit #{HEAD}"))
  end

  def test_a_gh_failure_while_classifying_is_denied
    failing = ->(_url) { raise ChangePrFacts::Unreadable, "gh api failed" }
    assert_match(/could not be classified \(gh api failed\)/, verdict(files: failing))
  end

  def fake_gh(count:, entries:)
    lambda do |*args|
      args.include?("--jq") ? "#{count}\n" : JSON.generate([ entries ])
    end
  end

  def test_three_thousand_files_and_a_truncated_page_are_denied
    entry = { "filename" => "docs/a.md" }
    big = ->(url) { ChangePrFacts.files(url, runner: fake_gh(count: 3000, entries: [ entry ])) }
    cut = ->(url) { ChangePrFacts.files(url, runner: fake_gh(count: 2, entries: [ entry ])) }
    assert_match(/at most 3000/, verdict(files: big))
    assert_match(/truncated/, verdict(files: cut))
  end

  def test_a_rename_into_a_carve_out_path_is_caught_by_its_previous_name
    entries = [ { "filename" => "docs/old.md", "previous_filename" => "CHANGE.md" } ]
    renamed = ->(url) { ChangePrFacts.files(url, runner: fake_gh(count: 1, entries: entries)) }
    assert_match(/carve-out \(CHANGE.md\)/, verdict(files: renamed))
  end

  def test_a_pr_outside_the_carve_out_paths_is_unchanged
    assert_nil verdict("gh pr merge 612 --squash", files: [ "docs/a.md" ])
  end

  def test_a_repo_without_a_carve_out_list_is_unaffected
    event = { "tool_name" => "Bash", "tool_input" => { "command" => "gh pr merge 612 --squash" } }
    io = StringIO.new
    Guard.new(event, root: @root, pr: [ "main", HEAD, PR_URL ], base_policy: policy(paths: []), files: CARVE, proof_store: @store).emit(io)
    assert_empty io.string
  end

  def test_the_escape_hatch_still_suppresses_the_guard
    ENV["CF_ALLOW_UNGATED_MERGE"] = "1"
    assert_nil verdict("gh pr merge 612 --squash")
  end

  def test_a_bare_merge_with_match_head_commit_resolves_the_current_branch_pr
    event = { "tool_name" => "Bash", "tool_input" => { "command" => "gh pr merge --squash --match-head-commit #{HEAD}" } }
    guard = ChangeMergeGuard.new(event)
    seen = []
    stub = lambda do |*args|
      seen << args
      [ "main\t#{HEAD}\t#{PR_URL}\n", "", Struct.new(:success?).new(true) ]
    end
    original = Open3.method(:capture3)
    Open3.define_singleton_method(:capture3, &stub)
    begin
      assert_equal [ "main", HEAD, PR_URL ], guard.send(:pr_facts)
    ensure
      Open3.define_singleton_method(:capture3, original)
    end
    refute_includes seen.first, HEAD
    assert_equal %w[gh pr view --json], seen.first.first(4)
  end

  def test_merge_ref_skips_flag_values_and_still_finds_the_selector
    guard = ChangeMergeGuard.new({})
    assert_nil guard.send(:merge_ref, "gh pr merge --squash --match-head-commit #{HEAD}")
    assert_equal "612", guard.send(:merge_ref, "gh pr merge --match-head-commit #{HEAD} 612 --squash")
    assert_equal "612", guard.send(:merge_ref, "gh pr merge 612 --body note --match-head-commit #{HEAD}")
  end

  def test_the_denial_hint_carries_the_summary_the_request_needs
    assert_match(/--type carve-out --pr-url #{Regexp.escape(PR_URL)} --summary /, verdict)
  end
end
