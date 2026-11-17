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

  def workflow_js = File.read(File.join(SKILL, "reference", "workflow.js"))

  def test_behind_is_eligible_and_rebased_at_head_of_line
    assert_includes workflow_js, '["CLEAN", "HAS_HOOKS", "UNSTABLE", "BEHIND"]'
    row = skill_md[/^\| SW-3 \|.*$/]
    assert_includes row, "CLEAN/HAS_HOOKS/UNSTABLE/BEHIND"
    assert_includes row, "BEHIND is rebased at head of line"
  end

  def test_rebase_then_merge_targets_trunk_only
    assert_includes workflow_js, "(never onto another PR)"
    refute_includes workflow_js, "or on an earlier PR in this order"
  end

  # One PR at a time.

  def section(name) = skill_md[/^#{Regexp.escape(name)}$.*?(?=^## )/m]
  def step7 = skill_md[/^7\. \*\*.*?(?=^8\. )/m]
  def summaries_md = File.read(File.join(SKILL, "reference", "summaries.md"))
  def stack_md = File.read(File.join(SKILL, "reference", "stack.md"))

  def test_one_pr_at_a_time_section_precedes_workflow
    text = skill_md
    assert_operator text.index("## One PR at a time"), :<, text.index("## Workflow")
    body = section("## One PR at a time")
    assert_includes body, "prefers rebase over merge and a linear history"
    assert_includes body, "regardless of"
    assert_includes body, "sweep-<first>-<last>"
    assert_includes body, "Never run cf:change on a PR that is"
    assert_includes body, "At most one write agent per repo"
  end

  def test_no_text_permits_driving_more_than_one_pr_before_a_merge
    refute_includes skill_md, "drives and pushes each queued PR"
    refute_includes skill_md, "on the earlier PR"
    refute_includes skill_md, "Walk `autoMergeQueue` in order. For each"
    assert_includes step7, "no next PR is driven before that"
  end

  def test_step7_merge_ready_hands_off_and_watches
    assert_includes step7, "stack_watch.rb"
    assert_includes step7, "Handoff boundary"
    assert_includes step7, "advance <slug> --expect <n>"
  end

  def test_gate_table_has_head_of_line_row
    row = skill_md[/^\| SW-7 \|.*$/]
    assert_includes row, "head of line"
    assert_includes row, "stack_store.rb set-pr"
    assert_includes row, "queued, untouched"
    assert_match(/Store refuses a transition.*\[SW-7\]/m, section("## Failure modes") || skill_md[/^## Failure modes.*/m])
  end

  def test_summaries_name_head_of_line_and_queued_untouched
    assert_includes summaries_md, "Head of line: <PR absolute URL>, N waiting"
    assert_includes summaries_md, "queued, untouched"
    refute_includes summaries_md, "drive each queued PR"
  end

  def test_handoff_says_squash_or_rebase_only
    assert_includes skill_md, "squash or rebase only, no merge commit"
    assert_includes summaries_md, "squash or\nrebase only, no merge commit"
  end

  def test_linear_history_checks
    body = section("## One PR at a time")
    assert_includes body, "allow_merge_commit"
    assert_includes body, "rev-list\n  --parents -n 1 <oid>"
    assert_includes body, "pause <slug> merge-commit"
  end

  def test_lease_precedes_init_and_trunk_is_resolved_not_main
    body = section("## One PR at a time")
    assert_operator body.index("$S lease <slug>"), :<, body.index("$S init <slug>")
    assert_includes body, "`init` refuses an\n   existing record"
    [ "origin/main", "HEAD:main", "--base main", "fetch origin main" ].each { |s| refute_includes skill_md, s }
  end

  def test_no_merge_commit_method
    [ skill_md, stack_md ].each do |text|
      text.scan(/gh pr merge[^\n`]*/).each { |line| refute_includes line, "--merge" }
    end
    body = section("## One PR at a time")
    assert_includes body, "Squash (the repo rule) or rebase only, never a merge commit"
    assert_includes body, "allows neither squash nor rebase, escalate"
  end

  def test_drive_nested_clause_forbids_rebasing_onto_unmerged_pr
    drive = File.read(File.expand_path("../skills/drive/SKILL.md", __dir__))
    assert_includes drive, "When nested under cf:sweep, a rebase\nis onto trunk only, never onto an unmerged PR"
  end

  def test_principle_states_the_tenet_with_enforcer
    text = File.read(File.expand_path("../PRINCIPLES.md", __dir__))
    body = text[/^## One PR at a time, rebased, linear history$.*?(?=^## )/m]
    assert_includes body, "Enforcer: scripts/stack_store.rb"
    assert_includes body, "prefers rebase\nover merge"
  end

  # Per mode: every mode records or resumes the queue, acts on the head only,
  # advances only on a gh-confirmed merge, and pauses on a watcher failure.

  def shared_loop_contract(text)
    assert_includes text, "claim <slug>"
    assert_includes text, "init <slug>"
    assert_includes text, "Resume table"
    assert_includes text, "set-pr <slug> <n> state=preparing"
    assert_includes text, "Watcher exit 0: confirm via gh"
    assert_match(/Exit 3, 7, or 2: `pause\n?\s*<slug> <reason>`/, text)
    assert_includes text, "No non-zero exit ever moves to the\nnext PR"
    assert_includes text, "must say\n   MERGED"
  end

  def test_report_mode_uses_the_head_of_line_loop
    shared_loop_contract(skill_md)
    assert_includes skill_md[/^- `report`:.*?(?=^- `land`)/m], "head of line"
    assert_includes step7, "`report` under Merge ready"
  end

  def test_land_mode_uses_the_head_of_line_loop
    shared_loop_contract(skill_md)
    assert_includes step7, "`land` and `auto`"
  end

  def test_auto_mode_uses_the_head_of_line_loop
    shared_loop_contract(skill_md)
    assert_includes skill_md[/^- `auto`.*?(?=^`--signoff`)/m], "Merge ready, step 7 drives\nthe head PR"
  end

  def test_loop_mode_resumes_and_never_starts_a_second_queue
    body = section("## Loop mode")
    assert_includes body, "unfinished `sweep-*` record"
    assert_includes body, "never starts a second\nqueue"
    assert_includes body, "The recorded queue wins until it finishes"
  end

  # Resuming keeps the recorded order but never the recorded eligibility: a
  # head whose author became blocked must not be landed unattended.
  def test_a_resumed_head_is_rechecked_against_current_trust
    body = section("## Loop mode")
    assert_includes body, "re-applies the current trust policy"
    assert_includes body, "never prepared or landed unattended"
  end

  def test_failure_modes_cites_the_cap_gate
    section = skill_md[/^## Failure modes.*/m]
    assert_match(/101-PR page.*\[SW-6\]/, section)
  end
end
