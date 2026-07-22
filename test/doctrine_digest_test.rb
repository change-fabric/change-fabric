# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/doctrine_digest"

class DoctrineDigestTest < Minitest::Test
  include SkillTempHome

  def emit(session_id)
    io = StringIO.new
    DoctrineDigest.new("session_id" => session_id).emit(io)
    io.string
  end

  def context(session_id)
    out = emit(session_id)
    out.empty? ? nil : JSON.parse(out).dig("hookSpecificOutput", "additionalContext")
  end

  def test_injects_the_containerize_and_slop_tenets
    text = context("sess-1")
    assert_includes text, "Containerize project services"
    assert_includes text, "host or system-level daemon"
    assert_includes text, "AI-slop"
  end

  def test_injects_the_pr_length_tenet
    text = context("sess-pr")
    assert_includes text, "PR titles"
    assert_includes text, "60 char"
    assert_includes text, "640 char"
    assert_includes text, "bona fide reason"
  end

  def test_marks_session_start_event
    out = emit("sess-2")
    assert_equal "SessionStart", JSON.parse(out).dig("hookSpecificOutput", "hookEventName")
  end

  def test_announces_once_per_session
    refute_nil context("sess-3"), "first start injects the digest"
    assert_nil context("sess-3"), "a second start in the same session stays silent"
  end

  def test_a_new_session_announces_again
    refute_nil context("sess-a")
    refute_nil context("sess-b")
  end

  def test_blank_session_still_emits_without_recording
    # A non-persistable session id cannot dedup, but the digest must still surface.
    refute_nil context("")
  end
end
