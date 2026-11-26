# frozen_string_literal: true

require 'time'
require_relative 'journal'
require_relative 'liveness'
require_relative 'inbox_items'

module Triage
  # Reconciles unfinished dispatches at the top of every tick (C2), using C1.
  #
  #   handshake, alive     keep waiting
  #   handshake, dead      terminal `dead`; the child's lease is released (only a
  #                        child proven dead releases it)
  #   handshake, unknown   one escalation; the lease stays held
  #   no handshake, young  wait (the child has 5 minutes to register)
  #   no handshake, old    the session is looked up in a complete listing: listed
  #                        means keep waiting, absent means the dispatch is dead
  #                        (the cap reservation stays consumed, one escalation is
  #                        queued), a failed or partial listing is unknown
  #
  # A launcher death never frees a lease by itself. With `apply: false` it only
  # reports what it would do.
  class Reconcile
    HANDSHAKE_WINDOW = 300

    Change = Struct.new(:action_id, :unit, :decision, :reason, keyword_init: true) do
      def to_h = { 'action_id' => action_id, 'unit' => unit, 'decision' => decision, 'reason' => reason }
    end

    def initialize(journal:, liveness:, inbox:, now:, unlease:, agents: Liveness.method(:agents), apply: true)
      @journal = journal
      @liveness = liveness
      @inbox = inbox
      @now = now
      @unlease = unlease
      @agents = agents
      @apply = apply
    end

    def call
      @journal.unfinished.filter_map { |dispatch| reconcile(dispatch) }
    end

    private

    def reconcile(dispatch)
      dispatch.handshake ? with_handshake(dispatch) : without_handshake(dispatch)
    end

    def with_handshake(dispatch)
      verdict = @liveness.verdict(owner(dispatch))
      return change(dispatch, 'alive', verdict.reason) if verdict.alive?
      return mark_dead(dispatch, verdict.reason, escalate: false) if verdict.dead?

      escalate_unknown(dispatch, verdict.reason)
    end

    def without_handshake(dispatch)
      return change(dispatch, 'waiting', 'inside the handshake window') if @now - dispatch.at < HANDSHAKE_WINDOW

      listing = @agents.call
      return escalate_unknown(dispatch, 'no handshake and the agent listing failed') unless listing.ok && listing.complete
      return change(dispatch, 'alive', 'session listed') if listing.sessions.include?(dispatch.session)

      mark_dead(dispatch, 'no handshake within 5 minutes and no process for the session', escalate: true)
    end

    def owner(dispatch)
      shake = dispatch.handshake
      { 'host' => shake['host'], 'boot_id' => shake['boot_id'], 'pid' => shake['pid'], 'pid_start' => shake['pid_start'],
        'session_id' => shake['session_id'] || dispatch.session, 'fence' => shake['fence'] }
    end

    def mark_dead(dispatch, reason, escalate:)
      if @apply
        @journal.append('type' => 'dead', 'action_id' => dispatch.id, 'reason' => reason)
        @unlease.call(dispatch.row)
        queue(dispatch, 'dispatch_dead', "dispatch #{dispatch.id} died: #{reason}") if escalate
      end
      change(dispatch, 'dead', reason)
    rescue Journal::Fenced
      change(dispatch, 'fenced', 'already finished')
    end

    def escalate_unknown(dispatch, reason)
      if @apply && !dispatch.escalated
        @journal.append('type' => 'escalated', 'action_id' => dispatch.id, 'reason' => reason)
        queue(dispatch, 'owner_unknown', "dispatch #{dispatch.id} owner is unknown: #{reason}")
      end
      change(dispatch, 'unknown', reason)
    end

    def queue(dispatch, finding, title)
      InboxItems.upsert(@inbox, kind: 'triage_escalation', unit: dispatch.unit.to_s, finding: "#{finding}:#{dispatch.id}", title: title,
                                body: "session #{dispatch.session}; the cap reservation stays consumed", data: { 'action_id' => dispatch.id })
    end

    def change(dispatch, decision, reason) = Change.new(action_id: dispatch.id, unit: dispatch.unit, decision: decision, reason: reason)
  end
end
