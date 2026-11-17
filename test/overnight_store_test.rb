# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../scripts/overnight_store"

# The overnight run store: journal order and replay, the fenced lease, the
# corrupt-state block, run selection, the ownership lock and the disabled
# execution gate. HOME is a temp dir, so nothing touches ~/.claude/cf.
class OvernightStoreTest < Minitest::Test
  REPO = "acme/web"

  def setup
    @home = Dir.mktmpdir
    @prev = Dir.home
    ENV["HOME"] = @home
    # Real time: StackStore judges its LEASE heartbeat against the wall clock.
    @now = Time.now.utc
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
  end

  # Every store shares one clock; `advance` moves it past the lease TTL.
  def store(run = "r1")
    s = OvernightStore.new(REPO, run)
    s.clock = -> { @now }
    s
  end

  def advance = @now += OvernightStore::LEASE_TTL + 1

  def fresh(run = "r1")
    s = store(run)
    s.create(repo: REPO, units: [ { "id" => "p1" } ])
    s
  end


  def test_execution_is_disabled
    refute OvernightStore::OVERNIGHT_EXECUTE_ENABLED
    refute OvernightStore.execute_enabled?
    assert_raises(OvernightStore::Disabled) { OvernightStore.assert_execute_enabled! }
  end

  def test_files_live_under_the_temp_home
    s = fresh
    assert s.state_path.start_with?(File.join(@home, ".claude", "cf", "overnight"))
    assert File.exist?(s.journal_path)
    assert_equal "r1", s.state["run_id"]
  end

  def test_journal_records_three_phases_in_order
    s = fresh
    token = s.acquire_lease(session: "a")["token"]
    s.plan_action("p1:push:1", kind: "push", token: token)
    s.dispatch_action("p1:push:1", token: token, external: { "sha" => "abc" })
    s.observe_action("p1:push:1", token: token, evidence: { "remote" => "abc" })
    assert_equal %w[planned dispatched observed-complete], s.journal.map { |r| r["phase"] }
    assert_equal "r1:p1:push:1", s.journal.first["key"], "intent carries an idempotency key"
    assert_empty s.nonterminal
  end

  def test_journal_refuses_out_of_order_and_repeats
    s = fresh
    token = s.acquire_lease(session: "a")["token"]
    assert_raises(OvernightStore::Error) { s.dispatch_action("p1:push:1", token: token) }
    s.plan_action("p1:push:1", kind: "push", token: token)
    assert_raises(OvernightStore::Error) { s.plan_action("p1:push:1", kind: "push", token: token) }
    assert_raises(OvernightStore::Error) { s.plan_action("bad id", kind: "push", token: token) }
    assert_raises(OvernightStore::Error) { s.plan_action("p1:x:1", kind: "teleport", token: token) }
  end

  def test_lease_fences_a_second_session_until_expiry
    s = fresh
    first = s.acquire_lease(session: "a", now: @now)
    assert_equal 1, first["token"]
    assert_equal 1, s.acquire_lease(session: "a", now: @now)["token"], "same session keeps its token"
    assert_raises(OvernightStore::Held) { s.acquire_lease(session: "b", now: @now) }
    second = s.acquire_lease(session: "b", now: @now + OvernightStore::LEASE_TTL + 1)
    assert_equal 2, second["token"]
  end

  def test_stale_token_write_is_rejected
    s = fresh
    s.acquire_lease(session: "a")
    advance
    s.acquire_lease(session: "b")
    error = assert_raises(OvernightStore::StaleToken) { s.plan_action("p1:push:1", kind: "push", token: 1) }
    assert_match(/stale/, error.message)
    assert_empty s.journal
  end

  def test_incomplete_lease_reads_as_held_until_ttl_old
    s = fresh
    s.acquire_lease(session: "a")
    File.write(s.lease_path, "")
    assert_raises(OvernightStore::Held) { s.acquire_lease(session: "b") }
    File.utime(@now - OvernightStore::LEASE_TTL - 1, @now - OvernightStore::LEASE_TTL - 1, s.lease_path)
    assert_equal 2, s.acquire_lease(session: "b")["token"], "the token still grows past the lost holder"
  end

  def test_token_never_repeats_after_release
    s = fresh
    token = s.acquire_lease(session: "a")["token"]
    s.release_lease(token: token)
    assert_equal 2, s.acquire_lease(session: "a")["token"]
  end

  def test_holder_suspended_before_request_is_rejected_after_takeover
    s = fresh
    old = s.acquire_lease(session: "a")["token"]
    s.plan_action("p1:merge:1", kind: "merge", token: old)
    # Session a stalls here; its lease expires and b takes over.
    advance
    fresh_token = s.acquire_lease(session: "b")["token"]
    assert_raises(OvernightStore::StaleToken) { s.dispatch_action("p1:merge:1", token: old) }
    # b reconciles: the lookup shows the merge never reached the remote.
    s.observe_action("p1:merge:1", token: fresh_token, evidence: { "outcome" => "not-sent" }, reconcile: true)
    s.plan_action("p1:merge:2", kind: "merge", token: fresh_token)
    s.dispatch_action("p1:merge:2", token: fresh_token, external: { "pr" => 7 })
    assert_equal [ "p1:merge:2" ], s.journal.select { |r| r["phase"] == "dispatched" }.map { |r| r["id"] }
  end

  def test_corrupt_state_blocks_mutation_and_is_kept
    s = fresh
    File.write(s.state_path, "{not json")
    assert s.mutations_blocked?
    assert_raises(OvernightStore::Corrupt) { s.acquire_lease(session: "a") }
    assert_equal "{not json", File.read(s.state_path), "never moved aside"
  end

  def test_corrupt_journal_blocks_mutation
    s = fresh
    token = s.acquire_lease(session: "a")["token"]
    File.open(s.journal_path, "a") { |io| io.puts("{half") }
    assert s.mutations_blocked?
    assert_raises(OvernightStore::Corrupt) { s.plan_action("p1:push:1", kind: "push", token: token) }
  end

  # Crash before and after each dispatched and each observed-complete, for
  # every kind: resume neither repeats nor loses the action.
  def test_crash_injection_per_kind
    OvernightStore::DISPATCH.each_key do |kind|
      [ :after_planned, :after_dispatched, :after_observed ].each do |point|
        run = "#{kind}-#{point}"
        s = fresh(run)
        token = s.acquire_lease(session: "a")["token"]
        id = "p1:step:1"
        s.plan_action(id, kind: kind, token: token)
        s.dispatch_action(id, token: token) unless point == :after_planned
        s.observe_action(id, token: token) if point == :after_observed

        resumed = store(run)
        advance
        lease = resumed.acquire_lease(session: "b")
        actions = resumed.actions
        assert_equal 1, actions.size, "#{run}: lost or duplicated"
        assert_raises(OvernightStore::Error) { resumed.plan_action(id, kind: kind, token: lease["token"]) }
        case point
        when :after_planned, :after_dispatched
          assert_equal "reconcile", lease["mode"], run
          assert_equal [ id ], resumed.nonterminal.map { |a| a["id"] }
          assert_raises(OvernightStore::Error) { resumed.plan_action("p1:next:1", kind: kind, token: lease["token"]) }
          resumed.observe_action(id, token: lease["token"], reconcile: true)
          resumed.plan_action("p1:next:1", kind: kind, token: lease["token"])
        when :after_observed
          assert_empty resumed.nonterminal
        end
      end
    end
  end

  def test_uncertain_dispatch_without_lookup_blocks_the_unit
    s = fresh
    token = s.acquire_lease(session: "a")["token"]
    s.plan_action("p2:write:1", kind: "destructive-write", token: token)
    s.dispatch_action("p2:write:1", token: token)
    s.mark_uncertain("p2:write:1", token: token, reason: "lost response")
    s.plan_action("p3:write:1", kind: "destructive-write", token: token)
    assert_equal %w[p2 p3], s.blocked_units, "a planned write may already have run"
    refute s.reconcilable?("destructive-write")
    assert s.reconcilable?("push")
  end

  def test_policy_freezes_once_with_hash
    s = fresh
    token = s.acquire_lease(session: "a")["token"]
    hash = s.freeze_policy({ "b" => 1, "a" => [ 2 ] }, token: token)
    assert_equal OvernightStore.policy_hash({ "a" => [ 2 ], "b" => 1 }), hash, "key order does not matter"
    assert_equal hash, s.policy["sha256"]
    assert_raises(OvernightStore::Error) { s.freeze_policy({}, token: token) }
    refute_equal OvernightStore.policy_hash({ "credential_isolation" => false }),
                 OvernightStore.policy_hash({ "credential_isolation" => nil })
  end

  def test_run_selection
    assert_nil OvernightStore.select(REPO)
    fresh("r1")
    assert_equal "r1", OvernightStore.select(REPO).run_id
    fresh("r2")
    assert_raises(OvernightStore::Ambiguous) { OvernightStore.select(REPO) }
    assert_equal "r2", OvernightStore.select(REPO, "r2").run_id
    token = store("r1").acquire_lease(session: "a")["token"]
    store("r1").update_state(token: token) { |st| st["finished"] = true }
    assert_equal "r2", OvernightStore.select(REPO).run_id
  end

  def test_corrupt_run_counts_as_unfinished
    fresh("r1")
    File.write(store("r1").state_path, "")
    assert_equal [ "r1" ], OvernightStore.unfinished(REPO)
  end

  def leased(run, session)
    s = fresh(run)
    [ s, s.acquire_lease(session: session)["token"] ]
  end

  def test_two_run_ids_on_one_target_are_refused
    r1, token = leased("r1", "a")
    r1.claim_target(target: "production", token: token)
    assert_equal "r1", r1.claim_target(target: "production", token: token)["slug"], "the owner reclaims"
    r2, token2 = leased("r2", "c")
    assert_raises(OvernightStore::Held) { r2.claim_target(target: "production", token: token2) }
  end

  def test_stale_holder_cannot_release_ownership
    r1, token = leased("r1", "a")
    r1.claim_target(target: "production", token: token)
    advance
    taken = store("r1").acquire_lease(session: "b")["token"]
    assert_raises(OvernightStore::StaleToken) { store("r1").release_target(target: "production", token: token) }
    assert File.exist?(r1.target_lock_path("production")), "the stale holder released nothing"
    store("r1").release_target(target: "production", token: taken)
    r2, token2 = leased("r2", "c")
    r2.claim_target(target: "production", token: token2)
  end

  def test_sweep_stale_recovery_cannot_release_a_live_overnight_claim
    r1, token = leased("r1", "a")
    r1.claim_target(target: "production", token: token)
    claim = StackStore.new(REPO, "overnight-r1")
    assert_raises(StackStore::Invalid) { claim.release(stale: true) }
    assert claim.claimed?
    assert_raises(StackStore::Held) { StackStore.new(REPO, "sweep-12-14").claim(source: "stack") }
  end

  def test_ownership_lock_is_shared_with_the_sweep_active_claim
    StackStore.new(REPO, "sweep-12-14").claim(source: "stack")
    s, token = leased("r1", "a")
    error = assert_raises(OvernightStore::Held) { s.claim_target(target: "production", token: token) }
    assert_match(/sweep-12-14/, error.message)
  end
end
