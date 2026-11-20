# frozen_string_literal: true

require 'securerandom'
require 'time'
require_relative 'canonical'
require_relative 'client'
require_relative 'local_store'
require_relative 'verifier'
require_relative 'sync'

module ApprovalConsole
  # The console path: post a canonical body, print the link, poll for the
  # proof, then verify it offline against the pinned passkeys, the pinned
  # receipt key and the caller's own context before anyone records it.
  module Remote
    LIFETIME = 900
    POLL = 3
    KIND = 'webauthn+totp'

    Result = Struct.new(:proof, :error, keyword_init: true) do
      def ok? = error.nil?
    end

    module_function

    # The context a verifier compares a signed body against, from the caller's
    # own attrs (never from the body): item digests are recomputed from fields.
    def expected(attrs, machine_id)
      context = string_keys(attrs)
      context['machine_id'] = machine_id
      context['profile'] = nil unless context.key?('profile')
      context['items'] = context['items'].map { |item| item_pair(string_keys(item)) } if context['items'].is_a?(Array)
      context.slice('type', 'machine_id', 'repo', 'sha', 'profile', *Canonical::PER_TYPE.fetch(context['type'], []),
                    *Canonical::OPTIONAL.fetch(context['type'], []))
    end

    def string_keys(hash) = hash.to_h { |key, value| [ key.to_s, value ] }

    def item_pair(item) = { 'step' => item['step'], 'digest' => item['digest'] || Canonical.step_digest(item['fields']) }

    # The same context read back from a body this machine built itself (for
    # `wait` and for terminal receipts, where the body is the caller's own).
    def expected_from_body(body)
      parsed = Canonical.parse(body)
      expected(parsed.except('v', 'request_id', 'created_at', 'expires_at'), parsed['machine_id'])
    end

    def verifier(store)
      pins = store.pins
      Verifier.new(rp_id: pins['rp_id'], credentials: pins['credentials'] || {}, receipt_public_key: pins['receipt_public_key'])
    end

    def build_body(attrs, store, now:, ttl: LIFETIME)
      Canonical.build(attrs.merge('machine_id' => store.machine_id, 'request_id' => SecureRandom.uuid,
                                  'created_at' => now.utc.iso8601, 'expires_at' => (now.utc + ttl).iso8601))
    end

    # Posts the request and returns [body, url]. Raises Client errors.
    # Queued offline approvals are synced first: a phone approval advances the
    # console's last_step past them, which would turn them into conflicts.
    # The body is saved by request id, so `approval_console.rb record <id>`
    # can resume when the waiting process dies.
    def submit(attrs, store:, client:, now:, ttl: LIFETIME)
      Sync.run(store: store, client: client) unless store.unsynced.empty?
      body = build_body(attrs, store, now: now, ttl: ttl)
      data = client.create_request(body)
      store.save_request(Canonical.parse(body)['request_id'], body)
      [ body, data['url'].to_s ]
    end

    def approve(attrs, store:, client:, out:, sleeper: ->(s) { sleep(s) }, clock: -> { Time.now }, ttl: LIFETIME)
      body, url = submit(attrs, store: store, client: client, now: clock.call, ttl: ttl)
      out.puts "Approve on your phone: #{url}"
      out.puts "(if this process dies, resume with: approval_console.rb record #{Canonical.parse(body)['request_id']})"
      out.flush # a piped or backgrounded agent must see the link before the poll
      out.puts '(review every field, enter the code from your TOTP app, then approve with your passkey)'
      wait(body, expected: expected(attrs, store.machine_id), store: store, client: client, sleeper: sleeper, clock: clock)
    rescue Client::Unreachable => e
      Result.new(error: "the console is unreachable (#{e.message})")
    rescue Client::Refused => e
      Result.new(error: e.message)
    end

    # Polls until approved, expired or past the body's own deadline.
    def wait(body, expected:, store:, client:, sleeper: ->(s) { sleep(s) }, clock: -> { Time.now })
      parsed = Canonical.parse(body)
      deadline = Canonical.parse_time(parsed['expires_at']) + POLL
      loop do
        data = poll(client, parsed['request_id'])
        case data&.fetch('status', nil)
        when 'approved' then return verified(data['proof'], body, expected, store)
        when 'pending', nil then nil
        else return Result.new(error: "the request is #{data['status']}")
        end
        return Result.new(error: 'timed out waiting for the approval') if clock.call >= deadline

        sleeper.call(POLL)
      end
    rescue Client::Refused => e
      Result.new(error: e.message)
    end

    def poll(client, request_id)
      client.proof(request_id)
    rescue Client::Unreachable
      nil
    end

    def verified(proof, body, expected, store)
      problem = check(proof, body, expected, store, kind: KIND)
      return Result.new(error: "the console proof did not verify: #{problem}") if problem

      store.observe_step(proof['totp_step'])
      Result.new(proof: proof)
    end

    # nil when `proof` is a receipt-backed proof of `kind` for exactly `body`
    # and `expected`, else the reason.
    def check(proof, body, expected, store, kind:)
      return 'no proof returned' unless proof.is_a?(Hash)
      return "unexpected proof kind #{proof['kind'].inspect}" unless proof['kind'] == kind
      return 'the proof is for a different body' unless proof['body'] == body

      result = verifier(store).verify(proof, expected: expected, require_receipt: true)
      result.ok? ? nil : result.reason
    end
  end
end
