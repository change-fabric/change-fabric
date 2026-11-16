# frozen_string_literal: true

require_relative "test_helpers"
require "stringio"
require_relative "../scripts/change_run"
require_relative "../scripts/change_gate_check"
require_relative "../scripts/change_schedule_store"

# `change_run.rb schedule <name>` (0.19.0, unreleased): reads CHANGE.md from
# the default branch, refuses unsafe runs before docker, and records into the
# time-keyed schedule store, never the per-sha gate.
class ChangeRunScheduleTest < Minitest::Test
  BASE_CHANGE_MD = <<~MD
    ---
    change_config:
      project: example
      default_profile: staging
      boot:
        target_url: http://app:3000
      lanes:
        zap:
          targets: ["/", "/admin"]
        k6: {}
      profiles:
        staging:
          allow_active_scan: true
          boot:
            target_url: https://staging.example.test
        production:
          boot:
            target_url: https://example.test
      schedules:
        nightly-pentest:
          cron: "0 3 * * *"
          profile: staging
          runner: local
          lanes: [zap]
          zap: { mode: full }
        weekly-load:
          cron: "0 4 * * 1"
          profile: staging
          runner: actions
          lanes: [k6]
          k6: { script: load/soak.js }
    ---

    Synthetic fixture.
  MD

  # A runner whose repo root is the fixture and whose docker and report seams
  # are stubbed, so nothing reaches a daemon or the real Desktop.
  class StubRun < ChangeRun
    attr_reader :executed_lanes, :context

    def initialize(argv, root:, findings: nil)
      @root = root
      @stub_findings = findings
      super(argv)
    end

    private

    def repo_root = @root
    def with_app(_config, _artifact = nil, trust:, prefix: "") = yield(:ctx)

    def execute(_config, lanes, _ctx)
      @executed_lanes = lanes
      [ @stub_findings, {} ]
    end

    def write_report(*, **) = { markdown: "/tmp/report.md", csv: "/tmp/report.csv" }
  end

  def setup
    @home = Dir.mktmpdir
    @prev_home = Dir.home
    ENV["HOME"] = @home
    @origin = Dir.mktmpdir
    GitFixture.git_init(@origin, "--bare", "-b", "main")
    @repo = Dir.mktmpdir
    GitFixture.git_init(@repo, "-b", "main")
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "Test")
    git("remote", "add", "origin", @origin)
    write("CHANGE.md", BASE_CHANGE_MD)
    write("load/soak.js", "export default function () {}\n")
    git("add", ".")
    git("commit", "-q", "-m", "initial")
    git("push", "-q", "origin", "main")
    @docker_calls = 0
    stub_docker
  end

  def teardown
    restore_docker
    ENV["HOME"] = @prev_home
    [ @home, @origin, @repo ].each { |dir| FileUtils.remove_entry(dir) }
  end

  def git(*args) = GitFixture.git(@repo, *args)

  def write(rel, body)
    path = File.join(@repo, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def stub_docker
    calls = -> { @docker_calls += 1 }
    @orig_available = ChangeDocker.method(:available?)
    @orig_run = ChangeDocker.method(:run)
    ChangeDocker.define_singleton_method(:available?) { calls.call || true }
    ChangeDocker.define_singleton_method(:run) { |**| calls.call }
  end

  def restore_docker
    ChangeDocker.define_singleton_method(:available?, @orig_available)
    ChangeDocker.define_singleton_method(:run, @orig_run)
  end

  def capture
    original = $stderr
    $stderr = StringIO.new
    code = begin
      yield
    rescue SystemExit => e
      e.status
    end
    [ code, $stderr.string ]
  ensure
    $stderr = original
  end

  def run_schedule(argv, findings: nil) = capture { StubRun.new(argv, root: @repo, findings: findings).run }

  def test_dry_run_prints_the_plan_and_runs_nothing
    code, out = run_schedule(%w[schedule nightly-pentest --dry-run])
    assert_equal 0, code, out
    assert_match(/lane zap mode=full -> https:\/\/staging\.example\.test\/?, https:\/\/staging\.example\.test\/admin/, out)
    assert_match(/profile: staging, target: https:\/\/staging\.example\.test/, out)
    assert_match(/zap image: ghcr\.io\/zaproxy\/zaproxy:/, out)
    assert_match(/base: origin\/main [0-9a-f]{12}/, out)
    assert_equal 0, @docker_calls
  end

  def test_reads_the_default_branch_change_md_not_the_working_tree
    write("CHANGE.md", BASE_CHANGE_MD.sub("https://staging.example.test", "https://branch.example.test"))
    _code, out = run_schedule(%w[schedule nightly-pentest --dry-run])
    assert_match(/staging\.example\.test/, out)
    refute_match(/branch\.example\.test/, out)
  end

  def test_unknown_schedule_exits_2
    code, out = run_schedule(%w[schedule no-such --dry-run])
    assert_equal 2, code
    assert_match(/no schedule named 'no-such'.*declared: nightly-pentest, weekly-load/, out)
  end

  def test_a_missing_schedule_name_exits_2
    code, out = run_schedule(%w[schedule --dry-run])
    assert_equal 2, code
    assert_match(/needs a schedule name/, out)
  end

  def test_full_scan_without_opt_in_exits_before_any_docker_call
    body = BASE_CHANGE_MD.sub("      allow_active_scan: true\n", "")
    write("CHANGE.md", body)
    git("commit", "-q", "-am", "drop opt-in")
    git("push", "-q", "origin", "main")
    code, out = run_schedule(%w[schedule nightly-pentest])
    assert_equal 2, code
    assert_match(/allow_active_scan/, out)
    assert_equal 0, @docker_calls
  end

  def test_the_runner_rechecks_the_opt_in_itself
    runner = StubRun.new(%w[schedule nightly-pentest], root: @repo)
    schedule = ChangeScheduleConfig::Schedule.new(name: "x", cron: "0 3 * * *", profile: "staging", runner: "local",
                                                  lanes: %w[zap], overrides: { "zap" => { "mode" => "full" } })
    config = Struct.new(:schedule_config).new(Struct.new(:x) { def allow_active_scan?(_p) = false }.new)
    code, out = capture { runner.send(:check_schedule_safety, config, schedule, "origin/main") }
    assert_equal 2, code
    assert_match(/refusing an active zap scan/, out)
  end

  def test_a_k6_script_that_differs_from_the_base_is_refused
    write("load/soak.js", "export default function () { /* edited */ }\n")
    code, out = run_schedule(%w[schedule weekly-load --dry-run])
    assert_equal 2, code
    assert_match(/k6 script 'load\/soak\.js' differs from origin\/main/, out)
  end

  def test_a_run_writes_a_schedule_record_and_never_a_sha_record
    findings = Findings.new
    findings.add(Finding.new(lane: "zap", check: "full scan", status: "pass"))
    code, out = run_schedule(%w[schedule nightly-pentest], findings: findings)
    assert_equal 0, code, out

    latest = ChangeScheduleStore.new("nightly-pentest", "staging").latest
    sha = git("rev-parse", "origin/main").strip
    assert_equal %w[finished_at lanes profile report_path result runner schedule sha started_at], latest.keys.sort
    assert_equal "pass", latest["result"]
    assert_equal "local", latest["runner"]
    assert_equal sha, latest["sha"]
    assert_equal({ "zap" => "pass" }, latest["lanes"])

    refute ChangeGateStore.new(sha, profile: "staging").read, "a schedule run must not write a per-sha record"
    refute ChangeGateCheck.new(sha: sha, profile: "staging").satisfied?
  end

  def test_the_zap_lane_context_allows_the_active_scan_only_after_the_recheck
    runner = StubRun.new(%w[schedule nightly-pentest --dry-run], root: @repo)
    refute runner.instance_variable_get(:@active_scan_allowed)
    capture { runner.send(:run_schedule) }
    assert runner.instance_variable_get(:@active_scan_allowed)
  end

  def test_a_failing_run_exits_1_and_records_fail
    findings = Findings.new
    findings.add(Finding.new(lane: "k6", check: "t", status: "fail"))
    code, = run_schedule(%w[schedule weekly-load], findings: findings)
    assert_equal 1, code
    assert_equal "fail", ChangeScheduleStore.new("weekly-load", "staging").latest["result"]
  end

  def test_schedule_trust_uses_the_default_branch_not_the_gate_trunk
    git("checkout", "-q", "-b", "develop")
    git("push", "-q", "origin", "develop")
    git("checkout", "-q", "main")
    body = BASE_CHANGE_MD.sub("  boot:\n    target_url: http://app:3000", "  boot:\n    up: echo new-boot\n    target_url: http://app:3000")
                         .sub("---\n\nSynthetic", "change_policy:\n  gate:\n    trunk: develop\n---\n\nSynthetic")
    write("CHANGE.md", body)
    git("commit", "-q", "-am", "new boot on main")
    git("push", "-q", "origin", "main")
    assert_includes body, "up: echo new-boot"
    assert_includes body, "trunk: develop"
    findings = Findings.new
    findings.add(Finding.new(lane: "zap", check: "full scan", status: "pass"))

    code, out = run_schedule(%w[schedule nightly-pentest], findings: findings)
    assert_equal 0, code, out
  end

  def test_reports_describe_the_overridden_lanes
    runner = StubRun.new(%w[schedule nightly-pentest], root: @repo)
    config = ChangeConfig.load(File.join(@repo, "CHANGE.md"), profile: "staging")
    runner.instance_variable_set(:@lane_overrides, { "zap" => { "targets" => [ "/only" ] }, "k6" => { "scenario" => { "assumptions" => "spike traffic" } } })

    assert_includes runner.send(:report_meta, config, Findings.new)["lane targets"], "zap=https://staging.example.test/only"
    assert_includes runner.send(:report_sections, config, [ "k6" ], {}).join, "spike traffic"
  end

  def test_scheduled_suites_must_match_the_base
    write("suites/a.yml", "suite: a\n")
    git("add", ".")
    git("commit", "-q", "-m", "suite")
    git("push", "-q", "origin", "main")
    runner = StubRun.new(%w[schedule nightly-pentest], root: @repo)
    runner.instance_variable_set(:@schedule, Struct.new(:name).new("nightly"))
    lane = ChangeConfig::LaneConfig.new("testcases", { "suites" => [ "suites/*.yml" ] }, @repo)
    guard = -> { capture { runner.send(:check_suites_match_base, lane, "origin/main") } }

    assert_nil guard.call.first, "identical suites pass"
    write("suites/b.yml", "suite: b\n")
    assert_equal 2, guard.call.first, "an extra branch-local suite is refused"
    File.delete(File.join(@repo, "suites/b.yml"))
    write("suites/a.yml", "suite: changed\n")
    assert_equal 2, guard.call.first, "edited suite content is refused"
  end

  def test_mode_flag_is_only_for_the_zap_scope
    code, out = capture { ChangeRun.new(%w[k6 --mode full]) }
    assert_equal 2, code
    assert_match(/--mode applies only to the zap scope/, out)
  end

  def test_standalone_full_zap_is_refused_without_opt_in
    runner = StubRun.new(%w[zap --mode full], root: @repo)
    config = ChangeConfig.load(File.join(@repo, "CHANGE.md"), profile: "production")
    code, out = capture { runner.send(:prepare_zap_mode, config) }
    assert_equal 2, code
    assert_match(/profile 'production' does not set allow_active_scan/, out)
  end

  def test_standalone_full_zap_is_allowed_on_an_opted_in_profile
    runner = StubRun.new(%w[zap --mode full], root: @repo)
    config = ChangeConfig.load(File.join(@repo, "CHANGE.md"), profile: "staging")
    runner.send(:prepare_zap_mode, config)
    assert runner.instance_variable_get(:@active_scan_allowed)
    assert_equal "full", runner.send(:scheduled_lane, config, "zap")["mode"]
  end
end
