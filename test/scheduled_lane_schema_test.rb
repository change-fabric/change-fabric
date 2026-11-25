# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_schema"
require_relative "../scripts/scheduled_lane/lane_config"

class ScheduledLaneSchemaTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/scheduled_lane/CHANGE.md", __dir__)

  def lane(overrides = {})
    { "id" => "app-smoke", "run" => "true", "result_file" => "out.json", "cadence" => "nightly", "timeout_minutes" => 10 }.merge(overrides)
  end

  def matrix(overrides = {})
    { "mode" => "touched-one-at-a-time", "touched_cmd" => "t", "flip_cmd" => "on {flag}", "revert_cmd" => "off {flag}",
      "read_cmd" => "r {flag}", "list_on_cmd" => "l", "ledger_cmd" => "g", "lock_group" => "grp" }.merge(overrides)
  end

  def errors(*lanes) = ChangeSchema.scheduled_lanes_errors(lanes)

  def test_fixture_is_valid
    assert_equal "example", ScheduledLane::LaneConfig.find(FIXTURE, "example").id
  end

  def test_absent_list_is_valid
    assert_empty ChangeSchema.scheduled_lanes_errors(nil)
  end

  def test_minimal_lane_is_valid
    assert_empty errors(lane)
  end

  def test_result_file_is_required
    assert_match(/result_file is required/, errors(lane.except("result_file")).join)
  end

  def test_timeout_minutes_is_required_and_bounded
    assert_match(/timeout_minutes is required/, errors(lane.except("timeout_minutes")).join)
    assert_match(/timeout_minutes is required/, errors(lane("timeout_minutes" => 361)).join)
    assert_match(/timeout_minutes is required/, errors(lane("timeout_minutes" => 0)).join)
  end

  def test_id_and_cadence_are_checked
    assert_match(/id must match/, errors(lane("id" => "Bad_Id")).join)
    assert_match(/cadence must be one of/, errors(lane("cadence" => "hourly")).join)
  end

  def test_duplicate_ids_are_rejected
    assert_match(/repeats id/, errors(lane, lane).join)
  end

  def test_unknown_keys_are_rejected
    assert_match(/unknown key/, errors(lane("surprise" => 1)).join)
  end

  def test_touched_mode_requires_every_adapter_command
    ChangeSchema::MATRIX_REQUIRED_CMDS.each do |key|
      assert_match(/matrix.#{key} is required/, errors(lane("matrix" => matrix.except(key))).join, key)
    end
  end

  def test_off_mode_needs_no_adapters
    assert_empty errors(lane("matrix" => { "mode" => "off" }))
  end

  def test_flip_and_revert_must_carry_the_flag_placeholder
    assert_match(/flip_cmd must contain \{flag\}/, errors(lane("matrix" => matrix("flip_cmd" => "on"))).join)
    assert_match(/revert_cmd must contain \{flag\}/, errors(lane("matrix" => matrix("revert_cmd" => "off"))).join)
  end

  def test_production_cannot_be_removed_from_forbid_envs
    assert_match(/must keep production/, errors(lane("matrix" => matrix("forbid_envs" => [ "qa" ]))).join)
    assert_empty errors(lane("matrix" => matrix("forbid_envs" => %w[production qa])))
  end

  def test_forbid_envs_default_is_production
    parsed = ScheduledLane::Lane.new(lane("matrix" => matrix))
    assert_includes parsed.forbidden_envs, "production"
  end

  def test_matrix_numbers_are_bounded
    assert_match(/max_flags/, errors(lane("matrix" => matrix("max_flags" => 0))).join)
    assert_match(/settle_seconds/, errors(lane("matrix" => matrix("settle_seconds" => -1))).join)
  end

  def test_ledger_credential_env_must_be_a_name
    assert_match(/ledger_credential_env/, errors(lane("matrix" => matrix("ledger_credential_env" => "not a name"))).join)
  end

  def test_chat_dm_requires_cmd
    assert_match(/cmd is required for chat_dm/, errors(lane("sinks" => [ { "type" => "chat_dm" } ])).join)
    assert_empty errors(lane("sinks" => [ { "type" => "chat_dm", "cmd" => "notify" } ]))
  end

  def test_unknown_sink_type_and_dispatch_input
    assert_match(/type must be one of/, errors(lane("sinks" => [ { "type" => "pager" } ])).join)
    assert_match(/unknown input/, errors(lane("dispatch_inputs" => [ "bogus" ])).join)
  end

  def test_result_path_is_per_iteration
    parsed = ScheduledLane::Lane.new(lane("result_file" => "out/result.json"))
    assert_equal "out/result.3.json", parsed.result_path(3)
  end

  def test_fill_escapes_and_refuses_unsafe_values
    assert_equal "on flag_a in staging", ScheduledLane::LaneConfig.fill("on {flag} in {env}", flag: "flag_a", env: "staging")
    assert_raises(ScheduledLane::ConfigError) { ScheduledLane::LaneConfig.fill("on {flag}", flag: "a; rm -rf /") }
    assert_raises(ScheduledLane::ConfigError) { ScheduledLane::LaneConfig.fill("on {flag}") }
  end
end
