# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require_relative "../scripts/change_config"
require_relative "../scripts/change_policy"
require_relative "../scripts/change_gate_store"

# The testcases lane's own config surface: what a profile may and may not say
# about it, what doctor reports about its suite files, and the promotion rule
# that gates a branch on the lane specifically.
class ChangeConfigTestcasesTest < Minitest::Test
  SUITE = <<~YAML
    suite: checkout
    cases:
      - id: happy-path
        tags: [smoke]
        acceptance: A guest can reach the confirmation page.
        steps:
          - goto: /
          - expect_visible: "main"
  YAML

  def with_config(config, profile = nil, suite: SUITE)
    Dir.mktmpdir do |root|
      File.write(File.join(root, "checkout.cf-testcases.yml"), suite) if suite
      path = File.join(root, "CHANGE.md")
      File.write(path, "#{YAML.dump("change_config" => config)}---\n\nbody\n")
      yield ChangeConfig.load(path, profile: profile), root
    end
  end

  def lane_config(extra = {})
    { "enabled" => true, "suites" => [ "*.cf-testcases.yml" ] }.merge(extra)
  end

  def base(extra = {}, profiles = nil)
    config = { "project" => "app", "lanes" => { "testcases" => lane_config(extra) } }
    config["profiles"] = profiles if profiles
    config
  end

  # --- profile overrides ---------------------------------------------------------

  # Exactly the where-not-what set: where the case is pointed and how that
  # environment is reached. Never which cases run or what they assert.
  def test_a_profile_may_override_base_url_basic_auth_and_auth
    profiles = { "staging" => { "lanes" => { "testcases" => {
      "base_url" => "https://staging.example.org",
      "basic_auth" => { "username_env" => "U", "password_env" => "P" },
      "auth" => { "login_url" => "/staging-login" }
    } } } }
    with_config(base({}, profiles), "staging") do |config, _root|
      lane = config.lane("testcases")
      assert_equal "https://staging.example.org", lane.base_url("https://fallback")
      assert_equal "/staging-login", lane["auth"]["login_url"]
      assert_equal "U", lane["basic_auth"]["username_env"]
    end
  end

  def test_a_profile_may_not_override_which_cases_run
    profiles = { "staging" => { "lanes" => { "testcases" => { "suites" => [ "other/*.yml" ] } } } }
    error = assert_raises(ChangeConfig::ConfigError) { with_config(base({}, profiles), "staging") { |_c, _r| } }
    assert_match(/lane 'testcases' sets unknown key\(s\): suites/, error.message)
  end

  # The lane reads no targets block, so accepting one would be a scope list
  # nothing consults.
  def test_targets_is_rejected_on_the_testcases_lane
    profiles = { "staging" => { "lanes" => { "testcases" => { "targets" => [ "/" ] } } } }
    error = assert_raises(ChangeConfig::ConfigError) { with_config(base({}, profiles), "staging") { |_c, _r| } }
    assert_match(/targets only applies to the zap lane/, error.message)
  end

  # --- doctor --------------------------------------------------------------------

  def test_doctor_counts_the_loaded_cases
    with_config(base) do |config, root|
      lines = ChangeConfig.doctor_lines(root, config)
      assert_includes lines, "testcases: 1 case(s) in 1 suite(s)"
    end
  end

  def test_doctor_reports_a_glob_that_matches_nothing
    with_config(base("suites" => [ "nope/*.yml" ])) do |config, root|
      lines = ChangeConfig.doctor_lines(root, config)
      assert lines.any? { |line| line.start_with?("error:") && line.include?("matched no readable file") }
    end
  end

  def test_doctor_reports_a_gate_tag_no_case_carries
    with_config(base("gate_tags" => [ "smoek" ])) do |config, root|
      lines = ChangeConfig.doctor_lines(root, config)
      assert lines.any? { |line| line.include?("gate_tags names 'smoek'") }
    end
  end

  def test_doctor_reports_a_broken_suite_file
    with_config(base, suite: "suite: broken\ncases: []\n") do |config, root|
      lines = ChangeConfig.doctor_lines(root, config)
      assert lines.any? { |line| line.include?("has no cases") }
    end
  end

  def test_doctor_is_silent_about_suites_when_the_lane_is_not_enabled
    config = { "project" => "app", "lanes" => { "a11y" => { "enabled" => true } } }
    with_config(config, nil, suite: nil) do |loaded, root|
      lines = ChangeConfig.doctor_lines(root, loaded)
      refute lines.any? { |line| line.include?("testcases") }
    end
  end

  # --- the promotion rule ---------------------------------------------------------

  def policy(front)
    Dir.mktmpdir do |root|
      File.write(File.join(root, "CHANGE.md"), "---\n#{front}---\n\nbody\n")
      yield ChangePolicy.for_repo(root)
    end
  end

  def test_require_testcases_is_opt_in
    front = <<~YAML
      change_policy:
        promotion:
          staging: { require_change_pass: true }
          production: { require_change_pass: true, require_testcases: true }
    YAML
    policy(front) do |rules|
      refute rules.require_testcases?("staging")
      assert rules.require_testcases?("production")
    end
  end

  def test_a_recorded_run_that_never_ran_the_lane_is_not_a_passing_lane
    home = Dir.mktmpdir
    previous = ENV.fetch("HOME", nil)
    ENV["HOME"] = home
    store = ChangeGateStore.new("abc123")
    store.record(scope: "all", status: "pass", project: "app", lanes: { "k6" => "pass" }, report: "r.md")

    assert store.comprehensive_pass?
    refute store.lane_passed?("testcases")

    store.record(scope: "all", status: "pass", project: "app",
                 lanes: { "k6" => "pass", "testcases" => "pass" }, report: "r.md")
    assert store.lane_passed?("testcases")
  ensure
    ENV["HOME"] = previous
  end
end
