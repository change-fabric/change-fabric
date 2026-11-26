# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/triage/liveness"

# C1: owner liveness is alive, dead or unknown, and only dead may act.
class TriageLivenessTest < Minitest::Test
  Agents = Triage::Liveness::Agents
  ABSENT = Triage::Liveness::ABSENT

  OWNER = { "host" => "h", "boot_id" => "boot-1", "pid" => 4242, "pid_start" => "Tue Nov 25 10:00:00 2026",
            "session_id" => "sess-1", "fence" => 1 }.freeze

  def verdict(owner = OWNER, boot: "boot-1", started: "Tue Nov 25 10:00:00 2026", listing: Agents.new(ok: true, complete: true, sessions: []), host: "h")
    Triage::Liveness.new(host: host, boot_id: -> { boot }, pid_start: ->(_pid) { started }, agents: -> { listing }).verdict(owner)
  end

  def test_a_live_pid_missing_from_the_agent_list_is_alive
    assert_predicate verdict, :alive?
  end

  def test_a_changed_boot_id_on_the_same_machine_is_dead_without_a_listing
    result = verdict(boot: "boot-2", listing: Agents.new(ok: false, complete: false, sessions: []))
    assert_predicate result, :dead?
    assert_match(/boot id changed/, result.reason)
  end

  def test_pid_reuse_with_a_complete_listing_is_dead
    result = verdict(started: "Wed Nov 26 01:00:00 2026")
    assert_predicate result, :dead?
    assert_match(/pid reuse/, result.reason)
  end

  def test_an_absent_pid_with_a_complete_listing_is_dead
    assert_predicate verdict(started: ABSENT), :dead?
  end

  def test_a_listing_failure_is_unknown
    assert_predicate verdict(started: ABSENT, listing: Agents.new(ok: false, complete: false, sessions: [])), :unknown?
  end

  def test_a_partial_listing_is_unknown
    assert_predicate verdict(started: ABSENT, listing: Agents.new(ok: true, complete: false, sessions: [])), :unknown?
  end

  def test_contradictory_evidence_is_unknown
    listed = Agents.new(ok: true, complete: true, sessions: [ "sess-1" ])
    result = verdict(started: ABSENT, listing: listed)
    assert_predicate result, :unknown?
    assert_match(/still listed/, result.reason)
  end

  def test_a_remote_owner_is_unknown
    assert_predicate verdict(OWNER.merge("host" => "other"), boot: "boot-2"), :unknown?
  end

  def test_a_failed_pid_probe_is_unknown
    assert_predicate verdict(started: nil), :unknown?
  end

  def test_missing_identity_is_unknown_never_dead
    assert_predicate verdict(OWNER.merge("boot_id" => nil), boot: "boot-2"), :unknown?
    assert_predicate verdict(nil), :unknown?
  end

  def test_an_unavailable_current_boot_id_is_unknown
    assert_predicate verdict(boot: nil), :unknown?
  end

  def test_agents_parses_a_complete_list_and_flags_a_partial_one
    runner = ->(_argv, _timeout) { Triage::Command::Result.new(out: '[{"session_id":"a"},{"sessionId":"b"}]', err: "", ok: true, timed_out: false) }
    assert_equal %w[a b], Triage::Liveness.agents(runner: runner).sessions
    partial = ->(_argv, _timeout) { Triage::Command::Result.new(out: '{"agents":[],"truncated":true}', err: "", ok: true, timed_out: false) }
    refute Triage::Liveness.agents(runner: partial).complete
    broken = ->(_argv, _timeout) { Triage::Command::Result.new(out: "not json", err: "", ok: true, timed_out: false) }
    refute Triage::Liveness.agents(runner: broken).ok
  end

  def test_pid_start_distinguishes_absent_from_a_failed_probe
    gone = ->(_argv, _timeout) { Triage::Command::Result.new(out: "", err: "", ok: false, timed_out: false) }
    assert_equal ABSENT, Triage::Liveness.pid_start(1, runner: gone)
    broken = ->(_argv, _timeout) { Triage::Command::Result.new(out: "", err: "No such file", ok: false, timed_out: false) }
    assert_nil Triage::Liveness.pid_start(1, runner: broken)
    seen = ->(_argv, _timeout) { Triage::Command::Result.new(out: "Tue Nov 25 10:00:00 2026\n", err: "", ok: true, timed_out: false) }
    assert_equal "Tue Nov 25 10:00:00 2026", Triage::Liveness.pid_start(1, runner: seen)
  end
end
