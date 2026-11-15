# frozen_string_literal: true

require 'time'

# Pure expiry arithmetic for enrolled keys. Providers do not expose expiry, so
# the date is user-recorded (cf_keys.rb enroll --expires, cf_keys.rb expires)
# and stored as ISO8601 UTC in meta.json. Every comparison is UTC; the clock is
# injected so callers and tests agree on "now".
module CfKeyExpiry
  WINDOW = 24 * 60 * 60
  DATE_ONLY = /\A\d{4}-\d{2}-\d{2}\z/

  module_function

  # A bare date means 00:00 UTC that day; anything else must be full ISO8601.
  # Raises ArgumentError on anything it cannot read.
  def parse(text)
    value = text.to_s.strip
    time = value.match?(DATE_ONLY) ? Time.iso8601("#{value}T00:00:00Z") : Time.iso8601(value)
    time.utc
  rescue ArgumentError, TypeError
    raise ArgumentError, "not an ISO8601 date: #{text.inspect}"
  end

  # :ok, :warn (within WINDOW of expiry) or :expired. No date, or one that no
  # longer parses, is :ok: an unreadable record never blocks a paid call.
  def state(expires_at, now: Time.now)
    time = coerce(expires_at)
    return :ok unless time

    remaining = time - now.utc
    return :expired if remaining <= 0
    return :warn if remaining <= WINDOW

    :ok
  end

  # Whole days left, rounded down; negative once passed. nil without a date.
  def days_remaining(expires_at, now: Time.now)
    time = coerce(expires_at)
    time && ((time - now.utc) / 86_400).floor
  end

  def coerce(value)
    return value.utc if value.is_a?(Time)
    return nil if value.nil? || value.to_s.empty?

    parse(value)
  rescue ArgumentError
    nil
  end
end
