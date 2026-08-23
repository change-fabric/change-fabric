#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"

SCRIPTS = File.expand_path("../scripts", __dir__) unless defined?(SCRIPTS)
require_relative "#{SCRIPTS}/hook_event"
require_relative "#{SCRIPTS}/merge_mode_slug"
require_relative "#{SCRIPTS}/guarded_command"
require_relative "#{SCRIPTS}/merge_mode_answer"
require_relative "#{SCRIPTS}/merge_mode_store"
require_relative "#{SCRIPTS}/away_store"
require_relative "#{SCRIPTS}/away_answer"
require_relative "#{SCRIPTS}/merge_mode_record"
require_relative "#{SCRIPTS}/merge_mode_restate"
require_relative "#{SCRIPTS}/merge_mode_guard"
require_relative "#{SCRIPTS}/session_start"

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

class MergeModeSlugTest < Minitest::Test
  def test_normalizes_every_legacy_label
    assert_equal "local-only", MergeModeSlug.of("Local only")
    assert_equal "merge-ready", MergeModeSlug.of("Merge ready")
    assert_equal "admin-bypass", MergeModeSlug.of("Admin bypass")
    assert_equal "yolo", MergeModeSlug.of("Yolo")
  end

  def test_identity_when_already_a_slug
    assert_equal "local-only", MergeModeSlug.of("local-only")
    assert_equal "merge-ready", MergeModeSlug.of("merge-ready")
    assert_equal "admin-bypass", MergeModeSlug.of("admin-bypass")
    assert_equal "yolo", MergeModeSlug.of("yolo")
  end

  def test_strips_trailing_parenthetical_hint
    assert_equal "admin-bypass", MergeModeSlug.of("Admin bypass (recommended)")
  end

  def test_tolerates_mixed_whitespace
    assert_equal "merge-ready", MergeModeSlug.of("  Merge ready  ")
    assert_equal "local-only", MergeModeSlug.of("\tLocal only\n")
  end

  def test_nil_for_garbage
    assert_nil MergeModeSlug.of("Bogus mode")
    assert_nil MergeModeSlug.of("something else entirely")
  end

  def test_nil_for_nil_input
    assert_nil MergeModeSlug.of(nil)
  end
end

class MergeModeStoreTest < Minitest::Test
  include TempHome

  def test_mode_is_nil_when_nothing_persisted
    assert_nil MergeModeStore.new("s1").mode
  end

  def test_write_then_read_round_trips_stripped
    MergeModeStore.new("s1").write("Merge ready")
    assert_equal "merge-ready", MergeModeStore.new("s1").mode
  end

  def test_blank_session_id_does_not_persist
    store = MergeModeStore.new("")
    store.write("Merge ready")
    assert_nil store.mode
    assert_empty Dir.glob(File.join(@home, ".claude", "cf", "sessions", "**", "*"))
  end

  def test_rewrite_overwrites_previous_mode
    MergeModeStore.new("s1").write("Local only")
    MergeModeStore.new("s1").write("Admin bypass")
    assert_equal "admin-bypass", MergeModeStore.new("s1").mode
  end

  def test_unrecognized_value_is_not_written
    store = MergeModeStore.new("s1")
    store.write("Bogus mode")
    assert_nil store.mode
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
      "questions" => [ { "question" => "How should I handle changes from this session?",
                        "header" => "Merge mode" } ],
      "answers" => { "How should I handle changes from this session?" => answer }
    }
  end

  def test_extracts_label_from_real_payload
    assert_equal "Merge ready", MergeModeAnswer.new(real_response("Merge ready")).label
  end

  def test_ignores_questions_without_merge_mode_header
    response = {
      "questions" => [ { "question" => "Pick a color", "header" => "Color" } ],
      "answers" => { "Pick a color" => "blue" }
    }
    assert_nil MergeModeAnswer.new(response).label
  end

  def test_nil_for_non_hash_or_missing_answer
    assert_nil MergeModeAnswer.new(nil).label
    assert_nil MergeModeAnswer.new(real_response("")).label
  end
end

class GuardedCommandTest < Minitest::Test
  def violation(command, mode, branch: nil)
    GuardedCommand.new(command, mode, branch: branch).violation
  end

  def test_local_only_flags_push_and_merge
    assert_equal "git push", violation("git push origin main", "local-only")
    assert_equal "gh pr merge", violation("gh pr merge --squash", "local-only")
  end

  def test_merge_ready_flags_merge
    assert_equal "gh pr merge", violation("gh pr merge --admin", "merge-ready")
  end

  def test_merge_ready_allows_pushing_a_feature_branch
    assert_nil violation("git push origin my-feature", "merge-ready", branch: "my-feature")
    assert_nil violation("git push -u origin my-feature", "merge-ready", branch: "my-feature")
  end

  def test_merge_ready_flags_explicit_push_to_trunk
    assert_equal "a direct push to the trunk", violation("git push origin main", "merge-ready")
    assert_equal "a direct push to the trunk", violation("git push origin master", "merge-ready")
    assert_equal "a direct push to the trunk", violation("git push -u origin main", "merge-ready")
    assert_equal "a direct push to the trunk", violation("git push origin HEAD:main", "merge-ready")
  end

  def test_merge_ready_flags_bare_push_while_on_trunk
    assert_equal "a direct push to the trunk", violation("git push", "merge-ready", branch: "main")
    assert_equal "a direct push to the trunk", violation("git push origin", "merge-ready", branch: "main")
    assert_equal "a direct push to the trunk", violation("git push origin HEAD", "merge-ready", branch: "main")
  end

  def test_merge_ready_allows_bare_push_while_on_feature_branch
    assert_nil violation("git push", "merge-ready", branch: "my-feature")
    assert_nil violation("git push origin", "merge-ready", branch: "my-feature")
  end

  def test_admin_bypass_flags_nothing
    assert_nil violation("git push origin main", "admin-bypass")
    assert_nil violation("gh pr merge --admin", "admin-bypass")
  end

  def test_yolo_allows_push_to_trunk
    assert_nil violation("git push origin main", "yolo")
    assert_nil violation("git push", "yolo", branch: "main")
  end

  def test_yolo_flags_pr_create_but_allows_merge
    assert_equal "gh pr create", violation("gh pr create --fill", "yolo")
    assert_nil violation("gh pr merge --squash", "yolo")
  end

  def test_unknown_mode_falls_back_to_merge_ready
    assert_equal "a direct push to the trunk", violation("git push origin main", "Bogus mode")
  end

  def test_matches_on_word_boundaries_only
    assert_nil violation("git pushups", "local-only")
    assert_nil violation("legit-push helper", "local-only")
  end

  def test_handles_non_string_command
    assert_nil violation(nil, "local-only")
  end

  def test_ignores_merge_phrase_inside_quoted_prose
    command = 'gh pr edit 5 --body "run gh pr merge only after ci"'
    assert_nil violation(command, "local-only")
  end
end

class MergeModeRecordTest < Minitest::Test
  include TempHome

  def event(tool_name)
    {
      "session_id" => "s1",
      "tool_name" => tool_name,
      "tool_response" => {
        "questions" => [ { "question" => "q", "header" => "Merge mode" } ],
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
    assert_equal "admin-bypass", MergeModeStore.new("s1").mode
  end

  def two_question_event
    {
      "session_id" => "s1",
      "tool_name" => "AskUserQuestion",
      "tool_response" => {
        "questions" => [
          { "question" => "merge-q", "header" => "Merge mode" },
          { "question" => "away-q", "header" => "Away mode" }
        ],
        "answers" => { "merge-q" => "Merge ready", "away-q" => "Away" }
      }
    }
  end

  def test_persists_both_answers_from_a_two_question_payload
    MergeModeRecord.new(two_question_event).call
    assert_equal "merge-ready", MergeModeStore.new("s1").mode
    assert AwayStore.new("s1").away?
  end
end

class MergeModeGuardTest < Minitest::Test
  include TempHome

  def decision(command:, mode:, tool: "Bash")
    MergeModeStore.new("s1").write(mode) if mode
    io = StringIO.new
    event = { "session_id" => "s1", "tool_name" => tool, "tool_input" => { "command" => command } }
    MergeModeGuard.new(event).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string).dig("hookSpecificOutput", "permissionDecision")
  end

  def test_local_only_denies_push
    assert_equal "deny", decision(command: "git push origin main", mode: "local-only")
  end

  def test_local_only_denies_merge
    assert_equal "deny", decision(command: "gh pr merge --squash", mode: "local-only")
  end

  def test_merge_ready_allows_feature_push_but_denies_merge
    assert_nil decision(command: "git push origin my-feature", mode: "merge-ready")
    assert_equal "deny", decision(command: "gh pr merge --admin", mode: "merge-ready")
  end

  def test_merge_ready_denies_explicit_push_to_trunk
    assert_equal "deny", decision(command: "git push origin main", mode: "merge-ready")
  end

  def test_admin_bypass_allows_everything
    assert_nil decision(command: "gh pr merge --admin", mode: "admin-bypass")
    assert_nil decision(command: "git push origin main", mode: "admin-bypass")
  end

  def test_yolo_allows_trunk_push_and_pr_merge_but_denies_pr_create
    assert_nil decision(command: "git push origin main", mode: "yolo")
    assert_nil decision(command: "gh pr merge --squash", mode: "yolo")
    assert_equal "deny", decision(command: "gh pr create --fill", mode: "yolo")
  end

  def test_ignores_non_bash_tools
    assert_nil decision(command: "git push", mode: "local-only", tool: "Edit")
  end

  def test_unset_mode_is_guarded_as_merge_ready
    assert_equal "deny", decision(command: "git push origin main", mode: nil)
  end
end

class SessionStartTest < Minitest::Test
  include TempHome

  def directive(session_id)
    io = StringIO.new
    MergeModeHook.new("session_id" => session_id).emit(io)
    JSON.parse(io.string).dig("hookSpecificOutput", "additionalContext")
  end

  def test_states_the_merge_ready_fallback_when_nothing_persisted
    assert_includes directive("s1"), "merge-ready"
    refute_includes directive("s1"), "AskUserQuestion"
  end

  def test_restates_when_mode_persisted
    MergeModeStore.new("s1").write("Local only")
    assert_includes directive("s1"), "local-only"
  end

  def test_states_away_mode_when_active
    AwayStore.new("s1").write(AwayStore::AWAY)
    assert_includes directive("s1"), "Away mode is active"
  end

  def test_omits_away_statement_when_not_away
    refute_includes directive("s1"), "Away mode"
  end
end

# Guards the cross-file contract: /cf's question headers must equal the
# headers the recorders match on, or recording silently breaks.
class CfSkillHeaderContractTest < Minitest::Test
  def skill_text
    @skill_text ||= File.read(File.expand_path("../skills/cf/SKILL.md", __dir__))
  end

  def test_skill_carries_both_answer_headers
    assert_includes skill_text, MergeModeAnswer::HEADER
    assert_includes skill_text, AwayAnswer::HEADER
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
    assert_includes context, "merge-ready"
  end
end
