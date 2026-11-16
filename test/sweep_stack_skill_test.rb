#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

# Guards cf:sweep stack mode docs: the SKILL.md section, its invocations and
# merge modes, and the stack_watch.rb exit-code contract in the reference.
class SweepStackSkillTest < Minitest::Test
  SKILL = File.expand_path("../skills/sweep", __dir__)

  def skill_md = File.read(File.join(SKILL, "SKILL.md"))
  def stack_md = File.read(File.join(SKILL, "reference", "stack.md"))

  def test_skill_has_stack_mode_section
    assert_match(/^## Stack mode$/, skill_md)
    assert_includes skill_md, "reference/stack.md"
  end

  def test_names_all_three_invocations
    [ skill_md, stack_md ].each do |text|
      assert_includes text, "/cf:sweep stack <plan_dir | #a #b ...>"
      assert_includes text, "/cf:sweep stack resume"
      assert_includes text, "/cf:sweep stack status"
    end
  end

  def test_names_all_three_merge_modes
    %w[merge\ ready admin\ bypass yolo].each do |mode|
      assert_includes skill_md, "| #{mode} |"
      assert_includes stack_md, "### #{mode}"
    end
  end

  def test_lists_every_watcher_exit_code
    require_relative "../scripts/stack_watch"
    codes = StackWatch.constants.map { |c| StackWatch.const_get(c) }.grep(Integer)
    assert_equal [ 0, 2, 3, 4, 5, 6, 7 ], codes.sort
    codes.each { |code| assert_match(/^\| #{code} \|/, stack_md) }
  end

  def test_report_land_and_auto_share_the_loop
    assert_includes stack_md, "Report, land, and auto share this per-PR loop"
    assert_includes stack_md, "Stack mode differs only in where the order comes from"
  end

  def test_stack_mode_claims_before_init_and_releases_at_the_end
    assert_operator stack_md.index("stack_store.rb claim <slug>"), :<, stack_md.index("stack_store.rb init <slug>")
    assert_includes stack_md, "stack_store.rb release\n   <slug>"
    refute_includes stack_md, "clear the store"
    assert_includes stack_md, "advance <slug> --expect <n>"
    assert_includes skill_md, "`stack_store.rb claim` then\n  `stack_store.rb init`"
  end

  def test_rebase_drops_squashed_commits
    assert_includes stack_md, "git rebase --onto origin/<trunk> <parent-old-head> <head>"
    assert_includes stack_md, "gh pr merge <n> --squash --admin"
  end
end
