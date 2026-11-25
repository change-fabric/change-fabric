# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "support/triage_fakes"
require_relative "../scripts/triage/snapshot"

# Contract C3: atomic publish by write-then-rename, and a bounded read-only SSH
# pull that never raises.
class TriageSnapshotTest < Minitest::Test
  Result = Triage::Command::Result

  def valid_snapshot(now = TriageFakes::NOW)
    { "host" => "vm", "generation" => 2, "generated_at" => now.iso8601, "heartbeat_at" => now.iso8601,
      "repos" => [], "decisions" => [] }
  end

  def test_write_atomic_replaces_the_file_and_leaves_no_temp
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      Triage::Snapshot.write_atomic(path, JSON.generate(valid_snapshot))
      Triage::Snapshot.write_atomic(path, JSON.generate(valid_snapshot.merge("generation" => 3)))
      assert_equal 3, Triage::Snapshot.read(path)["generation"]
      assert_equal [ "snapshot.json" ], Dir.children(dir)
    end
  end

  def test_a_failed_write_keeps_the_old_snapshot
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      Triage::Snapshot.write_atomic(path, JSON.generate(valid_snapshot))
      FileUtils.mkdir_p("#{path}.#{Process.pid}.tmp") # staging path blocked by a directory
      assert_raises(SystemCallError) { Triage::Snapshot.write_atomic(path, JSON.generate(valid_snapshot.merge("generation" => 9))) }
      assert_equal 2, Triage::Snapshot.read(path)["generation"]
    end
  end

  def test_read_rejects_corrupt_and_incomplete_snapshots
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      assert_nil Triage::Snapshot.read(path)
      File.write(path, "{")
      assert_nil Triage::Snapshot.read(path)
      File.write(path, JSON.generate("host" => "vm"))
      assert_nil Triage::Snapshot.read(path)
    end
  end

  def test_pull_runs_ssh_read_only_with_the_ten_second_bound
    seen = nil
    runner = lambda do |argv, timeout|
      seen = [ argv, timeout ]
      Result.new(out: JSON.generate(valid_snapshot), err: "", ok: true, timed_out: false)
    end
    pulled = Triage::Snapshot.pull("exe-vm", runner: runner)
    assert_equal "ok", pulled.status
    assert_equal 10, seen.last
    assert_equal [ "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "exe-vm", "cat ~/.claude/cf/triage/snapshot.json" ], seen.first
  end

  def test_pull_reports_unreachable_on_timeout_and_failure
    timeout = ->(_argv, _t) { Result.new(out: "", err: "timed out after 10s", ok: false, timed_out: true) }
    refused = ->(_argv, _t) { Result.new(out: "", err: "Connection refused", ok: false, timed_out: false) }
    assert_equal "unreachable", Triage::Snapshot.pull("vm", runner: timeout).status
    assert_includes Triage::Snapshot.pull("vm", runner: timeout).reason, "timed out"
    assert_equal "unreachable", Triage::Snapshot.pull("vm", runner: refused).status
  end

  def test_pull_reports_invalid_for_garbage_and_for_a_snapshot_missing_fields
    garbage = ->(_argv, _t) { Result.new(out: "<html>", err: "", ok: true, timed_out: false) }
    partial = ->(_argv, _t) { Result.new(out: JSON.generate("host" => "vm"), err: "", ok: true, timed_out: false) }
    assert_equal "invalid", Triage::Snapshot.pull("vm", runner: garbage).status
    assert_equal "invalid", Triage::Snapshot.pull("vm", runner: partial).status
  end

  def test_freshness_is_two_ticks_by_the_snapshots_own_clock
    assert_equal "fresh", Triage::Snapshot.freshness(valid_snapshot(TriageFakes::NOW - 1800), TriageFakes::NOW)
    assert_equal "stale", Triage::Snapshot.freshness(valid_snapshot(TriageFakes::NOW - 1801), TriageFakes::NOW)
  end

  def test_a_missing_ssh_binary_is_unreachable_not_a_crash
    result = Triage::Command.run([ "/nonexistent/ssh-binary" ], 1)
    refute result.ok
    refute result.timed_out
  end

  def test_command_kills_a_runaway_process_at_the_timeout
    started = Time.now
    result = Triage::Command.run([ "sleep", "30" ], 0.3)
    assert result.timed_out
    assert_operator Time.now - started, :<, 5
  end
end
