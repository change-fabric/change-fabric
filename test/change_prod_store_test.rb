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
    GitFixture.git_init(@origin, "--bare")
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
    @store.create("claims", ID, { "n" => 1 })
    assert_raises(ChangeProdStore::Exists) { @store.create("claims", ID, { "n" => 2 }) }
    assert_equal 1, @store.read("claims", ID)["n"]
    fresh = Dir.mktmpdir
    GitFixture.git_init(fresh, "-b", "main")
    GitFixture.git(fresh, "remote", "add", "origin", @origin)
    assert_raises(ChangeProdStore::Exists) { ChangeProdStore.new(fresh).create("claims", ID, { "n" => 3 }) }
    refute ChangeProdStore.new(fresh).exists?("claims", ID), "a refused push leaves no local ref"
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
end
