# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "yaml"
require_relative "../scripts/change_config"
require_relative "../scripts/change_apps"
require_relative "../scripts/change_schedule_config"

# change_config.schedules (0.20.0): parsing, every validation rule,
# the active-scan opt-in, the require_scheduled policy check, and doctor's
# schedule report. Synthetic example.test hosts only.
class ChangeScheduleConfigTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/schedules", __dir__)

  def base_config(schedules: nil, allow_active_scan: nil)
    staging = { "boot" => { "target_url" => "https://staging.example.test" } }
    staging["allow_active_scan"] = allow_active_scan unless allow_active_scan.nil?
    config = {
      "project" => "example",
      "default_profile" => "staging",
      "lanes" => { "zap" => { "targets" => [ "/", "/admin" ] }, "k6" => {} },
      "profiles" => { "staging" => staging, "prod" => { "boot" => { "target_url" => "https://prod.example.test" } } }
    }
    config["schedules"] = schedules if schedules
    config
  end

  def nightly(overrides = {})
    { "cron" => "0 3 * * *", "profile" => "staging", "runner" => "local", "lanes" => [ "zap" ] }.merge(overrides)
  end

  def errors_for(schedules, allow = nil) = ChangeScheduleConfig.new(base_config(schedules: schedules, allow_active_scan: allow)).errors

  def with_change_md(front)
    Dir.mktmpdir do |root|
      path = File.join(root, "CHANGE.md")
      File.write(path, "#{YAML.dump(front)}---\n\nbody\n")
      yield path
    end
  end

  def test_absent_block_yields_no_schedules_and_no_errors
    parsed = ChangeScheduleConfig.new(base_config)
    refute parsed.declared?
    assert_empty parsed.schedules
    assert_empty parsed.errors
  end

  def test_valid_block_parses_into_schedule_values
    block = {
      "nightly-pentest" => nightly("zap" => { "mode" => "full" }),
      "weekly-load" => { "cron" => "0 4 * * 1", "profile" => "staging", "runner" => "actions",
                         "lanes" => [ "k6" ], "k6" => { "script" => "load/soak.js" } }
    }
    parsed = ChangeScheduleConfig.new(base_config(schedules: block, allow_active_scan: true))
    assert_empty parsed.errors
    pentest, load = parsed.schedules
    assert_equal [ "nightly-pentest", "0 3 * * *", "staging", "local", [ "zap" ] ],
                 [ pentest.name, pentest.cron, pentest.profile, pentest.runner, pentest.lanes ]
    assert pentest.active_scan?
    assert_equal "load/soak.js", load.override("k6")["script"]
    refute load.active_scan?
    assert_equal "baseline", load.zap_mode
  end

  def test_block_must_be_a_mapping
    assert_match(/must be a mapping/, errors_for([ "x" ]).join)
  end

  def test_name_must_match_the_pattern
    assert_match(/schedule name must match/, errors_for("Nightly_Pentest" => nightly).join)
    assert_match(/schedule name must match/, errors_for("-x" => nightly).join)
  end

  def test_cron_must_have_five_valid_fields
    assert_match(/exactly five fields/, errors_for("n" => nightly("cron" => "0 3 * *")).join)
    assert_match(/exactly five fields/, errors_for("n" => nightly("cron" => "0 0 3 * * *")).join)
    assert_match(/exactly five fields/, errors_for("n" => nightly("cron" => "@reboot")).join)
    assert_match(/minute field '60'/, errors_for("n" => nightly("cron" => "60 3 * * *")).join)
    assert_match(/hour field '1-30'/, errors_for("n" => nightly("cron" => "0 1-30 * * *")).join)
    assert_match(/day-of-month field '0'/, errors_for("n" => nightly("cron" => "0 3 0 * *")).join)
    assert_match(/minute field '\*\/0'/, errors_for("n" => nightly("cron" => "*/0 3 * * *")).join)
    assert_match(/five-field cron string/, errors_for("n" => nightly("cron" => 5)).join)
    [ "0, 3 * * *", ",0 3 * * *", "0,,30 3 * * *" ].each do |cron|
      assert_match(/minute field/, errors_for("n" => nightly("cron" => cron)).join, cron)
    end
  end

  def test_cron_accepts_ranges_steps_and_lists
    [ "*/15 * * * *", "0 3 * * 1-5", "0,30 2-4 1,15 */2 0,7", "5 4 * 1-12/3 *" ].each do |cron|
      assert_empty errors_for("n" => nightly("cron" => cron)), cron
    end
  end

  def test_profile_must_be_defined
    assert_match(/profile 'qa' is not a defined profile; defined profiles: staging, prod/,
                 errors_for("n" => nightly("profile" => "qa")).join)
    assert_match(/profile is required/, errors_for("n" => nightly("profile" => nil)).join)
  end

  def test_runner_is_required_and_bounded
    assert_match(/runner is required and must be one of actions, local/, errors_for("n" => nightly("runner" => nil)).join)
    assert_match(/runner is required/, errors_for("n" => nightly("runner" => "cron")).join)
  end

  def test_lanes_must_be_a_non_empty_known_subset_without_command
    assert_match(/non-empty list/, errors_for("n" => nightly("lanes" => [])).join)
    assert_match(/unknown lane\(s\): nope/, errors_for("n" => nightly("lanes" => [ "nope" ])).join)
    assert_match(/may not include command/, errors_for("n" => nightly("lanes" => [ "command" ])).join)
  end

  def test_unknown_schedule_keys_are_rejected
    assert_match(/unknown key\(s\): timezone/, errors_for("n" => nightly("timezone" => "UTC")).join)
  end

  def test_override_must_name_a_listed_lane_and_known_fields
    assert_match(/overrides a lane this schedule does not run/,
                 errors_for("n" => nightly("k6" => { "script" => "a.js" })).join)
    assert_match(/zap sets unknown key\(s\): script/, errors_for("n" => nightly("zap" => { "script" => "a.js" })).join)
    assert_empty errors_for("n" => nightly("zap" => { "strict" => true, "targets" => [ "/" ] }))
  end

  def test_zap_mode_full_needs_the_profile_opt_in
    message = errors_for("n" => nightly("zap" => { "mode" => "full" })).join
    assert_match(/profile 'staging' does not set allow_active_scan: true/, message)
    assert_empty errors_for({ "n" => nightly("zap" => { "mode" => "full" }) }, true)
    refute_empty errors_for({ "n" => nightly("zap" => { "mode" => "full" }) }, false)
  end

  def test_zap_mode_must_be_known
    assert_match(/mode must be one of baseline, full/, errors_for("n" => nightly("zap" => { "mode" => "api" })).join)
  end

  def test_allow_active_scan_must_be_boolean
    assert_match(/allow_active_scan must be true or false/,
                 ChangeScheduleConfig.new(base_config(allow_active_scan: "yes")).errors.join)
  end

  def test_require_scheduled_must_name_declared_schedules_with_bounded_age
    parsed = ChangeScheduleConfig.new(base_config(schedules: { "nightly" => nightly }))
    ok = { "promotion.tag:v*" => { "require_scheduled" => { "nightly" => { "max_age_days" => 2 } } } }
    assert_empty parsed.require_scheduled_errors(ok)

    unknown = { "promotion.tag:v*" => { "require_scheduled" => { "weekly" => { "max_age_days" => 2 } } } }
    assert_match(/names no declared schedule; declared: nightly/, parsed.require_scheduled_errors(unknown).join)
    [ 0, 91, "2" ].each do |age|
      bad = { "promotion.tag:v*" => { "require_scheduled" => { "nightly" => { "max_age_days" => age } } } }
      assert_match(/max_age_days must be an integer from 1 to 90/, parsed.require_scheduled_errors(bad).join)
    end
  end

  def test_require_scheduled_on_a_branch_rule_with_a_local_schedule_warns
    parsed = ChangeScheduleConfig.new(base_config(schedules: { "nightly" => nightly }))
    rules = { "promotion.production" => { "require_scheduled" => { "nightly" => { "max_age_days" => 2 } } } }
    assert_match(/runner: local schedule/, parsed.require_scheduled_warnings(rules).join)
  end

  def test_load_fails_loud_on_an_invalid_schedule
    front = { "change_config" => base_config(schedules: { "n" => nightly("zap" => { "mode" => "full" }) }) }
    with_change_md(front) do |path|
      error = assert_raises(ChangeConfig::ConfigError) { ChangeConfig.load(path) }
      assert_match(/profile 'staging' does not set allow_active_scan/, error.message)
    end
  end

  def test_per_pr_lane_rejects_zap_mode_full_and_accepts_baseline
    config = base_config
    config["lanes"]["zap"]["mode"] = "full"
    with_change_md("change_config" => config) do |path|
      error = assert_raises(ChangeConfig::ConfigError) { ChangeConfig.load(path) }
      assert_match(/accepted only inside a schedule override/, error.message)
    end
    config["lanes"]["zap"]["mode"] = "baseline"
    with_change_md("change_config" => config) { |path| assert ChangeConfig.load(path) }
  end

  def test_allow_active_scan_is_not_merged_into_the_resolved_config
    with_change_md("change_config" => base_config(allow_active_scan: true)) do |path|
      with = ChangeConfig.load(path)
      File.write(path, "#{YAML.dump('change_config' => base_config)}---\n\nbody\n")
      assert_equal ChangeConfig.load(path).digest, with.digest
    end
  end

  def test_doctor_lists_schedules_and_active_scan_targets
    block = { "nightly-pentest" => nightly("zap" => { "mode" => "full" }) }
    with_change_md("change_config" => base_config(schedules: block, allow_active_scan: true)) do |path|
      out = ChangeConfig.doctor(path)
      assert_includes out, "schedules:\n  nightly-pentest: runner=local cron=\"0 3 * * *\" profile=staging lanes=zap"
      assert_includes out, "active-scan targets: https://staging.example.test/ (profile staging, schedule nightly-pentest)"
      assert_includes out, "active-scan targets: https://staging.example.test/admin (profile staging, schedule nightly-pentest)"
    end
  end

  def test_doctor_reports_no_active_scan_targets_for_passive_schedules
    with_change_md("change_config" => base_config(schedules: { "nightly" => nightly })) do |path|
      assert_includes ChangeConfig.doctor(path), "active-scan targets: none"
    end
  end

  def test_registry_doctor_reports_require_scheduled_errors
    front = {
      "change_config" => base_config(schedules: { "nightly" => nightly }),
      "change_policy" => { "promotion" => { "tag:v*" => { "require_scheduled" => { "weekly" => { "max_age_days" => 2 } } } } }
    }
    with_change_md(front) do |path|
      assert_match(/error: change_policy\.promotion\.tag:v\*\.require_scheduled\.weekly names no declared schedule/,
                   ChangeAppRegistry.doctor(path))
    end
  end

  # A CHANGE.md with no schedules block produces byte-identical doctor output
  # to origin/main before this block existed. The golden was generated by
  # running origin/main's own change_config.rb doctor on the same fixture; the
  # trailing policy: lines came later and are independent of schedules.
  def test_doctor_output_is_unchanged_without_a_schedules_block
    Dir.mktmpdir do |root|
      FileUtils.cp(File.join(FIXTURES, "no_schedules_CHANGE.md"), File.join(root, "CHANGE.md"))
      out = Dir.chdir(root) { ChangeAppRegistry.doctor("CHANGE.md") }
      assert_equal File.read(File.join(FIXTURES, "no_schedules_doctor.golden.txt")), "#{out}\n"
    end
  end
end
