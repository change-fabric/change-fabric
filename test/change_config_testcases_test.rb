# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require "date"
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

  # --- launch_args ---------------------------------------------------------------

  def test_launch_args_accepts_a_list_of_flags
    with_config(base("launch_args" => [ "--disable-features=LocalNetworkAccessChecks" ])) do |config, _root|
      assert_equal [ "--disable-features=LocalNetworkAccessChecks" ], config.lane("testcases")["launch_args"]
    end
  end

  def test_launch_args_rejects_an_entry_that_is_not_a_flag
    error = assert_raises(ChangeConfig::ConfigError) { with_config(base("launch_args" => [ "disable-features=X" ])) { |_c, _r| } }
    assert_match(/launch_args must be a list of Chromium flags/, error.message)
  end

  def test_launch_args_rejects_a_bare_string
    assert_raises(ChangeConfig::ConfigError) { with_config(base("launch_args" => "--x")) { |_c, _r| } }
  end

  # --- parallel ------------------------------------------------------------------

  def test_parallel_accepts_one_to_ten
    [ 1, 10 ].each do |value|
      with_config(base("parallel" => value)) do |config, _root|
        assert_equal value, config.lane("testcases")["parallel"]
      end
    end
  end

  def test_parallel_rejects_out_of_range_and_non_integers
    [ 0, 11, "4", 2.5 ].each do |value|
      error = assert_raises(ChangeConfig::ConfigError) { with_config(base("parallel" => value)) { |_c, _r| } }
      assert_match(/lanes.testcases.parallel must be an integer from 1 to 10/, error.message)
    end
  end

  # --- personas (0.22.0) --------------------------------------------------------

  ADMIN = { "login_url" => "/admin-login", "email_env" => "AE", "password_env" => "AP" }.freeze

  def test_personas_accept_named_auth_blocks
    with_config(base("personas" => { "admin" => ADMIN })) do |config, _root|
      assert_equal "/admin-login", config.lane("testcases")["personas"]["admin"]["login_url"]
    end
  end

  def test_personas_reserve_default_and_anonymous
    %w[default anonymous].each do |name|
      error = assert_raises(ChangeConfig::ConfigError) { with_config(base("personas" => { name => ADMIN })) { |_c, _r| } }
      assert_match(/personas.#{name} is reserved/, error.message)
    end
  end

  def test_expired_when_takes_one_selector_or_one_probe
    [ { "selector" => "#signed-out" }, { "probe_url" => "/api/me", "expect_status" => [ 401, 302 ] } ].each do |rule|
      with_config(base("personas" => { "admin" => ADMIN.merge("expired_when" => rule) })) { |_c, _r| }
      with_config(base("auth" => ADMIN.merge("expired_when" => rule))) { |_c, _r| }
    end
    [ {}, { "selector" => "#x", "probe_url" => "/me", "expect_status" => 401 }, { "probe_url" => "/me" },
      { "probe_url" => "me", "expect_status" => 401 }, { "selector" => "" } ].each do |rule|
      assert_raises(ChangeConfig::ConfigError) do
        with_config(base("personas" => { "admin" => ADMIN.merge("expired_when" => rule) })) { |_c, _r| }
      end
    end
  end

  def test_personas_must_be_a_mapping_of_auth_blocks
    [ [ "admin" ], { "admin" => "nope" }, { "bad name" => ADMIN } ].each do |value|
      assert_raises(ChangeConfig::ConfigError) { with_config(base("personas" => value)) { |_c, _r| } }
    end
  end

  def test_doctor_reports_a_case_naming_an_undefined_persona
    suite = SUITE.sub("suite: checkout\n", "suite: checkout\nsuite_version: 3\n")
                 .sub("    tags: [smoke]\n", "    tags: [smoke]\n    persona: ghost\n")
    with_config(base, suite: suite) do |config, root|
      assert_includes ChangeConfig.doctor_lines(root, config),
                      "error: a testcases case names persona 'ghost', which lanes.testcases.personas does not define"
    end
  end

  # --- doctor --------------------------------------------------------------------

  def test_doctor_prints_the_installed_suite_version
    with_config(base) do |config, root|
      assert_includes ChangeConfig.doctor_lines(root, config),
                      "testcases: this install reads suite_version up to #{ChangeSuiteSchema::SUITE_VERSION}"
    end
  end

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

  # --- doctor on a quarantine ------------------------------------------------------

  # Real dates against the real clock, because doctor's whole job is to tell a
  # person what their file says TODAY.
  def quarantined(days_out, reason: "the sandbox gateway drops a redirect")
    lines = [ "suite: checkout", "cases:", "  - id: happy-path", "    tags: [smoke]",
              "    acceptance: A guest can reach the confirmation page.", "    quarantined: true" ]
    lines << "    quarantine_reason: #{reason}" unless reason.nil?
    lines << "    quarantine_until: #{(Date.today + days_out).iso8601}"
    "#{lines.concat([ "    steps:", "      - goto: /" ]).join("\n")}\n"
  end

  def doctor_on(suite)
    with_config(base, suite: suite) { |config, root| yield ChangeConfig.doctor_lines(root, config) }
  end

  def test_doctor_is_quiet_about_a_quarantine_with_time_left
    doctor_on(quarantined(60)) do |lines|
      refute lines.any? { |line| line.include?("quarantine") }
    end
  end

  def test_doctor_warns_on_an_approaching_expiry
    doctor_on(quarantined(3)) do |lines|
      warning = lines.find { |line| line.start_with?("warning:") && line.include?("quarantine expires") }
      assert warning
      assert_includes warning, "3 day(s)"
      assert_includes warning, "the sandbox gateway drops a redirect"
    end
  end

  # The date is the day the quarantine ends, so it has already lapsed on it.
  def test_doctor_errors_on_a_quarantine_expiring_today
    doctor_on(quarantined(0)) do |lines|
      assert lines.any? { |line| line.start_with?("error:") && line.include?("expired quarantine") }
    end
  end

  def test_doctor_errors_on_an_expired_quarantine
    doctor_on(quarantined(-14)) do |lines|
      error = lines.find { |line| line.start_with?("error:") && line.include?("expired quarantine") }
      assert error
      assert_includes error, "checkout/happy-path"
      assert_includes error, "it gates again"
    end
  end

  def test_doctor_errors_on_a_quarantine_with_no_reason
    doctor_on(quarantined(30, reason: nil)) do |lines|
      assert lines.any? { |line| line.start_with?("error:") && line.include?("no `quarantine_reason`") }
    end
  end

  def test_doctor_errors_on_a_quarantine_with_no_date
    suite = quarantined(30).sub(/    quarantine_until: .*\n/, "")
    doctor_on(suite) do |lines|
      assert lines.any? { |line| line.start_with?("error:") && line.include?("no `quarantine_until` date") }
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

  MEASURE_SUITE = <<~YAML
    suite_version: 5
    suite: orders
    cases:
      - id: unread
        acceptance: The header total is shown.
        steps:
          - goto: /orders
          - capture: { var: header_total, selector: ".total", kind: number }
          - expect_visible: "main"
      - id: compared
        acceptance: The header total matches the list.
        steps:
          - goto: /orders
          - capture: { var: header_total, selector: ".total", kind: number }
          - expect_equal: { var: header_total, selector: ".rows", kind: count }
      - id: static
        acceptance: The page says Orders.
        steps:
          - goto: /orders
          - expect_text: { selector: "h1", equals: "Orders" }
  YAML

  def doctor_lines(suite)
    with_config(base, suite: suite.sub("suite: checkout", "suite: checkout")) do |config, _root|
      ChangeConfig.testcase_suite_lines(config)
    end
  end

  def test_doctor_warns_about_a_captured_figure_nothing_compares
    lines = doctor_lines(MEASURE_SUITE)

    assert_includes lines, "warning: testcases captured figure header_total in orders/unread is never compared " \
                           "(no expect_equal or expect_relation reads it)"
    refute(lines.any? { |line| line.include?("orders/compared") && line.include?("never compared") })
  end

  RELATION_SUITE = <<~YAML
    suite_version: 8
    suite: orders
    cases:
      - id: related
        acceptance: The header total matches the list.
        steps:
          - goto: /orders
          - capture: { var: header_total, selector: ".total", kind: number }
          - capture: { var: rows, selector: ".rows", kind: count }
          - capture: { var: unrelated, selector: ".other", kind: number }
          - expect_relation: { relation: equal, reads: { a: header_total, b: rows } }
  YAML

  def test_doctor_counts_an_expect_relation_as_comparing_its_reads
    lines = doctor_lines(RELATION_SUITE)

    refute(lines.any? { |line| line.include?("figure header_total") || line.include?("figure rows") }, lines.inspect)
    assert(lines.any? { |line| line.include?("figure unrelated in orders/related is never compared") }, "unrelated is read by no relation")
  end

  def test_doctor_warns_about_a_case_asserting_only_static_text
    lines = doctor_lines(MEASURE_SUITE)

    assert(lines.any? { |line| line.include?("orders/static") && line.include?("asserts only static text") })
    refute(lines.any? { |line| line.include?("orders/compared") && line.include?("static text") })
    refute(lines.any? { |line| line.include?("orders/unread") && line.include?("static text") })
  end

  def test_doctor_does_not_flag_a_text_case_that_also_has_another_kind_of_expectation
    suite = MEASURE_SUITE.sub("- expect_text: { selector: \"h1\", equals: \"Orders\" }",
                              "- expect_text: { selector: \"h1\", equals: \"Orders\" }\n          - expect_count: { selector: \".row\", equals: 3 }")
    refute(doctor_lines(suite).any? { |line| line.include?("orders/static") && line.include?("static text") })
  end
end
