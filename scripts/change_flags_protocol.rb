#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'timeout'

# cf.flags/1: the adapter protocol between cf and a consumer's feature-flag
# CLI. One JSON request on stdin, one JSON reply on stdout. This module holds
# the request and reply validation, the pure state machine every adapter must
# agree with (revision conflicts, the incident latch, fencing, recovery_auth),
# and the confirmed-disable routine triage uses.
#
# `expected_revision` always means the adapter's own flag_state_version, never
# the rollout_revision in a delivery file. cf never calls a production adapter
# with production credentials: in production the adapter runs inside the
# consumer's worker, and this module only defines what it must answer.
module ChangeFlagsProtocol
  PROTOCOL = 'cf.flags/1'
  OPS = %w[get set_cohort disable enable].freeze
  WRITE_OPS = %w[set_cohort disable enable].freeze
  ERROR_CODES = %w[revision_conflict incident_open fenced unknown_flag unavailable invalid_request].freeze
  INCIDENT_STATES = %w[open closed].freeze
  RECOVERY_KEYS = %w[incident_id rollout_revision fix_commit cohort fencing_token nonce signature].freeze
  # Recovery re-enables the first (internal) cohort only.
  RECOVERY_COHORT = 'internal'
  DISABLE_RETRY_WINDOW_S = 120

  module_function

  # --- validation ----------------------------------------------------------

  def request_errors(request)
    return [ 'request must be a JSON object' ] unless request.is_a?(Hash)

    errors = []
    errors << "protocol must be '#{PROTOCOL}'" unless request['protocol'] == PROTOCOL
    %w[request_id idempotency_key flag env].each { |key| errors << "#{key} must be a non-empty string" unless text?(request[key]) }
    errors << "op must be one of #{OPS.join(', ')}" unless OPS.include?(request['op'])
    if WRITE_OPS.include?(request['op'])
      errors << 'expected_revision must be an integer on a write' unless request['expected_revision'].is_a?(Integer)
    elsif request.key?('expected_revision') && !request['expected_revision'].is_a?(Integer)
      errors << 'expected_revision must be an integer'
    end
    errors << 'cohort is required for set_cohort' if request['op'] == 'set_cohort' && !text?(request['cohort'])
    errors << 'fencing_token must be a non-negative integer' if request.key?('fencing_token') && !natural?(request['fencing_token'])
    errors.concat(recovery_errors(request['recovery_auth'])) if request.key?('recovery_auth')
    errors
  end

  def recovery_errors(auth)
    return [ 'recovery_auth must be an object' ] unless auth.is_a?(Hash)

    errors = (auth.keys - RECOVERY_KEYS).map { |key| "recovery_auth.#{key} is not a known key" }
    %w[incident_id fix_commit nonce].each { |key| errors << "recovery_auth.#{key} must be a non-empty string" unless text?(auth[key]) }
    errors << 'recovery_auth.rollout_revision must be an integer' unless auth['rollout_revision'].is_a?(Integer)
    errors << "recovery_auth.cohort must be '#{RECOVERY_COHORT}'" unless auth['cohort'] == RECOVERY_COHORT
    errors << 'recovery_auth.fencing_token must be a non-negative integer' unless natural?(auth['fencing_token'])
    errors
  end

  def reply_errors(reply)
    return [ 'reply must be a JSON object' ] unless reply.is_a?(Hash)

    errors = []
    errors << "protocol must be '#{PROTOCOL}'" unless reply['protocol'] == PROTOCOL
    errors << 'request_id must be a non-empty string' unless text?(reply['request_id'])
    errors << 'ok must be true or false' unless [ true, false ].include?(reply['ok'])
    %w[flag env].each { |key| errors << "#{key} must be a non-empty string" unless text?(reply[key]) }
    errors.concat(state_errors(reply['state']))
    errors << 'flag_state_version must be a non-negative integer' unless natural?(reply['flag_state_version'])
    errors.concat(error_errors(reply))
    errors
  end

  def state_errors(state)
    return [ 'state must be an object' ] unless state.is_a?(Hash)

    errors = []
    errors << 'state.enabled must be true or false' unless [ true, false ].include?(state['enabled'])
    errors << 'state.cohorts must be an array of strings' unless state['cohorts'].is_a?(Array) && state['cohorts'].all? { |c| text?(c) }
    errors << "state.incident must be one of #{INCIDENT_STATES.join(', ')}" unless INCIDENT_STATES.include?(state['incident'])
    errors << 'state.incident_id is required while the incident is open' if state['incident'] == 'open' && !text?(state['incident_id'])
    errors
  end

  def error_errors(reply)
    error = reply['error']
    if error.nil?
      return reply['ok'] == false ? [ 'a reply with ok: false must carry an error' ] : []
    end
    return [ 'error must be an object' ] unless error.is_a?(Hash)

    errors = []
    errors << "error.code must be one of #{ERROR_CODES.join(', ')}" unless ERROR_CODES.include?(error['code'])
    errors << 'error.message must be a non-empty string' unless text?(error['message'])
    # The one reply that is both applied and an error: a stale-revision disable.
    if reply['ok'] == true && error['code'] != 'revision_conflict'
      errors << 'ok: true may carry only a revision_conflict error (a disable applied despite a stale revision)'
    end
    errors
  end

  # --- the state machine ---------------------------------------------------

  # A fresh flag record: off, no cohorts, no incident, version 0.
  def initial_state
    {
      'enabled' => false, 'cohorts' => [], 'incident' => 'closed', 'incident_id' => nil,
      'flag_state_version' => 0, 'fencing_token' => 0, 'incident_count' => 0,
      'used_nonces' => [], 'replies' => {}, 'outage' => false
    }
  end

  # Applies one request to a flag record. Returns [reply, new_state]; the input
  # state is never mutated. Adapters must be observably equal to this, which is
  # what the conformance traces and the fixture adapter rely on.
  def apply(state, request)
    request = {} unless request.is_a?(Hash)
    errors = request_errors(request)
    return [ reply_for(initial_state, request, error: error('invalid_request', errors.join('; '))), state ] unless errors.empty?

    state = deep_copy(state)
    cached = state['replies'][request['idempotency_key']]
    return [ cached, state ] if cached
    return [ reply_for(state, request, error: error('unavailable', 'adapter is unavailable')), state ] if state['outage']

    reply = request['op'] == 'get' ? reply_for(state, request) : apply_write(state, request)
    # Only writes are remembered: a read replayed from cache would hide a later state change.
    state['replies'][request['idempotency_key']] = reply if request['op'] != 'get' && reply.dig('error', 'code') != 'unavailable'
    [ reply, state ]
  end

  def apply_write(state, request)
    return apply_disable(state, request) if request['op'] == 'disable'

    fenced = fencing_error(state, request)
    return reply_for(state, request, error: fenced) if fenced

    conflict = stale_revision(state, request)
    return reply_for(state, request, error: conflict) if conflict

    recovery = state['incident'] == 'open' ? recovery_check(state, request) : nil
    return reply_for(state, request, error: recovery) if recovery

    mutate(state, request)
    reply_for(state, request)
  end

  # Disable always applies: a stale revision still disables and latches the
  # incident, and the reply reports the conflict. It also ignores fencing, so a
  # superseded controller can still turn a flag off.
  def apply_disable(state, request)
    conflict = stale_revision(state, request)
    state['enabled'] = false
    open_incident(state) unless state['incident'] == 'open'
    state['flag_state_version'] += 1
    reply_for(state, request, ok: true, error: conflict)
  end

  def open_incident(state)
    state['incident'] = 'open'
    state['incident_count'] += 1
    state['incident_id'] = "inc-#{state['incident_count']}"
  end

  def mutate(state, request)
    recovered = state['incident'] == 'open'
    if recovered
      state['used_nonces'] << request['recovery_auth']['nonce']
      state['incident'] = 'closed'
      state['incident_id'] = nil
    end
    state['fencing_token'] = [ state['fencing_token'], request['fencing_token'].to_i ].max
    state['enabled'] = true if request['op'] == 'enable'
    if request['op'] == 'set_cohort'
      state['enabled'] = true if recovered
      state['cohorts'] = (state['cohorts'] + [ request['cohort'] ]).uniq
    end
    state['cohorts'] = [ RECOVERY_COHORT ] if recovered
    state['flag_state_version'] += 1
  end

  def stale_revision(state, request)
    return nil if request['expected_revision'] == state['flag_state_version']

    error('revision_conflict', "expected_revision #{request['expected_revision']} but flag_state_version is #{state['flag_state_version']}")
  end

  def fencing_error(state, request)
    return nil unless request.key?('fencing_token')
    return nil if request['fencing_token'] >= state['fencing_token']

    error('fenced', "fencing_token #{request['fencing_token']} is below the current lease #{state['fencing_token']}")
  end

  # While an incident is open, enable and set_cohort need a recovery_auth bound
  # to this incident, the internal cohort and this fencing token, used once.
  # The signature itself is verified by the worker; the protocol checks binding.
  def recovery_check(state, request)
    auth = request['recovery_auth']
    return error('incident_open', "incident #{state['incident_id']} is open; a recovery_auth is required") unless auth
    return error('incident_open', 'recovery_auth is not bound to the open incident') unless auth['incident_id'] == state['incident_id']
    return error('incident_open', 'recovery_auth was already used') if state['used_nonces'].include?(auth['nonce'])
    return error('incident_open', 'recovery_auth fencing_token does not match the request') unless auth['fencing_token'] == request['fencing_token']
    return nil if recovery_cohort_ok?(request)

    error('incident_open', "recovery re-enables the #{RECOVERY_COHORT} cohort only")
  end

  def recovery_cohort_ok?(request)
    request['op'] == 'enable' || request['cohort'] == RECOVERY_COHORT
  end

  def reply_for(state, request, error: nil, ok: nil)
    {
      'protocol' => PROTOCOL, 'request_id' => request['request_id'] || 'unknown', 'ok' => ok.nil? ? error.nil? : ok,
      'flag' => request['flag'] || 'unknown', 'env' => request['env'] || 'unknown',
      'state' => public_state(state), 'flag_state_version' => state['flag_state_version']
    }.tap { |reply| reply['error'] = error if error }
  end

  def public_state(state)
    { 'enabled' => state['enabled'], 'cohorts' => state['cohorts'].dup, 'incident' => state['incident'] }.tap do |pub|
      pub['incident_id'] = state['incident_id'] if state['incident'] == 'open'
    end
  end

  def error(code, message) = { 'code' => code, 'message' => message }

  # --- disable as an operation ----------------------------------------------

  # Disables a flag idempotently, retrying for up to `window` seconds (default
  # DISABLE_RETRY_WINDOW_S), then confirms the off state with a `get`. The
  # window is a hard bound: each adapter call gets only the time left in it
  # (passed as a second argument when `call` takes one, and enforced with a
  # timeout either way), and a pause never sleeps past it. `call` takes a request
  # hash and returns a reply hash (or raises); a reply that fails reply_errors
  # counts as a failed call. Returns {status:, reply:, attempts:, reason:}
  # where status is :confirmed or :disable_unconfirmed, and reason is :timeout
  # when the window expired. :disable_unconfirmed must page at once and halt
  # automatic recovery. `clock` and `pause` are injectable.
  def disable_confirmed(call, flag:, env:, incident_key:, expected_revision: 0, fencing_token: nil,
                        clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, pause: ->(seconds) { sleep(seconds) },
                        window: DISABLE_RETRY_WINDOW_S)
    deadline = clock.call + window
    left = -> { deadline - clock.call }
    attempts = 0
    applied = nil
    while left.call.positive?
      attempts += 1
      applied = bounded_call(call, base_request('disable', flag, env, "disable-#{incident_key}", attempts, expected_revision, fencing_token), left.call)
      if applied&.fetch('ok', false) && left.call.positive?
        confirm = base_request('get', flag, env, "confirm-#{incident_key}-#{attempts}", attempts, expected_revision, nil)
        confirmed = bounded_call(call, confirm, left.call)
        return { status: :confirmed, reply: confirmed, attempts: attempts } if confirmed && confirmed['ok'] && confirmed.dig('state', 'enabled') == false
      end
      pause.call([ retry_delay(attempts), [ left.call, 0 ].max ].min)
    end
    { status: :disable_unconfirmed, reply: applied, attempts: attempts, reason: :timeout }
  end

  def retry_delay(attempts) = [ 2**attempts, 15 ].min

  def base_request(op, flag, env, key, _attempt, revision, token)
    { 'protocol' => PROTOCOL, 'request_id' => key, 'idempotency_key' => key, 'op' => op, 'flag' => flag, 'env' => env,
      'expected_revision' => revision }.tap { |request| request['fencing_token'] = token if token }
  end

  # One adapter call, never longer than `seconds`. Raises, timeouts and replies
  # that break the protocol all read as nil (a failed call).
  def bounded_call(call, request, seconds)
    return nil unless seconds.positive?

    reply = Timeout.timeout(seconds) { call_arity(call) == 1 ? call.call(request) : call.call(request, seconds) }
    reply_errors(reply).empty? ? reply : nil
  rescue StandardError, Timeout::Error
    nil
  end

  # Lambdas expose arity; adapter objects only expose #call.
  def call_arity(call) = call.respond_to?(:arity) ? call.arity : call.method(:call).arity

  def text?(value) = value.is_a?(String) && !value.strip.empty?
  def natural?(value) = value.is_a?(Integer) && !value.negative?
  def deep_copy(value) = JSON.parse(JSON.generate(value))
end
