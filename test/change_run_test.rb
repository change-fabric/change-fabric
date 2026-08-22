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
