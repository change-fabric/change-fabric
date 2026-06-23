#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"

SCRIPTS = File.expand_path("../scripts", __dir__)
require_relative "#{SCRIPTS}/merge_mode_store"
require_relative "#{SCRIPTS}/merge_mode_record"
require_relative "#{SCRIPTS}/merge_mode_restate"
require_relative "#{SCRIPTS}/session_start"

module TempHome
  def setup
    @home = Dir.mktmpdir
    @prev_home = ENV["HOME"]
    ENV["HOME"] = @home
  end

  def teardown
    ENV["HOME"] = @prev_home
    FileUtils.remove_entry(@home)
  end
end

class MergeModeStoreTest < Minitest::Test
  include TempHome

  def test_mode_is_nil_when_nothing_persisted
    assert_nil MergeModeStore.new("s1").mode
  end

  def test_write_then_read_round_trips_stripped
    MergeModeStore.new("s1").write("Merge ready")
    assert_equal "Merge ready", MergeModeStore.new("s1").mode
  end

  def test_blank_session_id_does_not_persist
    store = MergeModeStore.new("")
    store.write("Merge ready")
    assert_nil store.mode
    assert_empty Dir.glob(File.join(@home, ".claude", "pst", "sessions", "**", "*"))
  end

  def test_rewrite_overwrites_previous_mode
    MergeModeStore.new("s1").write("Local only")
    MergeModeStore.new("s1").write("Admin bypass")
    assert_equal "Admin bypass", MergeModeStore.new("s1").mode
  end
end

class HookEventTest < Minitest::Test
  def read(text)
    HookEvent.read(StringIO.new(text))
  end

  def test_empty_input_is_empty_event
    assert_equal({}, read(""))
  end

  def test_malformed_json_is_empty_event
    assert_equal({}, read("{not json"))
  end

  def test_non_hash_json_is_empty_event
    assert_equal({}, read("42"))
  end

  def test_parses_hash_payload
    assert_equal({ "session_id" => "s1" }, read('{"session_id":"s1"}'))
  end
end

class MergeModeAnswerTest < Minitest::Test
  def real_response(answer)
    {
      "questions" => [{ "question" => "How should I handle changes from this session?",
                        "header" => "Merge mode" }],
      "answers" => { "How should I handle changes from this session?" => answer }
    }
  end

  def test_extracts_label_from_real_payload
    assert_equal "Merge ready", MergeModeAnswer.new(real_response("Merge ready")).label
  end

  def test_ignores_questions_without_merge_mode_header
    response = {
      "questions" => [{ "question" => "Pick a color", "header" => "Color" }],
      "answers" => { "Pick a color" => "blue" }
    }
    assert_nil MergeModeAnswer.new(response).label
  end

  def test_nil_for_non_hash_or_missing_answer
    assert_nil MergeModeAnswer.new(nil).label
    assert_nil MergeModeAnswer.new(real_response("")).label
  end
end

class MergeModeRecordTest < Minitest::Test
  include TempHome

  def event(tool_name)
    {
      "session_id" => "s1",
      "tool_name" => tool_name,
      "tool_response" => {
        "questions" => [{ "question" => "q", "header" => "Merge mode" }],
        "answers" => { "q" => "Admin bypass" }
      }
    }
  end

  def test_ignores_non_ask_user_question
    MergeModeRecord.new(event("Bash")).call
    assert_nil MergeModeStore.new("s1").mode
  end

  def test_persists_answer_for_ask_user_question
    MergeModeRecord.new(event("AskUserQuestion")).call
    assert_equal "Admin bypass", MergeModeStore.new("s1").mode
  end
end

class SessionStartTest < Minitest::Test
  include TempHome

  def directive(session_id)
    io = StringIO.new
    MergeModeHook.new("session_id" => session_id).emit(io)
    JSON.parse(io.string).dig("hookSpecificOutput", "additionalContext")
  end

  def test_asks_when_no_mode_persisted
    assert_includes directive("s1"), "AskUserQuestion"
  end

  def test_restates_when_mode_persisted
    MergeModeStore.new("s1").write("Local only")
    assert_includes directive("s1"), "Local only"
  end

  # Guards the cross-file contract: the header the directive tells the model to
  # use must equal the header the recorder matches on, or recording silently breaks.
  def test_ask_directive_uses_the_header_the_recorder_matches
    assert_includes directive("unset"), MergeModeAnswer::HEADER
  end
end

class MergeModeRestateTest < Minitest::Test
  include TempHome

  def emitted(session_id)
    io = StringIO.new
    MergeModeRestate.new("session_id" => session_id).emit(io)
    io.string
  end

  def test_emits_nothing_when_no_mode
    assert_empty emitted("s1")
  end

  def test_emits_active_mode_when_set
    MergeModeStore.new("s1").write("Merge ready")
    context = JSON.parse(emitted("s1")).dig("hookSpecificOutput", "additionalContext")
    assert_includes context, "Merge ready"
  end
end
