#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "json"

# Pins three cf:drive lane-prompt rules that a downstream quick run broke:
# lanes take their task from the brief (not a relayed mode-toggle command),
# file-editing lanes leave product-copy punctuation to the repo's own
# convention, and cf:change reports missing local infrastructure as an
# environment skip rather than a blocker.
class DriveLanePromptsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  WORKFLOW = File.join(ROOT, "skills/drive/reference/workflow.js")
  HARNESS = File.join(__dir__, "support", "workflow_harness.mjs")
  FIXTURE = File.join(__dir__, "fixtures", "workflow_harness", "drive.json")

  def prompts
    skip "node not available" unless system("node", "--version", out: File::NULL, err: File::NULL)
    return @prompts if @prompts
    out, status = Open3.capture2("node", HARNESS, WORKFLOW, "--fixture", FIXTURE)
    assert status.success?, out
    @prompts = JSON.parse(out).fetch("prompts")
  end

  def lane_prompts
    @lane_prompts ||= prompts.select { |key, _| key.match?(/\Aiteration \d+:cf:/) }
  end

  def test_every_lane_takes_its_task_from_the_brief
    refute_empty lane_prompts
    lane_prompts.each do |key, prompt|
      assert_includes prompt, "Your task is the cf:drive lane brief", key
      assert_includes prompt, "/cf:active", key
    end
  end

  def test_editing_lanes_leave_product_copy_punctuation_alone
    %w[cf:code-review cf:ai-slop cf:refactor].each do |skill|
      prompt = lane_prompts.find { |key, _| key.end_with?(":#{skill}#1") }&.last
      refute_nil prompt, skill
      assert_includes prompt, "target repo's own punctuation convention", skill
    end
  end

  def test_change_lane_treats_missing_infrastructure_as_environment_skip
    source = File.read(WORKFLOW)
    assert_includes source, "no reverse proxy or trusted CA"
    assert_includes source, "'environment:' prefix"
    assert_includes source, "never withhold approval for it alone"
  end
end
