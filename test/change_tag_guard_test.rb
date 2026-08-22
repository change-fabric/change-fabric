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
  def initialize(event, root:)
    super(event)
    @root = root
  end

  private

  def repo_root = @root
end

class ChangeTagGuardTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir
    @prev_home = Dir.home
    ENV["HOME"] = @home
    ENV.delete("CF_ALLOW_UNGATED_MERGE")

    @origin = Dir.mktmpdir
    @repo = Dir.mktmpdir
    GitFixture.git_init(@origin, "--bare")
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

  def write_change_md(policy_yaml)
    File.write(File.join(@repo, "CHANGE.md"), "---\n#{policy_yaml}---\n\nbody\n")
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
end
