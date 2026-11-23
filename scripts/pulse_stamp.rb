#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'

# A partial runtime copy must not turn every tool call into a stack trace.
begin
  require_relative 'hook_event'
  require_relative 'cf_state'
  require_relative 'pulse_store'
  require_relative 'pulse_precheck'
  require_relative 'pulse_watch'
rescue LoadError
  exit 0 if __FILE__ == $PROGRAM_NAME
  raise
end

# Claude hook on PostToolUse, SubagentStart, SubagentStop and Stop. It stamps
# the C6 activity fields into the CfState session record and detects engage
# triggers. It never dispatches work: until Pulse::ACTIVATED is true and every
# ready part is installed (C8), it only records, and prints nothing.
class PulseStamp
  EVENTS = %w[PostToolUse SubagentStart SubagentStop Stop].freeze
  SPEAKS_ON = %w[PostToolUse SubagentStart].freeze
  COALESCE_S = 300
  AGENT_TTL_S = 86_400
  BACKGROUND_S = 3600
  PLAN_FILE = %r{([^\s"'\\]*?/plans/[^\s"'\\]+?)/(?:workflow\.js|plan\.md|goal\.md)}
  SAFE_ID = /\A\w[\w.-]*\z/
  ARM = '[cf] pulse engaged: arm watcher (run pulse_watch.rb --session %s with run_in_background)'
  REARM = '[cf] pulse watcher stale: re-arm (run pulse_watch.rb --session %s with run_in_background)'
  DUE = '[cf] pulse due'

  def initialize(event, home: Dir.home, now: Time.now, activated: Pulse::ACTIVATED, bin: __dir__)
    @event = event
    @name = event['hook_event_name'].to_s
    @home = home
    @now = now
    @activated = activated
    @bin = bin
    @session = event['session_id'].to_s
  end

  # Returns the additionalContext text, or nil. Never raises into the hook.
  def call
    return unless EVENTS.include?(@name) && @session.match?(SAFE_ID) && File.directory?(@event['cwd'].to_s)
    return if state.pulse['opted_out']

    @away = state.read['availability'] == 'away' # read outside the record lock
    record = state.update_pulse { |pulse| stamp(pulse) }
    dispatch(record) unless record.empty?
  rescue StandardError
    nil
  end

  def self.missing_parts(bin:, home:)
    Pulse::READY_PARTS.reject do |part|
      File.file?(part.end_with?('.md') ? File.join(home, '.claude', 'skills', part.delete_prefix('skills/')) : File.join(bin, "#{part}.rb"))
    end
  end

  private

  def state
    @state ||= CfState.new(host: 'claude', project: @event['cwd'], session_id: @session,
                           root: CfState.root(home: @home), home: @home)
  end

  def iso = @now.utc.iso8601

  def stamp(pulse)
    pulse['last_activity'] = iso
    agents = Array(pulse['open_subagents']).select { |a| a.is_a?(Hash) && @now - Time.parse(a['started_at']) < AGENT_TTL_S }
    id = @event['agent_id'].to_s
    agents = agents.reject { |a| a['id'] == id } if @name == 'SubagentStop'
    agents << { 'id' => id, 'started_at' => iso } if @name == 'SubagentStart' && !id.empty? && agents.none? { |a| a['id'] == id }
    pulse['open_subagents'] = agents
    stamp_tool(pulse) if @name == 'PostToolUse'
    trigger = engage_trigger(pulse)
    pulse['detected_trigger'] ||= { 'trigger' => trigger, 'at' => iso } if trigger
  end

  def stamp_tool(pulse)
    input = @event['tool_input'].is_a?(Hash) ? @event['tool_input'] : {}
    pulse['background_at'] = iso if input['run_in_background'] == true
    return unless @event['tool_name'] == 'Workflow'

    pulse['workflow_active'] = true
    dir = plan_dir(input)
    pulse['plan_path'] = dir if dir
  end

  def plan_dir(input)
    dir = JSON.generate(input)[PLAN_FILE, 1]&.gsub('\\/', '/')
    return unless dir

    dir = File.expand_path(dir.sub(/\A~/, @home))
    dir if %w[goal.md plan.md].any? { |name| File.file?(File.join(dir, name)) }
  end

  def active_work?(pulse)
    Array(pulse['open_subagents']).any? || pulse['workflow_active'] ||
      (pulse['background_at'] && @now - Time.parse(pulse['background_at']) < BACKGROUND_S)
  end

  # Only a recorded detection here; whether it engages is decided by dispatch.
  def engage_trigger(pulse)
    return 'workflow' if pulse['workflow_active']
    return 'agents' if Array(pulse['open_subagents']).size >= 2

    'away' if @away && active_work?(pulse)
  end

  def dispatch(record)
    return unless record['detected_trigger'] && ready?

    store = PulseStore.new(@session)
    unless record['engaged_at']
      store.advance_cursor('engaged_at' => iso)
      record = state.update_pulse { |pulse| pulse['engaged_at'] = iso }
    end
    lines = [ watcher_line(record), (DUE if due?(record, store.cursor)) ].compact
    lines.join("\n") unless lines.empty? || !SPEAKS_ON.include?(@name)
  end

  # C8: every ready part installed, else log the miss and stay silent.
  def ready?
    return false unless @activated

    missing = self.class.missing_parts(bin: @bin, home: @home)
    return true if missing.empty?

    stamped = state.pulse['missing_logged_at']
    unless stamped && @now - Time.parse(stamped) < 3600
      state.update_pulse { |pulse| pulse['missing_logged_at'] = iso }
      log("pulse not engaged: missing #{missing.join(', ')}")
    end
    false
  end

  def watcher_line(record)
    return unless PulseWatch::Health.new(@session, clock: -> { @now }).check == 'rearm'

    last = record['arm_requested_at']
    return if last && @now - Time.parse(last) < COALESCE_S

    state.update_pulse { |pulse| pulse['arm_requested_at'] = iso }
    format(last ? REARM : ARM, @session)
  end

  def due?(record, cursor)
    last = [ cursor['last_pass_at'], cursor['engaged_at'] ].compact.map { |t| Time.parse(t) }.max
    return false unless last && @now - last >= PulsePrecheck.interval_s(cursor['empty_passes'])
    return false unless record['last_activity'] && Time.parse(record['last_activity']) > last
    return false if record['due_at'] && @now - Time.parse(record['due_at']) < COALESCE_S

    state.update_pulse { |pulse| pulse['due_at'] = iso }
    true
  end

  def log(text)
    file = File.join(@home, '.claude', 'cf', 'logs', 'pulse.log')
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, "#{iso} #{text}\n", mode: 'a')
  end
end

# `pulse_stamp.rb off|on --session ID [--project DIR]` is the opt-out; the
# cf:pulse skill calls it. With no subcommand it is the hook.
if __FILE__ == $PROGRAM_NAME
  if %w[off on].include?(ARGV.first)
    off = ARGV.first == 'off'
    opts = ARGV.drop(1).each_slice(2).to_h { |flag, value| [ flag.delete_prefix('--'), value ] }
    abort 'usage: pulse_stamp.rb off|on --session ID [--project DIR]' unless opts['session']
    record = CfState.new(host: 'claude', project: opts['project'] || Dir.pwd, session_id: opts['session'])
                    .update_pulse { |pulse| off ? pulse['opted_out'] = true : pulse.delete('opted_out') }
    abort 'no session record for that id; nothing changed' if record.empty? && off
    puts JSON.generate(pulse: off ? 'off' : 'on')
  else
    event = HookEvent.read
    text = PulseStamp.new(event).call
    puts JSON.generate(hookSpecificOutput: { hookEventName: event['hook_event_name'], additionalContext: text }) if text
  end
end
