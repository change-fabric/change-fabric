# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/triage/heartbeat"

class TriageHeartbeatTest < Minitest::Test
  NOW = Time.utc(2026, 11, 25, 12, 0, 0)

  def test_write_then_read_round_trips_per_host
    Dir.mktmpdir do |dir|
      Triage::Heartbeat.write(dir, "mini", now: NOW, generation: 4)
      Triage::Heartbeat.write(dir, "vm", now: NOW - 60)
      beats = Triage::Heartbeat.read_all(dir)
      assert_equal %w[mini vm], beats.keys
      assert_equal NOW, beats["mini"]["at"]
      assert_equal 4, beats["mini"]["generation"]
    end
  end

  def test_status_is_fresh_through_two_ticks_and_stale_after
    beat = { "at" => NOW - 1800 }
    assert_equal "fresh", Triage::Heartbeat.status(beat, NOW), "exactly 30 minutes is still fresh"
    assert_equal "stale", Triage::Heartbeat.status({ "at" => NOW - 1801 }, NOW)
    assert_equal "fresh", Triage::Heartbeat.status({ "at" => NOW - 60 }, NOW)
  end

  def test_a_host_with_no_heartbeat_reads_missing
    assert_equal "missing", Triage::Heartbeat.status(nil, NOW)
    assert_nil Triage::Heartbeat.age(nil, NOW)
  end

  def test_corrupt_heartbeat_files_are_skipped
    Dir.mktmpdir do |dir|
      Triage::Heartbeat.write(dir, "mini", now: NOW)
      File.write(File.join(dir, "vm.json"), "not json")
      File.write(File.join(dir, "bad.json"), JSON.generate("at" => "yesterday-ish"))
      assert_equal %w[mini], Triage::Heartbeat.read_all(dir).keys
    end
  end

  def test_write_leaves_no_temp_file_behind
    Dir.mktmpdir do |dir|
      Triage::Heartbeat.write(dir, "mini", now: NOW)
      assert_equal [ "mini.json" ], Dir.children(dir)
    end
  end

  def test_a_missing_directory_reads_empty
    assert_empty Triage::Heartbeat.read_all("/nonexistent/triage/heartbeat")
  end
end
