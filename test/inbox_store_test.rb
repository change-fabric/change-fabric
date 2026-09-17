# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../scripts/inbox_store"

class InboxStoreTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir
    @root = Dir.mktmpdir
    @prev_home = ENV["HOME"]
    @prev_root = ENV["INBOX_ROOT"]
    ENV["HOME"] = @home
    ENV["INBOX_ROOT"] = @root
  end

  def teardown
    ENV["HOME"] = @prev_home
    if @prev_root
      ENV["INBOX_ROOT"] = @prev_root
    else
      ENV.delete("INBOX_ROOT")
    end
    FileUtils.remove_entry(@home)
    FileUtils.remove_entry(@root)
  end

  def run_cli(argv)
    out = StringIO.new
    InboxStore::CLI.run(argv, out: out)
    JSON.parse(out.string)
  end

  def test_append_refuses_with_no_roster_when_roster_json_is_absent
    result = run_cli([ "append", "BUILD", "--from", "PLAN", "--subject", "hello" ])
    assert_equal "no_roster", result["error"]
  end

  def test_init_creates_tree_and_roster
    result = run_cli([ "init", "--roles", "A,B,C" ])
    assert_equal %w[A B C], result["roles"]
    assert File.directory?(File.join(@root, "inbox", "A"))
    assert File.exist?(File.join(@root, "roster.json"))
    assert File.exist?(File.join(@root, "LEDGER.md"))
  end

  def test_second_init_refuses
    run_cli([ "init", "--roles", "A,B,C" ])
    result = run_cli([ "init", "--roles", "X,Y" ])
    assert_equal "roster_exists", result["error"]
  end

  def test_root_verb_reports_env_source
    result = run_cli([ "root" ])
    assert_equal @root, result["root"]
    assert_equal "env", result["source"]
  end

  def test_cli_run_returns_the_hash_it_printed
    out = StringIO.new
    result = InboxStore::CLI.run([ "root" ], out: out)
    assert_equal JSON.parse(out.string), result
  end

  def test_every_error_response_carries_an_error_key
    result = InboxStore::CLI.run([ "append", "BUILD", "--from", "PLAN", "--subject", "hello" ], out: StringIO.new)
    assert result.key?("error")
  end

  def test_long_ledger_clause_is_truncated_with_marker
    run_cli([ "init", "--roles", "PLAN,BUILD" ])
    clause = "x" * 5000
    result = run_cli([ "ledger", "PLAN", "BUILD", "pending", "slug", clause ])
    line = result["ledger"]
    assert line.length < 300
    assert line.end_with?("...(truncated, see item body)")
  end

  def write_pending_item(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "---\nfrom: PLAN\nto: BUILD\nsubject: thing\nrefs: \nstatus: pending\n---\n\nbody\n")
  end

  def test_two_done_calls_on_colliding_filenames_keep_both_files
    run_cli([ "init", "--roles", "PLAN,BUILD" ])
    path1 = File.join(@root, "inbox", "BUILD", "20260101-0000-PLAN-thing.md")
    write_pending_item(path1)
    path2 = File.join(@root, "inbox", "BUILD", "20260101-0000-PLAN-thing2.md")
    write_pending_item(path2)
    FileUtils.mkdir_p(File.join(@root, "done"))
    File.write(File.join(@root, "done", "20260101-0000-PLAN-thing2.md"), "placeholder")

    result1 = run_cli([ "done", path1 ])
    result2 = run_cli([ "done", path2 ])

    assert File.exist?(result1["path"])
    assert File.exist?(result2["path"])
    refute_equal result1["path"], result2["path"]
  end

  def test_unblock_returns_a_blocked_item_to_pending_and_reappears_in_list
    run_cli([ "init", "--roles", "PLAN,BUILD" ])
    run_cli([ "append", "BUILD", "--from", "PLAN", "--subject", "blocked thing" ])
    item = Dir.glob(File.join(@root, "inbox", "BUILD", "*.md")).first
    run_cli([ "done", item, "--blocked", "waiting" ])

    result = run_cli([ "unblock", item ])
    assert_equal "pending", result["status"]

    listed = run_cli([ "list", "--role", "BUILD" ])
    assert listed["items"].any? { |i| i["path"] == item }
  end

  def test_done_with_trailing_blocked_flag_blocks_instead_of_completing
    run_cli([ "init", "--roles", "PLAN,BUILD" ])
    run_cli([ "append", "BUILD", "--from", "PLAN", "--subject", "blocked thing" ])
    item = Dir.glob(File.join(@root, "inbox", "BUILD", "*.md")).first

    result = run_cli([ "done", item, "--blocked" ])

    assert_equal "blocked", result["status"]
    assert File.exist?(item)
  end

  def test_unblock_on_a_pending_item_errors
    run_cli([ "init", "--roles", "PLAN,BUILD" ])
    run_cli([ "append", "BUILD", "--from", "PLAN", "--subject", "pending thing" ])
    item = Dir.glob(File.join(@root, "inbox", "BUILD", "*.md")).first

    result = run_cli([ "unblock", item ])
    assert_equal "not_blocked", result["error"]
  end

  def test_announce_writes_one_item_per_role_and_none_are_actionable
    run_cli([ "init", "--roles", "PLAN,BUILD,QA" ])
    result = run_cli([ "announce", "--from", "PLAN", "--subject", "release cut at 14:00" ])
    assert_equal 3, result["paths"].length
    result["paths"].each { |p| assert File.exist?(p) }

    %w[PLAN BUILD QA].each do |role|
      listed = run_cli([ "list", "--role", role ])
      assert_equal 0, listed["count"]
    end
  end

  def test_announce_appends_exactly_one_ledger_line
    run_cli([ "init", "--roles", "PLAN,BUILD" ])
    before = File.readlines(File.join(@root, "LEDGER.md")).length
    run_cli([ "announce", "--from", "PLAN", "--subject", "heads up" ])
    after = File.readlines(File.join(@root, "LEDGER.md")).length
    assert_equal before + 1, after
  end

  def test_bind_writes_session_role_file_and_updates_roster_only_with_session_name
    run_cli([ "init", "--roles", "PLAN,BUILD" ])
    result = run_cli([ "bind", "PLAN", "--session", "sess-1" ])
    assert_equal "PLAN", result["role"]
    role_file = File.join(@home, ".claude", "cf", "sessions", "sess-1", "inbox-role")
    assert_equal "PLAN", File.read(role_file)
    refute result["roster_updated"]

    result2 = run_cli([ "bind", "PLAN", "--session", "sess-1", "--session-name", "plan-session" ])
    assert result2["roster_updated"]
    roster = JSON.parse(File.read(File.join(@root, "roster.json")))
    assert_equal "plan-session", roster["sessions"]["PLAN"]
  end

  def unsafe_roster!
    roster = JSON.parse(File.read(File.join(@root, "roster.json")))
    roster["roles"] = [ "BUILD", "../../ESCAPED" ]
    File.write(File.join(@root, "roster.json"), JSON.generate(roster))
  end

  def test_append_to_a_hand_edited_traversal_role_is_rejected
    run_cli([ "init", "--roles", "BUILD" ])
    unsafe_roster!

    result = run_cli([ "append", "../../ESCAPED", "--from", "BUILD", "--subject", "pwn" ])
    assert_equal "bad_role", result["error"]
    assert_equal %w[BUILD], result["roles"]
    refute File.exist?(File.expand_path(File.join(@root, "..", "..", "ESCAPED")))
  end

  def test_announce_skips_a_hand_edited_traversal_role
    run_cli([ "init", "--roles", "BUILD" ])
    unsafe_roster!

    result = run_cli([ "announce", "--from", "BUILD", "--subject", "heads up" ])
    assert_equal %w[BUILD], result["roles"]
    assert_equal 1, result["paths"].length
    refute File.exist?(File.expand_path(File.join(@root, "..", "..", "ESCAPED")))
  end

  def test_bind_with_no_resolvable_session_errors
    run_cli([ "init", "--roles", "PLAN,BUILD" ])
    prev = ENV.delete("CLAUDE_CODE_SESSION_ID")
    result = run_cli([ "bind", "PLAN" ])
    assert_equal "no_session", result["error"]
  ensure
    ENV["CLAUDE_CODE_SESSION_ID"] = prev if prev
  end
end
