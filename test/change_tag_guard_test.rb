# frozen_string_literal: true

require_relative "test_helpers"
require "json"
require "yaml"
require_relative "#{SKILL_SCRIPTS}/change_tag_guard"
require_relative "#{SKILL_SCRIPTS}/change_gate_store"
require_relative "#{SKILL_SCRIPTS}/change_override_store"

# A guard with only repo_root stubbed, so the decision logic (ChangeTagRefs
# resolution, the CHANGE.md policy read, the gate store read, the git-backed
# ancestor/prior-tag checks) all run for real against the fixture repo built
# in setup, exactly as they would in a live hook.
class StubTagGuard < ChangeTagGuard
  # base_policy: :same_as_root (default) reads the trunk's policy for real
  # (origin/<trunk>, fetched from the fixture's bare @origin), exercising the
  # production base-read path. Pass an explicit ChangePolicy, nil, or
  # :unreadable to force the #553 fail-closed/fail-open branches directly.
  def initialize(event, root:, base_policy: :same_as_root)
    super(event)
    @root = root
    @stub_base_policy = base_policy
  end

  private

  def repo_root = @root

  def default_branch(_source)
    "main"
  end

  def base_policy(source, trunk)
    return super if @stub_base_policy == :same_as_root

    @stub_base_policy
  end
end

class ChangeTagGuardTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir
    @prev_home = Dir.home
    ENV["HOME"] = @home
    ENV.delete("CF_ALLOW_UNGATED_MERGE")

    @origin = Dir.mktmpdir
    @repo = Dir.mktmpdir
    GitFixture.git_init(@origin, "--bare", "-b", "main")
    GitFixture.git_init(@repo, "-b", "main")
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "Test")
    git("remote", "add", "origin", @origin)
    write_file("app.txt", "one")
    git("add", "app.txt")
    git("commit", "-q", "-m", "initial")
    git("push", "-q", "origin", "main")
  end

  def teardown
    ENV["HOME"] = @prev_home
    FileUtils.remove_entry(@home)
    FileUtils.remove_entry(@origin)
    FileUtils.remove_entry(@repo)
  end

  def git(*args) = GitFixture.git(@repo, *args)
  def write_file(name, contents) = File.write(File.join(@repo, name), contents)
  def head_sha = git("rev-parse", "HEAD").strip

  # Commits and pushes CHANGE.md to origin/main, the real base the guard now
  # reads (#553), so the existing suite below continues to exercise genuine
  # base-branch policy, not a working-tree copy the guard no longer trusts.
  def write_change_md(policy_yaml)
    front = "change_config:\n  project: app\n  lanes:\n    k6: { enabled: true }\n#{policy_yaml}"
    File.write(File.join(@repo, "CHANGE.md"), "---\n#{front}---\n\nbody\n")
    git("add", "CHANGE.md")
    git("commit", "-q", "-m", "change.md")
    git("push", "-q", "origin", "HEAD:main")
  end

  def record_pass(sha: head_sha, profile: nil)
    ChangeGateStore.new(sha, profile: profile).record(
      scope: "all", status: "pass", project: "app", lanes: {}, report: "r.md"
    )
  end

  def decision(command)
    event = { "tool_name" => "Bash", "tool_input" => { "command" => command } }
    io = StringIO.new
    StubTagGuard.new(event, root: @repo).emit(io)
    return nil if io.string.empty?

    parsed = JSON.parse(io.string).dig("hookSpecificOutput")
    [ parsed["permissionDecision"], parsed["permissionDecisionReason"] ]
  end

  BASIC_POLICY = <<~YAML
    change_policy:
      promotion:
        tag:staging/v*: { require_change_pass: true, profile: staging }
  YAML

  def test_denies_a_protected_tag_push_with_no_recorded_pass
    write_change_md(BASIC_POLICY)
    git("tag", "staging/v1.0.0")

    decision, = decision("git push origin staging/v1.0.0")
    assert_equal "deny", decision
  end

  def test_allows_once_a_passing_record_exists_under_the_right_profile
    write_change_md(BASIC_POLICY)
    git("tag", "staging/v1.0.0")
    record_pass(profile: "staging")

    assert_nil decision("git push origin staging/v1.0.0")&.first
  end

  def test_denies_when_the_recorded_pass_is_under_the_wrong_profile
    write_change_md(BASIC_POLICY)
    git("tag", "staging/v1.0.0")
    record_pass(profile: "production")

    decision, reason = decision("git push origin staging/v1.0.0")
    assert_equal "deny", decision
    assert_match(/'staging' profile/, reason)
  end

  def test_recorded_override_suppresses_the_denial
    write_change_md(BASIC_POLICY)
    git("tag", "staging/v1.0.0")
    ChangeOverrideStore.new(head_sha, profile: "staging").record(reason: "urgent", recorded_by: "cf")

    assert_nil decision("git push origin staging/v1.0.0")&.first
  end

  def test_fails_open_when_repo_root_cannot_be_resolved
    write_change_md(BASIC_POLICY)
    git("tag", "staging/v1.0.0")
    event = { "tool_name" => "Bash", "tool_input" => { "command" => "git push origin staging/v1.0.0" } }
    io = StringIO.new
    StubTagGuard.new(event, root: nil).emit(io)
    assert_empty io.string
  end

  def test_fails_open_when_there_is_no_change_md
    git("tag", "staging/v1.0.0")
    assert_nil decision("git push origin staging/v1.0.0")&.first
  end

  def test_fails_open_when_the_pushed_ref_does_not_resolve_as_a_tag
    write_change_md(BASIC_POLICY)
    assert_nil decision("git push origin main")&.first
  end

  def test_unprotected_tag_pushes_freely
    write_change_md(BASIC_POLICY)
    git("tag", "production/v1.0.0")

    assert_nil decision("git push origin production/v1.0.0")&.first
  end

  def test_gh_release_create_is_gated_the_same_way
    write_change_md(BASIC_POLICY)
    decision, = decision("gh release create staging/v1.0.0")
    assert_equal "deny", decision
  end

  ANCESTOR_POLICY = <<~YAML
    change_policy:
      promotion:
        tag:production/v*: { require_change_pass: true, require_trunk_ancestor: main }
  YAML

  def test_denies_a_tag_on_a_commit_not_descended_from_the_required_branch
    write_change_md(ANCESTOR_POLICY)
    git("checkout", "-q", "-b", "feature")
    write_file("app.txt", "two")
    git("commit", "-q", "-am", "unmerged change")
    record_pass(sha: head_sha)
    git("tag", "production/v1.0.0")

    decision, reason = decision("git push origin production/v1.0.0")
    assert_equal "deny", decision
    assert_match(/not an ancestor of 'main'/, reason)
  end

  def test_allows_a_tag_on_a_commit_that_is_a_trunk_ancestor
    write_change_md(ANCESTOR_POLICY)
    record_pass(sha: head_sha)
    git("tag", "production/v1.0.0")

    assert_nil decision("git push origin production/v1.0.0")&.first
  end

  PRIOR_TAG_POLICY = <<~YAML
    change_policy:
      promotion:
        tag:production/v*: { require_change_pass: true, require_prior_tag: "staging/v*" }
  YAML

  def test_denies_a_production_tag_with_no_matching_prior_staging_tag
    write_change_md(PRIOR_TAG_POLICY)
    record_pass(sha: head_sha)
    git("tag", "production/v1.0.0")

    decision, reason = decision("git push origin production/v1.0.0")
    assert_equal "deny", decision
    assert_match(/no tag matching 'staging\/v\*'/, reason)
  end

  def test_allows_a_production_tag_once_a_matching_prior_tag_is_present
    write_change_md(PRIOR_TAG_POLICY)
    record_pass(sha: head_sha)
    git("tag", "staging/v1.0.0")
    git("tag", "production/v1.0.0")

    assert_nil decision("git push origin production/v1.0.0")&.first
  end

  def test_escape_hatch_suppresses_the_guard
    write_change_md(BASIC_POLICY)
    git("tag", "staging/v1.0.0")
    ENV["CF_ALLOW_UNGATED_MERGE"] = "1"

    assert_nil decision("git push origin staging/v1.0.0")&.first
  end

  def test_a_quoted_mention_of_git_push_tags_inside_a_pr_body_does_not_trip_it
    write_change_md(BASIC_POLICY)
    command = 'gh pr edit 5 --body "remember to run git push --tags later"'
    assert_nil decision(command)&.first
  end

  def test_promotion_scope_never_relaxes_a_tag_rule
    write_change_md("change_policy:\n  gate:\n    require_on: promotion\n" \
                    "  promotion:\n    tag:staging/v*: { require_change_pass: true, profile: staging }\n")
    git("tag", "staging/v1.0.0")

    decision, = decision("git push origin staging/v1.0.0")
    assert_equal "deny", decision
  end

  # --- base-branch policy read (#553) --------------------------------------

  def stubbed_decision(command, base_policy:)
    event = { "tool_name" => "Bash", "tool_input" => { "command" => command } }
    io = StringIO.new
    StubTagGuard.new(event, root: @repo, base_policy: base_policy).emit(io)
    return nil if io.string.empty?

    JSON.parse(io.string).dig("hookSpecificOutput", "permissionDecision")
  end

  def test_tag_push_is_gated_by_the_trunk_policy_even_when_the_pr_loosened_its_own
    # Working tree's own CHANGE.md declares nothing (a PR that removed its
    # tag rule entirely); the base/trunk still requires the gate, unsatisfied.
    File.write(File.join(@repo, "CHANGE.md"), "---\nchange_policy: {}\n---\n\nbody\n")
    git("tag", "staging/v1.0.0")
    base = ChangePolicy.new(
      { "promotion" => { "tag:staging/v*" => { "require_change_pass" => true, "profile" => "staging" } } }, "base"
    )

    assert_equal "deny", stubbed_decision("git push origin staging/v1.0.0", base_policy: base)
  end

  def test_unreadable_trunk_policy_denies_when_a_working_tree_change_md_exists
    write_change_md(BASIC_POLICY)
    git("tag", "staging/v1.0.0")

    assert_equal "deny", stubbed_decision("git push origin staging/v1.0.0", base_policy: :unreadable)
  end

  def test_unreadable_trunk_policy_allows_when_the_repo_is_otherwise_ungoverned
    File.write(File.join(@repo, "CHANGE.md"), "---\nchange_policy: {}\n---\n\nbody\n")
    FileUtils.rm_f(File.join(@repo, "CHANGE.md"))
    git("tag", "staging/v1.0.0")

    assert_nil stubbed_decision("git push origin staging/v1.0.0", base_policy: :unreadable)
  end

  def test_trunk_without_a_change_md_at_all_pushes_tags_freely
    write_change_md(BASIC_POLICY)
    git("tag", "staging/v1.0.0")

    assert_nil stubbed_decision("git push origin staging/v1.0.0", base_policy: nil)
  end

  def test_trunk_and_ancestor_rule_come_from_the_base_not_the_working_tree
    write_change_md(ANCESTOR_POLICY)
    git("tag", "production/v1.0.0")
    record_pass
    # Base requires an ancestor of main; the tagged commit is on main, so it
    # allows. A working-tree CHANGE.md redirecting the trunk and dropping the
    # ancestor rule must not change that, and must not make a non-ancestor pass.
    File.write(File.join(@repo, "CHANGE.md"),
               "---\nchange_policy:\n  gate: { trunk: other }\n  promotion: {}\n---\n\nbody\n")
    assert_nil stubbed_decision("git push origin production/v1.0.0", base_policy: :same_as_root)

    git("checkout", "-q", "-b", "feature")
    write_file("f.txt", "x")
    git("add", "f.txt")
    git("commit", "-q", "-m", "off trunk")
    git("tag", "production/v2.0.0")
    record_pass
    assert_equal "deny", stubbed_decision("git push origin production/v2.0.0", base_policy: :same_as_root)
  end

  def test_default_branch_is_asked_of_the_destination_repository
    guard = ChangeTagGuard.new({})
    assert_equal "main", guard.send(:default_branch, ChangePolicy::Source.for_destination(@repo, "origin"))
  end

  def test_unreadable_trunk_policy_still_allows_a_push_that_publishes_no_tag
    write_change_md(BASIC_POLICY)

    assert_nil stubbed_decision("git push origin feature", base_policy: :unreadable)
  end

  def test_a_failed_fetch_reads_as_unreadable_even_with_a_cached_trunk
    git("fetch", "-q", "origin")
    git("remote", "set-url", "origin", File.join(@repo, "no-such-remote"))
    guard = ChangeTagGuard.new({})
    source = ChangePolicy::Source.for_destination(@repo, "origin")
    assert_equal :unreadable, guard.send(:base_policy, source, "main")
  end
  def test_a_remote_with_a_separate_pushurl_resolves_to_the_push_repository
    push = Dir.mktmpdir
    GitFixture.git_init(push, "--bare", "-b", "main")
    git("remote", "set-url", "--push", "origin", push)
    source = ChangePolicy::Source.for_destination(@repo, "origin")
    assert_equal push, source.remote
  ensure
    FileUtils.remove_entry(push)
  end

  def test_release_without_repo_is_denied_when_gh_default_differs_from_push_remote
    write_change_md(BASIC_POLICY)
    git("remote", "add", "upstream", @origin)
    git("config", "remote.upstream.gh-resolved", "base")

    assert_equal "deny", stubbed_decision("gh release create staging/v1.0.0", base_policy: nil)
  end

  def test_release_without_repo_follows_the_push_remote_when_gh_default_matches
    write_change_md(BASIC_POLICY)
    git("config", "remote.origin.gh-resolved", "base")

    assert_nil stubbed_decision("gh release create staging/v1.0.0", base_policy: nil)
  end
  def test_release_without_repo_is_denied_when_the_push_remote_has_a_separate_pushurl
    write_change_md(BASIC_POLICY)
    push = Dir.mktmpdir
    git("remote", "set-url", "--push", "origin", push)

    assert_equal "deny", stubbed_decision("gh release create staging/v1.0.0", base_policy: nil)
  ensure
    FileUtils.remove_entry(push)
  end

  def test_a_remote_with_several_push_urls_fails_closed
    write_change_md(BASIC_POLICY)
    git("tag", "staging/v1.0.0")
    a = Dir.mktmpdir
    b = Dir.mktmpdir
    git("remote", "set-url", "--add", "--push", "origin", a)
    git("remote", "set-url", "--add", "--push", "origin", b)

    assert_nil ChangePolicy::Source.for_destination(@repo, "origin")
    assert_equal "deny", decision("git push origin staging/v1.0.0")&.first
  ensure
    [ a, b ].compact.each { |d| FileUtils.remove_entry(d) }
  end
  def test_push_repo_option_selects_the_destination
    guard = ChangeTagGuard.new({ "tool_name" => "Bash", "tool_input" => { "command" => "git push --repo=upstream --tags" } })
    assert_equal "upstream", guard.send(:push_destination)
    guard = ChangeTagGuard.new({ "tool_name" => "Bash", "tool_input" => { "command" => "git push --tags --repo upstream" } })
    assert_equal "upstream", guard.send(:push_destination)
  end
end
