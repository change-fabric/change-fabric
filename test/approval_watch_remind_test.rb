# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/approval_watch_remind"

class ApprovalWatchRemindTest < Minitest::Test
  def note(command, tool: "Bash", background: false)
    input = { "command" => command }
    input["run_in_background"] = true if background
    io = StringIO.new
    ApprovalWatchRemind.new({ "tool_name" => tool, "tool_input" => input }).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string).dig("hookSpecificOutput", "additionalContext")
  end

  def test_a_foreground_no_wait_request_is_told_to_start_record_in_the_background
    text = note("ruby scripts/approval_console.rb request --type release --tag skills/v1 --no-wait")
    assert_includes text, "approval_console.rb record <request_id>"
    assert_includes text, "run_in_background"
    assert_includes text, "Never ask the human"
  end

  def test_the_installed_path_and_a_leading_option_are_recognised
    refute_nil note("ruby ~/.claude/cf/bin/approval_console.rb request --no-wait --type carve-out")
  end

  def test_a_foreground_record_is_told_to_run_in_the_background
    assert_includes note("ruby scripts/approval_console.rb record 1234"), "blocks until the phone decides"
  end

  def test_a_background_record_is_silent
    assert_nil note("ruby scripts/approval_console.rb record 1234", background: true)
  end

  def test_a_waiting_request_and_other_verbs_and_commands_are_silent
    assert_nil note("ruby scripts/approval_console.rb request --type release --tag t")
    assert_nil note("ruby scripts/approval_console.rb status")
    assert_nil note("echo 'approval_console.rb request --no-wait'")
    assert_nil note("ls")
  end

  def test_other_tools_and_bad_input_are_silent
    assert_nil note("ruby approval_console.rb request --no-wait", tool: "Edit")
    io = StringIO.new
    ApprovalWatchRemind.new({ "tool_name" => "Bash", "tool_input" => "x" }).emit(io)
    assert_empty io.string
  end
end
