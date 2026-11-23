#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require 'digest'
require 'fileutils'
require 'open3'
require 'rbconfig'
require_relative 'pulse_store'
require_relative 'pulse_precheck'
require_relative 'cf_state'
require_relative 'pulse_grants'

# C3: an authorization and reservation service. It never touches a worker: it
# returns a typed command, the coordinator runs it through the one `pulse-exec`
# adapter (skills/pulse/SKILL.md), and acknowledges the result. State per
# idempotency key lives in pulse_actions.jsonl: authorized, executing, then
# acked or failed (denied is terminal for that attempt).
class PulseAct
  TTL_S = 300
  MAX_TEXT = 500
  MAX_ATTEMPTS = 2
  # Action type to exactly one host tool call (v1 allowlist). reorder_phase is
  # a proposal for now: its target is a workflow phase title, and the C6 record
  # has no phase signal to check that title or its freshness against.
  TOOLS = { 'nudge_worker' => 'SendMessage', 'stop_runaway' => 'TaskStop' }.freeze
  # Decision 18 hard limits, matched against the text a nudge would send.
  HARD_LIMIT = /CF_ALLOW_\w+|\bgit\s+(?:push\s+)?tag\b|--no-verify|\bterraform\s+apply\b|approval_console|\bprod(?:uction)?\b/i

  # Every state transition is serialized (see `exclusive`).
  module Serialized
    %i[authorize begin ack reconcile notify delivered].each do |name|
      define_method(name) { |*args, **opts| exclusive { super(*args, **opts) } }
    end
  end
  prepend Serialized

  def initialize(session, project: Dir.pwd, now: Time.now, inbox: nil, wall_clock: false)
    @session = session
    @wall_clock = wall_clock
    @project = project
    @now = now
    @dir = Pulse.session_dir(session)
    @store = PulseStore.new(session)
    @inbox = inbox || method(:inbox_announce)
  end

  def self.key(finding, action, target) = Pulse.sha([ finding, action, target ].join("\u0000"))

  # Checks in order (C3). Returns {state: authorized|denied|acked, ...}; a
  # denial queues a proposal. An acked key is never run twice.
  def authorize(finding:, action:, target:, observed_at:, text: nil)
    key = self.class.key(finding, action, target)
    prior = latest(key)
    return { 'state' => 'acked', 'key' => key, 'idempotent' => true } if prior&.dig('state') == 'acked'
    return { 'state' => 'denied', 'key' => key, 'reason' => 'in-flight' } if prior&.dig('state') == 'executing'
    request = { 'finding' => finding, 'action' => action, 'target' => target, 'observed_at' => observed_at, 'text' => text.to_s }
    reason = denial(request) || (attempts_exhausted?(key) && 'attempts-exhausted')
    return deny(key, request, reason) if reason

    # The cached authorization is reused only when it passes every check again.
    return prior.slice('state', 'command', 'key', 'expires_at') if prior&.dig('state') == 'authorized' && fresh_auth?(prior) &&
                                                                    prior.values_at('text', 'observed_at') == request.values_at('text', 'observed_at')

    row = request.merge('key' => key, 'state' => 'authorized', 'command' => command(action, target, text),
                        'expires_at' => (@now + TTL_S).utc.iso8601)
    record(row)
    row.slice('state', 'command', 'key', 'expires_at')
  end

  # Immediately before the tool call: expiry and every authorization check
  # again, so a target that moved on, or a scope that drifted, is refused.
  def begin(key)
    row = latest(key)
    return { 'state' => 'denied', 'key' => key, 'reason' => 'unknown-key' } unless row
    return { 'state' => 'denied', 'key' => key, 'reason' => "not-authorized:#{row['state']}" } unless row['state'] == 'authorized'

    reason = fresh_auth?(row) ? denial(row) : 'expired'
    return record(row.merge('state' => 'denied', 'reason' => reason)).slice('state', 'key', 'reason') if reason

    record(row.merge('state' => 'executing', 'began_at' => iso))
    { 'state' => 'executing', 'key' => key }
  end

  def ack(key, result:, detail: nil)
    row = latest(key)
    return { 'state' => 'denied', 'key' => key, 'reason' => 'not-executing' } unless row && row['state'] == 'executing'

    state = result == 'ok' ? 'acked' : 'failed'
    record(row.merge('state' => state, 'detail' => detail.to_s[0, 500], 'acked_at' => iso))
    { 'state' => state, 'key' => key }
  end

  # An `executing` key means the coordinator died between begin and ack. Read
  # the target: a task already finished, or a nudge visible in the transcript,
  # is acked; anything else fails and needs a new authorization.
  def reconcile(key, transcript: nil)
    row = latest(key)
    return { 'state' => 'denied', 'key' => key, 'reason' => 'not-executing' } unless row && row['state'] == 'executing'

    done = case row['action']
    when 'stop_runaway' then finished?(row['target'])
    when 'nudge_worker' then sent_in?(transcript, row)
    else false
    end
    state = done ? 'acked' : 'failed'
    record(row.merge('state' => state, 'detail' => "reconciled: #{done ? 'effect visible' : 'effect not visible'}", 'acked_at' => iso))
    { 'state' => state, 'key' => key }
  end

  # The authorize call carries the same text, so only a SendMessage line to
  # this target, not a pulse_act line, counts as the nudge having been sent.
  def sent_in?(transcript, row)
    return false unless transcript && File.file?(transcript) && !row['text'].to_s.empty?

    File.foreach(transcript).any? do |line|
      line.include?('SendMessage') && line.include?(row['text']) && line.include?(row['target']) && !line.include?('pulse_act')
    end
  end

  def proposals = read(File.join(@dir, 'pulse_proposals.jsonl'))

  # P0 delivery (C3): consumes pulse_notifications.jsonl through the cf:inbox
  # store (`inbox_store.rb announce`). Announce only files the item; the
  # returned doorbell must reach the human, so a filed row carries the doorbell
  # for the coordinator to surface and is `delivered` only after `delivered`
  # is called. A filed row is returned again each pass until then; a failed
  # attempt is retried once. There is no phone push path outside the approval
  # console's own request flow, so the channel is the inbox only.
  def notify(only: nil)
    path = File.join(@dir, 'pulse_notifications.jsonl')
    newest = read(path).group_by { |row| row['finding'] }.transform_values(&:last)
    newest.filter_map do |id, row|
      next if only && id != only
      next if row['state'] == 'delivered' || (row['state'] == 'failed' && row['attempts'].to_i >= MAX_ATTEMPTS)
      next row if row['state'] == 'filed'

      finding = @store.findings[id]
      next unless finding

      outcome = @inbox.call("pulse P0: #{finding['claim']}", "#{finding['evidence']}\n\nfinding #{id}, session #{@session}", id)
      attempts = row['attempts'].to_i + 1
      done = { 'finding' => id, 'state' => outcome[:ok] ? 'filed' : 'failed', 'channel' => 'inbox', 'attempts' => attempts,
               'doorbell' => outcome[:doorbell], 'error' => outcome[:error], 'at' => iso }.compact
      File.write(path, "#{JSON.generate(done)}\n", mode: 'a')
      done
    end
  end

  # The coordinator surfaced the doorbell of a filed P0.
  def delivered(id)
    path = File.join(@dir, 'pulse_notifications.jsonl')
    row = read(path).reverse.find { |r| r['finding'] == id }
    return { 'state' => 'denied', 'reason' => 'not-filed' } unless row && row['state'] == 'filed'

    File.write(path, "#{JSON.generate(row.merge('state' => 'delivered', 'at' => iso))}\n", mode: 'a')
    { 'state' => 'delivered', 'finding' => id }
  end

  private

  def iso = @now.utc.iso8601

  def denial(req)
    return 'action-not-allowed' unless TOOLS.key?(req['action'])
    return 'local-only' if merge_mode == 'local-only'

    finding = @store.findings[req['finding']]
    return 'unknown-finding' unless finding
    return 'not-authorizable' unless finding['authorizable'] && finding['action_class'] == 'auto'
    return 'finding-closed' if %w[rejected parked].include?(@store.disposition_of(finding['fingerprint']) || finding['disposition'])
    return 'out-of-scope' unless @store.serves_current?(finding)
    return not_allowed_reason(req['action']) unless protocol.include?(req['action']) || grants.allows?(req['action'])
    return 'hard-limit' if HARD_LIMIT.match?(req['text'].to_s) || HARD_LIMIT.match?(req['target'].to_s)
    return 'no-text' if req['action'] == 'nudge_worker' && req['text'].to_s.strip.empty?
    current = state_at(req['target'], req['action'])
    seen = parse(req['observed_at'])
    return 'stale-target' unless current && seen && current == seen

    nil
  end

  def deny(key, request, reason)
    record(request.merge('key' => key, 'state' => 'denied', 'reason' => reason))
    File.write(File.join(@dir, 'pulse_proposals.jsonl'), "#{JSON.generate(request.merge('reason' => reason, 'at' => iso))}\n", mode: 'a')
    { 'state' => 'denied', 'key' => key, 'reason' => reason }
  end

  def command(action, target, text)
    args = case action
    when 'nudge_worker' then { 'target_id' => target, 'text' => text.to_s[0, MAX_TEXT] }
    else { 'target_id' => target }
    end
    { 'tool' => TOOLS.fetch(action), 'args' => args }
  end

  def merge_mode
    CfState.new(host: 'claude', project: @project, session_id: @session).read['mode']
  rescue StandardError
    'local-only' # unreadable state fails closed
  end

  # The plan protocol failed, and so did every grant. A grant that covers the
  # action but was refused (expired, tampered, wrong project, unverified) is
  # named; plain absence stays `not-in-protocol`.
  def not_allowed_reason(action)
    why = grants.refusal_for(action)
    why ? "grant-#{why}" : 'not-in-protocol'
  end

  # The CLI passes wall_clock: its `--now` is caller-set, and a caller must not
  # be able to back-date a grant's expiry.
  # Phone-approved console receipts only (pulse_grants.rb); re-verified on
  # every call, so authorize and begin both see an expiry the moment it lands.
  def grants = PulseGrants.new(project: @project, now: @wall_clock ? Time.now : @now)

  # The run's plan.md lists the acts it authorizes: `pulse-allow: nudge_worker, stop_runaway`.
  # A verified, unexpired grant (`grants`) widens this list.
  def protocol
    scope = File.join(@dir, 'pulse_scope.json')
    sources = File.file?(scope) ? Array(JSON.parse(File.read(scope))['sources']) : []
    plan = sources.find { |src| src['role'] == 'run_plan' }
    text = plan && (File.read(File.expand_path(plan['source_path'])) rescue nil) # rubocop:disable Style/RescueModifier
    text.to_s.scan(/^pulse-allow:\s*(.+)$/).flatten.flat_map { |line| line.split(/[,\s]+/) }
  rescue JSON::ParserError
    []
  end

  # The current state timestamp of a child, command or pass (the C6 record).
  # A nudge targets a child of this session only; a stop may also
  # name a budgeted command. The pulse pass itself is never a target.
  def state_at(target, action)
    check = PulsePrecheck.new(@session, now: @now)
    child = check.children[target]
    return child['changed_at'] if child
    return nil if target.to_s.empty?

    budget = action == 'nudge_worker' ? nil : check.budgets.find { |b| b['command'] == target }
    parse(budget['started_at']) if budget
  end

  def finished?(target)
    check = PulsePrecheck.new(@session, now: @now)
    return true if check.children[target]&.dig('done')

    budget = check.budgets.find { |b| b['command'] == target }
    !!budget&.dig('finished_at')
  end

  def attempts_exhausted?(key) = read(actions_path).count { |row| row['key'] == key && row['state'] == 'failed' } >= MAX_ATTEMPTS

  def parse(text)
    Time.parse(text.to_s) unless text.to_s.empty?
  rescue ArgumentError
    nil
  end

  def fresh_auth?(row) = row['expires_at'] && @now < Time.parse(row['expires_at'])

  def latest(key) = read(actions_path).reverse.find { |row| row['key'] == key }

  def actions_path = File.join(@dir, 'pulse_actions.jsonl')

  def record(row)
    File.write(actions_path, "#{JSON.generate(row.merge('at' => iso))}\n", mode: 'a')
    row
  end

  # Every state transition reads and writes under one lock, so two coordinators
  # cannot both move the same key to `executing`.
  def exclusive
    FileUtils.mkdir_p(@dir)
    File.open(File.join(@dir, '.pulse_act.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      yield
    end
  end

  def read(path)
    return [] unless File.file?(path)

    File.readlines(path).filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
  end

  def inbox_announce(subject, body, ref)
    file = File.join(@dir, ".notify-#{Process.pid}.md")
    File.write(file, body)
    out, status = Open3.capture2(RbConfig.ruby, File.join(__dir__, 'inbox_store.rb'), 'announce', '--from', 'all', '--subject', subject,
                                 '--body-file', file, '--refs', ref, chdir: @project)
    result = JSON.parse(out.lines.last.to_s) rescue {} # rubocop:disable Style/RescueModifier
    status.success? && !result['error'] ? { ok: true, doorbell: result['doorbell'] } : { ok: false, error: result['error'] || 'inbox failed' }
  ensure
    FileUtils.rm_f(file)
  end
end

# CLI: authorize|begin|ack|reconcile|notify|delivered|proposals --session ID. JSON out.
class PulseActCLI
  def self.run(argv, out: $stdout)
    cmd, *rest = argv
    opts = rest.each_slice(2).to_h { |flag, value| [ flag.delete_prefix('--'), value ] }
    act = PulseAct.new(opts.fetch('session'), project: opts['project'] || Dir.pwd, now: opts['now'] ? Time.parse(opts['now']) : Time.now, wall_clock: true)
    out.puts(JSON.generate(dispatch(act, cmd, opts)))
    0
  rescue StandardError => e
    out.puts(JSON.generate('error' => e.message))
    2
  end

  def self.dispatch(act, cmd, opts)
    case cmd
    when 'authorize'
      act.authorize(finding: opts.fetch('finding'), action: opts.fetch('action'), target: opts.fetch('target'),
                    observed_at: opts.fetch('observed-at'), text: opts['text'])
    when 'begin' then act.begin(opts.fetch('key'))
    when 'ack' then act.ack(opts.fetch('key'), result: opts.fetch('result'), detail: opts['detail'])
    when 'reconcile' then act.reconcile(opts.fetch('key'), transcript: opts['transcript'])
    when 'notify' then act.notify(only: opts['finding'])
    when 'delivered' then act.delivered(opts.fetch('finding'))
    when 'proposals' then { 'queued' => act.proposals.size, 'proposals' => act.proposals }
    else raise ArgumentError, 'usage: pulse_act.rb authorize|begin|ack|reconcile|notify|delivered|proposals --session ID'
    end
  end
end

exit(PulseActCLI.run(ARGV)) if __FILE__ == $PROGRAM_NAME
