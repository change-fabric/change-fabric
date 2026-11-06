#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'

# Watches one PR for cf:sweep stack mode and exits on the first event worth
# waking the session for. Stack mode runs it with Bash run_in_background, so
# the harness re-invokes the session when this process exits; the exit code is
# the event and one JSON line on stdout describes it.
#
# A baseline (head SHA, unresolved thread ids) is captured on the first poll.
# Later polls compare against it. A head SHA listed in --expect-sha is ours (the
# stack's own push), so moving to it is not a foreign push.
class StackWatch
  MERGED = 0
  SETUP = 2
  CLOSED = 3
  FOREIGN_PUSH = 4
  NEW_THREAD = 5
  RED_CHECK = 6
  TIMEOUT = 7

  RED = %w[FAILURE ERROR CANCELLED TIMED_OUT ACTION_REQUIRED STARTUP_FAILURE].freeze

  THREADS_QUERY = <<~GRAPHQL
    query($owner: String!, $name: String!, $number: Int!, $after: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100, after: $after) {
            nodes { id isResolved }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }
  GRAPHQL

  class SetupError < StandardError; end

  def initialize(pr:, repo:, interval: 60, ttl: 86_400, expect_sha: [], sleeper: method(:sleep))
    @pr = Integer(pr)
    @owner, @name = repo.to_s.split('/', 2)
    raise SetupError, 'repo must be owner/name' if @owner.to_s.empty? || @name.to_s.empty?

    @interval = interval.to_f
    @ttl = ttl.to_f
    @expect = Array(expect_sha).map(&:to_s)
    @sleeper = sleeper
  end

  # Returns [exit_code, event_hash].
  def run
    started = now
    baseline = nil
    loop do
      snap = snapshot
      baseline ||= snap
      event = classify(snap, baseline)
      return event if event
      return [ TIMEOUT, { event: 'timeout', pr: @pr, ttl: @ttl } ] if now - started >= @ttl

      @sleeper.call(@interval)
    end
  end

  private

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def classify(snap, baseline)
    return [ MERGED, event('merged', merged_at: snap[:merged_at]) ] if snap[:state] == 'MERGED'
    return [ CLOSED, event('closed') ] if snap[:state] == 'CLOSED'
    return [ FOREIGN_PUSH, event('foreign_push', head: snap[:head]) ] if foreign_push?(snap, baseline)
    opened = snap[:threads] - baseline[:threads]
    return [ NEW_THREAD, event('new_thread', unresolved: snap[:threads].size, opened: opened) ] unless opened.empty?
    return [ RED_CHECK, event('red_check', checks: snap[:red]) ] unless snap[:red].empty?

    nil
  end

  def foreign_push?(snap, baseline)
    snap[:head] != baseline[:head] && !@expect.include?(snap[:head])
  end

  def event(name, **fields) = { event: name, pr: @pr }.merge(fields)

  def snapshot
    view = gh_json('pr', 'view', @pr.to_s, '--repo', "#{@owner}/#{@name}",
                   '--json', 'state,mergedAt,headRefOid,statusCheckRollup')
    { state: view['state'], merged_at: view['mergedAt'], head: view['headRefOid'],
      red: red_checks(view['statusCheckRollup']), threads: unresolved_threads }
  end

  def red_checks(rollup)
    Array(rollup).filter_map do |check|
      verdict = (check['conclusion'] || check['state']).to_s.upcase
      check['name'] || check['context'] if RED.include?(verdict)
    end
  end

  # Ids of every unresolved thread, following pageInfo past the first 100.
  def unresolved_threads
    ids = []
    cursor = nil
    loop do
      page = threads_page(cursor)
      ids.concat(Array(page['nodes']).reject { |node| node['isResolved'] }.map { |node| node['id'] })
      info = page['pageInfo'] || {}
      break unless info['hasNextPage'] && info['endCursor']

      cursor = info['endCursor']
    end
    ids
  end

  def threads_page(cursor)
    args = [ 'api', 'graphql', '-f', "query=#{THREADS_QUERY}", '-F', "owner=#{@owner}",
             '-F', "name=#{@name}", '-F', "number=#{@pr}" ]
    args += [ '-f', "after=#{cursor}" ] if cursor
    gh_json(*args).dig('data', 'repository', 'pullRequest', 'reviewThreads') || {}
  end

  def gh_json(*args)
    out, status = Open3.capture2e('gh', *args)
    raise SetupError, "gh #{args.first(2).join(' ')} failed: #{out.strip}" unless status.success?

    JSON.parse(out)
  rescue Errno::ENOENT
    raise SetupError, 'gh is not installed'
  rescue JSON::ParserError
    raise SetupError, "gh #{args.first(2).join(' ')} returned non-JSON"
  end

  # Flag parsing and the exit-code contract.
  class CLI
    USAGE = 'stack_watch.rb --pr N --repo owner/name [--interval 60] [--ttl 86400] [--expect-sha SHA ...]'

    def self.run(argv, out: $stdout)
      code, payload = StackWatch.new(**parse(argv)).run
      out.puts(JSON.generate(payload))
      code
    rescue SetupError, ArgumentError, TypeError => e
      out.puts(JSON.generate(event: 'setup_error', error: e.message, usage: USAGE))
      SETUP
    end

    def self.parse(argv)
      opts = { expect_sha: [] }
      argv.each_slice(2) do |flag, value|
        raise ArgumentError, "missing value for #{flag}" if value.nil?

        apply(opts, flag, value)
      end
      raise ArgumentError, '--pr and --repo are required' unless opts[:pr] && opts[:repo]

      opts
    end

    def self.apply(opts, flag, value)
      case flag
      when '--pr' then opts[:pr] = value
      when '--repo' then opts[:repo] = value
      when '--interval' then opts[:interval] = Float(value)
      when '--ttl' then opts[:ttl] = Float(value)
      when '--expect-sha' then opts[:expect_sha] << value
      else raise ArgumentError, "unknown flag #{flag}"
      end
    end
  end
end

exit(StackWatch::CLI.run(ARGV)) if __FILE__ == $PROGRAM_NAME
