# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_command_config"

# lanes.command validation: every rule has a message that names the path an
# author has to fix.
class ChangeConfigCommandTest < Minitest::Test
  ENTRY = { "name" => "integration", "run" => "bin/itest", "timeout_seconds" => 900 }.freeze

  # The doctrine check reads CF_ALLOW_HOSTDAEMON, so every test starts with it
  # unset and leaves it as it found it.
  def setup = @prev_hostdaemon = ENV.delete("CF_ALLOW_HOSTDAEMON")

  def teardown
    @prev_hostdaemon ? ENV["CF_ALLOW_HOSTDAEMON"] = @prev_hostdaemon : ENV.delete("CF_ALLOW_HOSTDAEMON")
  end

  def errors(section, profiles: %w[staging production]) = ChangeCommandConfig.errors(section, profiles: profiles)

  def lane(*entries) = { "enabled" => true, "commands" => entries }

  def entry(**fields) = ENTRY.merge(fields.transform_keys(&:to_s))

  def test_a_valid_lane_has_no_errors
    full = entry(env: %w[DATABASE_URL], artifacts: [ "tmp/itest/**/*.xml" ], profiles: %w[staging], retries: 1)
    assert_empty errors(lane(full, entry(name: "smoke")))
  end

  def test_lane_must_be_a_mapping
    assert_equal [ "lanes.command must be a mapping" ], errors([])
  end

  def test_commands_must_be_a_non_empty_list
    assert_equal [ "lanes.command.commands must be a non-empty list" ], errors({ "enabled" => true })
    assert_equal [ "lanes.command.commands must be a non-empty list" ], errors(lane)
  end

  def test_a_disabled_lane_needs_no_commands
    assert_empty errors({ "enabled" => false })
  end

  def test_lane_level_retries_is_rejected
    assert_includes errors(lane(entry).merge("retries" => 2)),
                    "lanes.command.retries is not supported; set retries per command entry"
  end

  def test_unused_lane_keys_are_rejected
    %w[base_url wait_for basic_auth auth targets].each do |key|
      assert_includes errors(lane(entry).merge(key => "x")), "lanes.command.#{key} is not used by the command lane"
    end
  end

  def test_unknown_lane_key_is_rejected
    assert_match(/lanes\.command\.bogus is not a command lane key/, errors(lane(entry).merge("bogus" => 1)).join)
  end

  def test_entry_must_be_a_mapping
    assert_includes errors(lane("bin/x")), "lanes.command.commands[0] must be a mapping"
  end

  def test_unknown_entry_key_is_rejected
    assert_match(/lanes\.command\.commands\[0\] sets unknown key\(s\): shell/, errors(lane(entry(shell: "bash"))).join)
  end

  def test_name_shape
    [ "Upper", "-lead", "", "a" * 64 ].each do |name|
      assert_match(/lanes\.command\.commands\[0\]\.name must match/, errors(lane(entry(name: name))).join)
    end
  end

  def test_names_must_be_unique
    assert_includes errors(lane(entry, entry)), "lanes.command.commands names must be unique; repeated: integration"
  end

  def test_run_must_be_a_non_empty_string
    assert_includes errors(lane(entry, entry(name: "b", run: " "))), "lanes.command.commands[1].run must be a non-empty string"
  end

  def test_timeout_is_required_and_bounded
    [ nil, 0, 21_601, "60" ].each do |value|
      assert_match(/lanes\.command\.commands\[0\]\.timeout_seconds is required: an integer from 1 to 21600/,
                   errors(lane(entry(timeout_seconds: value))).join)
    end
  end

  def test_env_names_shape_and_reserved_names
    assert_match(/\.env must be a list of variable names/, errors(lane(entry(env: [ "lower" ]))).join)
    assert_match(/\.env may not declare HOME, CF_CHANGE_TARGET_URL/,
                 errors(lane(entry(env: %w[HOME CF_CHANGE_TARGET_URL]))).join)
  end

  def test_artifacts_must_be_relative_without_parent_segments
    assert_match(/\.artifacts entry "\/etc\/passwd" must be repo-relative/, errors(lane(entry(artifacts: [ "/etc/passwd" ]))).join)
    assert_match(/\.artifacts entry "\.\.\/x" must be repo-relative/, errors(lane(entry(artifacts: [ "../x" ]))).join)
    assert_match(/\.artifacts must be a list of repo-relative globs/, errors(lane(entry(artifacts: "x"))).join)
  end

  def test_profiles_must_name_defined_profiles
    assert_match(/\.profiles names undefined profile\(s\): qa \(defined: staging, production\)/,
                 errors(lane(entry(profiles: %w[qa]))).join)
    assert_match(/\.profiles names undefined profile\(s\): staging \(defined: none\)/,
                 errors(lane(entry(profiles: %w[staging])), profiles: []).join)
    assert_match(/\.profiles must be a non-empty list/, errors(lane(entry(profiles: []))).join)
  end

  def test_retries_are_bounded
    [ -1, 4, "1" ].each do |value|
      assert_match(/\.retries must be an integer from 0 to 3/, errors(lane(entry(retries: value))).join)
    end
  end

  def test_run_starting_a_host_daemon_is_rejected
    assert_match(/lanes\.command\.commands\[0\]\.run starts a host daemon \(redis-server\)/,
                 errors(lane(entry(run: "redis-server --port 7000"))).join)
  end

  def test_host_daemon_escape_hatch
    ENV["CF_ALLOW_HOSTDAEMON"] = "1"
    assert_empty errors(lane(entry(run: "redis-server --port 7000")))
  end

  def test_profile_override_may_set_enabled_only
    assert_nil ChangeCommandConfig.profile_override_error("staging", "enabled" => false)
    assert_match(/profile 'staging' lane 'command' sets commands; a profile may only set enabled/,
                 ChangeCommandConfig.profile_override_error("staging", "commands" => []))
  end
end
