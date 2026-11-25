#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'digest'
require 'stringio'
require 'time'
require 'yaml'

# Parse a hook event from stdin. Hooks fire on every event, so a bad or
# unexpected payload must fail silent (empty event), never crash the session.
module HookEvent
  def self.read(io = $stdin)
    raw = io.read.to_s
    return {} if raw.empty?

    parsed = JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  # Opt-in payload shape capture (CF_HOOK_DEBUG_KEYS=1): one line per event
  # naming the hook, the event, the sorted top-level keys and whether agent_id
  # is present. Key names only, never values, so nothing sensitive is logged.
  def self.debug_keys(event, hook_name)
    return unless ENV['CF_HOOK_DEBUG_KEYS'] == '1' && event.is_a?(Hash)

    path = File.join(Dir.home, '.claude', 'cf', 'logs', 'hook-keys.log')
    FileUtils.mkdir_p(File.dirname(path))
    keys = event.keys.map(&:to_s).sort.join(',')
    agent = !event['agent_id'].to_s.empty?
    File.write(path, "#{hook_name}\t#{event['hook_event_name']}\t#{keys}\tagent_id present: #{agent}\n", mode: 'a')
  rescue StandardError
    nil
  end
  LEVELS = %w[strict standard lean].freeze
  OUTCOMES = %w[deny advise inject abort].freeze
  # Per type, the only fields an event may carry beyond the common four. Anything
  # else is dropped, so a caller can never put a prompt, path, command or diff
  # into the log by passing it.
  COMMON_FIELDS = %i[ts type session level doctrine_version].freeze
  TYPE_FIELDS = {
    'session_start' => %i[host model_tier parent_session],
    'session_end' => %i[turns],
    'evaluation' => %i[rule_id rule_version hook tool],
    'intervention' => %i[rule_id rule_version outcome],
    'rubric_surfaced' => %i[rule_id rule_version]
  }.freeze
  SAFE_VALUE = %r{\A[A-Za-z0-9_./:@-]{1,96}\z}

  def self.state_dir(home = Dir.home) = File.join(home, '.claude', 'cf', 'state')
  # CF_GUARD_EVENTS_PATH redirects the log for the real HOME (tests set it so no
  # hook run writes the real one); a caller-supplied other home still wins.
  def self.events_path(home = nil)
    override = ENV.fetch('CF_GUARD_EVENTS_PATH', '')
    return override if !override.empty? && (home.nil? || home == Dir.home)

    File.join(state_dir(home || Dir.home), 'guard_events.jsonl')
  end
  def self.session_dir(session, home = Dir.home) = File.join(home, '.claude', 'cf', 'sessions', session.to_s)

  # Append one content-free event. Locks the file, never raises into the hook.
  # Returns the written hash, or nil when the type is unknown or the write failed.
  def self.record(type, session: nil, home: nil, **fields)
    type = type.to_s
    allowed = TYPE_FIELDS[type]
    return nil unless allowed

    entry = { ts: Time.now.utc.iso8601, type: type, session: safe(session) || '',
              level: level(fields[:level]), doctrine_version: fields[:doctrine_version] || doctrine_version(session, home: home) }
    allowed.each { |key| entry[key] = safe(fields[key]) unless fields[key].nil? }
    return nil if entry[:outcome] && !OUTCOMES.include?(entry[:outcome])

    append(entry.compact, home)
  rescue StandardError
    nil
  end

  def self.append(entry, home)
    path = events_path(home)
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, 'a') do |file|
      file.flock(File::LOCK_EX)
      file.write("#{JSON.generate(entry)}\n")
    end
    entry
  end

  def self.safe(value)
    return value if value.is_a?(Integer)

    text = value.to_s
    text.match?(SAFE_VALUE) ? text : nil
  end

  def self.level(given = nil)
    candidate = (given || ENV['CF_DOCTRINE_LEVEL']).to_s
    LEVELS.include?(candidate) ? candidate : 'unset'
  end

  def self.doctrine_version(session, home: Dir.home)
    path = File.join(session_dir(session, home), 'doctrine-version')
    session.to_s.empty? || !File.file?(path) ? 'none' : File.read(path).strip
  rescue StandardError
    'none'
  end

  def self.sha8(text) = Digest::SHA256.hexdigest(text.to_s)[0, 8]

  # Rule IDs are declared in config/rule_ids.yml: beside scripts/ in the repo,
  # beside the installed bin/ in a runtime copy.
  def self.rule_ids
    @rule_ids ||= YAML.safe_load_file(File.expand_path('../config/rule_ids.yml', __dir__)).fetch('rules')
  rescue StandardError
    {}
  end

  def self.rule_for(hook)
    rule_ids.find { |_id, rule| rule['hook'] == hook }
  end

  def self.rule_version(hook)
    source = File.join(__dir__, "#{hook}.rb")
    sha8(File.file?(source) ? File.read(source) : hook)
  end

  # First caller per session and name wins; a blank session always wins.
  def self.once?(session, name, home: Dir.home)
    return true if session.to_s.empty?

    dir = session_dir(session, home)
    FileUtils.mkdir_p(dir)
    File.open(File.join(dir, name), File::WRONLY | File::CREAT | File::EXCL) { nil }
    true
  rescue Errno::EEXIST
    false
  rescue StandardError
    true
  end

  def self.model_tier(model)
    name = model.to_s.downcase
    %w[haiku sonnet opus fable].find { |tier| name.include?(tier) } || 'unknown'
  end

  # Records a SessionStart or SubagentStart once per session.
  def self.session_started(event, host: 'claude', home: Dir.home)
    session = event['session_id']
    return unless once?(session, 'guard-events-started', home: home)

    parent = event['parent_session_id']
    version = doctrine_version(session, home: home)
    version = doctrine_version(parent, home: home) if version == 'none' && parent
    record('session_start', session: session, home: home, host: host, model_tier: model_tier(event['model']),
                            parent_session: parent, doctrine_version: version)
  end

  # Runs a hook, passes its output through untouched, and records an evaluation
  # (always) and an intervention (when the output changed the outcome). Never
  # raises, never alters what the hook printed.
  def self.instrument(hook, event, home: Dir.home)
    original = $stdout
    captured = StringIO.new
    $stdout = captured
    begin
      yield
    ensure
      $stdout = original
      original.print(captured.string)
      observe(hook, event, captured.string, home: home)
    end
  end

  def self.observe(hook, event, output, home: Dir.home)
    event = {} unless event.is_a?(Hash)
    id, rule = rule_for(hook)
    return unless id

    session = event['session_id']
    digest_text = context_text(output)
    set_doctrine_version(session, digest_text, home) if rule['starts_session'] && digest_text
    session_started(event, home: home) if rule['starts_session']
    version = rule_version(hook)
    record('evaluation', session: session, home: home, rule_id: id, rule_version: version, hook: hook, tool: event['tool_name'])
    outcome = outcome_of(output, rule)
    record('intervention', session: session, home: home, rule_id: id, rule_version: version, outcome: outcome) if outcome
    bump_turns(session, home) if rule['turn']
    session_ended(session, home) if rule['event'] == 'SessionEnd'
  rescue StandardError
    nil
  end

  def self.parsed_lines(output)
    output.to_s.lines.filter_map do |line|
      parsed = JSON.parse(line)
      parsed if parsed.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end
  end

  def self.context_text(output)
    parsed_lines(output).filter_map { |hash| hash.dig('hookSpecificOutput', 'additionalContext') }.join("\n").then { |text| text.empty? ? nil : text }
  end

  def self.outcome_of(output, rule)
    return nil if output.to_s.strip.empty?

    parsed = parsed_lines(output)
    return 'deny' if parsed.any? { |h| h.dig('hookSpecificOutput', 'permissionDecision') == 'deny' || h['decision'] == 'block' }

    rule['kind'] == 'inject' ? 'inject' : 'advise'
  end

  def self.set_doctrine_version(session, text, home)
    return if session.to_s.empty?

    FileUtils.mkdir_p(session_dir(session, home))
    File.write(File.join(session_dir(session, home), 'doctrine-version'), "#{sha8(text)}\n")
  end

  def self.bump_turns(session, home)
    return if session.to_s.empty?

    path = File.join(session_dir(session, home), 'turns')
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, File::RDWR | File::CREAT) do |file|
      file.flock(File::LOCK_EX)
      count = file.read.to_i + 1
      file.rewind
      file.truncate(0)
      file.write(count.to_s)
    end
  end

  def self.session_ended(session, home)
    return unless once?(session, 'guard-events-ended', home: home)

    path = File.join(session_dir(session, home), 'turns')
    turns = File.file?(path) ? File.read(path).to_i : 0
    record('session_end', session: session, home: home, turns: turns)
  end
end
