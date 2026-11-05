# frozen_string_literal: true

require_relative "test_helpers"

class PlanJudgeModeTest < Minitest::Test
  ROOT = File.expand_path("../skills/plan", __dir__)
  SKILL = File.read(File.join(ROOT, "SKILL.md"))
  INTERVIEW = File.read(File.join(ROOT, "reference/interview.md"))
  HANDOFF = File.read(File.join(ROOT, "reference/handoff-prompt.md"))
  WRITER = File.read(File.join(ROOT, "reference/research-prompt.md"))
  SUBSECTION = "### Judged decisions (unreviewed)"

  def test_skill_documents_judge_flag_scoped_to_admin_bypass
    assert_includes SKILL, "--judge"
    assert_includes SKILL, "admin-bypass"
    assert_includes SKILL, "merge-ready the human interview always runs"
  end

  def test_interview_carries_ledger_marker_and_judge_protocol
    assert_includes INTERVIEW, "## Judge mode (`--judge`)"
    assert_includes INTERVIEW, "Answered by: judge"
    assert_includes INTERVIEW, "proposer"
  end

  def test_subsection_named_in_skill_interview_and_writer
    [ SKILL, INTERVIEW, WRITER ].each { |text| assert_includes text, SUBSECTION }
  end

  def test_handoff_lists_judged_decisions_as_open
    assert_includes HANDOFF, "{{judged_note}}"
    assert_includes HANDOFF, "open to revisiting"
  end
end
