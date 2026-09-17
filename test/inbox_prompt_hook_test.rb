# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../scripts/inbox_prompt_hook"
require_relative "../scripts/inbox_store"

class InboxPromptHookTest < Minitest::Test
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

  def init_roster(roles)
    InboxStore::CLI.run([ "init", "--roles", roles.join(",") ], out: StringIO.new)
  end

  def bind_role(session_id, role)
    dir = File.join(@home, ".claude", "cf", "sessions", session_id)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "inbox-role"), role)
  end

  def transcript_with_title(session_id, title)
    dir = File.join(@home, ".claude", "projects", "cwd")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "#{session_id}.jsonl")
    File.write(path, JSON.generate(type: "custom-title", customTitle: title) + "\n")
    path
  end

  def run_hook(event)
    out = StringIO.new
    InboxPromptHook.run(event, out)
    out.string
  end

  def test_prints_nothing_when_no_roster_is_configured
    event = { "session_id" => "sess-1", "cwd" => "/x", "transcript_path" => "" }
    assert_empty run_hook(event)
  end

  def test_prints_bound_roles_pending_items
    init_roster(%w[PLAN BUILD])
    InboxStore::CLI.run([ "append", "BUILD", "--from", "PLAN", "--subject", "wire it" ], out: StringIO.new)
    bind_role("sess-1", "BUILD")

    event = { "session_id" => "sess-1", "cwd" => "/x", "transcript_path" => "" }
    output = run_hook(event)
    refute_empty output
    parsed = JSON.parse(output)
    body = parsed["hookSpecificOutput"]["additionalContext"]
    assert_match(/\[inbox\] BUILD: 1 pending/, body)
    assert_match(/wire it/, body)
  end

  def test_falls_back_to_transcript_title_when_no_bind_exists
    init_roster(%w[PLAN BUILD])
    InboxStore::CLI.run([ "append", "BUILD", "--from", "PLAN", "--subject", "wire it" ], out: StringIO.new)
    transcript = transcript_with_title("sess-2", "Session for BUILD work")

    event = { "session_id" => "sess-2", "cwd" => "/x", "transcript_path" => transcript }
    output = run_hook(event)
    refute_empty output
    body = JSON.parse(output)["hookSpecificOutput"]["additionalContext"]
    assert_match(/\[inbox\] BUILD: 1 pending/, body)
  end

  def test_transcript_title_prefers_the_longest_matching_role
    init_roster(%w[BUILD BUILD-API])
    InboxStore::CLI.run([ "append", "BUILD-API", "--from", "BUILD", "--subject", "ship the api" ], out: StringIO.new)
    transcript = transcript_with_title("sess-9", "Session for BUILD-API work")

    event = { "session_id" => "sess-9", "cwd" => "/x", "transcript_path" => transcript }
    body = JSON.parse(run_hook(event))["hookSpecificOutput"]["additionalContext"]
    assert_match(/\[inbox\] BUILD-API: 1 pending/, body)
  end

  def test_bind_wins_over_a_conflicting_transcript_title
    init_roster(%w[PLAN BUILD])
    InboxStore::CLI.run([ "append", "PLAN", "--from", "BUILD", "--subject", "review it" ], out: StringIO.new)
    bind_role("sess-3", "PLAN")
    transcript = transcript_with_title("sess-3", "Session for BUILD work")

    event = { "session_id" => "sess-3", "cwd" => "/x", "transcript_path" => transcript }
    output = run_hook(event)
    body = JSON.parse(output)["hookSpecificOutput"]["additionalContext"]
    assert_match(/\[inbox\] PLAN: 1 pending/, body)
  end

  def test_prints_nothing_the_second_time_the_same_body_would_be_produced
    init_roster(%w[PLAN BUILD])
    InboxStore::CLI.run([ "append", "BUILD", "--from", "PLAN", "--subject", "wire it" ], out: StringIO.new)
    bind_role("sess-4", "BUILD")

    event = { "session_id" => "sess-4", "cwd" => "/x", "transcript_path" => "" }
    first = run_hook(event)
    refute_empty first
    second = run_hook(event)
    assert_empty second
  end
end
