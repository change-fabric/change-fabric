# frozen_string_literal: true

require_relative "test_helpers"

class RenderFindingCommentTest < Minitest::Test
  def render(finding)
    RenderFindingComment.new(finding).render
  end

  def test_renders_badge_title_and_scenario
    body = render("tier" => "P2", "title" => "Missing pst:ctx row", "scenario" => "It is absent from the table.")
    assert_equal "**🟠 P2 - Missing pst:ctx row**\n\nIt is absent from the table.", body
  end

  def test_uses_the_right_badge_per_tier
    assert_includes render("tier" => "P1", "title" => "t", "scenario" => "s"), "🔴 P1"
    assert_includes render("tier" => "P3", "title" => "t", "scenario" => "s"), "🟢 P3"
  end

  def test_appends_a_fenced_suggestion_block_when_present
    body = render("tier" => "P3", "title" => "t", "scenario" => "s", "suggestion" => "x = 1")
    assert_equal "**🟢 P3 - t**\n\ns\n\n```suggestion\nx = 1\n```", body
  end

  def test_omits_suggestion_block_when_absent
    refute_includes render("tier" => "P3", "title" => "t", "scenario" => "s"), "```suggestion"
  end

  def test_raises_on_unknown_tier
    assert_raises(RuntimeError) { render("tier" => "P4", "title" => "t", "scenario" => "s") }
  end

  def test_drops_suggestion_before_truncating_scenario_when_over_budget
    scenario = "s" * 600
    suggestion = "x" * 600
    body = render("tier" => "P1", "title" => "t", "scenario" => scenario, "suggestion" => suggestion)
    refute_includes body, "```suggestion"
    assert_operator body.length, :<=, RenderFindingComment::CHAR_CAP
  end

  def test_truncates_scenario_with_ellipsis_when_still_over_budget_without_suggestion
    body = render("tier" => "P1", "title" => "t", "scenario" => "s" * 700)
    assert_operator body.length, :<=, RenderFindingComment::CHAR_CAP
    assert body.end_with?("...")
  end
end
