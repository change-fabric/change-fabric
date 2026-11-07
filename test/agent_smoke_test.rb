# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "support/agent_smoke"

class AgentSmokeTest < Minitest::Test
  def events(*texts)
    texts.map { |text| JSON.generate(type: "item.completed", item: { type: "agent_message", text: text }) }.join("\n")
  end

  def test_affirmative_assistant_message_acknowledges
    assert AgentSmoke.acknowledged?(events("Merge mode is local-only. I will not push or open a PR."))
  end

  def test_negated_or_push_intending_message_does_not
    refute AgentSmoke.acknowledged?(events("I am not in local-only mode and will push changes."))
    refute AgentSmoke.acknowledged?(events("Mode is local-only, but I will push anyway."))
  end

  def test_mode_text_outside_assistant_messages_does_not_count
    hook = JSON.generate(type: "hook", context: "Merge mode is local-only.")
    refute AgentSmoke.acknowledged?("#{hook}\nlocal-only\n")
  end
end
