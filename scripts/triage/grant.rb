# frozen_string_literal: true

require 'time'
require_relative 'paths'

module Triage
  # The grant a dispatch carries (C6): the phone-approved autopilot receipt id,
  # the repo, the machine, the unit, the verb and the expiry. The merge and tag
  # guards and the autopilot ledger enforce the receipt at mutation time; the
  # prompt is not the boundary. Unreadable approval state means no grant.
  class Grant
    # Verbs triage may start: the next unit, and the three reversible stack
    # recoveries. Anything else escalates.
    VERBS = %w[start_next takeover redrive rewatch].freeze

    Value = Struct.new(:receipt_id, :repo, :machine, :unit, :verb, :expires_at, keyword_init: true) do
      def to_h = { 'receipt_id' => receipt_id, 'repo' => repo, 'machine' => machine, 'unit' => unit, 'verb' => verb,
                   'expires_at' => expires_at.utc.iso8601 }

      def self.from(hash)
        new(receipt_id: hash['receipt_id'], repo: hash['repo'], machine: hash['machine'], unit: hash['unit'],
            verb: hash['verb'], expires_at: Time.iso8601(hash['expires_at']))
      end

      def expired?(now) = expires_at <= now
    end

    # `reader.call(path)` returns the active autopilots for a checkout (each
    # responds to id and expires_at); the default reads the receipt store, which
    # already scopes them to that checkout's project and this machine.
    def self.default_reader
      lambda do |path|
        require_relative '../change_autopilot'
        ChangeAutopilot.new(project: path).active
      end
    end

    def initialize(reader: self.class.default_reader, machine: Paths.host)
      @reader = reader
      @machine = machine
    end

    # The Value for this repo, unit and verb, or nil: no receipt, an expired
    # one, an unknown verb, no machine, or any error reading approval state.
    def for(repo:, path:, unit:, verb:, now:)
      return nil unless @machine && VERBS.include?(verb) && path

      active = Array(@reader.call(path)).select { |auto| auto.expires_at > now }.max_by(&:expires_at)
      active && Value.new(receipt_id: active.id, repo: repo, machine: @machine, unit: unit, verb: verb, expires_at: active.expires_at)
    rescue StandardError
      nil
    end

    # Re-check just before spawn: the same receipt must still be active for the
    # checkout, and the value still bound to this machine and a known verb.
    def still_valid?(value, path:, now:)
      return false if value.expired?(now) || value.machine != @machine || !VERBS.include?(value.verb)

      Array(@reader.call(path)).any? do |auto|
        auto.id == value.receipt_id && auto.expires_at > now
      end
    rescue StandardError
      false
    end
  end
end
