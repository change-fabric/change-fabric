#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"

SCRIPTS = File.expand_path("../scripts", __dir__) unless defined?(SCRIPTS)
require_relative "#{SCRIPTS}/hook_event"
require_relative "#{SCRIPTS}/away_store"
require_relative "#{SCRIPTS}/merge_mode_store"
require_relative "#{SCRIPTS}/mode_command"
require_relative "#{SCRIPTS}/away_guard"
require_relative "#{SCRIPTS}/away_restate"

unless defined?(TempHome)
  module TempHome
    def setup
      @home = Dir.mktmpdir
      @prev_home = Dir.home
      ENV["HOME"] = @home
    end

    def teardown
      ENV["HOME"] = @prev_home
      FileUtils.remove_entry(@home)
    end
  end
end

class AwayStoreTest < Minitest::Test
  include TempHome

  def test_default_state_is_active_when_nothing_persisted
    assert_equal "active", AwayStore.new("s1").state
    refute AwayStore.new("s1").away?
  end

  def test_write_then_read_round_trips
    AwayStore.new("s1").write("away")
    assert_equal "away", AwayStore.new("s1").state
    assert AwayStore.new("s1").away?
  end

  def test_write_active_then_read_round_trips
    AwayStore.new("s1").write("away")
    AwayStore.new("s1").write("active")
    assert_equal "active", AwayStore.new("s1").state
    refute AwayStore.new("s1").away?
  end

  def test_blank_session_id_does_not_persist
    store = AwayStore.new("")
    store.write("away")
    assert_equal "active", store.state
    refute store.away?
    assert_empty Dir.glob(File.join(@home, ".claude", "cf", "sessions", "**", "*"))
  end

  def test_anything_other_than_away_normalizes_to_active
    AwayStore.new("s1").write("bogus")
    assert_equal "active", AwayStore.new("s1").state
  end
end

class ModeCommandTest < Minitest::Test
  include TempHome

  def run_prompt(prompt, session_id: "s1")
    io = StringIO.new
    event = { "session_id" => session_id, "prompt" => prompt }
    ModeCommand.new(event).emit(io)
    io.string
  end

  def test_away_command_writes_away_store
    run_prompt("/cf:away")
    assert AwayStore.new("s1").away?
  end

  def test_active_command_writes_away_store
    AwayStore.new("s1").write("away")
    run_prompt("/cf:active")
    refute AwayStore.new("s1").away?
  end

  def test_local_only_command_writes_merge_mode_store
    run_prompt("/cf:local-only")
    assert_equal "local-only", MergeModeStore.new("s1").mode
  end

  def test_merge_ready_command_writes_merge_mode_store
    run_prompt("/cf:merge-ready")
    assert_equal "merge-ready", MergeModeStore.new("s1").mode
  end

  def test_admin_bypass_command_writes_merge_mode_store
    run_prompt("/cf:admin-bypass")
    assert_equal "admin-bypass", MergeModeStore.new("s1").mode
  end

  def test_yolo_command_writes_merge_mode_store
    run_prompt("/cf:yolo")
    assert_equal "yolo", MergeModeStore.new("s1").mode
  end

  def test_each_command_injects_a_confirmation
    %w[/cf:away /cf:active /cf:local-only /cf:merge-ready /cf:admin-bypass /cf:yolo].each do |prompt|
      output = run_prompt(prompt)
      refute_empty output, "#{prompt} should inject additionalContext"
      context = JSON.parse(output).dig("hookSpecificOutput", "additionalContext")
      refute_nil context
    end
  end

  def test_non_matching_prompt_writes_nothing
    output = run_prompt("just a normal message, not a command")
    assert_empty output
    assert_nil MergeModeStore.new("s1").mode
    refute AwayStore.new("s1").away?
  end

  def test_cf_plan_refusal_fires_only_while_away
    output = run_prompt("/cf:plan build something")
    assert_empty output, "cf:plan should not be touched while active"

    AwayStore.new("s1").write("away")
    output = run_prompt("/cf:plan build something")
    refute_empty output
    context = JSON.parse(output).dig("hookSpecificOutput", "additionalContext")
    assert_match(/refuse/i, context)
    assert_match(%r{/cf:active}, context)
  end

  def test_blank_session_id_is_a_no_op
    output = run_prompt("/cf:away", session_id: "")
    refute AwayStore.new("").away?
    # AwayStore itself no-ops on write; the hook may still emit a confirmation,
    # but nothing is persisted.
    assert_empty Dir.glob(File.join(@home, ".claude", "cf", "sessions", "**", "*"))
    refute_nil output
  end
end

class AwayGuardTest < Minitest::Test
  include TempHome

  def guard(tool_name:, questions: nil, session_id: "s1")
    io = StringIO.new
    input = questions ? { "questions" => questions } : {}
    event = { "session_id" => session_id, "tool_name" => tool_name, "tool_input" => input }
    AwayGuard.new(event).emit(io)
    io.string
  end

  def question(header)
    { "header" => header, "question" => "irrelevant", "options" => [] }
  end

  def test_denies_an_ordinary_question_while_away
    AwayStore.new("s1").write("away")
    output = guard(tool_name: "AskUserQuestion", questions: [ question("Sign-off") ])
    refute_empty output
    decision = JSON.parse(output).dig("hookSpecificOutput", "permissionDecision")
    assert_equal "deny", decision
    reason = JSON.parse(output).dig("hookSpecificOutput", "permissionDecisionReason")
    assert_match(/away/i, reason)
    assert_match(/Sign-off/, reason)
    assert_match(%r{/cf:active}, reason)
  end

  def test_allows_each_floor_header
    AwayStore.new("s1").write("away")
    %w[Remote\ delete Untracked Secret\ alert].each do |header|
      output = guard(tool_name: "AskUserQuestion", questions: [ question(header) ])
      assert_empty output, "#{header} should be a floor and pass through"
    end
  end

  def test_allows_everything_when_not_away
    output = guard(tool_name: "AskUserQuestion", questions: [ question("Sign-off") ])
    assert_empty output
  end

  def test_ignores_non_ask_user_question_tools
    AwayStore.new("s1").write("away")
    output = guard(tool_name: "Bash", questions: [ question("Sign-off") ])
    assert_empty output
  end

  def test_allows_a_multi_question_call_when_any_one_question_floors
    AwayStore.new("s1").write("away")
    output = guard(tool_name: "AskUserQuestion", questions: [ question("Sign-off"), question("Untracked") ])
    assert_empty output
  end
end

class AwayRestateTest < Minitest::Test
  include TempHome

  def restate(session_id: "s1")
    io = StringIO.new
    AwayRestate.new({ "session_id" => session_id }).emit(io)
    io.string
  end

  def test_silent_when_not_away
    assert_empty restate
  end

  def test_emits_the_directive_when_away
    AwayStore.new("s1").write("away")
    output = restate
    refute_empty output
    context = JSON.parse(output).dig("hookSpecificOutput", "additionalContext")
    assert_match(/Away mode active/, context)
    assert_match(%r{/cf:active}, context)
  end
end
