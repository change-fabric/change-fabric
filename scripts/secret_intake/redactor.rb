# frozen_string_literal: true

module SecretIntake
  # Scrubs registered values (a staged secret, the signed PUT URL and its
  # signature) from any message before it is printed. The page GET URL is
  # printed once on purpose and is never routed through here.
  class Redactor
    MASK = '[redacted]'
    MIN_LENGTH = 4

    def initialize
      @values = []
    end

    def add(value)
      text = value.to_s
      return self if text.strip.length < MIN_LENGTH

      @values = (@values | [ text, text.strip ]).sort_by { |v| -v.length }
      self
    end

    def scrub(message)
      @values.reduce(message.to_s) { |text, value| text.gsub(value, MASK) }
    end
  end
end
