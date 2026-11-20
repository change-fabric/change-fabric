# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../scripts/cf_pids"

class CfPidsTest < Minitest::Test
  # A fake process table: pid => {start_time:, command:}. Never touches real processes.
  class FakeTable
    attr_accessor :procs

    def initialize(procs) = @procs = procs
    def read(pid) = @procs[pid]
  end

  def setup
    @root = Dir.mktmpdir
    @signals = []
    @table = FakeTable.new(100 => { start_time: "Mon Nov 20 09:00:00 2026", command: "node server.js" })
    @killer = ->(signal, pid) { @signals << [ signal, pid ] }
  end

  def teardown = FileUtils.remove_entry(@root)

  def registry(session = "s1") = CfPids.new(session: session, root: @root, table: @table, killer: @killer)

  def test_register_records_pid_start_time_and_command_from_ps
    entry = registry.register(pid: 100)
    assert_equal({ "pid" => 100, "start_time" => "Mon Nov 20 09:00:00 2026", "command" => "node server.js" }, entry)
    assert_equal [ entry ], registry.entries
    assert_equal "600", format("%o", File.stat(registry.path).mode & 0o777)
  end

  def test_register_a_missing_process_raises
    assert_raises(ArgumentError) { registry.register(pid: 999) }
  end

  def test_matching_entry_is_stopped_and_dropped
    reg = registry
    reg.register(pid: 100)
    assert_equal [ 100 ], reg.stop_matching
    assert_equal [ [ "TERM", 100 ] ], @signals
    assert_empty reg.entries
  end

  def test_reused_pid_with_a_new_start_time_is_never_killed
    reg = registry
    reg.register(pid: 100)
    @table.procs[100] = { start_time: "Tue Nov 21 10:00:00 2026", command: "node server.js" }
    assert_empty reg.stop_matching
    assert_empty @signals
    assert_empty reg.entries
  end

  def test_reused_pid_with_a_different_command_is_never_killed
    reg = registry
    reg.register(pid: 100)
    @table.procs[100] = { start_time: "Mon Nov 20 09:00:00 2026", command: "vim notes.txt" }
    assert_empty reg.stop_matching
    assert_empty @signals
  end

  def test_exited_process_is_dropped_without_a_signal
    reg = registry
    reg.register(pid: 100)
    @table.procs.clear
    assert_empty reg.stop_matching
    assert_empty @signals
    assert_empty reg.entries
  end

  def test_unregistered_processes_are_never_touched
    @table.procs[200] = { start_time: "x", command: "postgres" }
    registry.register(pid: 100)
    registry.stop_matching
    assert_equal [ [ "TERM", 100 ] ], @signals
  end

  def test_sessions_do_not_share_entries
    registry("a").register(pid: 100)
    assert_empty registry("b").entries
  end

  def test_unsafe_session_id_cannot_escape_the_root
    reg = registry("../../etc")
    reg.register(pid: 100)
    assert reg.path.start_with?(File.join(@root, "sessions") + "/")
    refute_includes reg.path, ".."
  end

  def test_corrupt_registry_reads_as_empty
    reg = registry
    reg.register(pid: 100)
    File.write(reg.path, "{not json")
    assert_empty reg.entries
  end

  def test_signal_failure_is_not_reported_as_stopped
    reg = CfPids.new(session: "s1", root: @root, table: @table, killer: ->(_s, _p) { raise Errno::EPERM })
    reg.register(pid: 100)
    assert_empty reg.stop_matching
  end
end
