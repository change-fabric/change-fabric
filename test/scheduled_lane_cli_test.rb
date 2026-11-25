# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "stringio"
require "open3"
require_relative "../scripts/scheduled_lane"

# The CLI end to end with real shell commands in a temp directory. Sinks are a
# chat_dm command writing to a file, so nothing here needs gh or a network.
class ScheduledLaneCliTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/scheduled_lane/CHANGE.md", __dir__)
  LANE_SCRIPT = File.expand_path("fixtures/scheduled_lane/example_lane.sh", __dir__)

  def setup
    @dir = Dir.mktmpdir
    @out = StringIO.new
    @err = StringIO.new
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def config(lane_overrides = {}, matrix = nil)
    lane = { "id" => "example", "run" => "sh #{LANE_SCRIPT}", "result_file" => "out/result.json", "cadence" => "nightly",
             "timeout_minutes" => 1, "sinks" => [ { "type" => "chat_dm", "cmd" => "cat > dm.txt" } ] }.merge(lane_overrides)
    lane["matrix"] = matrix if matrix
    path = File.join(@dir, "CHANGE.md")
    File.write(path, "---\n#{YAML.dump("scheduled_lanes" => [ lane ]).delete_prefix("---\n")}---\n")
    path
  end

  def cli(*args, environ: {})
    ScheduledLane::Cli.new(out: @out, err: @err, environ: environ, workdir: @dir).call(args)
  end

  def result_doc = JSON.parse(File.read(File.join(@dir, "scheduled-lane-result.json")))
  def dm = File.exist?(File.join(@dir, "dm.txt")) ? File.read(File.join(@dir, "dm.txt")) : nil

  def test_dry_run_against_the_fixture_executes_nothing
    assert_equal 0, cli("run", "--config", FIXTURE, "--lane", "example", "--dry-run")
    assert_includes @out.string, "lane: example"
    assert_includes @out.string, "per run: tmp/example-result.<iteration>.json"
    refute File.exist?(File.join(@dir, "scheduled-lane-result.json"))
  end

  def test_dry_run_with_the_matrix_lists_touched_flags
    assert_equal 0, cli("run", "--config", FIXTURE, "--lane", "example", "--matrix", "touched", "--dry-run")
    assert_includes @out.string, "touched flags (1): example_flag"
  end

  def test_a_passing_run_writes_the_result_file_and_sends_no_dm
    assert_equal 0, cli("run", "--config", config, "--lane", "example", "--ref", "release-branch", environ: { "GITHUB_RUN_ID" => "42", "GITHUB_RUN_ATTEMPT" => "2" })
    doc = result_doc
    assert_equal "pass", doc["status"]
    assert_equal "release-branch", doc["ref"]
    assert_equal "42-2", doc["run_id"]
    assert_equal "42-2-0", doc["iterations"].first["run_id"]
    assert_nil dm
  end

  def test_a_failing_lane_exits_1_and_dms
    path = config({ "run" => "sh -c 'exit 3'" })
    assert_equal 1, cli("run", "--config", path, "--lane", "example")
    assert_equal "infra", result_doc["class"], "no result file was written, so it cannot be graded"
    assert_includes dm, "FAIL (infra)"
  end

  def test_a_nonzero_exit_over_a_passing_file_is_an_app_fail
    path = config({ "run" => "sh #{LANE_SCRIPT}; exit 1" })
    assert_equal 1, cli("run", "--config", path, "--lane", "example")
    assert_equal "app", result_doc["class"]
    assert_includes result_doc["notes"], "exit/status disagree"
  end

  def test_a_command_that_overruns_its_timeout_is_killed
    started = Time.now
    outcome = ScheduledLane::CommandRunner.new(chdir: @dir).call("sleep 30", timeout: 0.3)
    assert outcome.timed_out
    refute outcome.ok?
    assert_operator Time.now - started, :<, 10
  end

  def test_report_infra_sinks_without_running_the_lane
    assert_equal 1, cli("report-infra", "--config", config({ "run" => "touch ran.txt" }), "--lane", "example", "--reason", "runner never started")
    assert_includes dm, "FAIL (infra)"
    assert_includes dm, "runner never started"
    refute File.exist?(File.join(@dir, "ran.txt"))
  end

  def test_report_infra_needs_a_reason
    assert_equal 2, cli("report-infra", "--config", config, "--lane", "example")
  end

  def test_unknown_lane_and_missing_config_are_usage_errors
    assert_equal 2, cli("run", "--config", config, "--lane", "nope")
    assert_equal 2, cli("run", "--config", File.join(@dir, "missing.md"), "--lane", "example")
    assert_equal 2, cli("bogus")
    assert_equal 2, cli("run", "--config", config)
  end

  def test_matrix_touched_needs_a_declared_matrix
    assert_equal 2, cli("run", "--config", config, "--lane", "example", "--matrix", "touched")
  end

  def matrix_def
    { "mode" => "touched-one-at-a-time", "touched_cmd" => "echo a", "flip_cmd" => "echo flip {flag}", "revert_cmd" => "echo revert {flag}",
      "read_cmd" => "echo off", "list_on_cmd" => "true", "ledger_cmd" => "true", "lock_group" => "g" }
  end

  def test_matrix_refuses_production_before_anything_runs
    path = config({ "run" => "touch ran.txt" }, matrix_def)
    assert_equal 1, cli("run", "--config", path, "--lane", "example", "--matrix", "touched", "--env", "production", "--keys", "a",
                        "--receipt", "r1", "--job-timeout-minutes", "60")
    assert_includes result_doc["notes"].join, "forbid_envs"
    refute File.exist?(File.join(@dir, "ran.txt"))
  end

  def test_matrix_run_without_a_receipt_is_refused
    path = config({ "run" => "touch ran.txt" }, matrix_def)
    assert_equal 1, cli("run", "--config", path, "--lane", "example", "--matrix", "touched", "--keys", "a", "--job-timeout-minutes", "60")
    assert_includes result_doc["notes"].join, "authority"
  end

  def test_nightly_detection_reports_a_stray_flag_without_running_the_lane
    path = config({ "run" => "touch ran.txt" }, matrix_def.merge("list_on_cmd" => "echo stray_flag"))
    assert_equal 1, cli("run", "--config", path, "--lane", "example", "--matrix", "off")
    assert_equal "infra", result_doc["class"]
    assert_includes dm, "stray_flag"
    refute File.exist?(File.join(@dir, "ran.txt"))
  end

  def git(*args) = Open3.capture2e("git", "-C", @dir, "-c", "user.name=t", "-c", "user.email=t@example.test", *args)

  def test_release_tag_with_a_different_deployed_sha_is_labeled_and_fails
    git("init", "-q")
    File.write(File.join(@dir, "f"), "x")
    git("add", "f")
    git("commit", "-q", "-m", "init")
    git("tag", "v1.0.0")
    path = config({ "deployed_sha_cmd" => "echo ffffffffffffffffffff" })
    assert_equal 1, cli("run", "--config", path, "--lane", "example", "--release-tag", "v1.0.0")
    doc = result_doc
    assert doc["ref_mismatch"]
    assert_equal "staging at ffffffffffff, not v1.0.0", doc["label"]
    assert_equal git("rev-parse", "v1.0.0^{commit}").first.strip, doc["release_sha"]
    assert_includes dm, "staging at ffffffffffff, not v1.0.0"
  end

  def test_release_tag_matching_the_deployed_sha_passes
    git("init", "-q")
    File.write(File.join(@dir, "f"), "x")
    git("add", "f")
    git("commit", "-q", "-m", "init")
    git("tag", "v1.0.0")
    sha = git("rev-parse", "HEAD").first.strip
    path = config({ "deployed_sha_cmd" => "echo #{sha}" })
    assert_equal 0, cli("run", "--config", path, "--lane", "example", "--release-tag", "v1.0.0")
    refute result_doc["ref_mismatch"]
  end

  def test_a_tag_that_looks_like_an_option_is_refused
    assert_equal 2, cli("run", "--config", config, "--lane", "example", "--release-tag", "--upload-pack=x")
  end

def test_a_stalled_stdin_write_counts_against_the_timeout
  started = Time.now
  outcome = ScheduledLane::CommandRunner.new(chdir: @dir).call("sleep 20", stdin: "x" * 2_000_000, timeout: 0.3)
  assert outcome.timed_out
  assert_operator Time.now - started, :<, 12
end

def test_the_dry_run_touched_command_runs_without_the_ledger_credential
  ENV["CF_TEST_LEDGER_TOKEN"] = "secret"
  matrix = matrix_def.merge("ledger_credential_env" => "CF_TEST_LEDGER_TOKEN", "touched_cmd" => "printf %s \"$CF_TEST_LEDGER_TOKEN\"")
  path = config({}, matrix)
  assert_equal 0, cli("run", "--config", path, "--lane", "example", "--matrix", "touched", "--dry-run")
  assert_includes @out.string, "touched flags (0)"
ensure
  ENV.delete("CF_TEST_LEDGER_TOKEN")
end

def test_runner_passes_stdin_and_drops_nil_env
    runner = ScheduledLane::CommandRunner.new(chdir: @dir)
    assert_equal "hello", runner.call("cat", stdin: "hello").stdout
    assert_equal "", runner.call("printf %s \"$SECRET_X\"", env: { "SECRET_X" => nil }).stdout
    assert_equal "yes", runner.call("printf %s \"$SECRET_X\"", env: { "SECRET_X" => "yes" }).stdout
  end

  def test_runner_unsets_an_inherited_variable_given_nil
    ENV["CF_TEST_LEDGER_TOKEN"] = "secret"
    runner = ScheduledLane::CommandRunner.new(chdir: @dir)
    assert_equal "secret", runner.call("printf %s \"$CF_TEST_LEDGER_TOKEN\"").stdout
    assert_equal "", runner.call("printf %s \"$CF_TEST_LEDGER_TOKEN\"", env: { "CF_TEST_LEDGER_TOKEN" => nil }).stdout
  ensure
    ENV.delete("CF_TEST_LEDGER_TOKEN")
  end

  def test_a_child_that_ignores_term_is_killed_and_the_call_returns_promptly
    started = Time.now
    marker = "cf-survivor-#{Process.pid}"
    cmd = "ruby -e 'trap(%q(TERM), %q(IGNORE)); sleep 30' #{marker} & wait"
    outcome = ScheduledLane::CommandRunner.new(chdir: @dir).call(cmd, timeout: 0.3)
    assert outcome.timed_out
    assert_operator Time.now - started, :<, 12
    survivors = 20.times.map do
      sleep 0.1
      `ps -axo command | grep "[c]f-survivor-#{Process.pid}"`.strip
    end
    assert_equal "", survivors.last, "the TERM-ignoring child is gone"
  end

  def test_runner_reports_failures_without_raising
    runner = ScheduledLane::CommandRunner.new(chdir: @dir)
    outcome = runner.call("echo boom >&2; exit 4")
    refute outcome.ok?
    assert_equal 4, outcome.exit_code
    assert_includes outcome.summary, "boom"
    assert_match(/spawn failed/, ScheduledLane::CommandRunner.new(chdir: File.join(@dir, "nope")).call("true").error)
  end
end
