# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/plan_check"

# Pins full auto as the default across the seven skills that used to ask
# for sign-off: each documents --signoff as the opt-in, and none keeps the
# old "unless the invocation said to" escape hatches.
class FullAutoDefaultTest < Minitest::Test
  SKILLS = File.expand_path("../skills", __dir__)
  DEFAULT_SKILLS = %w[code-review drive resolve-threads sweep qa screenshot testcases].freeze
  RETIRED = [
    "proceed automatically",
    "post automatically",
    "Never post without an explicit go-ahead",
    "Write the file only on an explicit answer",
    "Header: \"Sign-off\"",
    "in its own Full auto mode"
  ].freeze

  def skill_md(name) = File.read(File.join(SKILLS, name, "SKILL.md"))

  def test_every_skill_documents_signoff
    DEFAULT_SKILLS.each { |name| assert_includes skill_md(name), "--signoff", name }
  end

  def test_no_skill_keeps_a_retired_escape_hatch
    DEFAULT_SKILLS.each do |name|
      RETIRED.each { |phrase| refute_includes skill_md(name), phrase, "#{name}: #{phrase}" }
    end
  end

  def test_full_auto_words_are_answered_as_already_default
    (DEFAULT_SKILLS - %w[sweep]).each do |name|
      assert_includes skill_md(name), "already the default", name
    end
  end

  def test_destructive_asks_are_untouched
    assert_includes File.read(File.join(SKILLS, "prune", "SKILL.md")), "AskUserQuestion"
    assert_includes skill_md("sweep"), "sweep_trust_store.rb"
  end

  def test_skill_prose_is_free_of_slop_glyphs
    DEFAULT_SKILLS.each do |name|
      Dir.glob(File.join(SKILLS, name, "**", "*.md")).each do |path|
        refute_match PlanCheck::GLYPHS, File.read(path), path
      end
    end
  end
end
