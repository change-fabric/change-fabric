# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../scripts/change_autopilot_store"

class ChangeAutopilotStoreTest < Minitest::Test
  ID = "a" * 64

  def setup
    @dir = Dir.mktmpdir
    @store = ChangeAutopilotStore.new(root: @dir)
  end

  def teardown = FileUtils.remove_entry(@dir)

  def test_record_lookup_and_all
    @store.record(repo: "repo:x", autopilot_id: ID, proof: { "k" => 1 }, policy_sha: "p", recorded_by: "t")
    assert_equal({ "k" => 1 }, @store.lookup(repo: "repo:x", autopilot_id: ID)["proof"])
    assert_nil @store.lookup(repo: "repo:y", autopilot_id: ID)
    assert_equal 1, @store.all.size
  end

  def test_tombstone
    refute @store.ended?(ID)
    @store.end!(autopilot_id: ID, by: "agent", reason: "done")
    assert @store.ended?(ID)
    assert_equal "done", JSON.parse(File.read(File.join(@dir, "#{ID}.ended")))["reason"]
  end

  def test_a_bad_id_is_refused_and_reads_as_ended
    assert_raises(ArgumentError) { @store.end!(autopilot_id: "../x", by: "a", reason: "r") }
    assert @store.ended?("../x")
  end

  def test_ledger_appends_rows_and_is_not_a_receipt
    @store.append_ledger(ID, "gate" => "review")
    @store.append_ledger(ID, "gate" => "carve_out")
    assert_equal %w[review carve_out], @store.ledger(ID).map { |row| row["gate"] }
    assert_empty @store.all
    assert_empty @store.ledger("b" * 64)
  end

  def test_published_root_is_recorded_per_autopilot
    Dir.mktmpdir do |dir|
      store = ChangeAutopilotStore.new(root: dir)
      assert_nil store.published_root("a" * 64)
      store.mark_published("a" * 64, root: "/some/checkout")
      assert_equal "/some/checkout", store.published_root("a" * 64)
      assert_nil store.published_root("b" * 64)
      File.write(File.join(dir, "#{'c' * 64}.published"), "not json")
      assert_equal "", store.published_root("c" * 64)
    end
  end
end
