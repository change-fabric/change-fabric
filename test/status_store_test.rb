# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../scripts/status_store"

class StatusStoreTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir
    @prev = Dir.home
    @prev_session_env = ENV["CLAUDE_CODE_SESSION_ID"]
    ENV["HOME"] = @home
    ENV.delete("CLAUDE_CODE_SESSION_ID")
  end

  def teardown
    ENV["HOME"] = @prev
    if @prev_session_env
      ENV["CLAUDE_CODE_SESSION_ID"] = @prev_session_env
    else
      ENV.delete("CLAUDE_CODE_SESSION_ID")
    end
    FileUtils.remove_entry(@home)
  end

  def run_cli(argv)
    out = StringIO.new
    StatusStore::CLI.run(argv, out: out)
    JSON.parse(out.string)
  end

  def test_unarmed_session_reads_as_not_armed_with_no_items
    result = run_cli([ "show", "--session", "s1" ])
    refute result["armed"]
    assert_empty result["items"]
  end

  def test_arm_records_interval_and_cron_job_id_read_back_by_a_new_store_instance
    run_cli([ "arm", "--session", "s1", "--interval", "10", "--cron", "cron_1" ])
    result = run_cli([ "show", "--session", "s1" ])
    assert result["armed"]
    assert_equal 10, result["interval"]
    assert_equal "cron_1", result["cron_job_id"]
  end

  def test_arm_clears_items_left_over_from_a_previous_arming
    run_cli([ "arm", "--session", "s1", "--interval", "10", "--cron", "cron_1" ])
    run_cli([ "write", "--session", "s1", "--item", "50:in flight" ])
    run_cli([ "arm", "--session", "s1", "--interval", "5", "--cron", "cron_2" ])
    result = run_cli([ "show", "--session", "s1" ])
    assert_empty result["items"]
  end

  def test_write_on_a_fresh_store_reports_changed_true
    result = run_cli([ "write", "--session", "s1", "--item", "10:new item" ])
    assert result["changed"]
  end

  def test_write_with_an_identical_list_reports_changed_false_and_preserves_previous
    run_cli([ "write", "--session", "s1", "--item", "10:one", "--item", "20:two" ])
    result = run_cli([ "write", "--session", "s1", "--item", "10:one", "--item", "20:two" ])
    refute result["changed"]
    assert_equal [ 10, 20 ], result["previous"].map { |item| item["percent"] }
  end

  def test_write_with_a_reordered_list_reports_changed_true
    run_cli([ "write", "--session", "s1", "--item", "10:one", "--item", "20:two" ])
    result = run_cli([ "write", "--session", "s1", "--item", "20:two", "--item", "10:one" ])
    assert result["changed"]
  end

  def test_percent_bands_render_the_correct_color_at_each_boundary
    {
      0 => "red", 33 => "red",
      34 => "yellow", 79 => "yellow",
      80 => "green", 100 => "green"
    }.each do |percent, color|
      result = run_cli([ "write", "--session", "s1", "--item", "#{percent}:item" ])
      assert_equal color, result["items"].first["color"], "expected #{percent}% to render #{color}"
    end
  end

  def test_all_green_is_true_only_when_every_item_is_at_or_above_80
    result = run_cli([ "write", "--session", "s1", "--item", "80:one", "--item", "100:two" ])
    assert result["all_green"]

    result = run_cli([ "write", "--session", "s1", "--item", "79:one", "--item", "100:two" ])
    refute result["all_green"]
  end

  def test_all_green_is_false_for_an_empty_list
    result = run_cli([ "write", "--session", "s1" ])
    refute result["all_green"]
  end

  def test_rendered_line_format_is_exactly_emoji_label_percent
    result = run_cli([ "write", "--session", "s1", "--item", "55:Writing plan.md" ])
    assert_equal [ "\u{1F7E1} Writing plan.md (55%)" ], result["rendered"]
  end

  def test_a_percent_above_100_is_clamped
    result = run_cli([ "write", "--session", "s1", "--item", "999:too high" ])
    assert_equal 100, result["items"].first["percent"]
  end

  def test_a_label_containing_a_pipe_or_a_newline_is_stripped_not_rejected
    result = run_cli([ "write", "--session", "s1", "--item", "10:has|pipe\nand newline" ])
    refute_nil result["items"].first
    label = result["items"].first["label"]
    refute_includes label, "|"
    refute_includes label, "\n"
  end

  def test_a_malformed_item_returns_bad_item_error_and_leaves_stored_items_untouched
    run_cli([ "write", "--session", "s1", "--item", "10:kept" ])
    result = run_cli([ "write", "--session", "s1", "--item", "not-an-item" ])
    assert_equal "bad_item", result["error"]
    show = run_cli([ "show", "--session", "s1" ])
    assert_equal [ "kept" ], show["items"].map { |item| item["label"] }
  end

  def test_a_corrupt_items_file_reads_as_empty_rather_than_raising
    run_cli([ "arm", "--session", "s1", "--interval", "10", "--cron", "cron_1" ])
    path = run_cli([ "path", "--session", "s1" ])["items"]
    File.write(path, "\xFF\xFE not|even|close\nto valid")
    result = run_cli([ "show", "--session", "s1" ])
    assert result["armed"]
    assert_equal [], result["items"]
  end

  def test_a_blank_session_id_is_non_persistable
    run_cli([ "write", "--session", "", "--item", "10:ghost" ])
    result = run_cli([ "show", "--session", "" ])
    refute result["armed"]
    assert_empty result["items"]
  end

  def test_an_explicitly_blank_session_flag_does_not_fall_back_to_another_session
    sessions_root = File.join(@home, ".claude", "cf", "sessions")
    other = File.join(sessions_root, "other-real-session")
    FileUtils.mkdir_p(other)
    FileUtils.touch(other, mtime: Time.now + 60)

    assert_equal "", run_cli([ "resolve", "--session", "" ])["session_id"]
    run_cli([ "write", "--session", "", "--item", "10:ghost" ])
    refute File.exist?(File.join(other, "status"))
  end

  def test_an_explicitly_blank_session_env_does_not_fall_back_to_another_session
    sessions_root = File.join(@home, ".claude", "cf", "sessions")
    other = File.join(sessions_root, "other-real-session")
    FileUtils.mkdir_p(other)
    FileUtils.touch(other, mtime: Time.now + 60)

    ENV["CLAUDE_CODE_SESSION_ID"] = ""
    assert_equal "", run_cli([ "resolve" ])["session_id"]
    run_cli([ "write", "--item", "10:ghost" ])
    refute File.exist?(File.join(other, "status"))
  ensure
    ENV.delete("CLAUDE_CODE_SESSION_ID")
  end

  def test_a_corrupt_config_file_reads_as_empty_rather_than_raising
    run_cli([ "arm", "--session", "s1", "--interval", "10", "--cron", "cron_1" ])
    path = run_cli([ "path", "--session", "s1" ])["config"]
    File.write(path, "\xFF\xFE not a valid config line")
    result = run_cli([ "show", "--session", "s1" ])
    assert result["armed"], "the config file still exists, so armed? (a presence check) stays true"
    assert_nil result["interval"]
    assert_nil result["cron_job_id"]
    assert_empty result["items"]
  end

  def test_disarm_returns_the_recorded_cron_job_id_and_removes_both_files
    run_cli([ "arm", "--session", "s1", "--interval", "10", "--cron", "cron_9" ])
    run_cli([ "write", "--session", "s1", "--item", "10:one" ])
    paths = run_cli([ "path", "--session", "s1" ])
    result = run_cli([ "disarm", "--session", "s1" ])
    assert_equal "cron_9", result["cron_job_id"]
    assert result["disarmed"]
    refute File.exist?(paths["config"])
    refute File.exist?(paths["items"])
  end

  def test_disarm_on_an_unarmed_session_returns_null_cron_job_id_without_raising
    result = run_cli([ "disarm", "--session", "s1" ])
    assert_nil result["cron_job_id"]
    refute result["disarmed"]
  end

  def test_resolve_honors_the_session_flag_over_the_env_var
    sessions_root = File.join(@home, ".claude", "cf", "sessions")
    FileUtils.mkdir_p(File.join(sessions_root, "some-other-session"))

    ENV["CLAUDE_CODE_SESSION_ID"] = "env-session"
    assert_equal "flag-session", run_cli([ "resolve", "--session", "flag-session" ])["session_id"]
    assert_equal "env-session", run_cli([ "resolve" ])["session_id"]
  ensure
    ENV.delete("CLAUDE_CODE_SESSION_ID")
  end

  def test_resolve_returns_null_rather_than_guessing_another_sessions_directory
    sessions_root = File.join(@home, ".claude", "cf", "sessions")
    older = File.join(sessions_root, "older-session")
    newer = File.join(sessions_root, "newer-session")
    FileUtils.mkdir_p(older)
    FileUtils.mkdir_p(newer)
    FileUtils.touch(newer, mtime: Time.now + 60)

    assert_nil run_cli([ "resolve" ])["session_id"]
    run_cli([ "write", "--item", "10:ghost" ])
    refute File.exist?(File.join(newer, "status")), "an unresolved session must write nowhere"
    refute File.exist?(File.join(older, "status"))
  end

  def test_writes_leave_no_temp_file_behind
    run_cli([ "arm", "--session", "s1", "--interval", "10", "--cron", "cron_1" ])
    run_cli([ "write", "--session", "s1", "--item", "10:one" ])
    paths = run_cli([ "path", "--session", "s1" ])
    refute File.exist?("#{paths['config']}.tmp")
    refute File.exist?("#{paths['items']}.tmp")
    assert File.exist?(paths["config"])
    assert File.exist?(paths["items"])
  end
end
