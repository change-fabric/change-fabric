# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../scripts/change_run"

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
end
