# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../scripts/doctrine_review_surface"
require_relative "../scripts/triage/inbox_items"

class DoctrineReviewSurfaceTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir
    @root = Dir.mktmpdir
    @store = Dir.mktmpdir
    @prev = { "HOME" => ENV["HOME"], "INBOX_ROOT" => ENV["INBOX_ROOT"] }
    ENV["HOME"] = @home
    ENV["INBOX_ROOT"] = @root
    @inbox = LeasedInbox.new(root: @store)
  end

  def teardown
    @prev.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    [ @home, @root, @store ].each { |d| FileUtils.remove_entry(d) }
  end

  def surface(event = { "session_id" => "s1" })
    io = StringIO.new
    DoctrineReviewSurface.run(event, io, inbox: @inbox)
    io.string.empty? ? nil : JSON.parse(io.string)
  end

  def triage_item(finding, kind: "triage_decision")
    Triage::InboxItems.upsert(@inbox, kind: kind, unit: "acme/api#stack/s1", finding: finding, title: "decide #{finding}")
  end

  def test_silent_with_an_empty_inbox
    assert_nil surface
  end

  def test_announces_new_triage_items_once_then_stays_open
    triage_item("a")
    out = surface
    assert_includes out["systemMessage"], "[triage_decision] decide a"
    assert_nil surface, "a delivered item is not announced again"
    assert_equal 1, @inbox.open_items.size
  end

  def test_second_item_announces_only_the_new_one
    triage_item("a")
    surface
    triage_item("b", kind: "triage_escalation")
    msg = surface["systemMessage"]
    assert_includes msg, "decide b"
    refute_includes msg, "decide a"
  end

  def test_session_that_ends_mid_delivery_leaves_item_for_next_session
    triage_item("a")
    @inbox.lease(owner: "dead-session", ttl: -1)
    assert_includes surface({ "session_id" => "s2" })["systemMessage"], "decide a"
  end

  def test_stop_hook_active_never_re_enters
    triage_item("a")
    assert_nil surface({ "session_id" => "s1", "stop_hook_active" => true })
  end

  def test_pulse_p0_announce_reaches_the_stop_surface
    InboxStore::CLI.run([ "init", "--roles", "lead,worker" ], out: StringIO.new)
    dir = File.join(@home, ".claude", "cf", "sessions", "s1")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "inbox-role"), "WORKER")
    InboxStore::CLI.run([ "announce", "--from", "lead", "--subject", "Pulse P0: integrity breach" ], out: StringIO.new)
    msg = surface["systemMessage"]
    assert_includes msg, "[announce] Pulse P0: integrity breach"
    assert_nil surface
  end

  def test_announce_without_a_bound_role_is_ignored
    InboxStore::CLI.run([ "init", "--roles", "lead,worker" ], out: StringIO.new)
    InboxStore::CLI.run([ "announce", "--from", "lead", "--subject", "hello" ], out: StringIO.new)
    assert_nil surface
  end

  def test_same_announce_in_two_inbox_roots_is_not_collapsed
    other = Dir.mktmpdir
    announce_to_worker("hello")
    first = surface["systemMessage"]
    ENV["INBOX_ROOT"] = other
    announce_to_worker("hello")
    second = surface["systemMessage"]
    assert_includes first, "[announce] hello"
    assert_includes second, "[announce] hello", "same subject in another root is a new item"
  ensure
    FileUtils.remove_entry(other) if other
  end

  def test_failed_output_leaves_items_leased_for_a_later_session
    triage_item("a")
    broken = Object.new
    def broken.puts(*) = raise(IOError, "closed")
    DoctrineReviewSurface.run({ "session_id" => "s1" }, broken, inbox: @inbox)
    assert_equal "leased", @inbox.open_items.first["state"]
  end

  private

  def announce_to_worker(subject)
    InboxStore::CLI.run([ "init", "--roles", "lead,worker" ], out: StringIO.new)
    dir = File.join(@home, ".claude", "cf", "sessions", "s1")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "inbox-role"), "WORKER")
    InboxStore::CLI.run([ "announce", "--from", "lead", "--subject", subject ], out: StringIO.new)
  end
end
