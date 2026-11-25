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

  # Items now come from a triage report, never from judgment. Each pair
  # becomes one report group whose done/total yields exactly that percent.
  def report_file(items)
    groups = items.map do |percent, label|
      { "group" => label, "kind" => "epic", "name" => label, "total" => 100, "done" => percent,
        "percent" => percent, "percent_label" => "#{percent}%", "next_step" => "" }
    end
    path = File.join(@home, "report-#{items.hash.abs}.json")
    File.write(path, JSON.generate("groups" => groups))
    path
  end

  def write_items(session, items)
    args = [ "write", "--report-file", report_file(items) ]
    args.push("--session", session) unless session.nil?
    run_cli(args)
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
    write_items("s1", [ [ 50, "in flight" ] ])
    run_cli([ "arm", "--session", "s1", "--interval", "5", "--cron", "cron_2" ])
    result = run_cli([ "show", "--session", "s1" ])
    assert_empty result["items"]
  end

  def test_write_on_a_fresh_store_reports_changed_true
    result = write_items("s1", [ [ 10, "new item" ] ])
    assert result["changed"]
  end

  def test_write_with_an_identical_list_reports_changed_false_and_preserves_previous
    write_items("s1", [ [ 10, "one" ], [ 20, "two" ] ])
    result = write_items("s1", [ [ 10, "one" ], [ 20, "two" ] ])
    refute result["changed"]
    assert_equal [ 10, 20 ], result["previous"].map { |item| item["percent"] }
  end

  def test_write_with_a_reordered_list_reports_changed_true
    write_items("s1", [ [ 10, "one" ], [ 20, "two" ] ])
    result = write_items("s1", [ [ 20, "two" ], [ 10, "one" ] ])
    assert result["changed"]
  end

  def test_percent_bands_render_the_correct_color_at_each_boundary
    {
      0 => "red", 33 => "red",
      34 => "yellow", 79 => "yellow",
      80 => "green", 99 => "green"
    }.each do |percent, color|
      result = write_items("s1", [ [ percent, "item" ] ])
      assert_equal color, result["items"].first["color"], "expected #{percent}% to render #{color}"
    end
    assert_equal "green", StatusStore.band_for(100)[2]
  end

  def test_all_green_is_true_only_when_every_item_is_at_or_above_80
    result = write_items("s1", [ [ 80, "one" ], [ 99, "two" ] ])
    assert result["all_green"]

    result = write_items("s1", [ [ 79, "one" ], [ 99, "two" ] ])
    refute result["all_green"]
  end

  def test_all_green_is_false_when_the_report_has_no_groups
    result = write_items("s1", [])
    refute result["all_green"]
  end

  def test_finished_groups_are_not_listed_but_a_report_of_only_finished_groups_is_all_green
    result = write_items("s1", [ [ 100, "shipped" ] ])
    assert_empty result["items"]
    assert result["all_green"]
  end

  def test_a_group_with_an_empty_denominator_has_no_line_and_keeps_the_loop_running
    path = File.join(@home, "na.json")
    File.write(path, JSON.generate("groups" => [ { "name" => "empty", "total" => 0, "done" => 0, "percent" => nil,
                                                    "percent_label" => "n/a", "next_step" => "no units" } ]))
    result = run_cli([ "write", "--session", "s1", "--report-file", path ])
    assert_empty result["items"]
    refute result["all_green"]
  end

  def test_the_repo_filter_keeps_only_that_repos_groups
    path = File.join(@home, "repo.json")
    File.write(path, JSON.generate("groups" => [
      { "group" => "a", "name" => "a", "total" => 4, "done" => 1, "percent" => 25, "next_step" => "x" },
      { "group" => "b", "name" => "b", "total" => 4, "done" => 2, "percent" => 50, "next_step" => "y" }
    ], "units" => [ { "group" => "a", "repo" => "o/a" }, { "group" => "b", "repo" => "o/b" } ]))
    result = run_cli([ "write", "--session", "s1", "--report-file", path, "--repo", "o/b" ])
    assert_equal [ "b: y" ], result["items"].map { |item| item["label"] }
  end

  def test_rendered_line_format_is_exactly_emoji_label_percent
    result = write_items("s1", [ [ 55, "Writing plan.md" ] ])
    assert_equal [ "\u{1F7E1} Writing plan.md (55%)" ], result["rendered"]
  end

  def test_a_percent_above_100_is_clamped
    path = File.join(@home, "high.json")
    File.write(path, JSON.generate("groups" => [ { "name" => "too high", "total" => 100, "done" => 50, "percent" => 999,
                                                    "next_step" => "" } ]))
    result = run_cli([ "write", "--session", "s1", "--report-file", path ])
    assert_equal 100, result["items"].first["percent"]
  end

  def test_a_label_containing_a_pipe_or_a_newline_is_stripped_not_rejected
    result = write_items("s1", [ [ 10, "has|pipe\nand newline" ] ])
    refute_nil result["items"].first
    label = result["items"].first["label"]
    refute_includes label, "|"
    refute_includes label, "\n"
  end

  def test_the_item_flag_is_rejected_because_percents_come_only_from_the_report
    write_items("s1", [ [ 10, "kept" ] ])
    result = run_cli([ "write", "--session", "s1", "--item", "90:judged" ])
    assert_equal "usage", result["error"]
    show = run_cli([ "show", "--session", "s1" ])
    assert_equal [ "kept" ], show["items"].map { |item| item["label"] }
  end

  def test_an_unreadable_report_returns_report_unavailable_and_leaves_stored_items_untouched
    write_items("s1", [ [ 10, "kept" ] ])
    result = run_cli([ "write", "--session", "s1", "--report-file", File.join(@home, "missing.json") ])
    assert_equal "report_unavailable", result["error"]
    show = run_cli([ "show", "--session", "s1" ])
    assert_equal [ "kept" ], show["items"].map { |item| item["label"] }
  end

  def test_the_default_loader_reads_triage_report_json_read_only
    captured = nil
    loader = lambda do |argv|
      captured = argv
      [ JSON.generate("groups" => [ { "name" => "g", "total" => 2, "done" => 1, "percent" => 50, "next_step" => "n" } ]), true ]
    end
    out = StringIO.new
    StatusStore::CLI.run([ "write", "--session", "s1" ], out: out, loader: loader)
    assert_equal [ "report", "--json" ], captured.last(2)
    assert_equal [ "g: n" ], JSON.parse(out.string)["items"].map { |item| item["label"] }
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
    write_items("", [ [ 10, "ghost" ] ])
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
    write_items("", [ [ 10, "ghost" ] ])
    refute File.exist?(File.join(other, "status"))
  end

  def test_an_explicitly_blank_session_env_does_not_fall_back_to_another_session
    sessions_root = File.join(@home, ".claude", "cf", "sessions")
    other = File.join(sessions_root, "other-real-session")
    FileUtils.mkdir_p(other)
    FileUtils.touch(other, mtime: Time.now + 60)

    ENV["CLAUDE_CODE_SESSION_ID"] = ""
    assert_equal "", run_cli([ "resolve" ])["session_id"]
    write_items(nil, [ [ 10, "ghost" ] ])
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
    write_items("s1", [ [ 10, "one" ] ])
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
    write_items(nil, [ [ 10, "ghost" ] ])
    refute File.exist?(File.join(newer, "status")), "an unresolved session must write nowhere"
    refute File.exist?(File.join(older, "status"))
  end

  def test_writes_leave_no_temp_file_behind
    run_cli([ "arm", "--session", "s1", "--interval", "10", "--cron", "cron_1" ])
    write_items("s1", [ [ 10, "one" ] ])
    paths = run_cli([ "path", "--session", "s1" ])
    refute File.exist?("#{paths['config']}.tmp")
    refute File.exist?("#{paths['items']}.tmp")
    assert File.exist?(paths["config"])
    assert File.exist?(paths["items"])
  end
end
