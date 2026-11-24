# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "git_fixture"
require_relative "../scripts/change_prod_store"

class ChangeProdStoreTest < Minitest::Test
  ID = "11111111-2222-4333-8444-555555555555"

  def setup
    @origin = Dir.mktmpdir
    @dir = Dir.mktmpdir
    GitFixture.git_init(@origin, "--bare", "-b", "main")
    GitFixture.git_init(@dir, "-b", "main")
    GitFixture.git(@dir, "remote", "add", "origin", @origin)
    @store = ChangeProdStore.new(@dir)
  end

  def teardown = [ @origin, @dir ].each { |path| FileUtils.remove_entry(path) }

  def test_round_trips_a_payload_through_the_remote
    @store.create("requests", ID, { "a" => 1 })
    other = Dir.mktmpdir
    GitFixture.git_init(other, "-b", "main")
    GitFixture.git(other, "remote", "add", "origin", @origin)
    reader = ChangeProdStore.new(other)
    reader.fetch
    assert_equal({ "a" => 1 }, reader.read("requests", ID))
    assert reader.exists?("requests", ID)
  ensure
    FileUtils.remove_entry(other) if other
  end

  def test_create_is_conditional_locally_and_on_the_remote
    @store.create("approvals", ID, { "n" => 1 })
    assert_raises(ChangeProdStore::Exists) { @store.create("approvals", ID, { "n" => 2 }) }
    assert_equal 1, @store.read("approvals", ID)["n"]
    fresh = Dir.mktmpdir
    GitFixture.git_init(fresh, "-b", "main")
    GitFixture.git(fresh, "remote", "add", "origin", @origin)
    assert_raises(ChangeProdStore::Exists) { ChangeProdStore.new(fresh).create("approvals", ID, { "n" => 3 }) }
    refute ChangeProdStore.new(fresh).exists?("approvals", ID), "a refused push leaves no local ref"
  ensure
    FileUtils.remove_entry(fresh) if fresh
  end

  def test_refuses_unknown_kinds_and_bad_ids
    assert_raises(ChangeProdStore::Error) { @store.ref("journal", ID) }
    assert_raises(ChangeProdStore::Error) { @store.ref("requests", "../x") }
  end

  def test_missing_and_corrupt_refs
    assert_raises(ChangeProdStore::Missing) { @store.read("requests", ID) }
    commit = @store.send(:write_commit, "not json")
    GitFixture.git(@dir, "update-ref", @store.ref("requests", ID), commit)
    error = assert_raises(ChangeProdStore::Error) { @store.read("requests", ID) }
    assert_match(/valid JSON/, error.message)
  end

  def test_fetch_failure_is_an_error
    assert_raises(ChangeProdStore::Error) { ChangeProdStore.new(@dir, remote: "nowhere").fetch }
  end

  AUTOPILOT = "c" * 64

  def test_autopilot_kinds_are_named_by_a_body_hash_and_the_others_by_a_uuid
    assert_match %r{/autopilots/#{AUTOPILOT}\z}, @store.ref("autopilots", AUTOPILOT)
    assert_match %r{/autopilot-ends/#{AUTOPILOT}\z}, @store.ref("autopilot-ends", AUTOPILOT)
    assert_match %r{/audit/#{ID}\z}, @store.ref("audit", ID)
    assert_raises(ChangeProdStore::Error) { @store.ref("autopilots", ID) }
    assert_raises(ChangeProdStore::Error) { @store.ref("audit", AUTOPILOT) }
    assert_raises(ChangeProdStore::Error) { @store.ref("autopilots", "../#{AUTOPILOT}") }
    assert_raises(ChangeProdStore::Error) { @store.ref("elsewhere", ID) }
  end

  def test_list_returns_the_valid_ids_of_one_kind_only
    @store.create("autopilots", AUTOPILOT, { "n" => 1 })
    @store.create("autopilots", "d" * 64, { "n" => 2 })
    @store.create("autopilot-ends", AUTOPILOT, { "n" => 3 })
    @store.create("requests", ID, { "n" => 4 })
    GitFixture.git(@dir, "update-ref", "refs/cf-prod/autopilots/not-an-id", @store.read("autopilots", AUTOPILOT).then { GitFixture.git(@dir, "rev-parse", @store.ref("autopilots", AUTOPILOT)).strip })
    assert_equal [ AUTOPILOT, "d" * 64 ], @store.list("autopilots")
    assert_equal [ AUTOPILOT ], @store.list("autopilot-ends")
    assert_equal [ ID ], @store.list("requests")
    assert_empty @store.list("audit")
    assert_raises(ChangeProdStore::Error) { @store.list("elsewhere") }
  end
end
