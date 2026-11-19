# frozen_string_literal: true

require 'io/console'
require 'securerandom'
require 'time'
require_relative 'canonical'
require_relative 'host_health'
require_relative 'local_store'

module ApprovalConsole
  # The terminal second factor used by change_approve.rb and change_override.rb
  # after their TTY check and typed confirmation: read a TOTP code with echo
  # off, spend it through LocalStore (the fenced, locked write), and return the
  # proof to store beside the approval. The proof has `receipt: null`; a later
  # phase attaches a console receipt on sync.
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
    def approve(attrs, stdin:, stdout:, store: LocalStore.new, now: Time.now)
      raise LocalStore::NotEnrolled unless store.enrolled?

      body = Canonical.build(attrs.merge('machine_id' => store.machine_id, 'request_id' => SecureRandom.uuid,
                                         'created_at' => now.utc.iso8601,
                                         'expires_at' => (now.utc + LIFETIME).iso8601))
      code = read_code(stdin, stdout)
      outcome = store.consume(code, now: now, entry: { 'type' => attrs['type'], 'sha' => attrs['sha'],
                                                      'body_sha256' => Canonical.body_sha256(body) })
      return Result.new(error: message(outcome)) unless outcome.ok?

      Result.new(proof: { 'kind' => KIND, 'body' => body, 'totp_step' => outcome.step, 'receipt' => nil })
    rescue LocalStore::NotEnrolled
      Result.new(error: "no TOTP seed is enrolled on this machine. Enroll from a real terminal: #{ENROLL_HINT}")
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
