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
    store.record(reason: "CI green, no separate reviewer available", recorded_by: "cf")
    assert store.authorized?
  end

  def test_record_carries_reason_and_recorded_by
    store = ChangeOverrideStore.new("abc123")
    store.record(reason: "urgent hotfix", recorded_by: "cf")
    record = store.read
    assert_equal "urgent hotfix", record["reason"]
    assert_equal "cf", record["recorded_by"]
    assert record["recorded_at"]
  end

  def test_proof_is_stored_when_given_and_absent_otherwise
    proof = { "kind" => "totp-terminal", "body" => "{}", "totp_step" => 1, "receipt" => nil }
    ChangeOverrideStore.new("abc123").record(reason: "x", recorded_by: "cf", proof: proof)
    assert_equal proof, ChangeOverrideStore.new("abc123").read["proof"]
    ChangeOverrideStore.new("def456").record(reason: "x", recorded_by: "cf")
    refute ChangeOverrideStore.new("def456").read.key?("proof")
  end

  def test_blank_sha_is_not_recordable
    store = ChangeOverrideStore.new("")
    store.record(reason: "x", recorded_by: "cf")
    assert_nil store.read
    refute store.authorized?
  end

  # Scoped exactly like ChangeGateStore: an override for one profile's head
  # must never unlock a different profile, or the unscoped case.
  def test_profile_scoped_override_does_not_authorize_the_unscoped_gate
    ChangeOverrideStore.new("abc123", profile: "staging").record(reason: "x", recorded_by: "cf")
    refute ChangeOverrideStore.new("abc123").authorized?
  end

  def test_unscoped_override_does_not_authorize_a_profile_scoped_gate
    ChangeOverrideStore.new("abc123").record(reason: "x", recorded_by: "cf")
    refute ChangeOverrideStore.new("abc123", profile: "staging").authorized?
  end

  def test_two_profiles_authorize_independently_for_the_same_sha
    ChangeOverrideStore.new("abc123", profile: "staging").record(reason: "x", recorded_by: "cf")
    assert ChangeOverrideStore.new("abc123", profile: "staging").authorized?
    refute ChangeOverrideStore.new("abc123", profile: "production").authorized?
  end

  # The whole point: a new commit needs a new override. No separate expiry
  # mechanism, since the key itself expires the moment the head SHA moves.
  def test_a_different_sha_is_not_authorized_by_an_earlier_overrides_record
    ChangeOverrideStore.new("abc123").record(reason: "x", recorded_by: "cf")
    refute ChangeOverrideStore.new("def456").authorized?
  end

  # A scope narrows an override to the merge or the tag guard; with none it
  # unlocks both, as before.
  def test_a_scoped_override_authorizes_only_its_own_scope
    ChangeOverrideStore.new("abc123", scope: "merge").record(reason: "x", recorded_by: "cf")
    assert ChangeOverrideStore.new("abc123", scope: "merge").authorized?
    refute ChangeOverrideStore.new("abc123", scope: "tag").authorized?
    refute ChangeOverrideStore.new("abc123").authorized?
    assert_equal "merge", ChangeOverrideStore.new("abc123", scope: "merge").read["scope"]
  end

  def test_merge_and_tag_overrides_coexist_for_one_sha
    ChangeOverrideStore.new("abc123", scope: "merge").record(reason: "x", recorded_by: "cf")
    ChangeOverrideStore.new("abc123", scope: "tag").record(reason: "y", recorded_by: "cf")
    assert_equal "x", ChangeOverrideStore.new("abc123", scope: "merge").read["reason"]
    assert_equal "y", ChangeOverrideStore.new("abc123", scope: "tag").read["reason"]
  end

  def test_a_copied_scoped_record_cannot_widen_its_scope
    ChangeOverrideStore.new("abc123", scope: "merge").record(reason: "x", recorded_by: "cf")
    dir = File.join(Dir.home, ".claude", "cf", "change")
    FileUtils.cp(File.join(dir, "abc123@merge.override"), File.join(dir, "abc123.override"))
    refute ChangeOverrideStore.new("abc123").authorized?
    FileUtils.cp(File.join(dir, "abc123@merge.override"), File.join(dir, "abc123@tag.override"))
    refute ChangeOverrideStore.new("abc123", scope: "tag").authorized?
  end

  def test_an_unscoped_override_still_authorizes_the_unscoped_gate
    ChangeOverrideStore.new("abc123").record(reason: "x", recorded_by: "cf")
    assert ChangeOverrideStore.new("abc123").authorized?
    refute ChangeOverrideStore.new("abc123").read.key?("scope")
  end
end
