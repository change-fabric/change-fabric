#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require 'digest'
require 'fileutils'
require 'securerandom'
require 'yaml'

# Pulse is the background acceleration and integrity review. Landing code does
# not turn it on: ACTIVATED stays false until the phase that ships the watcher
# events and the action executor (C8).
module Pulse
  ACTIVATED = false
  READY_PARTS = %w[pulse_store pulse_precheck pulse_stamp pulse_scope pulse_integrity pulse_watch pulse_act
                   skills/pulse/SKILL.md].freeze
  DEFAULTS = { 'max_passes_per_day' => 24, 'max_tokens_per_pass' => 60_000, 'max_turns_per_pass' => 12,
               'max_critic_passes_per_day' => 6, 'max_seconds_per_pass' => 300 }.freeze

  def self.root = File.join(Dir.home, '.claude', 'cf')

  def self.session_dir(session) = File.join(root, 'sessions', session.to_s)

  # Config comes from <cf dir>/pulse.yml, a `pulse:` block, over DEFAULTS.
  def self.config
    file = File.join(root, 'pulse.yml')
    given = File.file?(file) ? (YAML.safe_load_file(file) || {})['pulse'] : nil
    DEFAULTS.merge(given.is_a?(Hash) ? given.slice(*DEFAULTS.keys).select { |_, v| v.is_a?(Integer) } : {})
  rescue StandardError
    DEFAULTS
  end

  def self.sha(text) = Digest::SHA256.hexdigest(text.to_s)
end

# Append-only ledger, cursor, fingerprints and disposition memory for one
# session, plus the per-project daily pass budget (C4).
class PulseStore
  KINDS = %w[accel integrity stall scope].freeze
  SEVERITIES = %w[P0 P1 P2].freeze
  ACTION_CLASSES = %w[report auto ask park].freeze
  DISPOSITIONS = %w[open applied queued rejected parked].freeze

  def initialize(session)
    @dir = Pulse.session_dir(session)
  end

  def ledger_path = File.join(@dir, 'pulse.jsonl')

  def self.fingerprint(kind, subject, anchor)
    norm = ->(text) { text.to_s.downcase.gsub(/\s+/, ' ').strip }
    Pulse.sha([ kind, norm.call(subject), norm.call(anchor) ].join("\u0000"))
  end

  # Rows are append-only; a disposition change is a new row, last row wins.
  def rows
    return [] unless File.file?(ledger_path)

    File.readlines(ledger_path).filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
  end

  def findings = rows.reject { |row| row['event'] == 'disposition' }.to_h { |row| [ row['id'], row ] }

  def disposition_of(fingerprint)
    rows.select { |row| row['fingerprint'] == fingerprint }.map { |row| row['disposition'] }.compact.last
  end

  # Returns {status: stored|duplicate|suppressed|rejected, ...}. No evidence,
  # no finding. A rejected idea never resurfaces. A `serves` that fails C7
  # validation parks the finding instead of dropping it.
  def append(input)
    finding = input.transform_keys(&:to_s).except('origin')
    reason = invalid_reason(finding)
    return { 'status' => 'rejected', 'reason' => reason } if reason

    fp = finding['fingerprint'] = self.class.fingerprint(finding['kind'], finding['subject'] || finding['claim'],
                                                          finding['anchor'])
    locked do
      prior = disposition_of(fp)
      next { 'status' => 'suppressed', 'fingerprint' => fp } if prior == 'rejected'
      next { 'status' => 'duplicate', 'fingerprint' => fp } if prior

      store(finding)
    end
  end

  # Deterministic system findings (for example pulse-dispatch-down) have no
  # run scope to serve; only code inside the toolkit calls this.
  def append_system(input)
    finding = input.transform_keys(&:to_s).merge('origin' => 'system')
    reason = invalid_reason(finding)
    return { 'status' => 'rejected', 'reason' => reason } if reason

    fp = finding['fingerprint'] = self.class.fingerprint(finding['kind'], finding['claim'], finding['anchor'])
    locked { disposition_of(fp) ? { 'status' => 'duplicate', 'fingerprint' => fp } : store(finding) }
  end

  def disposition(fingerprint, value)
    return { 'status' => 'rejected', 'reason' => 'bad disposition' } unless DISPOSITIONS.include?(value)

    write_row('event' => 'disposition', 'fingerprint' => fingerprint, 'disposition' => value, 'at' => now)
    { 'status' => 'recorded' }
  end

  def cursor = (JSON.parse(File.read(cursor_path)) if File.file?(cursor_path)) || {}

  def advance_cursor(values)
    locked { atomic_write(cursor_path, JSON.generate(cursor.merge(values.transform_keys(&:to_s)))) }
  end

  # C4: atomic, per-project, per-day reservation. Nothing is refunded.
  def self.reserve(project, critic: false, now: Time.now)
    cfg = Pulse.config
    path = File.join(Pulse.root, 'pulse', Pulse.sha(File.realpath(project)), 'budget.json')
    FileUtils.mkdir_p(File.dirname(path))
    File.open(File.join(File.dirname(path), '.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      take(path, cfg, critic, now.localtime.strftime('%Y-%m-%d'))
    end
  end

  def self.take(path, cfg, critic, day)
    used = begin
      File.file?(path) ? JSON.parse(File.read(path)) : {}
    rescue JSON::ParserError
      {}
    end
    used = { 'passes' => 0, 'critic' => 0 } unless used['day'] == day
    over = used['passes'].to_i >= cfg['max_passes_per_day'] || (critic && used['critic'].to_i >= cfg['max_critic_passes_per_day'])
    return { 'reserved' => false, 'exhausted' => true, 'mode' => 'report-only', 'passes' => used['passes'] } if over

    used = { 'day' => day, 'passes' => used['passes'].to_i + 1, 'critic' => used['critic'].to_i + (critic ? 1 : 0) }
    File.write("#{path}.tmp", JSON.generate(used))
    File.rename("#{path}.tmp", path)
    { 'reserved' => true, 'passes' => used['passes'], 'max_seconds_per_pass' => cfg['max_seconds_per_pass'] }
  end

  private_class_method :take

  private

  def invalid_reason(finding)
    return 'unknown kind' unless KINDS.include?(finding['kind'])
    return 'unknown severity' unless SEVERITIES.include?(finding['severity'])
    return 'no evidence' if finding['evidence'].to_s.strip.empty?
    return 'no claim' if finding['claim'].to_s.strip.empty?
    return 'no anchor' if finding['anchor'].to_s.strip.empty?

    nil
  end

  def store(finding)
    finding['id'] ||= SecureRandom.hex(6)
    finding['at'] = now
    finding['action_class'] = 'report' unless ACTION_CLASSES.include?(finding['action_class'])
    verdict = finding['origin'] == 'system' ? :system : serves_verdict(finding['serves'])
    finding['authorizable'] = verdict == :ok
    finding['action_class'] = 'report' if verdict == :stale
    unless %i[ok stale system].include?(verdict)
      finding['action_class'] = 'park'
      finding['park_reason'] = "serves: #{verdict}"
    end
    finding['disposition'] = finding['action_class'] == 'park' ? 'parked' : 'open'
    write_row(finding)
    { 'status' => 'stored', 'id' => finding['id'], 'fingerprint' => finding['fingerprint'],
      'action_class' => finding['action_class'], 'authorizable' => finding['authorizable'] }
  end

  # C7: source and revision must match pulse_scope.json, and the quote must be
  # an exact substring of the source. A revision older than the current one is
  # stored but never authorizable.
  def serves_verdict(serves)
    return :missing unless serves.is_a?(Hash) && %w[source_path revision quote relevance].all? { |k| !serves[k].to_s.strip.empty? }

    entry = scope_sources.find { |src| src['source_path'] == serves['source_path'] }
    return :unscoped_source unless entry

    text = File.read(File.expand_path(entry['source_path'])) rescue nil # rubocop:disable Style/RescueModifier
    return :unreadable_source unless text
    return :quote_not_in_source unless serves['quote'].is_a?(String) && text.include?(serves['quote'])

    serves['revision'] == entry['revision'] && Pulse.sha(text) == entry['revision'] ? :ok : :stale
  end

  def scope_sources
    file = File.join(@dir, 'pulse_scope.json')
    File.file?(file) ? Array(JSON.parse(File.read(file))['sources']) : []
  rescue JSON::ParserError
    []
  end

  # One lock covers the dedup check and the write, and the cursor update.
  # Reentrant only for the owning thread; other threads wait on the file lock.
  def locked
    FileUtils.mkdir_p(@dir)
    return yield if @owner == Thread.current

    File.open(File.join(@dir, '.pulse.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      @owner = Thread.current
      yield
    ensure
      @owner = nil
    end
  end

  def write_row(row)
    FileUtils.mkdir_p(@dir)
    File.open(ledger_path, 'a') { |file| file.puts(JSON.generate(row)) }
  end

  def cursor_path = File.join(@dir, 'pulse_cursor.json')

  def atomic_write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    tmp = "#{path}.#{Process.pid}.tmp"
    File.write(tmp, text)
    File.rename(tmp, path)
  end

  def now = Time.now.utc.iso8601
end

# CLI: append (JSON on stdin), disposition, cursor, reserve. Prints JSON.
class PulseStoreCLI
  def self.run(argv, out: $stdout, input: $stdin)
    cmd, *rest = argv
    opts = rest.each_slice(2).to_h { |flag, value| [ flag.delete_prefix('--'), value ] }
    store = PulseStore.new(opts['session']) if opts['session']
    out.puts(JSON.generate(dispatch(cmd, opts, store, input)))
    0
  rescue StandardError => e
    out.puts(JSON.generate('error' => e.message))
    2
  end

  def self.dispatch(cmd, opts, store, input)
    case cmd
    when 'append' then store.append(JSON.parse(input.read))
    when 'disposition' then store.disposition(opts.fetch('fingerprint'), opts.fetch('value'))
    when 'cursor' then store.cursor
    when 'advance' then store.advance_cursor(JSON.parse(input.read)) || store.cursor
    when 'reserve' then PulseStore.reserve(opts.fetch('project'), critic: opts['critic'] == 'true')
    else raise ArgumentError, 'usage: pulse_store.rb append|disposition|cursor|reserve --session ID'
    end
  end
end

exit(PulseStoreCLI.run(ARGV)) if __FILE__ == $PROGRAM_NAME
