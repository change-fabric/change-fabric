# frozen_string_literal: true

require 'json'
require_relative 'command'

module Triage
  # Live PR facts for the report: state, aggregate CI, mergeability and the
  # unresolved review thread count. Checks and mergeability come from
  # `gh pr view --json state,statusCheckRollup,mergeStateStatus`; review
  # threads are not a `gh pr view` field, so they come from a paginated
  # `gh api graphql` reviewThreads query. A network failure raises
  # Unavailable (callers mark the fields `unknown`); anything else gh or
  # GraphQL rejects raises QueryError, which fails loudly.
  class GhLive
    class Unavailable < StandardError; end
    class QueryError < StandardError; end

    TIMEOUT = 20
    VIEW_FIELDS = 'state,statusCheckRollup,mergeStateStatus'

    THREADS_QUERY = <<~GRAPHQL
      query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            reviewThreads(first: 100, after: $cursor) {
              pageInfo { hasNextPage endCursor }
              nodes { isResolved }
            }
          }
        }
      }
    GRAPHQL

    NETWORK = Regexp.union(
      /could not resolve host/i, /connection (refused|reset)/i, /timed out/i, /timeout/i, /network is unreachable/i,
      /no route to host/i, /tls handshake/i, /rate limit/i, /HTTP 5\d\d/, /something went wrong while executing your query/i, /\bEOF\b/, /temporary failure/i
    )
    FAILED = %w[FAILURE TIMED_OUT ACTION_REQUIRED STARTUP_FAILURE ERROR].freeze
    NEUTRAL = %w[SKIPPED CANCELLED NEUTRAL STALE].freeze
    PENDING = %w[QUEUED IN_PROGRESS WAITING PENDING REQUESTED EXPECTED].freeze

    Facts = Struct.new(:state, :ci, :clean, :unresolved_threads, keyword_init: true)

    UNKNOWN = Facts.new(state: 'unknown', ci: 'unknown', clean: 'unknown', unresolved_threads: 'unknown').freeze

    # failed over pending over passed; skipped and cancelled are neutral, and a
    # PR with no non-neutral check reads `none`.
    def self.aggregate(rollup)
      kinds = Array(rollup).map { |check| classify(check) }.reject { |kind| kind == :neutral }
      return 'none' if kinds.empty?
      return 'failed' if kinds.include?(:failed)

      kinds.include?(:pending) ? 'pending' : 'passed'
    end

    def self.classify(check)
      verdict = (check['conclusion'].to_s.empty? ? check['state'] : check['conclusion']).to_s.upcase
      return :neutral if NEUTRAL.include?(verdict)
      return :failed if FAILED.include?(verdict)

      verdict.empty? || PENDING.include?(verdict) ? :pending : :passed
    end

    def initialize(runner: Command.method(:run), timeout: TIMEOUT)
      @runner = runner
      @timeout = timeout
      @cache = {}
    end

    def pr(repo, number)
      @cache[[ repo, number ]] ||= fetch(repo, number)
    end

    def fetch(repo, number)
      view = JSON.parse(call(view_argv(repo, number), "gh pr view #{repo}##{number}"))
      state = view['state'].to_s
      Facts.new(state: state, ci: self.class.aggregate(view['statusCheckRollup']),
                clean: view['mergeStateStatus'].to_s == 'CLEAN',
                unresolved_threads: state == 'OPEN' ? unresolved_threads(repo, number) : 0)
    rescue JSON::ParserError => e
      raise QueryError, "gh pr view #{repo}##{number}: bad json (#{e.message})"
    end

    def view_argv(repo, number)
      [ 'gh', 'pr', 'view', number.to_s, '--repo', repo, '--json', VIEW_FIELDS ]
    end

    def graphql_argv(repo, number, cursor)
      owner, name = repo.split('/', 2)
      argv = [ 'gh', 'api', 'graphql', '-f', "query=#{THREADS_QUERY}", '-F', "owner=#{owner}", '-F', "name=#{name}",
               '-F', "number=#{number}" ]
      argv.push('-F', "cursor=#{cursor}") if cursor
      argv
    end

    def unresolved_threads(repo, number)
      cursor = nil
      count = 0
      loop do
        page = threads_page(repo, number, cursor)
        count += page.fetch('nodes').count { |node| !node['isResolved'] }
        info = page.fetch('pageInfo')
        return count unless info['hasNextPage']

        cursor = info['endCursor']
      end
    end

    def threads_page(repo, number, cursor)
      data = JSON.parse(call(graphql_argv(repo, number, cursor), "gh api graphql #{repo}##{number}"))
      raise QueryError, "graphql #{repo}##{number}: #{Array(data['errors']).map { |e| e['message'] }.join('; ')}" if data['errors']

      page = data.dig('data', 'repository', 'pullRequest', 'reviewThreads')
      raise QueryError, "graphql #{repo}##{number}: no reviewThreads in response" unless page

      page
    rescue JSON::ParserError => e
      raise QueryError, "graphql #{repo}##{number}: bad json (#{e.message})"
    end

    def call(argv, label)
      result = @runner.call(argv, @timeout)
      return result.out if result.ok

      message = "#{label}: #{result.err.to_s.strip}"
      raise Unavailable, message if result.timed_out || result.err.to_s.match?(NETWORK)

      raise QueryError, message
    end
  end
end
