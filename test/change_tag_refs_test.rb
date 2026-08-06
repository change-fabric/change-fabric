# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/change_tag_refs"

class ChangeTagRefsTest < Minitest::Test
  def setup
    @origin = Dir.mktmpdir
    @repo = Dir.mktmpdir
    GitFixture.git_init(@origin, "--bare")
    GitFixture.git_init(@repo, "-b", "main")
    git(@repo, "config", "user.email", "test@example.com")
    git(@repo, "config", "user.name", "Test")
    git(@repo, "remote", "add", "origin", @origin)
    write_file("app.txt", "one")
    git(@repo, "add", "app.txt")
    git(@repo, "commit", "-q", "-m", "initial")
    git(@repo, "push", "-q", "origin", "main")
  end

  def teardown
    FileUtils.remove_entry(@origin)
    FileUtils.remove_entry(@repo)
  end

  def git(dir, *args) = GitFixture.git(dir, *args)
  def write_file(name, contents) = File.write(File.join(@repo, name), contents)
  def head_sha = git(@repo, "rev-parse", "HEAD").strip

  def test_explicit_refspec_resolves_to_the_pointed_at_commit
    git(@repo, "tag", "-a", "staging/v1.4.0", "-m", "release")
    pairs = ChangeTagRefs.from_push("git push origin staging/v1.4.0", @repo)
    assert_equal [ [ "staging/v1.4.0", head_sha ] ], pairs
  end

  def test_refs_tags_form_strips_the_prefix
    git(@repo, "tag", "v2.0.0")
    pairs = ChangeTagRefs.from_push("git push origin refs/tags/v2.0.0", @repo)
    assert_equal [ [ "v2.0.0", head_sha ] ], pairs
  end

  def test_tag_keyword_form_is_resolved
    git(@repo, "tag", "v3.0.0")
    pairs = ChangeTagRefs.from_push("git push origin tag v3.0.0", @repo)
    assert_equal [ [ "v3.0.0", head_sha ] ], pairs
  end

  def test_src_dst_refspec_takes_the_destination_name_and_the_source_commit
    git(@repo, "checkout", "-q", "-b", "release-branch")
    write_file("app.txt", "two")
    git(@repo, "commit", "-q", "-am", "release commit")
    release_sha = git(@repo, "rev-parse", "HEAD").strip

    pairs = ChangeTagRefs.from_push("git push origin release-branch:refs/tags/production/v1.0.0", @repo)
    assert_equal [ [ "production/v1.0.0", release_sha ] ], pairs
  end

  def test_annotated_tag_resolves_to_the_commit_not_the_tag_object
    git(@repo, "tag", "-a", "v1.0.0", "-m", "annotated")
    pairs = ChangeTagRefs.from_push("git push origin v1.0.0", @repo)
    assert_equal [ [ "v1.0.0", head_sha ] ], pairs
  end

  def test_a_positional_that_is_not_a_real_tag_resolves_to_nothing
    pairs = ChangeTagRefs.from_push("git push origin main", @repo)
    assert_empty pairs
  end

  def test_tags_flag_publishes_every_local_tag_not_already_on_the_remote
    git(@repo, "tag", "v1.0.0")
    git(@repo, "tag", "v2.0.0")
    git(@repo, "push", "-q", "origin", "v1.0.0")

    pairs = ChangeTagRefs.from_push("git push origin --tags", @repo)
    assert_equal [ [ "v2.0.0", head_sha ] ], pairs
  end

  def test_follow_tags_flag_publishes_reachable_annotated_tags_not_on_the_remote
    git(@repo, "tag", "-a", "v1.0.0", "-m", "one")
    git(@repo, "tag", "unreachable-lightweight")

    pairs = ChangeTagRefs.from_push("git push origin --follow-tags", @repo)
    assert_equal [ [ "v1.0.0", head_sha ] ], pairs
  end

  def test_gh_release_create_resolves_an_existing_tag
    git(@repo, "tag", "v9.0.0")
    pairs = ChangeTagRefs.from_gh_release("gh release create v9.0.0", @repo)
    assert_equal [ [ "v9.0.0", head_sha ] ], pairs
  end

  def test_gh_release_create_falls_back_to_head_when_the_tag_does_not_exist_yet
    pairs = ChangeTagRefs.from_gh_release("gh release create v10.0.0", @repo)
    assert_equal [ [ "v10.0.0", head_sha ] ], pairs
  end

  def test_gh_release_create_honors_an_explicit_target
    git(@repo, "checkout", "-q", "-b", "release-branch")
    write_file("app.txt", "three")
    git(@repo, "commit", "-q", "-am", "target commit")
    target_sha = git(@repo, "rev-parse", "HEAD").strip

    pairs = ChangeTagRefs.from_gh_release("gh release create v11.0.0 --target release-branch", @repo)
    assert_equal [ [ "v11.0.0", target_sha ] ], pairs
  end

  def test_for_command_dispatches_push_and_release_create
    git(@repo, "tag", "v12.0.0")
    assert_equal [ [ "v12.0.0", head_sha ] ], ChangeTagRefs.for_command("git push origin v12.0.0", @repo)
    assert_equal [ [ "v12.0.0", head_sha ] ], ChangeTagRefs.for_command("gh release create v12.0.0", @repo)
  end

  def test_for_command_returns_nothing_for_an_unrelated_command
    assert_empty ChangeTagRefs.for_command("gh pr view 12", @repo)
  end

  def test_unresolvable_repo_fails_open_to_empty
    assert_empty ChangeTagRefs.from_push("git push origin v1.0.0", "/no/such/repo")
  end
end
