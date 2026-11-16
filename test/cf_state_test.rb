# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "digest"
require "json"
require_relative "../scripts/cf_state"

class CfStateTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir
    @root = File.join(@home, "state")
    @repo = File.join(@home, "repo")
    @worktree = File.join(@repo, ".claude", "worktrees", "agent")
    @other = File.join(@home, "other-repo")
    [ @worktree, @other ].each { |dir| FileUtils.mkdir_p(dir) }
  end

  def teardown = FileUtils.remove_entry(@home)

  def state(session_id, project: @repo, host: "claude")
    CfState.new(host: host, project: project, session_id: session_id, root: @root, home: @home)
  end

  def legacy_dir
    File.join(@root, "sessions", "claude", Digest::SHA256.hexdigest(File.realpath(@repo)))
  end

  def write_legacy(id, data)
    FileUtils.mkdir_p(legacy_dir)
    path = File.join(legacy_dir, "#{Digest::SHA256.hexdigest(id)}.json")
    File.write(path, JSON.generate(data.merge("version" => 1)))
    path
  end

  def test_writes_by_session_id_not_by_project
    state("parent").update({ "mode" => "local-only" })
    assert File.file?(File.join(@root, "sessions", "claude", "by-id", "#{Digest::SHA256.hexdigest('parent')}.json"))
    refute Dir.exist?(legacy_dir)
  end

  def test_child_in_another_worktree_or_repo_sees_parent_mode
    state("parent").update({ "mode" => "admin-bypass" })
    [ @worktree, @other ].each_with_index do |project, index|
      child = "parent:agent#{index}"
      assert_equal "admin-bypass", state(child, project: project).update({}, parent: "parent")["mode"]
      assert_equal "admin-bypass", state(child, project: project).read["mode"]
    end
  end

  def test_child_sees_parent_mode_changed_after_child_start
    state("parent").update({ "mode" => "merge-ready" })
    state("parent:agent", project: @worktree).update({}, parent: "parent")
    state("parent").update({ "mode" => "local-only", "availability" => "away" })
    assert_equal({ "mode" => "local-only", "availability" => "away" }, state("parent:agent", project: @worktree).read)
  end

  def test_host_isolation_is_kept
    state("parent").update({ "mode" => "yolo" })
    assert_equal "merge-ready", state("parent", host: "pi").read["mode"]
  end

  def test_legacy_per_project_record_is_read_but_not_written
    legacy = write_legacy("old", "mode" => "yolo")
    assert_equal "yolo", state("old").read["mode"]

    state("old").update({ "availability" => "away" })
    assert_equal({ "mode" => "yolo", "version" => 1 }, JSON.parse(File.read(legacy)))
    assert_equal({ "mode" => "yolo", "availability" => "away" }, state("old", project: @other).read)
  end

  def test_by_id_record_wins_over_legacy
    write_legacy("s", "mode" => "yolo")
    state("s", project: @other).update({ "mode" => "local-only" })
    assert_equal "local-only", state("s").read["mode"]
  end
end
