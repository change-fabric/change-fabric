# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "git_fixture"
require_relative "../scripts/cf_project_identity"

class CfProjectIdentityTest < Minitest::Test
  def setup
    @tmp = File.realpath(Dir.mktmpdir)
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def repo(name, remote: nil)
    dir = File.join(@tmp, name)
    FileUtils.mkdir_p(dir)
    GitFixture.git_init(dir)
    GitFixture.git(dir, "config", "--local", "remote.origin.url", remote) if remote
    GitFixture.git(dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "init")
    dir
  end

  def test_repo_with_remote_is_keyed_by_normalized_remote
    dir = repo("web", remote: "git@github.com:acme/web.git")
    identity = CfProjectIdentity.for(dir)
    assert_equal "repo:github.com/acme/web", identity.id
    assert_equal dir, identity.root
    assert_equal 32, identity.slug.length
  end

  def test_subdirectory_resolves_to_its_repo
    dir = repo("web", remote: "https://github.com/acme/web")
    sub = File.join(dir, "a", "b")
    FileUtils.mkdir_p(sub)
    assert_equal CfProjectIdentity.for(dir).id, CfProjectIdentity.for(sub).id
  end

  def test_worktree_maps_to_its_main_repo_without_a_remote
    dir = repo("local")
    tree = File.join(@tmp, "tree")
    GitFixture.git(dir, "worktree", "add", "-q", tree)
    main = CfProjectIdentity.for(dir)
    assert_equal "git:#{dir}", main.id
    assert_equal main.id, CfProjectIdentity.for(tree).id
    assert_equal dir, CfProjectIdentity.for(tree).root
  end

  def test_worktree_maps_to_its_main_repo_with_a_remote
    dir = repo("web", remote: "https://github.com/acme/web.git")
    tree = File.join(@tmp, "tree")
    GitFixture.git(dir, "worktree", "add", "-q", tree)
    assert_equal CfProjectIdentity.for(dir).slug, CfProjectIdentity.for(tree).slug
  end

  def test_directory_outside_any_repo_is_its_own_project
    plain = File.join(@tmp, "notes")
    FileUtils.mkdir_p(plain)
    identity = CfProjectIdentity.for(plain)
    assert_equal "dir:#{plain}", identity.id
    assert_equal plain, identity.root
  end

  def test_prefixes_keep_the_forms_from_colliding
    ids = %w[repo git dir].map { |kind| CfProjectIdentity.slug("#{kind}:/same") }
    assert_equal 3, ids.uniq.size
  end

  def test_explicit_worktree_root_is_its_repo
    dir = repo("local")
    tree = File.join(@tmp, "tree")
    GitFixture.git(dir, "worktree", "add", "-q", tree)
    assert_equal "git:#{dir}", CfProjectIdentity.for_explicit_dir(tree).id
  end

  def test_explicit_dir_inside_a_repo_is_a_dir_level_not_the_repo
    dir = repo("web", remote: "https://github.com/acme/web")
    sub = File.join(dir, "org")
    FileUtils.mkdir_p(sub)
    assert_equal "dir:#{sub}", CfProjectIdentity.for_explicit_dir(sub).id
    assert_equal "repo:github.com/acme/web", CfProjectIdentity.for_explicit_dir(dir).id
  end
end
