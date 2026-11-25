# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../scripts/scheduled_lane/sinks"

class ScheduledLaneSinksTest < Minitest::Test
  # A fake gh holding issues in memory. Only stdout is ever parsed by the sinks,
  # so the fake prints exactly what gh prints.
  class FakeGh
    attr_reader :calls, :issues, :comments

    def initialize
      @calls = []
      @issues = []
      @comments = Hash.new { |hash, key| hash[key] = [] }
      @next = 10
      @api = {}
    end

    def respond(path_fragment, json) = @api[path_fragment] = json

    def seed_issue(label:, marker:, number: nil)
      number ||= (@next += 1)
      @issues << { "number" => number, "body" => "#{marker}\nold", "labels" => [ label ], "open" => true }
      number
    end

    def call(args, stdin: nil)
      @calls << { args: args, stdin: stdin }
      verb = args.first(2)
      return list(args) if verb == %w[issue list]
      return create(args, stdin) if verb == %w[issue create]
      return close(args) if verb == %w[issue close]
      return comment(args, stdin) if verb == %w[issue comment]
      return api(args, stdin) if args.first == "api"

      ""
    end

    def list(args)
      label = args[args.index("--label") + 1]
      found = @issues.select { |issue| issue["open"] && issue["labels"].include?(label) }
      JSON.generate(found.map { |issue| issue.slice("number", "body") })
    end

    def create(args, stdin)
      labels = args.each_index.select { |i| args[i] == "--label" }.map { |i| args[i + 1] }
      number = (@next += 1)
      @issues << { "number" => number, "body" => stdin, "labels" => labels, "open" => true, "title" => args[args.index("--title") + 1] }
      "https://github.com/o/r/issues/#{number}\n"
    end

    def comment(args, stdin)
      @comments[args[2].to_i] << stdin
      ""
    end

    def close(args)
      @issues.find { |issue| issue["number"] == args[2].to_i }["open"] = false
      ""
    end

    def api(args, stdin)
      key = @api.keys.find { |fragment| args.join(" ").include?(fragment) }
      raise ScheduledLane::SinkError, "gh api failed: not found" unless key

      @api[key].is_a?(String) ? @api[key] : JSON.generate(@api[key])
    end

    def subcommands = @calls.map { |call| call[:args].first(2).join(" ") }
  end

  def report(status: "fail", failure_class: "app", release_tag: nil, label: nil, cases: [], rows: [])
    ScheduledLane::Report.new(lane_id: "app-smoke", status: status, failure_class: failure_class, label: label, notes: [ "a note" ],
                              ref: "main", env: "staging", release_tag: release_tag, run_id: "99-1", deployed_sha: "abc1234",
                              rows: rows, cases: cases, run_url: "https://example.test/run/99")
  end

  def issue_sink(gh, config = {})
    ScheduledLane::GithubIssueSink.new({ "labels" => [ "scheduled-lane" ] }.merge(config), ScheduledLane::IssueStore.new(gh))
  end

  LABEL = "scheduled-lane:app-smoke"
  MARKER = "<!-- cf-scheduled-lane:app-smoke -->"

  def test_first_failure_creates_one_issue_with_label_and_marker
    gh = FakeGh.new
    issue_sink(gh).report(report)
    assert_equal 1, gh.issues.length
    issue = gh.issues.first
    assert_includes issue["body"], MARKER
    assert_includes issue["labels"], LABEL
    assert_includes issue["labels"], "scheduled-lane"
    assert_empty gh.comments, "the creating call does not also comment"
  end

  def test_a_second_failure_comments_instead_of_opening_another
    gh = FakeGh.new
    sink = issue_sink(gh)
    sink.report(report)
    sink.report(report)
    assert_equal 1, gh.issues.length
    assert_equal 1, gh.comments[gh.issues.first["number"]].length
    assert_equal 1, gh.calls.count { |call| call[:args].first(2) == %w[issue create] }
  end

  def test_a_later_pass_comments_and_closes
    gh = FakeGh.new
    sink = issue_sink(gh)
    sink.report(report)
    sink.report(report(status: "pass", failure_class: nil))
    issue = gh.issues.first
    refute issue["open"]
    assert_match(/Passing again/, gh.comments[issue["number"]].last)
  end

  def test_a_pass_with_no_open_issue_does_nothing_else
    gh = FakeGh.new
    issue_sink(gh).report(report(status: "pass", failure_class: nil))
    assert_equal [ "issue list" ], gh.subcommands
  end

  def test_an_issue_wearing_the_label_without_the_marker_is_left_alone
    gh = FakeGh.new
    gh.issues << { "number" => 3, "body" => "unrelated", "labels" => [ LABEL ], "open" => true }
    issue_sink(gh).report(report)
    assert_equal 2, gh.issues.length
    assert gh.issues.first["open"]
    assert_empty gh.comments[3]
  end

  def test_a_create_race_is_deduped_by_re_search
    gh = FakeGh.new
    # After this call's create, a concurrent run's lower-numbered issue shows up.
    competing = nil
    gh.define_singleton_method(:create) do |args, stdin|
      competing = seed_issue(label: LABEL, marker: MARKER, number: 5)
      super(args, stdin)
    end
    issue_sink(gh).report(report)
    open = gh.issues.select { |issue| issue["open"] }
    assert_equal [ competing ], open.map { |issue| issue["number"] }
    mine = gh.issues.find { |issue| issue["number"] != competing }
    assert_match(/Duplicate of #5/, gh.comments[mine["number"]].first)
    assert_match(/a note/, gh.comments[5].first, "the report lands on the surviving issue")
  end

  def test_two_open_duplicates_collapse_to_the_lowest
    gh = FakeGh.new
    gh.seed_issue(label: LABEL, marker: MARKER, number: 8)
    gh.seed_issue(label: LABEL, marker: MARKER, number: 4)
    issue_sink(gh).report(report)
    assert_equal [ 4 ], gh.issues.select { |issue| issue["open"] }.map { |issue| issue["number"] }
    assert_match(/Duplicate of #4/, gh.comments[8].first)
  end

  def test_assignee_follows_the_failure_class
    gh = FakeGh.new
    sink = issue_sink(gh, "assignee_on_app_failure" => "qa-role", "assignee_on_infra_failure" => "tech-lead")
    sink.report(report(failure_class: "infra"))
    edit = gh.calls.find { |call| call[:args].first(2) == %w[issue edit] }
    assert_equal "tech-lead", edit[:args].last
  end

  def test_body_carries_the_mismatch_label_failing_cases_and_matrix_rows
    cases = [ { "name" => "switch|view", "grade" => "fail", "step_ms" => 16_000, "reason" => "too slow" },
             { "name" => "ok", "grade" => "pass", "step_ms" => 10, "reason" => nil } ]
    rows = [ { "key" => "example_flag", "seed_state" => "off", "flip_ok" => true, "lane" => { "status" => "fail", "class" => "app" }, "revert_ok" => true } ]
    body = ScheduledLane::SinkBody.render(report(label: "staging at abc1234, not v1.0.0", cases: cases, rows: rows))
    assert_includes body, "staging at abc1234, not v1.0.0"
    assert_includes body, "switch\\|view"
    refute_includes body, "| ok | pass"
    assert_includes body, "| example_flag | off | ok | fail (app) | confirmed |"
  end

  # --- release comment ------------------------------------------------------

  def release_sink(gh) = ScheduledLane::ReleaseCommentSink.new(gh, ScheduledLane::IssueStore.new(gh))

  def test_release_sink_skips_when_no_tag
    gh = FakeGh.new
    release_sink(gh).report(report)
    assert_empty gh.calls
  end

  def test_release_with_a_discussion_gets_a_discussion_comment_and_never_an_edit
    gh = FakeGh.new
    gh.respond("releases/tags/v1.0.0", "discussion_url" => "https://github.com/o/r/discussions/7", "html_url" => "https://github.com/o/r/releases/v1.0.0")
    gh.respond("query($owner", "data" => { "repository" => { "discussion" => { "id" => "D_1" } } })
    gh.respond("mutation", "data" => {})
    release_sink(gh).report(report(release_tag: "v1.0.0"))
    mutation = gh.calls.find { |call| call[:args].join(" ").include?("addDiscussionComment") }
    assert_includes mutation[:args], "id=D_1"
    assert_includes mutation[:stdin], "a note"
    assert_empty gh.issues
    refute(gh.calls.any? { |call| call[:args].first(2) == %w[release edit] })
  end

  def test_release_without_a_discussion_upserts_one_issue_per_tag
    gh = FakeGh.new
    gh.respond("releases/tags/v1.0.0", "html_url" => "https://github.com/o/r/releases/v1.0.0")
    sink = release_sink(gh)
    sink.report(report(release_tag: "v1.0.0"))
    sink.report(report(release_tag: "v1.0.0"))
    assert_equal 1, gh.issues.length
    issue = gh.issues.first
    assert_equal "Release diligence v1.0.0", issue["title"]
    assert_includes issue["labels"], "release-diligence"
    assert_includes issue["body"], "<!-- cf-release-diligence:v1.0.0 -->"
    assert_includes issue["body"], "https://github.com/o/r/releases/v1.0.0"
    assert_equal 1, gh.comments[issue["number"]].length
    refute(gh.calls.any? { |call| call[:args].first(2) == %w[release edit] })
  end

  def test_a_draft_release_with_no_tag_page_still_gets_a_checklist_issue
    gh = FakeGh.new
    release_sink(gh).report(report(release_tag: "v2.0.0"))
    assert_includes gh.issues.first["body"], "no published release page"
  end

  def test_a_different_tag_gets_its_own_issue
    gh = FakeGh.new
    sink = release_sink(gh)
    sink.report(report(release_tag: "v1.0.0"))
    sink.report(report(release_tag: "v1.1.0"))
    assert_equal 2, gh.issues.length
  end

  # --- chat dm -----------------------------------------------------------------

  def test_dm_sink_pipes_the_body_to_the_command_on_stdin
    seen = []
    runner = Object.new
    runner.define_singleton_method(:call) do |cmd, stdin: nil, **|
      seen << [ cmd, stdin ]
      ScheduledLane::CommandRunner::Outcome.new(stdout: "", stderr: "", exit_code: 0, timed_out: false)
    end
    sink = ScheduledLane::ChatDmSink.new({ "cmd" => "send-dm --to lead" }, runner)
    sink.report(report)
    assert_equal "send-dm --to lead", seen.first[0]
    assert_includes seen.first[1], "Lane `app-smoke`: FAIL (app)"
    sink.report(report(status: "pass", failure_class: nil))
    assert_equal 1, seen.length, "a passing run sends no DM"
  end

  def test_dm_sink_runs_without_the_ledger_credential
    seen = []
    runner = Object.new
    runner.define_singleton_method(:call) do |_cmd, env: {}, **|
      seen << env
      ScheduledLane::CommandRunner::Outcome.new(stdout: "", stderr: "", exit_code: 0, timed_out: false)
  end
  lane = ScheduledLane::Lane.new({ "matrix" => { "mode" => "off", "ledger_credential_env" => "LEDGER_TOKEN" },
                                   "sinks" => [ { "type" => "chat_dm", "cmd" => "send" } ] })
  ScheduledLane::Sinks.build(lane, runner: runner).first.report(report)
  assert_equal [ { "LEDGER_TOKEN" => nil } ], seen
  end

  def test_dm_sink_failure_is_a_sink_error
    runner = Object.new
    runner.define_singleton_method(:call) { |*, **| ScheduledLane::CommandRunner::Outcome.new(stdout: "", stderr: "denied", exit_code: 1, timed_out: false) }
    assert_raises(ScheduledLane::SinkError) { ScheduledLane::ChatDmSink.new({ "cmd" => "x" }, runner).report(report) }
  end

  def test_report_all_runs_every_sink_and_collects_errors
    good = Object.new
    reached = []
    good.define_singleton_method(:report) { |_| reached << :good }
    bad = Object.new
    bad.define_singleton_method(:report) { |_| raise ScheduledLane::SinkError, "no" }
    errors = ScheduledLane::Sinks.report_all([ bad, good ], report)
    assert_equal [ :good ], reached
    assert_equal 1, errors.length
  end
end
