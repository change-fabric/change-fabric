# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "git_fixture"
require_relative "../scripts/change_git_context"

# Covers the shared git lookup a run is identified by: git first, then the
# GitHub Actions variables a detached CI checkout leaves, and a `gh` that is
# absent or answers from the repo directory rather than the process cwd.
class ChangeGitContextTest < Minitest::Test
  MISSING_GH = "/nonexistent/cf-test-gh"

  def setup
    @root = Dir.mktmpdir
    @repo = File.join(@root, "repo")
    GitFixture.git_init(@repo, "-b", "feature/example")
    GitFixture.git(@repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                   "commit", "-q", "--allow-empty", "-m", "Add fixture commit")
    @sha = GitFixture.git(@repo, "rev-parse", "HEAD").strip
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def read(gh: MISSING_GH, **env) = ChangeGitContext.read(@repo, env:, gh:)

  def detach! = GitFixture.git(@repo, "checkout", "-q", "--detach")

  def test_reads_branch_sha_and_subject_from_git
    context = read

    assert_equal "feature/example", context["branch"]
    assert_equal @sha, context["sha"]
    assert_equal @sha[0, 7], context["short_sha"]
    assert_equal "Add fixture commit", context["subject"]
  end

  def test_no_gh_yields_a_nil_pr
    assert_nil read["pr"]
  end

  def test_a_named_branch_ignores_the_ci_variables
    assert_equal "feature/example", read("GITHUB_HEAD_REF" => "other", "GITHUB_REF_NAME" => "x")["branch"]
  end

  def test_detached_head_falls_back_to_github_head_ref_first
    detach!

    branch = read("GITHUB_HEAD_REF" => "feature/from-pr", "GITHUB_REF_NAME" => "7/merge")["branch"]
    assert_equal "feature/from-pr", branch
  end

  def test_detached_head_falls_back_to_github_ref_name
    detach!

    assert_equal "main", read("GITHUB_HEAD_REF" => "", "GITHUB_REF_NAME" => "main")["branch"]
  end

  def test_detached_head_without_ci_variables_reports_head
    detach!

    assert_equal "HEAD", read["branch"]
  end

  def test_github_sha_is_used_only_when_git_has_none
    assert_equal @sha, read("GITHUB_SHA" => "f" * 40)["sha"]

    outside = ChangeGitContext.read(File.join(@root, "not-a-repo"), env: { "GITHUB_SHA" => "a" * 40 }, gh: MISSING_GH)
    assert_equal "a" * 40, outside["sha"]
    assert_equal "a" * 7, outside["short_sha"]
  end

  def test_pr_number_from_a_pull_merge_ref
    detach!

    assert_equal({ "number" => 7, "url" => nil }, read("GITHUB_REF" => "refs/pull/7/merge")["pr"])
    assert_nil read("GITHUB_REF" => "refs/heads/main")["pr"]
  end

  # The fake gh records the directory it ran in, which is how this proves the
  # lookup asks about the repo rather than whatever the process cwd is.
  def test_gh_runs_in_the_repo_and_its_answer_wins
    gh = fake_gh('{"number":42,"url":"https://example.invalid/pr/42","title":"Fixture PR"}')

    context = ChangeGitContext.new(@repo, env: { "GITHUB_REF" => "refs/pull/7/merge" }, gh:)

    assert_equal({ "number" => 42, "url" => "https://example.invalid/pr/42" }, context.to_h["pr"])
    assert_equal "Fixture PR", context.pull_request["title"]
    assert_equal File.realpath(@repo), File.realpath(File.read(File.join(@root, "gh-cwd")).strip)
  end

  def test_a_failing_gh_yields_a_nil_pr
    assert_nil read(gh: fake_gh("not authenticated", exit_code: 1))["pr"]
  end

  def test_outside_a_repo_every_field_is_nil
    context = ChangeGitContext.read(File.join(@root, "not-a-repo"), env: {}, gh: MISSING_GH)

    assert_equal({ "branch" => nil, "sha" => nil, "short_sha" => nil, "subject" => nil, "pr" => nil }, context)
  end

  def test_trunk_default_reads_origin_head_else_main
    assert_equal "main", ChangeGitContext.trunk_default(@repo)

    GitFixture.git(@repo, "update-ref", "refs/remotes/origin/develop", @sha)
    GitFixture.git(@repo, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/develop")
    assert_equal "develop", ChangeGitContext.trunk_default(@repo)
  end

  def test_head_commit_time_is_the_commit_time
    expected = GitFixture.git(@repo, "log", "-1", "--format=%ct").strip.to_i

    assert_equal Time.at(expected).utc, ChangeGitContext.head_commit_time(@repo)
    assert_nil ChangeGitContext.head_commit_time(File.join(@root, "not-a-repo"))
  end

  def test_origin_url_strips_userinfo
    GitFixture.git(@repo, "remote", "add", "origin", "https://user:secret@example.invalid/org/app.git")

    assert_equal "https://example.invalid/org/app.git", ChangeGitContext.origin_url(@repo)
    assert_equal "git@example.invalid:org/app.git", ChangeGitContext.sanitize_url("git@example.invalid:org/app.git")
    assert_nil ChangeGitContext.sanitize_url(nil)
  end

  private

  def fake_gh(output, exit_code: 0)
    path = File.join(@root, "gh")
    File.write(path, <<~SH)
      #!/bin/sh
      pwd > "#{File.join(@root, 'gh-cwd')}"
      printf '%s' '#{output}'
      exit #{exit_code}
    SH
    File.chmod(0o755, path)
    path
  end
end
