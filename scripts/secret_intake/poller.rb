# frozen_string_literal: true

module SecretIntake
  # Polls a block until it returns true or the deadline passes. The clock and
  # sleeper are injected so tests run a timeout without waiting.
  class Poller
    INTERVAL = 3

    def initialize(clock: -> { Time.now }, sleeper: ->(seconds) { sleep(seconds) }, interval: INTERVAL)
      @clock, @sleeper, @interval = clock, sleeper, interval
    end

    # True when the block reported arrival, false on timeout.
    def wait(deadline)
      loop do
        return true if yield
        return false if @clock.call >= deadline

        @sleeper.call(@interval)
      end
    end
  end
end
