#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

# Parse a hook event from stdin. Hooks fire on every event, so a bad or
# unexpected payload must fail silent (empty event), never crash the session.
module HookEvent
  def self.read(io = $stdin)
    raw = io.read.to_s
    return {} if raw.empty?

    parsed = JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end
end
