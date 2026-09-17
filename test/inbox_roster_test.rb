# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../scripts/inbox_roster"

class InboxRosterTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_load_with_no_roster_json_is_empty
    assert_equal({}, InboxRoster.load(@root))
    assert InboxRoster.no_roster?(@root)
  end

  def test_write_creates_roster_and_second_write_refuses
    assert InboxRoster.write(@root, roles: %w[PLAN BUILD QA])
    refute InboxRoster.write(@root, roles: %w[X])
    assert_equal %w[PLAN BUILD QA], InboxRoster.roles(@root)
  end

  def test_actors_include_roles_all_and_humans
    InboxRoster.write(@root, roles: %w[PLAN BUILD], humans: %w[operator])
    assert_equal %w[PLAN BUILD all operator], InboxRoster.actors(@root)
  end

  def test_bind_session_updates_sessions_map
    InboxRoster.write(@root, roles: %w[PLAN BUILD])
    assert InboxRoster.bind_session(@root, role: "PLAN", name: "plan-session")
    assert_equal "plan-session", InboxRoster.sessions(@root)["PLAN"]
  end

  def test_bind_session_fails_soft_with_no_roster
    refute InboxRoster.bind_session(@root, role: "PLAN", name: "x")
  end

  def test_legacy_hash_shaped_roster_migrates
    legacy = { "roles" => { "PLAN" => "plan-session", "BUILD" => "" }, "chain" => "PLAN -> BUILD" }
    File.write(InboxRoster.path(@root), JSON.generate(legacy))
    assert_equal %w[PLAN BUILD], InboxRoster.roles(@root)
    assert_equal({ "PLAN" => "plan-session", "BUILD" => "" }, InboxRoster.sessions(@root))
  end

  def test_hand_edited_unsafe_role_and_human_names_are_dropped
    data = { "roles" => %w[BUILD ../../ESCAPED], "sessions" => {},
             "humans" => [ "operator", "../root" ], "chain" => "BUILD" }
    File.write(InboxRoster.path(@root), JSON.generate(data))
    assert_equal %w[BUILD], InboxRoster.roles(@root)
    assert_equal %w[operator], InboxRoster.humans(@root)
    assert_equal %w[BUILD all operator], InboxRoster.actors(@root)
  end

  def test_legacy_hash_shaped_roster_drops_unsafe_role_keys
    legacy = { "roles" => { "BUILD" => "", "../../ESCAPED" => "" } }
    File.write(InboxRoster.path(@root), JSON.generate(legacy))
    assert_equal %w[BUILD], InboxRoster.roles(@root)
  end

  def test_malformed_roster_json_is_fail_soft
    File.write(InboxRoster.path(@root), "{not json")
    assert_equal({}, InboxRoster.load(@root))
    assert_equal [], InboxRoster.roles(@root)
  end
end
