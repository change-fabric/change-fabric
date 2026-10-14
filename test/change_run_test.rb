# frozen_string_literal: true

require_relative "test_helpers"
require "stringio"
require "yaml"
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

# --- QA coverage: the coverage subcommand and the per-sweep record -------------

class ChangeRunCoverageArgsTest < Minitest::Test
  def runner = ChangeRun.new(%w[all])

  def parse(argv) = runner.send(:parse_args, argv)

  def refused(argv)
    original = $stderr
    $stderr = StringIO.new
    error = assert_raises(SystemExit) { parse(argv) }
    assert_equal 2, error.status
    $stderr.string
  ensure
    $stderr = original
  end

  def test_coverage_build_parses_its_options
    args = parse(%w[coverage build --repo-copy --merge ci-a --merge ci-b/report-data.js --out site-out])
    assert_equal "coverage", args.scope
    assert_equal "build", args.coverage.verb
    assert args.coverage.repo_copy
    assert_equal %w[ci-a ci-b/report-data.js], args.coverage.merges
    assert_equal "site-out", args.coverage.out
    assert_empty args.coverage.files
  end

  def test_coverage_import_parses_files_and_identity_flags
    args = parse(%w[coverage import a.xml b.xml --format junit --label unit --sha abc1234 --branch main --pr 42
                    --profile staging --app web --out out])
    assert_equal "import", args.coverage.verb
    assert_equal %w[a.xml b.xml], args.coverage.files
    assert_equal [ "junit", "unit", "abc1234", "main", "42", "out" ],
                 [ args.coverage.format, args.coverage.label, args.coverage.sha, args.coverage.branch,
                   args.coverage.pr, args.coverage.out ]
    assert_equal "staging", args.profile
    assert_equal %w[web], args.apps
  end

  def test_coverage_import_parses_repeated_file_pairs
    args = parse(%w[coverage import --file coverage/lcov.info:lcov --file c:/ci/junit.xml:junit:unit])
    assert_empty args.coverage.files
    assert_equal [ { paths: [ "coverage/lcov.info" ], format: "lcov", label: nil },
                   { paths: [ "c:/ci/junit.xml" ], format: "junit", label: "unit" } ], args.coverage.entries
  end

  def test_coverage_import_refuses_a_bad_file_pair_and_a_stray_format
    assert_includes refused(%w[coverage import --file junit.xml]), "--file takes PATH:FORMAT[:LABEL]"
    assert_includes refused(%w[coverage import --file junit.xml:xunit]), "--file takes PATH:FORMAT[:LABEL]"
    assert_includes refused(%w[coverage import --file a.info:lcov --format junit]), "--format and --label name the FILE arguments"
    assert_includes refused(%w[coverage build --file a.info:lcov]), "does not take --file"
  end

  def test_a_sweep_scope_carries_no_coverage_args
    assert_nil parse(%w[all]).coverage
  end

  def test_coverage_needs_a_known_verb
    assert_includes refused(%w[coverage]), "verb must be one of build, import"
    assert_includes refused(%w[coverage publish]), "verb must be one of build, import"
  end

  def test_coverage_import_needs_a_file_and_a_format
    assert_includes refused(%w[coverage import --format junit]), "needs at least one FILE"
    assert_includes refused(%w[coverage import a.xml]), "needs --format"
  end

  def test_coverage_import_refuses_a_non_numeric_pr
    assert_includes refused(%w[coverage import a.xml --format junit --pr abc]), "--pr must be a number"
  end

  def test_coverage_build_refuses_files_and_import_flags
    assert_includes refused(%w[coverage build a.xml]), "takes no file arguments"
    assert_includes refused(%w[coverage build --format junit]), "does not take --format"
    assert_includes refused(%w[coverage build --profile staging]), "does not take --profile"
  end

  def test_coverage_import_refuses_build_flags
    assert_includes refused(%w[coverage import a.xml --format junit --repo-copy]), "does not take --repo-copy"
    assert_includes refused(%w[coverage import a.xml --format junit --merge x]), "does not take --merge"
  end

  def test_coverage_flags_are_refused_outside_coverage
    assert_includes refused(%w[all --out x]), "--out only apply to the coverage subcommand"
    assert_includes refused(%w[testcases --format junit --repo-copy]), "--format, --repo-copy only apply"
  end

  def test_coverage_refuses_sweep_flags_and_equals_forms
    assert_includes refused(%w[coverage build --target-url http://app]), "does not take --target-url"
    assert_includes refused(%w[coverage build --no-publish]), "does not take --no-publish"
    assert_includes refused(%w[coverage build --profile=staging]), "does not take --profile"
    assert_includes refused(%w[coverage build --prof prod]), "does not take --profile"
    assert_includes refused(%w[coverage build --a web]), "does not take --app"
    assert_includes refused(%w[coverage import a.xml --format junit --app web --app api]), "pass --app once"
  end

  def test_suite_is_refused_with_coverage
    assert_includes refused(%w[coverage build --suite checkout]), "--suite narrows the testcases lane"
  end
end

# A sweep with every container step replaced: the app never boots, the lanes
# hand back fixed findings, and the report is a path. Everything after the
# lanes (the gate record, the artifact step, the coverage step) is real.
class CoverageSweepRun < ChangeRun
  def initialize(argv, root:, findings: [], step: nil)
    @root = root
    @fixture_findings = findings
    @fixture_step = step
    super(argv)
  end

  private

  def repo_root = @root
  def toolkit_version = "test-toolkit"
  def with_app(_config, _artifact = nil) = yield(nil)

  def execute(_config, _lanes, _ctx)
    findings = Findings.new
    @fixture_findings.each { |finding| findings.add(finding) }
    [ findings, {} ]
  end

  def write_report(*, **) = { markdown: File.join(@root, "report.md"), csv: File.join(@root, "report.csv") }

  def coverage_step = @fixture_step || super
end

class ChangeRunCoverageTest < Minitest::Test
  include SkillTempHome

  def setup
    super
    @repo = Dir.mktmpdir
    GitFixture.git_init(@repo, "-b", "main")
    GitFixture.git(@repo, "config", "user.email", "test@example.com")
    GitFixture.git(@repo, "config", "user.name", "Test")
    File.write(File.join(@repo, "app.txt"), "one")
    GitFixture.git(@repo, "add", "app.txt")
    GitFixture.git(@repo, "commit", "-q", "-m", "initial")
  end

  def teardown
    FileUtils.remove_entry(@repo)
    super
  end

  def change_md = File.join(@repo, "CHANGE.md")
  def head_sha = GitFixture.git(@repo, "rev-parse", "HEAD").strip

  def write_change_md(change_config)
    File.write(change_md, "#{YAML.dump('change_config' => change_config)}---\n\nbody\n")
  end

  def app_config(project)
    { "project" => project, "boot" => { "target_url" => "http://app:3000" },
      "lanes" => { "a11y" => { "enabled" => true, "routes" => [ "/" ] } } }
  end

  def passing = [ Finding.new(lane: "a11y", check: "axe", status: "pass", location: "/") ]

  def capture
    original = $stderr
    $stderr = StringIO.new
    result = yield
    [ result, $stderr.string ]
  ensure
    $stderr = original
  end

  def sweep(argv, step: nil)
    capture { CoverageSweepRun.new(argv + [ "--config", change_md ], root: @repo, findings: passing, step: step).send(:run_sweep) }
  end

  def store_runs(project)
    path = File.join(@home, ".claude", "cf", "coverage", project, "report-data.js")
    assert File.file?(path), "expected a data file at #{path}"
    ChangeCoverageStore.parse(File.read(path)).runs
  end

  def test_coverage_never_asks_whether_docker_is_available
    original = ChangeDocker.method(:available?)
    ChangeDocker.define_singleton_method(:available?) { raise "docker was probed" }
    code, output = capture { StubChangeRun.new(%w[coverage build], root: @repo).run }
    assert_equal 0, code
    assert_includes output, "[change] [coverage] rebuilt"
  ensure
    ChangeDocker.define_singleton_method(:available?, original)
  end

  def test_a_passing_single_app_run_writes_one_run_line
    write_change_md(app_config("fixture-app"))
    code, output = sweep(%w[all])

    assert_equal 0, code
    assert_includes output, "[change] [coverage] recorded 1 run(s)"
    runs = store_runs("fixture-app")
    assert_equal 1, runs.size
    assert_equal "change_run", runs.first["source"]
    assert_equal "all", runs.first["scope"]
    assert_equal "#{runs.first['sweep_id']}-run", runs.first["id"]
    assert_equal head_sha, runs.first.dig("git", "sha")
  end

  def test_a_multi_app_sweep_writes_one_line_per_app_sharing_the_sweep_id
    %w[web api].each do |name|
      path = File.join(@repo, "apps", name, "CHANGE.app.yml")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, YAML.dump("change_config" => app_config(name)))
    end
    write_change_md("project" => "fixture-repo", "apps" => {
                      "web" => { "config" => "apps/web/CHANGE.app.yml" },
                      "api" => { "config" => "apps/api/CHANGE.app.yml" }
                    })
    code, output = sweep(%w[all])

    assert_equal 0, code
    assert_includes output, "[change] [coverage] [web] recorded 1 run(s)"
    runs = store_runs("fixture-repo")
    assert_equal 2, runs.size
    assert_equal 1, runs.map { |run| run["sweep_id"] }.uniq.size
    assert_equal %w[api web], runs.map { |run| run["app"] }.sort
    assert_equal [ "#{runs.first['sweep_id']}-run-api", "#{runs.first['sweep_id']}-run-web" ], runs.map { |run| run["id"] }.sort
  end

  def test_a_multi_app_sweep_records_its_imports_once_on_the_first_app
    %w[web api].each do |name|
      path = File.join(@repo, "apps", name, "CHANGE.app.yml")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, YAML.dump("change_config" => app_config(name)))
    end
    FileUtils.cp(File.expand_path("fixtures/coverage/lcov-basic.info", __dir__), File.join(@repo, "lcov.info"))
    front = { "change_config" => { "project" => "fixture-repo", "apps" => {
                "web" => { "config" => "apps/web/CHANGE.app.yml" }, "api" => { "config" => "apps/api/CHANGE.app.yml" }
              } },
              "qa_report" => { "imports" => { "coverage" => [ { "path" => "lcov.info", "format" => "lcov" } ] } } }
    File.write(change_md, "#{YAML.dump(front)}---\n\nbody\n")
    code, = sweep(%w[all])

    assert_equal 0, code
    imports = store_runs("fixture-repo").to_h { |run| [ run["app"], run["imports"] ] }
    assert_equal 1, imports["web"]["coverage"].size
    assert_nil imports["api"]
  end

  # Profiles may rename config.project (gate records show `<name>-production`);
  # the coverage store must not follow it or one repo's history splits in two.
  def test_the_store_key_is_the_registry_project_when_a_profile_renames_the_project
    config = app_config("fixture-app").merge("profiles" => { "production" => { "project" => "fixture-app-production" } })
    write_change_md(config)
    sweep(%w[all --profile production])

    runs = store_runs("fixture-app")
    assert_equal "production", runs.first["profile"]
    refute File.exist?(File.join(@home, ".claude", "cf", "coverage", "fixture-app-production"))
  end

  class RaisingStep
    def record_sweep(**) = raise("boom")
  end

  def test_a_raising_coverage_step_changes_neither_the_exit_code_nor_the_gate
    write_change_md(app_config("fixture-app"))
    code, output = sweep(%w[all], step: RaisingStep.new)

    assert_equal 0, code
    assert_includes output, "[change] [coverage] skipped (RuntimeError: boom)"
    assert_includes output, "[change] PASS"
    gate = ChangeGateStore.new(head_sha).read
    assert_equal "pass", gate["status"]
    assert_equal "all", gate["scope"]
    assert_equal({ "a11y" => "pass" }, gate["lanes"])
  end

  class StepRaising
    def initialize(error) = @error = error
    def record_sweep(**) = raise(@error)
  end

  def test_a_stack_overflow_in_the_coverage_step_changes_neither_the_exit_code_nor_the_gate
    write_change_md(app_config("fixture-app"))
    code, output = sweep(%w[all], step: StepRaising.new(SystemStackError.new("stack level too deep")))

    assert_equal 0, code
    assert_includes output, "[change] [coverage] skipped (SystemStackError: stack level too deep)"
    gate = ChangeGateStore.new(head_sha).read
    assert_equal "pass", gate["status"]
    assert_equal({ "a11y" => "pass" }, gate["lanes"])
  end

  def test_an_interrupt_in_the_coverage_step_still_propagates
    write_change_md(app_config("fixture-app"))
    assert_raises(Interrupt) { sweep(%w[all], step: StepRaising.new(Interrupt.new)) }
  end

  # A suite file nested deep enough to overflow YAML.safe_load raises
  # SystemStackError, which no StandardError rescue catches. The sweep must
  # still finish with its own verdict.
  def test_a_suite_yaml_that_overflows_the_parser_does_not_end_the_sweep
    suites = File.join(@repo, "suites")
    FileUtils.mkdir_p(suites)
    File.write(File.join(suites, "deep.yml"), "suite: s\ncases: #{'[' * 20_000}#{']' * 20_000}\n")
    config = app_config("fixture-app")
    config["lanes"]["testcases"] = { "enabled" => false, "suites" => [ "suites/*.yml" ] }
    write_change_md(config)
    code, output = sweep(%w[a11y])

    assert_equal 0, code, output
    assert_includes output, "[change] [coverage] skipped (SystemStackError: "
    assert_includes output, "[change] PASS"
    assert_equal "pass", ChangeGateStore.new(head_sha).read["status"]
  end
end
