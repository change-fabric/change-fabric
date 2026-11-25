# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../scripts/triage/gh_live"

# The command and GraphQL contract behind the report's live PR facts: which gh
# argv is issued, how reviewThreads pages, how checks aggregate, and which
# failures degrade to `unknown` (network) versus fail loudly (query error).
class TriageGhLiveContractTest < Minitest::Test
  Result = Triage::Command::Result

  # Replays queued results in order and records every argv it was asked to run.
  class Runner
    attr_reader :calls

    def initialize(*results)
      @results = results
      @calls = []
    end

    def call(argv, timeout)
      @calls << [ argv, timeout ]
      @results.shift || raise("unexpected extra command: #{argv.inspect}")
    end
  end

  def ok(data) = Result.new(out: JSON.generate(data), err: "", ok: true, timed_out: false)
  def fail_with(message, timed_out: false) = Result.new(out: "", err: message, ok: false, timed_out: timed_out)

  def view(state: "OPEN", merge: "CLEAN", checks: [])
    { "state" => state, "mergeStateStatus" => merge, "statusCheckRollup" => checks }
  end

  def page(resolved, next_cursor: nil)
    { "data" => { "repository" => { "pullRequest" => { "reviewThreads" => {
      "pageInfo" => { "hasNextPage" => !next_cursor.nil?, "endCursor" => next_cursor },
      "nodes" => resolved.map { |flag| { "isResolved" => flag } }
    } } } } }
  end

  def live(*results) = [ (runner = Runner.new(*results)), Triage::GhLive.new(runner: runner, timeout: 7) ]

  def test_pr_view_asks_for_exactly_the_checks_and_mergeability_fields
    runner, gh = live(ok(view), ok(page([])))
    gh.pr("acme/api", 12)
    assert_equal [ "gh", "pr", "view", "12", "--repo", "acme/api", "--json", "state,statusCheckRollup,mergeStateStatus" ],
                 runner.calls.first.first
    assert_equal 7, runner.calls.first.last, "every call is bounded by the timeout"
  end

  def test_review_threads_come_from_graphql_not_pr_view
    runner, gh = live(ok(view), ok(page([ true, false, false ])))
    facts = gh.pr("acme/api", 12)
    argv = runner.calls.last.first
    assert_equal %w[gh api graphql], argv.first(3)
    query = argv.find { |arg| arg.start_with?("query=") }
    assert_includes query, "reviewThreads(first: 100, after: $cursor)"
    assert_includes query, "pageInfo { hasNextPage endCursor }"
    assert_includes query, "isResolved"
    assert_includes argv, "owner=acme"
    assert_includes argv, "name=api"
    assert_includes argv, "number=12"
    refute(argv.any? { |arg| arg.start_with?("cursor=") }, "the first page sends no cursor")
    assert_equal 2, facts.unresolved_threads
  end

  def test_review_threads_are_paginated_until_no_next_page
    runner, gh = live(ok(view), ok(page([ false, true ], next_cursor: "C1")), ok(page([ false ], next_cursor: "C2")),
                      ok(page([ false, false ])))
    assert_equal 4, gh.pr("acme/api", 5).unresolved_threads
    cursors = runner.calls.drop(1).map { |argv, _| argv.find { |arg| arg.start_with?("cursor=") } }
    assert_equal [ nil, "cursor=C1", "cursor=C2" ], cursors
  end

  def test_a_merged_pr_makes_no_graphql_call
    runner, gh = live(ok(view(state: "MERGED", merge: "UNKNOWN")))
    facts = gh.pr("acme/api", 3)
    assert_equal 1, runner.calls.size
    assert_equal "MERGED", facts.state
    assert_equal 0, facts.unresolved_threads
  end

  def test_pr_facts_are_memoized_per_run
    runner, gh = live(ok(view), ok(page([])))
    2.times { gh.pr("acme/api", 12) }
    assert_equal 2, runner.calls.size
  end

  def test_clean_is_true_only_for_merge_state_clean
    _, gh = live(ok(view(merge: "BLOCKED")), ok(page([])))
    refute gh.pr("acme/api", 1).clean
    _, gh = live(ok(view(merge: "CLEAN")), ok(page([])))
    assert gh.pr("acme/api", 2).clean
  end

  def test_checks_aggregate_failed_over_pending_over_passed
    ok_run = { "status" => "COMPLETED", "conclusion" => "SUCCESS" }
    fail_run = { "status" => "COMPLETED", "conclusion" => "FAILURE" }
    pending_run = { "status" => "IN_PROGRESS", "conclusion" => "" }
    assert_equal "failed", Triage::GhLive.aggregate([ ok_run, pending_run, fail_run ])
    assert_equal "pending", Triage::GhLive.aggregate([ ok_run, pending_run ])
    assert_equal "passed", Triage::GhLive.aggregate([ ok_run, ok_run ])
  end

  def test_skipped_and_cancelled_checks_are_neutral
    skipped = { "status" => "COMPLETED", "conclusion" => "SKIPPED" }
    cancelled = { "status" => "COMPLETED", "conclusion" => "CANCELLED" }
    ok_run = { "status" => "COMPLETED", "conclusion" => "SUCCESS" }
    assert_equal "passed", Triage::GhLive.aggregate([ skipped, cancelled, ok_run ])
    assert_equal "none", Triage::GhLive.aggregate([ skipped, cancelled ])
    assert_equal "none", Triage::GhLive.aggregate([])
    assert_equal "none", Triage::GhLive.aggregate(nil)
  end

  def test_status_contexts_count_by_their_state
    assert_equal "failed", Triage::GhLive.aggregate([ { "state" => "FAILURE" } ])
    assert_equal "failed", Triage::GhLive.aggregate([ { "state" => "ERROR" } ])
    assert_equal "pending", Triage::GhLive.aggregate([ { "state" => "PENDING" } ])
    assert_equal "passed", Triage::GhLive.aggregate([ { "state" => "SUCCESS" } ])
  end

  def test_a_timeout_is_unavailable
    _, gh = live(fail_with("timed out after 7s", timed_out: true))
    assert_raises(Triage::GhLive::Unavailable) { gh.pr("acme/api", 1) }
  end

  def test_a_network_failure_is_unavailable
    _, gh = live(fail_with("error connecting to api.github.com: could not resolve host"))
    assert_raises(Triage::GhLive::Unavailable) { gh.pr("acme/api", 1) }
  end

  def test_a_rate_limit_is_unavailable
    _, gh = live(ok(view), fail_with("API rate limit exceeded"))
    assert_raises(Triage::GhLive::Unavailable) { gh.pr("acme/api", 1) }
  end

  def test_a_github_side_internal_error_is_unavailable_not_a_query_error
    _, gh = live(fail_with("GraphQL: Something went wrong while executing your query on 2026-11-25T18:53:51Z. Please include ABC."))
    assert_raises(Triage::GhLive::Unavailable) { gh.pr("acme/api", 1) }
  end

  def test_a_graphql_error_payload_fails_loudly
    error = { "errors" => [ { "message" => "Field 'reviewThreadz' doesn't exist" } ] }
    _, gh = live(ok(view), ok(error))
    raised = assert_raises(Triage::GhLive::QueryError) { gh.pr("acme/api", 1) }
    assert_includes raised.message, "reviewThreadz"
  end

  def test_a_non_network_gh_failure_fails_loudly
    _, gh = live(fail_with("GraphQL: Could not resolve to a PullRequest with the number of 99. (repository.pullRequest)"))
    assert_raises(Triage::GhLive::QueryError) { gh.pr("acme/api", 99) }
  end

  def test_a_response_without_review_threads_fails_loudly
    _, gh = live(ok(view), ok({ "data" => { "repository" => { "pullRequest" => nil } } }))
    assert_raises(Triage::GhLive::QueryError) { gh.pr("acme/api", 1) }
  end

  def test_unparseable_json_fails_loudly
    _, gh = live(Result.new(out: "not json", err: "", ok: true, timed_out: false))
    assert_raises(Triage::GhLive::QueryError) { gh.pr("acme/api", 1) }
  end
end
