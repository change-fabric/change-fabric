# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require_relative 'paths'

module Triage
  # Usage limits on the Claude CLI (C7), in the `cf_provider_error.rb` style:
  # `quota_exhausted` (a rejected window, no retry until it resets) versus
  # `rate_limited` (a transient 429, bounded retry). A limit gates model
  # dispatch only; report, expiry, inbox and heartbeat keep running.
  #
  # Classification keys off the stream-json frames, never the exit code (the
  # spike could not capture the exit code at a real limit, and 3 of 9 headless
  # runs exited 0 with no result frame). Exit 0 without a result frame is a
  # failure, `no_result`.
  module Limits
    DEFAULT_RESET = 3600
    RATE_LIMIT_RESET = 900
    HIT = /\AYou've hit your |\AYou're out of usage credits|out of usage credits/
    TRANSIENT = /overloaded_error|\b429\b|rate_limit_error/

    Outcome = Struct.new(:klass, :limited_until, :session_id, :detail, keyword_init: true) do
      def ok? = klass == 'ok'
      def limit? = %w[quota_exhausted rate_limited].include?(klass)
    end

    module_function

    # One CLI run -> an Outcome. `now` anchors the default reset.
    def classify(stdout, stderr = '', now: Time.now.utc)
      frames = parse(stdout)
      rejected = frames.find { |f| f['type'] == 'rate_limit_event' && f.dig('rate_limit_info', 'status') == 'rejected' }
      result = frames.reverse.find { |f| f['type'] == 'result' }
      session = (result || frames.find { |f| f['session_id'] } || {})['session_id']
      text = result ? result['result'].to_s : ''
      return quota(rejected, now, session) if rejected || (result && result['is_error'] && text.match?(HIT))
      return outcome('budget_exhausted', session, result['subtype']) if result && result['subtype'] == 'error_max_budget_usd'
      return transient(now, session, text) if (result.nil? || result['is_error']) && "#{text} #{stderr}".match?(TRANSIENT)
      return outcome('no_result', session, 'no result frame') unless result
      return outcome('error', session, text[0, 200]) if result['is_error']

      outcome('ok', session, nil)
    end

    def parse(stdout)
      stdout.to_s.lines.filter_map do |line|
        frame = JSON.parse(line)
        frame if frame.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end
    end

    def outcome(klass, session, detail, limited_until = nil)
      Outcome.new(klass: klass, limited_until: limited_until, session_id: session, detail: detail)
    end

    def quota(rejected, now, session)
      resets = rejected&.dig('rate_limit_info', 'resetsAt')
      reset = resets.is_a?(Numeric) && resets > now.to_i ? Time.at(resets).utc : now + DEFAULT_RESET
      outcome('quota_exhausted', session, rejected ? rejected.dig('rate_limit_info', 'rateLimitType').to_s : 'limit text', reset)
    end

    def transient(now, session, text) = outcome('rate_limited', session, text[0, 200], now + RATE_LIMIT_RESET)

    # limits.json: { limited_until, kind }. Once limited_until passes, the next
    # dispatch retries (one dispatch: a repeat limit rewrites the record).
    class Store
      def initialize(root: Paths.root)
        @root = root
      end

      def path = Paths.limits_file(@root)

      def record(outcome, now: Time.now.utc)
        until_time = outcome.limited_until || (now + DEFAULT_RESET)
        FileUtils.mkdir_p(@root)
        tmp = "#{path}.#{Process.pid}.tmp"
        File.write(tmp, JSON.generate('limited_until' => until_time.utc.iso8601, 'kind' => outcome.klass, 'recorded_at' => now.utc.iso8601))
        File.rename(tmp, path)
      end

      # nil when dispatch is open, else { 'limited_until', 'kind' }. An
      # unreadable record is treated as a limit for one default window so a
      # corrupt file cannot open the gate.
      def active(now: Time.now.utc)
        return nil unless File.file?(path)

        data = JSON.parse(File.read(path))
        Time.iso8601(data['limited_until']) > now ? data : nil
      rescue JSON::ParserError, ArgumentError, TypeError
        { 'limited_until' => (now + DEFAULT_RESET).utc.iso8601, 'kind' => 'unreadable' }
      rescue SystemCallError
        nil
      end
    end
  end
end
