# frozen_string_literal: true

require "minitest/autorun"
require_relative "support/triage_world"

# C2 kill points: every tick first reconciles unfinished dispatches with C1. A
# launcher death never frees a lease; only a child proven dead releases it, and
# a stale owner cannot mutate past the fence.
class TriageReconcileTest < Minitest::Test
  NOW = TriageFakes::NOW
  Agents = Triage::Liveness::Agents

  def setup
    @world = TriageWorld.new
    @released = []
    @unlease = ->(row) { @released << row["action_id"] }
  end

  def teardown = @world.close

  def dispatch(at: NOW - 3600, id: "d1", session: "sess-d1")
    @world.journal(now: at).append("type" => "dispatch", "action_id" => id, "host" => "mini", "repo" => "acme/api", "unit" => "acme/api#u",
                                   "verb" => "start_next", "session_id" => session, "path" => @world.path("acme/api"),
                                   "stack" => { "repo_id" => "acme/api", "slug" => "s2" })
    @world.cap.reserve(id)
  end

  def handshake(id = "d1", session: "sess-d1")
    @world.journal.append("type" => "handshake", "action_id" => id, "pid" => 4242, "pid_start" => "T0", "boot_id" => "boot-1",
                          "session_id" => session, "host" => "h", "fence" => 1)
  end

  def reconcile(liveness: @world.liveness, agents: Agents.new(ok: true, complete: true, sessions: []), now: NOW, apply: true)
    Triage::Reconcile.new(journal: @world.journal, liveness: liveness, inbox: @world.inbox, now: now, unlease: @unlease,
                          agents: -> { agents }, apply: apply).call
  end

  def escalations = @world.inbox.open_items.select { |item| item["kind"] == "triage_escalation" }

  # Kill point 1: killed after persisting, before the spawn.
  def test_killed_before_spawn_a_young_dispatch_waits_and_an_old_one_is_dead_with_one_escalation
    dispatch(at: NOW - 60)
    assert_equal "waiting", reconcile.first.decision
    assert_empty escalations

    old_world_row = @world.journal.find("d1")
    refute old_world_row.finished?

    later = NOW + 600
    changes = reconcile(now: later)
    assert_equal "dead", changes.first.decision
    assert_equal "dead", @world.journal.find("d1").terminal["type"]
    assert_equal 1, escalations.size
    assert_equal 1, @world.cap.used, "the reservation stays consumed"
    assert_equal [ "d1" ], @released

    reconcile(now: later + 900)
    assert_equal 1, escalations.size, "a later tick does not queue a second escalation"
  end

  # Kill point 2: the launcher spawned the child, then died before the handshake.
  def test_killed_after_spawn_before_handshake_a_listed_session_is_not_declared_dead
    dispatch
    listed = Agents.new(ok: true, complete: true, sessions: [ "sess-d1" ])
    change = reconcile(agents: listed).first
    assert_equal "alive", change.decision
    refute @world.journal.find("d1").finished?
    assert_empty @released, "a launcher death never frees a lease"
  end

  def test_no_handshake_and_a_failed_listing_escalates_instead_of_declaring_death
    dispatch
    failed = Agents.new(ok: false, complete: false, sessions: [])
    assert_equal "unknown", reconcile(agents: failed).first.decision
    assert_equal 1, escalations.size
    assert_empty @released
    refute @world.journal.find("d1").finished?
  end

  # Kill point 3: the child mutated, so it has a handshake; it is still running.
  def test_killed_after_mutation_a_live_child_keeps_its_lease
    dispatch
    handshake
    live = @world.liveness(boot: "boot-1", pid_start: ->(_pid) { "T0" })
    assert_equal "alive", reconcile(liveness: live).first.decision
    assert_empty @released
    refute @world.journal.find("d1").finished?
  end

  def test_an_unknown_child_keeps_its_lease_and_escalates_once
    dispatch
    handshake
    unknown = @world.liveness(boot: "boot-1", pid_start: ->(_pid) { nil })
    2.times { assert_equal "unknown", reconcile(liveness: unknown).first.decision }
    assert_empty @released
    assert_equal 1, escalations.size
  end

  # Kill point 4: the child died before its result was persisted.
  def test_killed_before_result_persistence_a_proven_dead_child_releases_the_lease
    dispatch
    handshake
    dead = @world.liveness(boot: "boot-2")
    assert_equal "dead", reconcile(liveness: dead).first.decision
    assert_equal [ "d1" ], @released
    assert_equal "dead", @world.journal.find("d1").terminal["type"]
    assert_equal 1, @world.cap.used
    assert_empty reconcile(liveness: dead), "a finished dispatch is not reconciled again"
  end

  def test_a_stale_owner_cannot_write_a_result_past_the_dead_row
    dispatch
    handshake
    reconcile(liveness: @world.liveness(boot: "boot-2"))
    assert_raises(Triage::Journal::Fenced) { @world.journal.append("type" => "result", "action_id" => "d1", "exit_class" => "ok") }
    assert_equal "dead", @world.journal.find("d1").terminal["type"]
  end

  def test_a_restart_replays_the_reservation_without_double_counting
    dispatch
    restarted = @world.cap
    assert restarted.reserve("d1").granted
    assert_equal 1, restarted.used
  end

  def test_a_dry_run_reports_without_writing
    dispatch
    handshake
    change = reconcile(liveness: @world.liveness(boot: "boot-2"), apply: false).first
    assert_equal "dead", change.decision
    refute @world.journal.find("d1").finished?
    assert_empty @released
    assert_empty escalations
  end

  def test_a_duplicate_dispatch_id_is_refused
    dispatch
    assert_raises(Triage::Journal::Fenced) { dispatch }
  end
end
