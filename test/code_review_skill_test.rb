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
    assert_includes text, '"event": "COMMENT"'
    assert_includes text, "viewer.login"
    assert_includes text, "P1"
    assert_includes text, "Never `REQUEST_CHANGES`"
    assert_equal 1, text.scan("REQUEST_CHANGES").size, "REQUEST_CHANGES only in the Never sentence"
  end

  # `gh api --input` turns every -f/-F field into a URL query parameter, so
  # a review event passed that way never reaches the JSON body and the
  # review stays pending. Every review-posting doc must keep event in JSON.
  def test_review_event_never_rides_a_field_flag_beside_input
    docs = [ skill_md, second_round ]
    flag = /(?:-f|-F|--field|--raw-field)\s+event=/
    docs.each do |text|
      refute_match flag, text
      assert_includes text, '"event": "COMMENT"'
    end
    [ "-f event=COMMENT", "-F event=COMMENT", "--field event=COMMENT",
      "--raw-field event=COMMENT" ].each { |variant| assert_match flag, variant }
  end

  # A GitHub REST route under pulls/<n>/reviews/<x> or pulls/<n>/comments/<x>
  # takes an integer database id; thread_history.rb's `id`, `threadId` and
  # `reviewId` are GraphQL node ids, which those routes reject. Every
  # placeholder a doc hands such a route must name a database id field.
  REST_ID_ROUTE = %r{pulls/<n>/(?:reviews|comments)/\s*<([^>]+)>}
  REST_ID_OK = %w[databaseId review_id commentId].freeze

  def test_rest_review_routes_take_a_database_id_never_a_node_id
    docs = Dir.glob(File.expand_path("../skills/{code-review,resolve-threads,drive}/**/*.md", __dir__))
    docs.each do |path|
      File.read(path).scan(REST_ID_ROUTE).flatten.each do |placeholder|
        assert_includes REST_ID_OK, placeholder, "#{path}: REST route fed <#{placeholder}>"
      end
    end
    assert_includes second_round, "databaseId"
    { "pulls/<n>/reviews/<id>/comments" => "id", "pulls/<n>/reviews/<threadId>" => "threadId",
      "pulls/<n>/comments/\n   <reviewId>/replies" => "reviewId",
      "pulls/<n>/reviews/<review_id>/comments" => "review_id" }.each do |route, expected|
      assert_equal expected, route[REST_ID_ROUTE, 1], route
    end
  end

  def test_reference_prose_is_free_of_slop_glyphs
    Dir.glob(File.join(SKILL, "**", "*.md")).each do |path|
      refute_match PlanCheck::GLYPHS, File.read(path), path
    end
  end
end
