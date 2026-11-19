# frozen_string_literal: true

require 'io/console'
require 'securerandom'
require 'time'
require_relative 'canonical'
require_relative 'client'
require_relative 'host_health'
require_relative 'local_store'
require_relative 'remote'
require_relative 'sync'

module ApprovalConsole
  # The terminal second factor used by change_approve.rb and change_override.rb
  # after their TTY check and typed confirmation: read a TOTP code with echo
  # off, and spend it. With a console configured and reachable the code goes to
  # its terminal-approve route first, which applies the shared per-machine
  # fence and returns a signed receipt (`channel: terminal`). Unreachable, the
  # code is spent through LocalStore (the fenced, locked write) with
  # `receipt: null` and queued for `approval_console.rb sync`. A reachable
  # console that refuses the code is final: there is no local retry.
  module TerminalPrompt
    KIND = 'totp-terminal'
    LIFETIME = 900
    ENROLL_HINT = 'ruby ~/.claude/cf/bin/approval_console.rb totp-enroll'

    Result = Struct.new(:proof, :error, keyword_init: true) do
      def ok? = error.nil?
    end

    MESSAGES = {
      malformed: 'the code must be 6 digits',
      invalid: 'that code is not valid',
      replay: 'that code was already used; wait for the next one (one approval per 30 seconds)',
      offline_limit: 'too many unsynced approvals or too long since a sync; sync with the console first',
      error: 'the approval state could not be updated safely'
    }.freeze

    CONSOLE_MESSAGES = {
      'totp_invalid' => 'the console says that code is not valid',
      'replay' => 'the console already accepted an approval in this 30 second step; wait for the next code',
      'locked' => 'the console has locked this machine after repeated failures; wait for the lockout to expire',
      'expired' => 'the approval window closed before the code arrived'
    }.freeze

    module_function

    # nil when ready, else the refusal text (not enrolled, or a degraded host
    # for a high-risk type). Cheap, so callers run it before showing a prompt.
    def preflight(type, store: LocalStore.new, home: ENV.fetch('HOME', Dir.home))
      return "no TOTP seed is enrolled on this machine. Enroll from a real terminal: #{ENROLL_HINT}" unless store.enrolled?

      HostHealth.refusal(type, HostHealth.check(store: store, home: home))
    end

    # Builds the canonical body for `attrs` (type, repo, sha, profile and the
    # per-type payload), prompts for the code and spends it. The body binds the
    # approval to the exact context the human just confirmed.
    def approve(attrs, stdin:, stdout:, store: LocalStore.new, now: nil, client: :default)
      raise LocalStore::NotEnrolled unless store.enrolled?

      client = Client.for(store) if client == :default
      started = now || Time.now
      body = Canonical.build(attrs.merge('machine_id' => store.machine_id, 'request_id' => SecureRandom.uuid,
                                         'created_at' => started.utc.iso8601,
                                         'expires_at' => (started.utc + LIFETIME).iso8601))
      code = read_code(stdin, stdout)
      online = client && online(store, client, body, code, stdout)
      return online if online

      offline(store, attrs, body, code, now)
    rescue LocalStore::NotEnrolled
      Result.new(error: "no TOTP seed is enrolled on this machine. Enroll from a real terminal: #{ENROLL_HINT}")
    end

    # The console's answer, or nil when it cannot be reached. Queued offline
    # approvals are synced first, so the console's fence sees them in order.
    def online(store, client, body, code, stdout)
      report = Sync.run(store: store, client: client)
      return nil if report.unreachable

      stdout.puts "[approval_console] synced #{report.synced} offline approval(s)" if report.synced.positive?
      proof = client.terminal_approve(body, code)['proof']
      problem = Remote.check(proof, body, Remote.expected_from_body(body), store, kind: KIND)
      return Result.new(error: "the console receipt did not verify: #{problem}") if problem

      store.observe_step(proof['totp_step'])
      Result.new(proof: proof)
    rescue Client::Unreachable
      stdout.puts '[approval_console] console unreachable; checking the code locally and queueing it for sync'
      nil
    rescue Client::Refused => e
      Result.new(error: CONSOLE_MESSAGES.fetch(e.code, e.message))
    end

    # The phase 3 local fence. The queued entry keeps the body and the spent
    # code so `sync` can submit them later; both live only in the protected store.
    def offline(store, attrs, body, code, now)
      # The clock is read after the blocking prompt, so a code typed late is
      # still checked against the step it was generated for.
      entry = { 'type' => attrs['type'], 'sha' => attrs['sha'], 'body_sha256' => Canonical.body_sha256(body),
                'body' => body, 'code' => code }
      outcome = store.consume(code, now: now || Time.now, entry: entry)
      return Result.new(error: message(outcome)) unless outcome.ok?

      Result.new(proof: { 'kind' => KIND, 'body' => body, 'totp_step' => outcome.step, 'receipt' => nil })
    end

    def read_code(stdin, stdout)
      stdout.print 'TOTP code from your authenticator app (input hidden): '
      code = stdin.respond_to?(:noecho) ? stdin.noecho(&:gets) : stdin.gets
      stdout.puts
      code.to_s.strip
    end

    def message(outcome)
      return "locked until #{outcome.locked_until.iso8601} after repeated failures" if outcome.reason == :locked

      MESSAGES.fetch(outcome.reason, 'the code was rejected')
    end
  end
end
