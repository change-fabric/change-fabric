# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../scripts/change_override_store"

class ChangeOverrideStoreTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir
    @prev = Dir.home
    ENV["HOME"] = @home
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
  end

  def test_unrecorded_sha_is_not_authorized
    refute ChangeOverrideStore.new("abc123").authorized?
  end

  def test_recorded_override_is_authorized
    store = ChangeOverrideStore.new("abc123")
    store.record(reason: "CI green, no separate reviewer available", recorded_by: "pst")
    assert store.authorized?
  end

  def test_record_carries_reason_and_recorded_by
    store = ChangeOverrideStore.new("abc123")
    store.record(reason: "urgent hotfix", recorded_by: "pst")
    record = store.read
    assert_equal "urgent hotfix", record["reason"]
    assert_equal "pst", record["recorded_by"]
    assert record["recorded_at"]
  end

  def test_blank_sha_is_not_recordable
    store = ChangeOverrideStore.new("")
    store.record(reason: "x", recorded_by: "pst")
    assert_nil store.read
    refute store.authorized?
  end

  # Scoped exactly like ChangeGateStore: an override for one profile's head
  # must never unlock a different profile, or the unscoped case.
  def test_profile_scoped_override_does_not_authorize_the_unscoped_gate
    ChangeOverrideStore.new("abc123", profile: "staging").record(reason: "x", recorded_by: "pst")
    refute ChangeOverrideStore.new("abc123").authorized?
  end

  def test_unscoped_override_does_not_authorize_a_profile_scoped_gate
    ChangeOverrideStore.new("abc123").record(reason: "x", recorded_by: "pst")
    refute ChangeOverrideStore.new("abc123", profile: "staging").authorized?
  end

  def test_two_profiles_authorize_independently_for_the_same_sha
    ChangeOverrideStore.new("abc123", profile: "staging").record(reason: "x", recorded_by: "pst")
    assert ChangeOverrideStore.new("abc123", profile: "staging").authorized?
    refute ChangeOverrideStore.new("abc123", profile: "production").authorized?
  end

  # The whole point: a new commit needs a new override. No separate expiry
  # mechanism, since the key itself expires the moment the head SHA moves.
  def test_a_different_sha_is_not_authorized_by_an_earlier_overrides_record
    ChangeOverrideStore.new("abc123").record(reason: "x", recorded_by: "pst")
    refute ChangeOverrideStore.new("def456").authorized?
  end
end
