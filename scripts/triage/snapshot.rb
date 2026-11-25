# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require_relative 'command'
require_relative 'heartbeat'

module Triage
  # Contract C3. Each host publishes `snapshot.json` by write-then-rename: host
  # id, generation, timestamp, its repos' state with their assignment and
  # assignment_version, its heartbeat and its decision items (ids and content,
  # not counts). The mini pulls the other host's snapshot read-only over SSH
  # with a 10 second bound; an unreachable, unreadable or older-than-two-ticks
  # snapshot reads `stale`. A remote snapshot is report-only.
  module Snapshot
    PULL_TIMEOUT = 10
    REMOTE_PATH = '~/.claude/cf/triage/snapshot.json'

    Pulled = Struct.new(:status, :snapshot, :reason, keyword_init: true)

    # `report` is the full report hash; only this host's pinned repos and its
    # decisions are carried, so a snapshot never speaks for the other host.
    def self.build(host:, generation:, now:, report:, host_map:, heartbeat_at: now)
      mine = host_map.entries.select { |entry| entry.host == host }.map(&:repo)
      units = report.fetch('units').select { |unit| mine.include?(unit['repo']) }
      {
        'host' => host, 'generation' => generation, 'generated_at' => now.utc.iso8601,
        'heartbeat_at' => heartbeat_at.utc.iso8601,
        'repos' => host_map.entries.select { |entry| entry.host == host }.map do |entry|
          { 'repo' => entry.repo, 'assignment' => entry.host, 'assignment_version' => entry.version,
            'units' => units.select { |unit| unit['repo'] == entry.repo }.map { |unit| slim(unit) } }
        end,
        'decisions' => report.fetch('decisions').select { |item| item['host'].nil? || item['host'] == host },
        'inbox' => { 'decisions' => report.fetch('decisions').size }
      }
    end

    def self.slim(unit)
      unit.slice('unit', 'state', 'percent', 'next_step', 'prs')
    end

    # Write-then-rename in the destination directory, so a reader sees the old
    # file or the new one and never a partial. Raises on failure with the old
    # file untouched.
    def self.write_atomic(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.#{Process.pid}.tmp"
      File.write(tmp, data)
      File.rename(tmp, path)
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
    end

    def self.read(path)
      data = JSON.parse(File.read(path))
      valid?(data) ? data : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def self.valid?(data)
      data.is_a?(Hash) && data['host'].is_a?(String) && data['generation'].is_a?(Integer) &&
        data['repos'].is_a?(Array) && data['decisions'].is_a?(Array) && parse_time(data['generated_at'])
    end

    def self.parse_time(text) = text.is_a?(String) ? Time.iso8601(text) : nil
    private_class_method :parse_time

    # Read-only pull of the other host's snapshot. Never raises.
    def self.pull(ssh_target, runner: Command.method(:run), timeout: PULL_TIMEOUT)
      argv = [ 'ssh', '-o', 'BatchMode=yes', '-o', "ConnectTimeout=#{timeout}", ssh_target, "cat #{REMOTE_PATH}" ]
      result = runner.call(argv, timeout)
      unless result.ok
        return Pulled.new(status: 'unreachable', snapshot: nil,
                          reason: result.timed_out ? "timed out after #{timeout}s" : result.err.to_s.strip)
      end

      data = JSON.parse(result.out)
      return Pulled.new(status: 'invalid', snapshot: nil, reason: 'snapshot failed validation') unless valid?(data)

      Pulled.new(status: 'ok', snapshot: data, reason: nil)
    rescue JSON::ParserError => e
      Pulled.new(status: 'invalid', snapshot: nil, reason: "bad json (#{e.message.lines.first.to_s.strip})")
    end

    # 'fresh' or 'stale' by the snapshot's own timestamp.
    def self.freshness(snapshot, now)
      age = now - Time.iso8601(snapshot['generated_at'])
      age > Heartbeat::STALE_AFTER ? 'stale' : 'fresh'
    end
  end
end
