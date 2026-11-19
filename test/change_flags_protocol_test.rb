# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/change_flags_protocol"
require_relative "../scripts/change_flags_fixture"

# cf.flags/1: validation, revision conflicts, the incident latch, fencing,
# recovery_auth binding, the fixture adapter, and confirmed disable.
class ChangeFlagsProtocolTest < Minitest::Test
  P = ChangeFlagsProtocol

  def request(op, revision: 0, **extra)
    { "protocol" => P::PROTOCOL, "request_id" => "r-#{extra.hash.abs}-#{op}", "idempotency_key" => extra.delete(:key) || "k-#{rand(1 << 30)}",
      "op" => op, "flag" => "new_checkout", "env" => "staging", "expected_revision" => revision }.merge(extra.transform_keys(&:to_s))
  end

  def step(state, op, **opts)
    P.apply(state, request(op, **opts))
  end

  def auth(incident_id, token: 5, nonce: "n1")
    { "incident_id" => incident_id, "rollout_revision" => 2, "fix_commit" => "abc123", "cohort" => "internal", "fencing_token" => token, "nonce" => nonce }
  end

  def test_valid_request_and_reply_round_trip
    reply, = step(P.initial_state, "get")
    assert_empty P.request_errors(request("get"))
    assert_empty P.reply_errors(reply)
  end

  def test_request_errors_name_the_field
    errors = P.request_errors("protocol" => "nope", "op" => "explode")
    assert(errors.any? { |e| e.include?("protocol") })
    assert(errors.any? { |e| e.include?("op must be") })
    assert(P.request_errors(request("set_cohort")).any? { |e| e.include?("cohort is required") })
    assert(P.request_errors(request("enable", revision: "1")).any? { |e| e.include?("expected_revision") })
    assert(P.request_errors(request("enable", recovery_auth: { "cohort" => "everyone" })).any? { |e| e.include?("recovery_auth") })
  end

  def test_invalid_request_yields_invalid_request_error_and_no_state_change
    state = P.initial_state
    reply, after = P.apply(state, "not a hash")
    assert_equal "invalid_request", reply.dig("error", "code")
    assert_equal state, after
  end

  def test_reply_rules
    reply, = step(P.initial_state, "get")
    assert(P.reply_errors(reply.merge("ok" => false)).any? { |e| e.include?("must carry an error") })
    assert(P.reply_errors(reply.merge("error" => { "code" => "fenced", "message" => "x" })).any? { |e| e.include?("revision_conflict") })
    assert(P.reply_errors(reply.merge("state" => { "enabled" => true, "cohorts" => [], "incident" => "open" })).any? { |e| e.include?("incident_id") })
  end

  def test_write_applies_and_bumps_version
    reply, state = step(P.initial_state, "set_cohort", cohort: "internal")
    assert reply["ok"]
    assert_equal 1, reply["flag_state_version"]
    assert_equal [ "internal" ], reply.dig("state", "cohorts")
    _, state = step(state, "enable", revision: 1)
    assert state["enabled"]
  end

  def test_stale_revision_changes_nothing
    _, state = step(P.initial_state, "set_cohort", cohort: "internal")
    reply, after = step(state, "set_cohort", cohort: "pilot", revision: 0)
    refute reply["ok"]
    assert_equal "revision_conflict", reply.dig("error", "code")
    assert_equal state["cohorts"], after["cohorts"]
    assert_equal 1, after["flag_state_version"]
  end

  def test_disable_with_stale_revision_still_disables_latches_and_reports_conflict
    _, state = step(P.initial_state, "enable")
    reply, state = step(state, "disable", revision: 99)
    assert reply["ok"]
    assert_equal "revision_conflict", reply.dig("error", "code")
    refute reply.dig("state", "enabled")
    assert_equal "open", reply.dig("state", "incident")
    assert_empty P.reply_errors(reply)
    assert_equal "inc-1", state["incident_id"]
  end

  def test_incident_open_blocks_enable_and_set_cohort
    _, state = step(P.initial_state, "disable")
    %w[enable set_cohort].each do |op|
      reply, = step(state, op, revision: state["flag_state_version"], cohort: "internal")
      assert_equal "incident_open", reply.dig("error", "code"), op
    end
  end

  def test_recovery_auth_reenables_internal_and_closes_incident
    _, state = step(P.initial_state, "disable")
    reply, state = step(state, "set_cohort", revision: 1, cohort: "internal", fencing_token: 5, recovery_auth: auth("inc-1"))
    assert reply["ok"], reply.inspect
    assert_equal "closed", reply.dig("state", "incident")
    assert reply.dig("state", "enabled")
    assert_equal 5, state["fencing_token"]
  end

  def test_recovery_auth_is_single_use_and_bound
    _, state = step(P.initial_state, "disable")
    bad = [ [ "wrong incident", auth("inc-9"), "internal" ], [ "wrong token", auth("inc-1", token: 4), "internal" ], [ "wrong cohort", auth("inc-1"), "everyone" ] ]
    bad.each do |label, recovery, cohort|
      reply, = step(state, "set_cohort", revision: 1, cohort: cohort, fencing_token: 5, recovery_auth: recovery)
      assert_equal "incident_open", reply.dig("error", "code"), label
    end
    _, state = step(state, "set_cohort", revision: 1, cohort: "internal", fencing_token: 5, recovery_auth: auth("inc-1"))
    # a second breach after the first recovery needs a fresh authorisation; the used nonce is dead
    _, state = step(state, "disable", revision: 2)
    assert_equal "inc-2", state["incident_id"]
    reply, = step(state, "enable", revision: 3, fencing_token: 5, recovery_auth: auth("inc-2"))
    assert_equal "incident_open", reply.dig("error", "code"), "token reuse"
    reply, = step(state, "enable", revision: 3, fencing_token: 5, recovery_auth: auth("inc-2", nonce: "n2"))
    assert reply["ok"]
    stale, = step(state, "enable", revision: 3, fencing_token: 5, recovery_auth: auth("inc-1", nonce: "n3"))
    assert_equal "incident_open", stale.dig("error", "code"), "an old incident's auth is invalidated by the new breach"
  end

  def test_fencing_rejects_a_stale_lease_but_not_disable
    _, state = step(P.initial_state, "set_cohort", cohort: "internal", fencing_token: 7)
    reply, = step(state, "set_cohort", revision: 1, cohort: "pilot", fencing_token: 6)
    assert_equal "fenced", reply.dig("error", "code")
    reply, = step(state, "disable", revision: 1, fencing_token: 6)
    assert reply["ok"]
    refute reply.dig("state", "enabled")
  end

  def test_idempotency_key_replays_the_first_reply
    first, state = step(P.initial_state, "set_cohort", cohort: "internal", key: "same")
    again, after = step(state, "set_cohort", cohort: "internal", key: "same", revision: 1)
    assert_equal first, again
    assert_equal 1, after["flag_state_version"]
  end

  def test_outage_is_unavailable
    state = P.initial_state.merge("outage" => true)
    reply, = step(state, "get")
    assert_equal "unavailable", reply.dig("error", "code")
  end

  def test_fixture_adapter_persists_and_reports_unknown_flag
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state.json")
      adapter = ChangeFlagsFixture.new(path, known: [ "new_checkout" ])
      assert adapter.call(request("enable"))["ok"]
      assert ChangeFlagsFixture.new(path).call(request("get")).dig("state", "enabled")
      reply = adapter.call(request("get").merge("flag" => "other"))
      assert_equal "unknown_flag", reply.dig("error", "code")
      adapter.set_outage("new_checkout", "staging", true)
      assert_equal "unavailable", adapter.call(request("get")).dig("error", "code")
    end
  end

  def disable_call(adapter)
    ->(req) { adapter.call(req) }
  end

  def test_disable_confirmed_succeeds_and_reads_off_state
    Dir.mktmpdir do |dir|
      adapter = ChangeFlagsFixture.new(File.join(dir, "s.json"))
      adapter.call(request("enable"))
      result = P.disable_confirmed(disable_call(adapter), flag: "new_checkout", env: "staging", incident_key: "i1", pause: ->(_) { })
      assert_equal :confirmed, result[:status]
      refute result[:reply].dig("state", "enabled")
    end
  end

  def test_disable_confirmed_retries_through_a_transient_outage
    calls = 0
    state = P.initial_state.merge("enabled" => true)
    flaky = lambda do |req|
      calls += 1
      raise "boom" if calls <= 2

      reply, state = P.apply(state, req)
      reply
    end
    result = P.disable_confirmed(flaky, flag: "f", env: "staging", incident_key: "i2", pause: ->(_) { })
    assert_equal :confirmed, result[:status]
    assert_operator result[:attempts], :>, 1
  end

  def test_disable_unconfirmed_after_the_retry_window_pages
    now = 0.0
    down = ->(_req) { raise "adapter down" }
    result = P.disable_confirmed(down, flag: "f", env: "staging", incident_key: "i3", clock: -> { now }, pause: ->(s) { now += s + 30 })
    assert_equal :disable_unconfirmed, result[:status]
  end

  def test_disable_unconfirmed_when_off_state_never_reads_back
    now = 0.0
    lying = lambda do |req|
      P.apply(P.initial_state, req).first.then { |reply| reply.merge("state" => reply["state"].merge("enabled" => true)) }
    end
    result = P.disable_confirmed(lying, flag: "f", env: "staging", incident_key: "i4", clock: -> { now }, pause: ->(s) { now += s + 30 })
    assert_equal :disable_unconfirmed, result[:status]
  end

  def test_recovery_resets_cohorts_to_internal_only
    %w[set_cohort enable].each do |op|
      _, state = step(P.initial_state, "set_cohort", cohort: "everyone")
      _, state = step(state, "disable", revision: 1)
      assert_equal [ "everyone" ], state["cohorts"], "disable preserves the cohorts"
      reply, = step(state, op, revision: 2, cohort: "internal", fencing_token: 5, recovery_auth: auth("inc-1"))
      assert reply["ok"], op
      assert_equal [ "internal" ], reply.dig("state", "cohorts"), op
    end
  end

  def test_a_get_is_never_replayed_from_the_idempotency_cache
    _, state = step(P.initial_state, "enable", key: "w")
    first, state = step(state, "get", key: "same-read")
    _, state = step(state, "disable", revision: 1)
    again, = step(state, "get", key: "same-read")
    assert first.dig("state", "enabled")
    refute again.dig("state", "enabled")
  end

  def test_confirmation_sees_a_flag_that_turns_off_after_provider_lag
    now = 0.0
    state = P.initial_state.merge("enabled" => true)
    reads = 0
    laggy = lambda do |req|
      reads += 1 if req["op"] == "get"
      reply, state = P.apply(state, req)
      reply = reply.merge("state" => reply["state"].merge("enabled" => true)) if req["op"] == "get" && reads < 3
      reply
    end
    result = P.disable_confirmed(laggy, flag: "f", env: "staging", incident_key: "i5", clock: -> { now }, pause: ->(s) { now += s })
    assert_equal :confirmed, result[:status]
  end
end
