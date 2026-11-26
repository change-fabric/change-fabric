# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../scripts/leased_inbox"
require_relative "../scripts/triage/inbox_items"

class LeasedInboxTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @now = Time.utc(2026, 11, 25, 12, 0, 0)
    @inbox = LeasedInbox.new(root: @dir, clock: -> { @now })
  end

  def teardown = FileUtils.remove_entry(@dir)

  def put(key = "k1", title: "T") = @inbox.upsert(kind: "triage_decision", key: key, title: title)

  def test_repeated_upserts_do_not_duplicate_and_refresh_content
    put
    put(title: "T2")
    assert_equal 1, @inbox.open_items.size
    assert_equal "T2", @inbox.fetch("k1")["title"]
  end

  def test_double_lease_is_rejected_until_it_lapses
    put
    assert_equal 1, @inbox.lease(owner: "a", ttl: 60).size
    assert_empty @inbox.lease(owner: "b", ttl: 60)
    @now += 61
    assert_equal 1, @inbox.lease(owner: "b", ttl: 60).size
  end

  def test_stale_token_cannot_deliver_after_reclaim
    put
    old = @inbox.lease(owner: "a", ttl: 60).first
    @now += 61
    fresh = @inbox.lease(owner: "b", ttl: 60).first
    assert_raises(LeasedInbox::Fenced) { @inbox.deliver("k1", token: old["fence"]) }
    assert_equal "delivered", @inbox.deliver("k1", token: fresh["fence"])["state"]
  end

  def test_lapsed_lease_cannot_deliver
    put
    item = @inbox.lease(owner: "a", ttl: 60).first
    @now += 61
    assert_raises(LeasedInbox::Fenced) { @inbox.deliver("k1", token: item["fence"]) }
  end

  def test_delivered_stays_open_and_is_not_leased_again
    put
    item = @inbox.lease(owner: "a").first
    @inbox.deliver("k1", token: item["fence"])
    assert_empty @inbox.lease(owner: "b")
    assert_equal [ "k1" ], @inbox.open_items.map { |i| i["key"] }
  end

  def test_lost_delivery_stays_visible
    put
    @inbox.lease(owner: "ended-session", ttl: 60)
    @now += 3600
    assert_equal [ "k1" ], @inbox.open_items.map { |i| i["key"] }
  end

  def test_upsert_on_delivered_keeps_state
    put
    @inbox.deliver("k1", token: @inbox.lease(owner: "a").first["fence"])
    put(title: "newer")
    assert_equal "delivered", @inbox.fetch("k1")["state"]
  end

  def test_acknowledge_resolves_and_resolved_stays_resolved
    put
    @inbox.acknowledge("k1")
    put(title: "again")
    assert_equal "resolved", @inbox.fetch("k1")["state"]
    assert_empty @inbox.open_items
  end

  def test_supersede_records_reason
    put
    assert_equal "gone", @inbox.supersede("k1", reason: "gone")["resolution"]
  end

  def test_unknown_item_raises
    assert_raises(LeasedInbox::Error) { @inbox.acknowledge("nope") }
  end

  def test_triage_items_dedup_on_kind_unit_finding
    2.times do
      Triage::InboxItems.upsert(@inbox, kind: "host_stale", unit: "acme/api#stack/s1", finding: "vm", title: "vm stale")
    end
    Triage::InboxItems.upsert(@inbox, kind: "limited", unit: "acme/api#stack/s1", finding: "vm", title: "limited")
    assert_equal 2, @inbox.open_items.size
    Triage::InboxItems.clear(@inbox, kind: "host_stale", unit: "acme/api#stack/s1", finding: "vm")
    assert_equal 1, @inbox.open_items.size
  end

  def test_unknown_triage_kind_is_refused
    assert_raises(ArgumentError) { Triage::InboxItems.upsert(@inbox, kind: "bogus", unit: "u", finding: "f", title: "t") }
  end

  def test_corrupt_item_file_is_skipped
    put
    File.write(File.join(@dir, "items", "junk.json"), "{")
    assert_equal 1, @inbox.open_items.size
  end
end
