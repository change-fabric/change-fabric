# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../scripts/change_gate_store"

class ChangeGateStoreTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir
    @prev = Dir.home
    ENV["HOME"] = @home
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
  end

  def test_comprehensive_pass_requires_all_scope_and_pass
    store = ChangeGateStore.new("abc123")
    store.record(scope: "all", status: "pass", project: "app", lanes: {}, report: "r.md")
    assert store.comprehensive_pass?
  end

  def test_single_lane_pass_does_not_satisfy_gate
    store = ChangeGateStore.new("abc123")
    store.record(scope: "k6", status: "pass", project: "app", lanes: {}, report: "r.md")
    refute store.comprehensive_pass?
  end

  def test_failed_all_run_does_not_satisfy_gate
    store = ChangeGateStore.new("abc123")
    store.record(scope: "all", status: "fail", project: "app", lanes: {}, report: "r.md")
    refute store.comprehensive_pass?
  end

  def test_unknown_sha_is_not_a_pass
    refute ChangeGateStore.new("never-recorded").comprehensive_pass?
  end

  # The run manifest is stored beside the verdict so a pass recorded weeks ago
  # can be traced to the inputs that produced it.
  def test_the_run_manifest_is_stored_with_the_record
    store = ChangeGateStore.new("abc123")
    manifest = { "axe-core" => "4.10.2", "config digest" => "sha256:deadbeef" }
    store.record(scope: "all", status: "pass", project: "app", lanes: {}, report: "r.md", manifest: manifest)
    assert_equal manifest, store.send(:read)["manifest"]
  end

  def test_the_manifest_is_stored_per_app_in_a_monorepo_record
    store = ChangeGateStore.new("abc123")
    store.record(scope: "all", status: "pass", project: "repo", lanes: {}, report: "r.md", app: "portal",
                 manifest: { "toolkit version" => "skills/v1.2.3" })
    assert_equal({ "toolkit version" => "skills/v1.2.3" }, store.send(:read).dig("apps", "portal", "manifest"))
  end

  # A record from a run that gathered no manifest carries no empty key, so a
  # pre-manifest record and a manifest-less one read identically.
  def test_no_manifest_key_when_there_is_nothing_to_record
    store = ChangeGateStore.new("abc123")
    store.record(scope: "all", status: "pass", project: "app", lanes: {}, report: "r.md")
    refute store.send(:read).key?("manifest")
  end

  # The manifest is evidence, never a gate input: a recorded pass stays a pass
  # whatever it carries.
  def test_the_manifest_does_not_change_the_gate_answer
    store = ChangeGateStore.new("abc123")
    store.record(scope: "all", status: "pass", project: "app", lanes: {}, report: "r.md",
                 manifest: { "config digest" => "sha256:whatever" })
    assert store.comprehensive_pass?
  end

  def test_blank_sha_is_not_recordable
    store = ChangeGateStore.new("")
    store.record(scope: "all", status: "pass", project: "app", lanes: {}, report: "r.md")
    assert_nil store.read
  end

  def test_profile_scoped_record_does_not_satisfy_the_unscoped_gate
    ChangeGateStore.new("abc123", profile: "staging").record(
      scope: "all", status: "pass", project: "app", lanes: {}, report: "r.md"
    )
    refute ChangeGateStore.new("abc123").comprehensive_pass?
  end

  def test_unscoped_record_does_not_satisfy_a_profile_scoped_gate
    ChangeGateStore.new("abc123").record(scope: "all", status: "pass", project: "app", lanes: {}, report: "r.md")
    refute ChangeGateStore.new("abc123", profile: "staging").comprehensive_pass?
  end

  def test_two_profiles_record_independently_for_the_same_sha
    ChangeGateStore.new("abc123", profile: "staging").record(
      scope: "all", status: "pass", project: "app", lanes: {}, report: "r.md"
    )
    ChangeGateStore.new("abc123", profile: "prod").record(
      scope: "all", status: "fail", project: "app", lanes: {}, report: "r.md"
    )
    assert ChangeGateStore.new("abc123", profile: "staging").comprehensive_pass?
    refute ChangeGateStore.new("abc123", profile: "prod").comprehensive_pass?
  end

  def test_single_app_record_shape_is_unchanged
    ChangeGateStore.new("abc123").record(scope: "all", status: "pass", project: "app", lanes: {}, report: "r.md")
    record = ChangeGateStore.new("abc123").read
    assert_equal %w[sha scope status project lanes report recorded_at].sort, record.keys.sort
  end

  def test_profile_and_target_are_recorded_when_given
    ChangeGateStore.new("abc123", profile: "staging").record(
      scope: "all", status: "pass", project: "app", lanes: {}, report: "r.md",
      profile: "staging", target: "https://staging.example.com"
    )
    record = ChangeGateStore.new("abc123", profile: "staging").read
    assert_equal "staging", record["profile"]
    assert_equal "https://staging.example.com", record["target"]
  end

  def test_two_app_runs_on_one_sha_merge_rather_than_clobber
    store = ChangeGateStore.new("abc123")
    store.record(scope: "all", status: "pass", project: "app", lanes: {}, report: "portal.md", app: "portal")
    store.record(scope: "all", status: "pass", project: "app", lanes: {}, report: "scattergram.md", app: "scattergram")

    record = store.read
    assert_equal %w[portal scattergram].sort, record["apps"].keys.sort
    assert_equal "pass", record["apps"]["portal"]["status"]
    assert_equal "pass", record["apps"]["scattergram"]["status"]
  end

  def test_aggregate_status_fails_when_any_app_failed
    store = ChangeGateStore.new("abc123")
    store.record(scope: "all", status: "pass", project: "app", lanes: {}, report: "portal.md", app: "portal")
    store.record(scope: "all", status: "fail", project: "app", lanes: {}, report: "scattergram.md", app: "scattergram")

    record = store.read
    assert_equal "fail", record["status"]
  end

  def test_comprehensive_pass_with_an_app_list_requires_every_named_app
    store = ChangeGateStore.new("abc123")
    store.record(scope: "all", status: "pass", project: "app", lanes: {}, report: "portal.md", app: "portal")
    store.record(scope: "all", status: "pass", project: "app", lanes: {}, report: "scattergram.md", app: "scattergram")

    assert store.comprehensive_pass?(apps: %w[portal scattergram])
  end

  def test_comprehensive_pass_with_an_app_list_fails_on_a_missing_app
    store = ChangeGateStore.new("abc123")
    store.record(scope: "all", status: "pass", project: "app", lanes: {}, report: "portal.md", app: "portal")

    refute store.comprehensive_pass?(apps: %w[portal scattergram])
  end

  def test_a_legacy_record_with_no_apps_key_fails_a_multi_app_query
    store = ChangeGateStore.new("abc123")
    store.record(scope: "all", status: "pass", project: "app", lanes: {}, report: "r.md")

    refute store.comprehensive_pass?(apps: %w[portal])
  end

  def test_a_legacy_record_with_no_apps_key_still_satisfies_the_nil_query
    store = ChangeGateStore.new("abc123")
    store.record(scope: "all", status: "pass", project: "app", lanes: {}, report: "r.md")

    assert store.comprehensive_pass?
  end

  def test_missing_apps_names_only_the_unrecorded_apps
    store = ChangeGateStore.new("abc123")
    store.record(scope: "all", status: "pass", project: "app", lanes: {}, report: "portal.md", app: "portal")

    assert_equal %w[scattergram], store.missing_apps(%w[portal scattergram])
  end
end
