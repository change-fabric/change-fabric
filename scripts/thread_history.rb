#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'render_finding_comment'
require_relative 'render_round_review'

# Reads a pull request's review history from GitHub and derives what
# cf:resolve-threads, cf:drive and cf:code-review need to decide whether
# review feedback is recurring: the unresolved threads to act on, the threads
# already deferred to a plan, the earlier threads we fixed one instance at a
# time, how many rounds each reviewer has run, and whether the authenticated
# GitHub user (viewer.login) already ran a code-review round on this PR.
#
# GitHub is the source of truth for rounds, never a local ledger: session
# state dies with the session, and cf:drive calls resolve-threads several
# times in one run, so a locally kept count would overcount. A round is a
# distinct reviewed head commit, which is exactly what GitHub records.
#
# ThreadHistory.new(data).to_h is pure over the parsed GraphQL `data` hash;
# ThreadHistory::CLI does the one `gh api graphql` call.
class ThreadHistory
  ROUND_THRESHOLD = 2
  FIXED = /\AFixed in ([0-9a-f]{7,40})\b/
  DEFERRED = /\ADeferred to plan ([a-z0-9][a-z0-9-]*)\./
  FINDING_HEADER = /\A\*\*(#{RenderFindingComment::BADGES.values.join('|')}) P[123] - /
  CONSOLIDATED_HEADER = /\A#{Regexp.escape(RenderRoundReview::HEADER_PREFIX)}/
  TITLE_CAP = 120
  IMAGE_LINK = /!\[[^\]]*\]\([^)]*\)/
  SUB_TAG = %r{</?sub>}

  QUERY = <<~GRAPHQL
    query($owner: String!, $name: String!, $number: Int!) {
      viewer { login }
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          number
          headRefOid
          reviews(first: 100) {
            pageInfo { hasNextPage }
            nodes {
              id
              author { login }
              commit { oid }
              submittedAt
              body
              comments(first: 100) { nodes { body path } }
            }
          }
          reviewThreads(first: 100) {
            pageInfo { hasNextPage }
            nodes {
              id
              isResolved
              isOutdated
              path
              line
              originalLine
              comments(first: 100) {
                nodes {
                  id
                  databaseId
                  author { login }
                  body
                  createdAt
                  pullRequestReview { id commit { oid } }
                }
              }
            }
          }
        }
      }
    }
  GRAPHQL

  URL_REF = %r{\Ahttps?://github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)(?:[/?#].*)?\z}
  SLUG_REF = %r{\A([\w.-]+)/([\w.-]+)#(\d+)\z}
  NUMBER_REF = /\A#?(\d+)\z/

  # [owner, name, number] for a PR URL, `o/r#12`, `#12` or `12` (owner and
  # name nil for the last two), or nil when the ref is none of those.
  def self.parse_ref(str)
    ref = str.to_s.strip
    if (m = ref.match(URL_REF) || ref.match(SLUG_REF))
      [ m[1], m[2], m[3].to_i ]
    elsif (m = ref.match(NUMBER_REF))
      [ nil, nil, m[1].to_i ]
    end
  end

  def initialize(data)
    @viewer = data.dig('viewer', 'login')
    @pr = data.dig('repository', 'pullRequest') or raise 'pull request not found'
    @head = @pr['headRefOid']
    @reviews = @pr.dig('reviews', 'nodes') || []
    @threads = @pr.dig('reviewThreads', 'nodes') || []
  end

  def to_h
    {
      'viewer' => @viewer,
      'pr' => @pr['number'],
      'headSha' => @head,
      'truncated' => truncated?,
      'threads' => open_entries,
      'deferred' => deferred,
      'priorThreads' => prior_threads,
      'rounds' => rounds,
      'recurrence' => recurrence,
      'reviewRound' => review_round
    }
  end

  private

  def truncated?
    [ @pr['reviews'], @pr['reviewThreads'] ].any? { |conn| conn&.dig('pageInfo', 'hasNextPage') == true }
  end

  def comments(thread)
    thread.dig('comments', 'nodes') || []
  end

  def login(node)
    node&.dig('author', 'login')
  end

  def viewer?(node)
    !@viewer.nil? && login(node) == @viewer
  end

  # The slug of the viewer's `Deferred to plan <slug>.` reply when it is the
  # thread's last comment; a reviewer comment after it reopens the thread.
  def deferred_slug(thread)
    last = comments(thread).last
    return nil unless last && viewer?(last)

    last['body'].to_s.match(DEFERRED)&.[](1)
  end

  def unresolved
    @threads.reject { |t| t['isResolved'] }
  end

  def open_threads
    unresolved.reject { |t| deferred_slug(t) }
  end

  def open_entries
    @open_entries ||= open_threads.map { |t| thread_entry(t) }
  end

  def thread_entry(thread)
    first = comments(thread).first
    {
      'threadId' => thread['id'],
      'path' => thread['path'],
      'line' => thread['line'] || thread['originalLine'],
      'isOutdated' => thread['isOutdated'] == true,
      'commentId' => comments(thread).last&.dig('databaseId'),
      'title' => title(first),
      'reviewer' => login(first),
      'reviewedCommit' => first&.dig('pullRequestReview', 'commit', 'oid'),
      'comments' => comments(thread).map { |c| { 'author' => login(c), 'body' => c['body'] } }
    }
  end

  # The first non-empty line of the opening comment, with badge images,
  # <sub> tags and bold markers removed, so a Codex badge header reads as
  # its plain title.
  def title(comment)
    line = comment ? comment['body'].to_s.lines.map(&:strip).find { |l| !l.empty? }.to_s : ''
    line.gsub(IMAGE_LINK, '').gsub(SUB_TAG, '').gsub('**', '').gsub(/\s+/, ' ').strip[0, TITLE_CAP]
  end

  def deferred
    unresolved.filter_map do |t|
      slug = deferred_slug(t) or next
      { 'threadId' => t['id'], 'path' => t['path'], 'title' => title(comments(t).first), 'slug' => slug }
    end
  end

  def prior_threads
    @prior_threads ||= @threads.select { |t| t['isResolved'] }.filter_map do |t|
      fix = comments(t).select { |c| viewer?(c) }.filter_map { |c| c['body'].to_s.match(FIXED) }.last or next
      first = comments(t).first
      { 'threadId' => t['id'], 'path' => t['path'], 'title' => title(first), 'reviewer' => login(first),
        'fixSha' => fix[1] }
    end
  end

  def rounds
    @rounds ||= @reviews.reject { |r| login(r).nil? || viewer?(r) }
                        .group_by { |r| login(r) }
                        .transform_values { |rs| rs.filter_map { |r| r.dig('commit', 'oid') }.uniq.size }
  end

  def recurrence
    prior_paths = prior_threads.map { |p| p['path'] }
    hits = open_entries.select do |t|
      rounds.fetch(t['reviewer'], 0) >= ROUND_THRESHOLD && prior_paths.include?(t['path'])
    end
    {
      'fired' => hits.any?,
      'threshold' => ROUND_THRESHOLD,
      'paths' => hits.map { |t| t['path'] }.uniq.sort,
      'reviewers' => hits.map { |t| t['reviewer'] }.uniq.sort
    }
  end

  def review_round
    prior = prior_reviews
    head_moved = prior.any? && @head != prior.last['commit']
    settled = prior_threads_settled?(prior)
    {
      'priorReviews' => prior,
      'headMoved' => head_moved,
      'priorThreadsSettled' => settled,
      'secondRound' => prior.any? && head_moved && settled,
      'consolidatedAtHead' => consolidated_at_head?
    }
  end

  def prior_reviews
    @reviews.select { |r| viewer?(r) && review_comments(r).any? { |c| c['body'].to_s.match?(FINDING_HEADER) } }
            .map { |r| { 'id' => r['id'], 'commit' => r.dig('commit', 'oid') } }
  end

  def review_comments(review)
    review.dig('comments', 'nodes') || []
  end

  def prior_threads_settled?(prior)
    return false if prior.empty?

    ids = prior.map { |r| r['id'] }
    @threads.select { |t| ids.include?(comments(t).first&.dig('pullRequestReview', 'id')) }
            .all? { |t| t['isResolved'] || t['isOutdated'] }
  end

  def consolidated_at_head?
    @reviews.any? do |r|
      viewer?(r) && r['body'].to_s.match?(CONSOLIDATED_HEADER) && r.dig('commit', 'oid') == @head
    end
  end

  # The command-line entry point: resolves the PR ref, runs the one GraphQL
  # call through an injectable runner, and prints the history as pretty JSON.
  # A gh failure goes to stderr with exit 1; this is a CLI the skills call,
  # not a hook, so it does not fail silent.
  module CLI
    module_function

    # gh writes notices (an available update, say) to stderr even on success,
    # so stdout is kept apart for JSON.parse and stderr only explains a failure.
    GH = lambda do |*cmd|
      stdout, stderr, status = Open3.capture3(*cmd)
      [ status.success? ? stdout : stderr, status ]
    end

    def run(argv, out: $stdout, err: $stderr, runner: GH)
      owner, name, number = resolve(argv.first, runner)
      output, status = runner.call('gh', 'api', 'graphql', '-f', "owner=#{owner}", '-f', "name=#{name}",
                                   '-F', "number=#{number}", '-f', "query=#{QUERY}")
      raise output unless status.success?

      out.puts JSON.pretty_generate(ThreadHistory.new(JSON.parse(output).fetch('data')).to_h)
      0
    rescue StandardError => e
      err.puts "thread_history: #{e.message.strip}"
      1
    end

    def resolve(ref, runner)
      ref = JSON.parse(gh(runner, 'pr', 'view', '--json', 'number,url')).fetch('url') if ref.nil? || ref.strip.empty?
      owner, name, number = ThreadHistory.parse_ref(ref) || raise("unrecognized PR ref: #{ref}")
      owner, name = gh(runner, 'repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner').split('/', 2) if owner.nil?
      [ owner, name, number ]
    end

    def gh(runner, *args)
      output, status = runner.call('gh', *args)
      raise output unless status.success?

      output.strip
    end
  end
end

exit ThreadHistory::CLI.run(ARGV) if __FILE__ == $PROGRAM_NAME
