# frozen_string_literal: true

require_relative "test_helpers"
require "stringio"
require_relative "../scripts/change_run"
require_relative "../scripts/change_gate_store"

# The dogfooding fix: a boot or health failure used to abort with nothing but
# the command line, hiding the one line of output that names the real cause.
# These exercise that the captured subprocess output actually reaches the
# abort message, via the same private methods change_run.rb's own flow calls.
class ChangeRunTest < Minitest::Test
  def runner = ChangeRun.new(%w[all])

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  Boot = Struct.new(:up, :down, :health_url, :health_status, :health_timeout, :network, :target_url) do
    def up? = !up.to_s.empty?
    def env_files = []
  end

  def test_boot_up_surfaces_captured_output_on_failure
    boot = Boot.new("sh -c 'echo BOOM 1>&2; exit 1'")
    output = capture_stderr { assert_raises(SystemExit) { runner.send(:boot_up, boot) } }
    assert_match(/BOOM/, output)
    assert_match(/boot command failed/, output)
  end

  def test_wait_healthy_surfaces_curl_output_on_timeout
    boot = Boot.new(nil, nil, "http://127.0.0.1:1/nope", 200, 0)
    output = capture_stderr { assert_raises(SystemExit) { runner.send(:wait_healthy, boot) } }
    assert_match(/never became healthy/, output)
    assert_match(/last health check output/, output)
  end

  # report_sections (F6 step 1): the browserless lane's own per-cell timing
  # table rides alongside the k6 narrative as an extra Markdown section, read
  # off the lane instance execute() already ran rather than re-derived.
  StubConfig = Struct.new(:scenario) do
    def lane(_name) = { "scenario" => scenario }
  end

  def test_report_sections_includes_browserless_timing_when_the_lane_ran
    lane = Object.new
    def lane.timing_section = "### Browserless per-cell timing (ms)"
    sections = runner.send(:report_sections, StubConfig.new(nil), %w[browserless], { "browserless" => lane })
    assert_equal [ "### Browserless per-cell timing (ms)" ], sections
  end

  def test_report_sections_omits_browserless_timing_when_the_lane_did_not_run
    sections = runner.send(:report_sections, StubConfig.new(nil), %w[a11y], {})
    assert_empty sections
  end

  def test_report_sections_omits_browserless_timing_when_it_has_no_data
    lane = Object.new
    def lane.timing_section = nil
    sections = runner.send(:report_sections, StubConfig.new(nil), %w[browserless], { "browserless" => lane })
    assert_empty sections
  end

  def test_sweep_scope_is_a_valid_argument
    args = runner.send(:parse_args, %w[sweep])
    assert_equal "sweep", args.scope
    assert_equal ChangeConfig::DEFAULT_PATH, args.config_path
    assert_nil args.profile
    assert_equal [], args.apps
  end

  def test_profile_flag_is_parsed
    args = runner.send(:parse_args, %w[all --profile staging])
    assert_equal "all", args.scope
    assert_equal ChangeConfig::DEFAULT_PATH, args.config_path
    assert_equal "staging", args.profile
  end

  def test_app_flag_is_repeatable
    args = runner.send(:parse_args, %w[all --app portal --app scattergram])
    assert_equal %w[portal scattergram], args.apps
  end

  def test_target_url_and_health_url_flags_are_parsed
    args = runner.send(:parse_args, %w[all --target-url https://preview.example --health-url https://preview.example/health])
    assert_equal "https://preview.example", args.target_url
    assert_equal "https://preview.example/health", args.health_url
  end

  # --suite: the deterministic regression entry point cf:qa drives. Repeatable,
  # and it reaches the lane on the run context rather than through the config,
  # because it narrows this invocation and not the repo.
  def test_suite_flag_is_repeatable_on_the_testcases_scope
    args = runner.send(:parse_args, %w[testcases --suite checkout --suite smoke])
    assert_equal %w[checkout smoke], args.suites
  end

  def test_suite_flag_is_accepted_on_a_full_sweep
    assert_equal %w[checkout], runner.send(:parse_args, %w[all --suite checkout]).suites
  end

  def test_no_suite_flag_leaves_the_selection_empty
    assert_equal [], runner.send(:parse_args, %w[testcases]).suites
  end

  # A flag that is silently ignored is indistinguishable, from the outside, from
  # a filter that matched, so a scope no testcases lane runs in refuses it.
  def test_suite_flag_is_refused_on_a_scope_that_cannot_read_it
    output = capture_stderr { assert_raises(SystemExit) { runner.send(:parse_args, %w[k6 --suite checkout]) } }
    assert_includes output, "--suite narrows the testcases lane"
  end

  # No browser lane enabled, so the context is built without standing up a real
  # browserless container; what is under test is the selection reaching it.
  ContextConfig = Struct.new(:boot) do
    def enabled_lanes = %w[k6]
  end

  def test_the_suite_selection_reaches_the_lane_context
    run = ChangeRun.new(%w[all --suite checkout])
    config = ContextConfig.new(Boot.new(nil, nil, "http://app/health", 200, 1, "net", "http://app"))
    captured = nil
    run.send(:with_context, config, Struct.new(:name).new("net")) { |ctx| captured = ctx }

    assert_equal %w[checkout], captured.suite_select
  end

  # boot.env_file: the compose build-arg trap fix. A KEY=VALUE file gets parsed
  # (not shell-sourced) and reaches the boot subprocess environment.
  def test_boot_up_sources_env_file_into_the_subprocess
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env.local")
      File.write(env_path, "export FOO=bar\n# a comment\n\nQUOTED=\"baz\"\n")
      out_path = File.join(dir, "out.txt")
      boot = Boot.new("sh -c 'echo $FOO-$QUOTED > #{out_path}'")
      boot.define_singleton_method(:env_files) { [ env_path ] }

      capture_stderr { runner.send(:boot_up, boot) }

      assert_equal "bar-baz\n", File.read(out_path)
    end
  end

  def test_boot_up_fails_fast_on_a_missing_env_file
    boot = Boot.new("true")
    boot.define_singleton_method(:env_files) { [ "/no/such/.env.local" ] }
    output = capture_stderr { assert_raises(SystemExit) { runner.send(:boot_up, boot) } }
    assert_match(%r{boot\.env_file not found: /no/such/\.env\.local}, output)
  end

  FakeBoot = Struct.new(:target_url)
  FakeConfig = Struct.new(:profile, :boot, :lane_targets)

  def test_report_meta_states_the_resolved_profile_and_target
    config = FakeConfig.new("staging", FakeBoot.new("https://staging.example"), { "k6" => [ "https://staging.example" ] })
    meta = runner.send(:report_meta, config, Findings.new)
    assert_equal "staging", meta["profile"]
    assert_equal "https://staging.example", meta["target"]
    assert_equal "k6=https://staging.example", meta["lane targets"]
  end

  def test_report_meta_states_none_when_there_is_no_profile
    config = FakeConfig.new(nil, FakeBoot.new("http://app:3000"), {})
    meta = runner.send(:report_meta, config, Findings.new)
    assert_equal "(none)", meta["profile"]
  end

  def test_for_tag_flag_is_parsed
    args = runner.send(:parse_args, %w[all --for-tag staging/v1.4.0])
    assert_equal "staging/v1.4.0", args.for_tag
  end

  def test_gate_status_scope_is_a_valid_argument
    args = runner.send(:parse_args, %w[gate-status --ref staging/v1.4.0])
    assert_equal "gate-status", args.scope
    assert_equal "staging/v1.4.0", args.ref
  end

  # --- the run manifest ---------------------------------------------------------

  ManifestConfig = Struct.new(:digest)

  def manifest(lanes) = runner.send(:run_manifest, ManifestConfig.new("abc123"), lanes)

  def test_the_manifest_names_the_digest_pinned_image_of_every_lane_that_ran
    all = manifest(%w[k6 a11y zap browserless])
    assert_equal ChangeDocker::K6_IMAGE, all["k6 image"]
    assert_equal ChangeDocker::ZAP_IMAGE, all["zap image"]
    assert_equal ChangeDocker::BROWSERLESS_IMAGE, all["browserless image"]
    assert_match(/@sha256:/, all["browserless image"])
  end

  # The manifest describes this run, not the platform: a k6-only run names no
  # browser image it never started.
  def test_the_manifest_omits_an_image_no_lane_in_this_run_used
    only_k6 = manifest(%w[k6])
    assert_equal ChangeDocker::K6_IMAGE, only_k6["k6 image"]
    refute only_k6.key?("browserless image")
    refute only_k6.key?("zap image")
    refute only_k6.key?("axe-core")
  end

  def test_the_browser_image_is_named_once_for_either_browser_lane
    assert_equal ChangeDocker::BROWSERLESS_IMAGE, manifest(%w[browserless])["browserless image"]
    assert_equal ChangeDocker::BROWSERLESS_IMAGE, manifest(%w[a11y])["browserless image"]
  end

  def test_the_manifest_records_the_vendored_axe_version_when_the_a11y_lane_ran
    assert_equal ChangeLaneA11y::AXE_VERSION, manifest(%w[a11y])["axe-core"]
  end

  def test_the_manifest_records_the_resolved_config_digest_and_the_toolkit_version
    recorded = manifest(%w[k6])
    assert_equal "sha256:abc123", recorded["config digest"]
    refute_empty recorded["toolkit version"]
  end

  # --- the retry policy ----------------------------------------------------------

  # A lane that hands back whatever findings its script was seeded with, one
  # list per attempt, so a retry can be observed without a container.
  class ScriptedLane
    ATTEMPTS = []

    def initialize(config, _ctx)
      @config = config
      @attempt = ATTEMPTS.shift
    end

    def run = @attempt
  end

  def with_scripted_lane(attempts)
    ScriptedLane::ATTEMPTS.replace(attempts)
    original = ChangeRun::LANE_CLASSES
    ChangeRun.send(:remove_const, :LANE_CLASSES)
    ChangeRun.const_set(:LANE_CLASSES, original.merge("k6" => ScriptedLane))
    capture_stderr { yield }
  ensure
    ChangeRun.send(:remove_const, :LANE_CLASSES)
    ChangeRun.const_set(:LANE_CLASSES, original)
    ScriptedLane::ATTEMPTS.clear
  end

  def finding(status) = Finding.new(lane: "k6", check: "p95", status: status)

  def lane_config(raw) = ChangeConfig::LaneConfig.new("k6", raw, "/repo")

  # A gate that quietly re-runs until green is not a gate, so nothing retries
  # unless a lane's own config asks: the second scripted attempt, which would
  # have passed, is never reached.
  def test_a_lane_runs_exactly_once_by_default
    results = nil
    with_scripted_lane([ [ finding("fail") ], [ finding("pass") ] ]) do
      results, = runner.send(:run_lane, "k6", lane_config({}), nil)
      assert_equal 1, ScriptedLane::ATTEMPTS.size
    end
    assert_equal [ "fail" ], results.map(&:status)
    assert_equal [ 1 ], results.map(&:attempts)
  end

  # A pass bought by a retry is still a pass, and is labeled as bought.
  def test_a_pass_that_needed_a_retry_is_recorded_as_flaky
    results = nil
    with_scripted_lane([ [ finding("fail") ], [ finding("pass") ] ]) do
      results, = runner.send(:run_lane, "k6", lane_config("retries" => 1), nil)
    end
    assert_equal [ "pass" ], results.map(&:status)
    assert_equal [ 2 ], results.map(&:attempts)
    assert results.all?(&:flaky)
  end

  # A failure that survives its budget is a plain failure, never flaky: nothing
  # about it was intermittent.
  def test_a_failure_that_survives_every_retry_is_not_flaky
    results = nil
    with_scripted_lane([ [ finding("fail") ], [ finding("fail") ], [ finding("fail") ] ]) do
      results, = runner.send(:run_lane, "k6", lane_config("retries" => 2), nil)
    end
    assert_equal [ "fail" ], results.map(&:status)
    assert_equal [ 3 ], results.map(&:attempts)
    refute results.any?(&:flaky)
  end

  def test_a_lane_that_passes_first_time_never_burns_its_budget
    results = nil
    with_scripted_lane([ [ finding("pass") ], [ finding("fail") ] ]) do
      results, = runner.send(:run_lane, "k6", lane_config("retries" => 1), nil)
    end
    assert_equal [ 1 ], results.map(&:attempts)
    refute results.any?(&:flaky)
  end

  def test_a_negative_retry_count_is_floored_at_no_retries
    assert_equal 0, runner.send(:retry_budget, lane_config("retries" => -3))
    assert_equal 0, runner.send(:retry_budget, lane_config({}))
    assert_equal 2, runner.send(:retry_budget, lane_config("retries" => 2))
  end
end

# --for-tag and gate-status resolve against a real CHANGE.md and a real git
# repo, so these run against a throwaway fixture repo, with only repo_root
# stubbed -- exactly the pattern change_tag_guard_test.rb and
# change_merge_guard_test.rb already use to exercise the real decision logic.
class StubChangeRun < ChangeRun
  def initialize(argv, root:)
    @root = root
    super(argv)
  end

  private

  def repo_root = @root
end

class ChangeRunForTagAndGateStatusTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir
    @prev_home = Dir.home
    ENV["HOME"] = @home

    @repo = Dir.mktmpdir
    GitFixture.git_init(@repo, "-b", "main")
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "Test")
    write_file("app.txt", "one")
    git("add", "app.txt")
    git("commit", "-q", "-m", "initial")
  end

  def teardown
    ENV["HOME"] = @prev_home
    FileUtils.remove_entry(@home)
    FileUtils.remove_entry(@repo)
  end

  def git(*args) = GitFixture.git(@repo, *args)
  def write_file(name, contents) = File.write(File.join(@repo, name), contents)
  def head_sha = git("rev-parse", "HEAD").strip

  def write_change_md(policy_yaml)
    File.write(File.join(@repo, "CHANGE.md"), "---\n#{policy_yaml}---\n\nbody\n")
  end

  def record_pass(sha: head_sha, profile: nil)
    ChangeGateStore.new(sha, profile: profile).record(
      scope: "all", status: "pass", project: "app", lanes: {}, report: "r.md"
    )
  end

  def runner(argv) = StubChangeRun.new(argv, root: @repo)

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    result = yield
    [ result, $stderr.string ]
  ensure
    $stderr = original
  end

  TAG_POLICY = <<~YAML
    change_policy:
      promotion:
        tag:staging/v*: { require_change_pass: true, profile: staging }
  YAML

  def test_resolve_for_tag_profiles_selects_the_matched_rules_profile
    write_change_md(TAG_POLICY)
    _result, output = capture_stderr do
      profiles = runner(%w[all]).send(:resolve_for_tag_profiles, "staging/v1.4.0")
      assert_equal [ "staging" ], profiles
    end
    assert_equal "", output
  end

  def test_resolve_for_tag_profiles_exits_2_when_no_rule_matches
    write_change_md(TAG_POLICY)
    _result, output = capture_stderr do
      assert_raises(SystemExit) { runner(%w[all]).send(:resolve_for_tag_profiles, "production/v1.0.0") }
    end
    assert_match(/no change_policy\.promotion tag: rule matches/, output)
  end

  def test_resolve_for_tag_profiles_exits_2_on_profile_conflict
    write_change_md(TAG_POLICY)
    _result, output = capture_stderr do
      assert_raises(SystemExit) do
        runner(%w[all --profile production]).send(:resolve_for_tag_profiles, "staging/v1.4.0")
      end
    end
    assert_match(/conflicts with the profile/, output)
  end

  def test_resolve_for_tag_profiles_allows_a_tag_pointing_at_head
    write_change_md(TAG_POLICY)
    git("tag", "staging/v1.4.0")
    _result, output = capture_stderr do
      profiles = runner(%w[all]).send(:resolve_for_tag_profiles, "staging/v1.4.0")
      assert_equal [ "staging" ], profiles
    end
    assert_equal "", output
  end

  def test_resolve_for_tag_profiles_refuses_a_tag_not_pointing_at_head
    write_change_md(TAG_POLICY)
    git("tag", "staging/v1.4.0")
    write_file("app.txt", "two")
    git("add", "app.txt")
    git("commit", "-q", "-m", "second")

    _result, output = capture_stderr do
      assert_raises(SystemExit) { runner(%w[all]).send(:resolve_for_tag_profiles, "staging/v1.4.0") }
    end
    assert_match(/HEAD is/, output)
  end

  def test_gate_status_returns_0_when_there_is_no_change_md
    result, output = capture_stderr { runner(%w[gate-status]).send(:gate_status) }
    assert_equal 0, result
    assert_match(/no CHANGE\.md/, output)
  end

  def test_gate_status_returns_0_when_no_rule_matches_ref
    write_change_md(TAG_POLICY)
    result, = capture_stderr { runner(%w[gate-status --ref main]).send(:gate_status) }
    assert_equal 0, result
  end

  def test_gate_status_returns_1_when_a_matching_rule_is_not_satisfied
    write_change_md(TAG_POLICY)
    git("tag", "staging/v1.4.0")
    result, output = capture_stderr { runner(%w[gate-status --ref staging/v1.4.0]).send(:gate_status) }
    assert_equal 1, result
    assert_match(/NOT SATISFIED/, output)
  end

  def test_gate_status_returns_0_when_the_matching_rule_is_satisfied
    write_change_md(TAG_POLICY)
    git("tag", "staging/v1.4.0")
    record_pass(profile: "staging")
    result, output = capture_stderr { runner(%w[gate-status --ref staging/v1.4.0]).send(:gate_status) }
    assert_equal 0, result
    assert_match(/SATISFIED/, output)
  end

  def test_gate_status_returns_2_when_the_ref_cannot_be_resolved
    write_change_md(TAG_POLICY)
    result, output = capture_stderr { runner(%w[gate-status --ref no-such-ref]).send(:gate_status) }
    assert_equal 2, result
    assert_match(/could not resolve ref/, output)
  end
end
