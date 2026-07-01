# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/branch_classify"
require "open3"
require "tmpdir"

class BranchClassifyTest < Minitest::Test
  def setup
    @origin = Dir.mktmpdir
    @repo = Dir.mktmpdir
    git(@origin, "init", "-q", "--bare")
    git(@repo, "init", "-q", "-b", "main")
    git(@repo, "config", "user.email", "test@example.com")
    git(@repo, "config", "user.name", "Test")
    git(@repo, "remote", "add", "origin", @origin)
    write_file("main.txt", "one")
    git(@repo, "add", "main.txt")
    git(@repo, "commit", "-q", "-m", "initial")
    git(@repo, "push", "-q", "origin", "main")
  end

  def teardown
    FileUtils.remove_entry(@origin)
    FileUtils.remove_entry(@repo)
  end

  def git(dir, *args)
    _out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed in #{dir}" unless status.success?
  end

  def write_file(name, contents)
    File.write(File.join(@repo, name), contents)
  end

  def branch(name)
    git(@repo, "checkout", "-q", "-b", name)
  end

  def result_for(name, trunk: "main")
    BranchClassify.run(trunk, dir: @repo).find { |r| r.branch == name }
  end

  def test_branch_merged_into_trunk_is_prunable
    branch("merged")
    write_file("main.txt", "two")
    git(@repo, "commit", "-q", "-am", "change")
    git(@repo, "checkout", "-q", "main")
    git(@repo, "merge", "-q", "merged")
    git(@repo, "push", "-q", "origin", "main")
    git(@repo, "fetch", "-q", "origin")

    result = result_for("merged")
    assert_equal "prunable", result.kind
    assert_equal 0, result.unmerged_count
    refute result.dirty
  end

  def test_squash_merged_branch_with_no_diff_is_squash_merged
    branch("squashed")
    write_file("main.txt", "squash-content")
    git(@repo, "commit", "-q", "-am", "squash source")
    git(@repo, "checkout", "-q", "main")
    write_file("main.txt", "squash-content")
    git(@repo, "commit", "-q", "-am", "squash merge of #1")
    git(@repo, "push", "-q", "origin", "main")
    git(@repo, "fetch", "-q", "origin")

    result = result_for("squashed")
    assert_equal "squash_merged", result.kind
    assert result.unmerged_count.positive?
    refute result.dirty
  end

  def test_unmerged_branch_with_real_diff_is_rogue
    branch("rogue")
    write_file("main.txt", "rogue-content")
    git(@repo, "commit", "-q", "-am", "unmerged change")
    git(@repo, "fetch", "-q", "origin")

    result = result_for("rogue")
    assert_equal "rogue", result.kind
    assert result.unmerged_count.positive?
    refute result.dirty
  end

  def test_dirty_checked_out_branch_is_rogue_even_if_merged
    branch("dirty-merged")
    write_file("main.txt", "three")
    git(@repo, "commit", "-q", "-am", "change")
    git(@repo, "checkout", "-q", "main")
    git(@repo, "merge", "-q", "dirty-merged")
    git(@repo, "push", "-q", "origin", "main")
    git(@repo, "fetch", "-q", "origin")
    git(@repo, "checkout", "-q", "dirty-merged")
    write_file("main.txt", "uncommitted-edit")

    result = result_for("dirty-merged")
    assert_equal "rogue", result.kind
    assert result.dirty
  ensure
    git(@repo, "checkout", "-q", "-f", "main")
  end

  def test_unresolved_trunk_raises
    assert_raises(BranchClassify::TrunkUnresolved) { BranchClassify.run("nope", dir: @repo) }
  end

  def test_trunk_itself_is_excluded
    branches = BranchClassify.run("main", dir: @repo).map(&:branch)
    refute_includes branches, "main"
  end
end
