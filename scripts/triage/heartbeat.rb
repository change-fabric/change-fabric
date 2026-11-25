# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'

module Triage
  # One small file per host under heartbeat/<host>.json, written by that host's
  # tick. A host whose heartbeat is older than two ticks (30 minutes) reads as
  # stale; one with no heartbeat reads as missing. No failover in v1.
  module Heartbeat
    TICK = 900
    STALE_AFTER = 2 * TICK

    def self.write(dir, host, now:, generation: nil)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{host}.json")
      tmp = "#{path}.#{Process.pid}.tmp"
      File.write(tmp, JSON.generate('host' => host, 'at' => now.utc.iso8601, 'generation' => generation))
      File.rename(tmp, path)
      path
    end

    # { host => { 'at' => Time, 'generation' => Integer|nil } }, skipping any
    # file that is unreadable or not a heartbeat.
    def self.read_all(dir)
      Dir.glob(File.join(dir, '*.json')).sort.each_with_object({}) do |file, memo|
        data = JSON.parse(File.read(file))
        memo[File.basename(file, '.json')] = { 'at' => Time.iso8601(data['at']), 'generation' => data['generation'] }
      rescue JSON::ParserError, ArgumentError, TypeError, SystemCallError
        next
      end
    end

    def self.age(entry, now) = entry ? (now - entry['at']).to_i : nil

    def self.status(entry, now)
      return 'missing' unless entry

      age(entry, now) > STALE_AFTER ? 'stale' : 'fresh'
    end
  end
end
