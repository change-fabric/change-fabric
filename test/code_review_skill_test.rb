#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/plan_check"

# Guards cf:code-review's full auto default and its second-round rule. A
# second round by the same authenticated user posts one consolidated
# root-cause review instead of more inline comments; these checks keep the
# skill wired to thread_history.rb and the round renderer, and keep the
# Workflow script carrying the cf name.
class CodeReviewSkillTest < Minitest::Test
  SKILL = File.expand_path("../skills/code-review", __dir__)
  WORKFLOW = File.join(SKILL, "reference", "workflow.js")
  SECOND_ROUND = File.join(SKILL, "reference", "second-round.md")

  def workflow = File.read(WORKFLOW)

  def skill_md = File.read(File.join(SKILL, "SKILL.md"))

  def second_round = File.read(SECOND_ROUND)

  def test_workflow_carries_the_cf_name
    refute_match(/pst:|pst-/, workflow)
    assert_equal "cf-code-review-scope", workflow[/^\s*name: "([^"]+)"/, 1]
  end

  # This script opens only the Shard phase with phase(); the later phases are
  # named per agent call through the phase option, so the check is that every
  # name used is a meta title and every meta title is used.
  def test_phase_names_match_meta_titles
    titles = workflow[/export const meta = \{.*?\n\}/m].scan(/title: "([^"]+)"/).flatten
    calls = workflow.scan(/phase\("([^"]+)"\)/).flatten.uniq
    options = workflow.scan(/phase: "([^"]+)"/).flatten.uniq
    assert_empty calls - titles, "phase() calls missing from meta.phases"
    assert_empty options - titles, "phase options missing from meta.phases"
    assert_equal titles.sort, (calls | options).sort, "every meta.phases title must be used"
  end

  def test_workflow_passes_the_contract_checks
    lines = []
    assert PlanCheck.check_determinism(workflow, lines), lines.join("\n")
    refute_match PlanCheck::GLYPHS, workflow
  end

  def test_skill_defaults_to_posting_and_reads_the_review_round
    assert_includes skill_md, "--signoff"
    assert_includes skill_md, "thread_history.rb"
    assert_includes skill_md, "second-round.md"
    assert_includes skill_md, "reviewRound.secondRound"
    refute_includes skill_md, "post automatically"
  end

  def test_second_round_posts_one_consolidated_comment
    text = second_round
    assert_includes text, "render_round_review.rb"
    assert_includes text, "event=COMMENT"
    assert_includes text, "viewer.login"
    assert_includes text, "P1"
    assert_includes text, "Never `REQUEST_CHANGES`"
    assert_equal 1, text.scan("REQUEST_CHANGES").size, "REQUEST_CHANGES only in the Never sentence"
  end

  def test_reference_prose_is_free_of_slop_glyphs
    Dir.glob(File.join(SKILL, "**", "*.md")).each do |path|
      refute_match PlanCheck::GLYPHS, File.read(path), path
    end
  end
end
