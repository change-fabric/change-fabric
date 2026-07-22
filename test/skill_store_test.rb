# frozen_string_literal: true

require_relative "test_helpers"

class SkillStoreTest < Minitest::Test
  include SkillTempHome

  def test_fresh_returns_unrecorded_then_marks_them
    store = SkillStore.new("s1")
    assert_equal %w[a b], store.fresh(%w[a b])
    store.mark(%w[a])
    assert_equal %w[b], store.fresh(%w[a b])
  end

  def test_keys_are_independent
    SkillStore.new("s1", "surfaced").mark(%w[a])
    assert_equal %w[a], SkillStore.new("s1", "announced").fresh(%w[a])
  end

  def test_record_is_newline_terminated_and_separated
    SkillStore.new("s1").mark(%w[ruby])
    SkillStore.new("s1").mark(%w[refactoring])
    path = File.join(@home, ".claude", "cf", "sessions", "s1", "skills-surfaced")
    assert_equal "ruby\nrefactoring\n", File.read(path)
  end

  def test_blank_session_never_persists
    store = SkillStore.new("")
    store.mark(%w[a])
    assert_equal %w[a], store.fresh(%w[a])
    assert_empty Dir.glob(File.join(@home, ".claude", "cf", "sessions", "**", "*"))
  end
end
