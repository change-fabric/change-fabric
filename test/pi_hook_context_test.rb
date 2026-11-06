# frozen_string_literal: true

require "minitest/autorun"

# Every Pi handler that calls a CF hook must forward the hook's nonblocking
# additionalContext, or a warning such as the review cap is silently dropped.
class PiHookContextTest < Minitest::Test
  SOURCE = File.read(File.expand_path("../extensions/pi-cf-hooks/index.ts", __dir__))
  HANDLERS = %w[input before_agent_start agent_end tool_call tool_result].freeze

  def handler_body(event)
    start = SOURCE.index("pi.on(\"#{event}\"")
    refute_nil start, "missing Pi handler #{event}"
    stop = SOURCE.index("pi.on(", start + 1) || SOURCE.length
    SOURCE[start...stop]
  end

  HANDLERS.each do |event|
    define_method(:"test_#{event}_forwards_additional_context") do
      assert_includes handler_body(event), "additionalContext", "#{event} drops nonblocking hook context"
    end
  end

  def test_every_hook_calling_handler_is_enumerated
    used = SOURCE.scan(/pi\.on\("(\w+)", async \(\w+, ctx\) => \{\n\s+const result = await callHook/).flatten
    assert_empty used - HANDLERS, "new hook-calling Pi handler must be added to HANDLERS"
  end

  # The input hook sees the prompt (an away plan refusal); before_agent_start
  # does not, so the input context has to reach the system prompt from there.
  def test_input_context_reaches_the_system_prompt
    assert_match(/inputContext = result\.hookSpecificOutput/, handler_body("input"))
    assert_match(/inputContext/, handler_body("before_agent_start"))
  end

  def test_agent_end_notice_does_not_start_a_turn
    assert_match(/deliverAs: "nextTurn"/, handler_body("agent_end"))
  end
end
