#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

# Guards cf:sweep's PR-list cap: a bare sweep must never compute a landing
# order from a truncated `gh pr list`, since the order is only correct when
# every open PR was seen. With more than 100 open PRs, gh pr list silently
# truncates at the limit it is given, so the limit requested here has to be
# one higher than the cap to make a full page detectable at all.
class SweepSkillTest < Minitest::Test
  SKILL = File.expand_path("../skills/sweep", __dir__)
  SKILL_MD = File.join(SKILL, "SKILL.md")

  def skill_md = File.read(SKILL_MD)

  def test_pr_list_is_fetched_one_above_the_cap
    assert_includes skill_md, "gh pr list --state open --limit 101"
    refute_includes skill_md, "--limit 100"
  end

  def test_hitting_the_cap_forces_report_mode_and_holds_every_pr
    text = skill_md
    assert_includes text, "Drop mode to `report`"
    assert_includes text, "hold every PR gathered"
    assert_includes text, "[SW-6]"
  end

  def test_gate_table_has_the_cap_row
    assert_includes skill_md, "| SW-6 |"
    row = skill_md[/^\| SW-6 \|.*$/]
    assert_match(/101/, row)
    assert_match(/report/i, row)
  end

  def test_failure_modes_cites_the_cap_gate
    section = skill_md[/^## Failure modes.*/m]
    assert_match(/101-PR page.*\[SW-6\]/, section)
  end
end
