# frozen_string_literal: true

require_relative "../../scripts/change_autopilot"

# Stands in for an open (or absent) autopilot at the guards' one seam,
# ChangeAutopilot.waive!, and records each call. The real reader is covered
# end to end in change_autopilot_test.rb. No minitest/mock in this bundle.
module AutopilotStub
  def with_autopilot(id = "a" * 64)
    calls = []
    original = ChangeAutopilot.method(:waive!)
    ChangeAutopilot.define_singleton_method(:waive!) do |gate, **row|
      calls << [ gate, row ]
      id
    end
    yield calls
  ensure
    ChangeAutopilot.define_singleton_method(:waive!, original)
  end
end
