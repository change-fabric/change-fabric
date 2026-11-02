# frozen_string_literal: true

require_relative "test_helpers"

class PlanHandoffPromptTest < Minitest::Test
  REFERENCE = File.expand_path("../skills/plan/reference", __dir__)
  PROMPT = File.read(File.join(REFERENCE, "handoff-prompt.md"))
  TEMPLATE = File.read(File.join(REFERENCE, "workflow-template.js"))

  def test_prompt_runs_end_to_end_by_default
    refute_includes PROMPT, "Do not run the whole workflow end to end unsupervised"
    assert_includes PROMPT, "Run the whole workflow end to end in one Workflow call"
  end

  def test_prompt_keeps_failure_stop_and_only_opt_in
    assert_includes PROMPT, "stops on its own when a phase fails verification"
    assert_includes PROMPT, "only"
  end

  def test_template_accepts_only_arg
    assert_match(/const only = Array\.isArray\(input\.only\)/, TEMPLATE)
    assert_includes TEMPLATE, "!only.includes(spec.title)"
  end
end
