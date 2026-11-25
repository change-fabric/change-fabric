# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require_relative "../scripts/scheduled_lane/command_runner"
require_relative "../scripts/scheduled_lane/lane_run"

class ScheduledLaneRunTest < Minitest::Test
  Outcome = ScheduledLane::CommandRunner::Outcome

  # Answers lane runs by writing the result file the test scripted, and
  # deployed-SHA commands from a queue.
  class FakeRunner
    attr_reader :calls

    def initialize(shas: [], &lane)
      @shas = shas
      @lane = lane
      @calls = []
    end

    def call(cmd, env: {}, stdin: nil, timeout: nil)
      @calls << { cmd: cmd, env: env, stdin: stdin, timeout: timeout }
      return Outcome.new(stdout: "#{@shas.shift}\n", stderr: "", exit_code: 0, timed_out: false) if cmd.start_with?("sha")

      @lane.call(env)
    end
  end

  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def lane(extra = {})
    ScheduledLane::Lane.new({ "id" => "x", "run" => "lane", "result_file" => "out/result.json", "cadence" => "nightly",
                              "timeout_minutes" => 2 }.merge(extra))
  end

  def ok(code = 0) = Outcome.new(stdout: "", stderr: "", exit_code: code, timed_out: false)

  def write_result(env, status: "pass", run_id: nil, cases: [])
    File.write(env["CF_LANE_RESULT_FILE"], JSON.generate("schema" => "cf-lane-result/1", "run_id" => run_id || env["CF_LANE_RUN_ID"],
                                                         "status" => status, "cases" => cases))
  end

  def iteration(runner, lane_def = lane, release: nil, number: 0)
    ScheduledLane::LaneRun.new(lane: lane_def, runner: runner, base_run_id: "run1", env_name: "staging", ref: "main", workdir: @dir,
                               release: release).call(number)
  end

  def test_valid_pass
    runner = FakeRunner.new { |env| write_result(env) && ok }
    result = iteration(runner)
    assert_equal "pass", result.verdict.status
    assert_equal "run1-0", result.run_id
    assert_equal "out/result.0.json", result.result_path
    assert_equal 120, runner.calls.first[:timeout]
  end

  def test_the_lane_gets_its_run_id_and_own_result_path
    runner = FakeRunner.new { |env| write_result(env) && ok }
    iteration(runner, number: 2)
    env = runner.calls.first[:env]
    assert_equal "run1-2", env["CF_LANE_RUN_ID"]
    assert_equal File.join(@dir, "out/result.2.json"), env["CF_LANE_RESULT_FILE"]
  end

  def test_valid_fail_file_is_app
    runner = FakeRunner.new { |env| write_result(env, status: "fail", cases: [ { "name" => "a", "grade" => "fail", "step_ms" => 9, "reason" => "slow" } ]) && ok(1) }
    verdict = iteration(runner).verdict
    assert_equal [ "fail", "app" ], [ verdict.status, verdict.failure_class ]
    assert_equal "slow", verdict.cases.first["reason"]
  end

  def test_nonzero_exit_with_a_pass_file_is_an_app_fail_noted
    runner = FakeRunner.new { |env| write_result(env) && ok(1) }
    verdict = iteration(runner).verdict
    assert_equal [ "fail", "app" ], [ verdict.status, verdict.failure_class ]
    assert_includes verdict.notes, "exit/status disagree"
  end

  def test_stale_run_id_is_infra
    runner = FakeRunner.new { |env| write_result(env, run_id: "someone-else") && ok }
    verdict = iteration(runner).verdict
    assert_equal "infra", verdict.failure_class
    assert_match(/stale/, verdict.notes.first)
  end

  def test_invalid_schema_is_infra
    runner = FakeRunner.new { |env| File.write(env["CF_LANE_RESULT_FILE"], JSON.generate("schema" => "other", "run_id" => env["CF_LANE_RUN_ID"])) && ok }
    assert_equal "infra", iteration(runner).verdict.failure_class
  end

  def test_unparseable_file_is_infra
    runner = FakeRunner.new { |env| File.write(env["CF_LANE_RESULT_FILE"], "{nope") && ok }
    assert_match(/not valid JSON/, iteration(runner).verdict.notes.first)
  end

  def test_bad_case_grade_is_infra
    runner = FakeRunner.new { |env| write_result(env, cases: [ { "name" => "a", "grade" => "meh" } ]) && ok }
    assert_match(/grade must be one of/, iteration(runner).verdict.notes.first)
  end

  def test_missing_file_is_infra
    runner = FakeRunner.new { ok }
    verdict = iteration(runner).verdict
    assert_equal "infra", verdict.failure_class
    assert_match(/missing/, verdict.notes.first)
  end

  def test_a_file_left_by_an_earlier_run_is_not_read
    FileUtils.mkdir_p(File.join(@dir, "out"))
    File.write(File.join(@dir, "out/result.0.json"), JSON.generate("schema" => "cf-lane-result/1", "run_id" => "run1-0", "status" => "pass", "cases" => []))
    assert_equal "infra", iteration(FakeRunner.new { ok }).verdict.failure_class
  end

  def test_timeout_and_spawn_error_are_infra
    timed = FakeRunner.new { Outcome.new(stdout: "", stderr: "", exit_code: nil, timed_out: true) }
    assert_match(/timed out/, iteration(timed).verdict.notes.first)
    broken = FakeRunner.new { Outcome.new(stdout: "", stderr: "", exit_code: nil, timed_out: false, error: "spawn failed: nope") }
    assert_equal "infra", iteration(broken).verdict.failure_class
  end

  def test_deployed_sha_read_before_and_after_each_run
    runner = FakeRunner.new(shas: %w[abc1234 abc1234]) { |env| write_result(env) && ok }
    result = iteration(runner, lane("deployed_sha_cmd" => "sha"))
    assert_equal %w[sha lane sha], runner.calls.map { |call| call[:cmd] }
    assert_equal %w[abc1234 abc1234], [ result.deployed_sha_before, result.deployed_sha_after ]
    assert_equal "pass", result.verdict.status
  end

  def test_a_deploy_landing_mid_run_is_infra_with_sha_moved
    runner = FakeRunner.new(shas: %w[abc1234 def5678]) { |env| write_result(env) && ok }
    result = iteration(runner, lane("deployed_sha_cmd" => "sha"))
    assert result.sha_moved
    assert_equal [ "fail", "infra" ], [ result.verdict.status, result.verdict.failure_class ]
  end

  def test_release_tag_matching_the_deployed_sha_passes
    runner = FakeRunner.new(shas: %w[abc1234def abc1234def]) { |env| write_result(env) && ok }
    result = iteration(runner, lane("deployed_sha_cmd" => "sha"), release: { tag: "v1.2.0", sha: "abc1234def0000" })
    assert_equal "pass", result.verdict.status
    refute result.ref_mismatch
  end

  def test_release_tag_mismatch_is_labeled_and_fails
    runner = FakeRunner.new(shas: %w[feedface0000aaaa feedface0000aaaa]) { |env| write_result(env) && ok }
    result = iteration(runner, lane("deployed_sha_cmd" => "sha"), release: { tag: "v1.2.0", sha: "abc1234def0000" })
    assert result.ref_mismatch
    assert_equal "staging at feedface0000, not v1.2.0", result.label
    assert_equal "fail", result.verdict.status
  end

  def test_release_tag_without_a_way_to_verify_fails
    runner = FakeRunner.new { |env| write_result(env) && ok }
    result = iteration(runner, release: { tag: "v1.2.0", sha: "abc1234def0000" })
    assert_equal "fail", result.verdict.status
    assert_match(/unknown/, result.label)
  end

  def test_unresolvable_release_tag_fails
    runner = FakeRunner.new { |env| write_result(env) && ok }
    result = iteration(runner, release: { tag: "v9", sha: nil })
    assert_equal "fail", result.verdict.status
  end
end
