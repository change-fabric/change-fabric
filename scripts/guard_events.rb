#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require 'optparse'
require 'yaml'
require_relative 'hook_event'

# Reads the content-free firing log written by HookEvent.record and reports on
# it. `summary` counts what fired; `idle` proposes advisory rules nobody has
# needed. Deny and gate guards are never proposed, and a low count is a reason
# to look, never proof a rule is useless: whether prose rules change behavior
# and whether a deny prevented harm are not observable from this log.
class GuardEvents
  PROPOSABLE = %w[advisory prose rubric].freeze

  def initialize(home: Dir.home, now: Time.now.utc, rules: nil)
    @home = home
    @now = now
    @rules = rules || HookEvent.rule_ids
  end

  def events
    @events ||= read_events
  end

  def summary(since_days: 7)
    window = within(since_days)
    {
      'since' => cutoff(since_days).iso8601, 'events' => window.size,
      'sessions' => window.count { |e| e['type'] == 'session_start' },
      'by_type' => window.group_by { |e| e['type'] }.transform_values(&:size),
      'levels' => window.group_by { |e| e['level'] }.transform_values(&:size),
      'doctrine_versions' => window.group_by { |e| e['doctrine_version'] }.transform_values(&:size),
      'rules' => rule_rows(window)
    }
  end

  def idle(days: 60, sessions: 200)
    started = events.filter_map { |e| parse_time(e['ts']) }.min
    log_days = started ? ((@now - started) / 86_400).floor : 0
    starts = events.select { |e| e['type'] == 'session_start' }
    candidates = proposable_ids.filter_map { |id| idle_row(id, starts, days, sessions) }
    { 'days' => days, 'sessions' => sessions, 'log_days' => log_days, 'session_starts' => starts.size,
      'enough_history' => log_days >= days && starts.size >= sessions, 'proposals' => candidates }
  end

  private

  def read_events
    path = HookEvent.events_path(@home)
    return [] unless File.file?(path)

    File.foreach(path).filter_map do |line|
      parsed = JSON.parse(line)
      parsed if parsed.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end
  end

  def parse_time(text)
    Time.iso8601(text.to_s)
  rescue ArgumentError
    nil
  end

  def cutoff(days) = @now - (days * 86_400)

  def within(days)
    limit = cutoff(days)
    events.select { |e| (t = parse_time(e['ts'])) && t >= limit }
  end

  def kind_of(id)
    return @rules.dig(id, 'kind') if @rules.key?(id)

    id.start_with?('rubric/') ? 'rubric' : nil
  end

  def rule_rows(window)
    by_rule = window.select { |e| e['rule_id'] }.group_by { |e| e['rule_id'] }
    by_rule.map do |id, list|
      outcomes = list.select { |e| e['type'] == 'intervention' }.group_by { |e| e['outcome'] }.transform_values(&:size)
      { 'rule_id' => id, 'kind' => kind_of(id), 'declared' => !kind_of(id).nil?,
        'evaluations' => list.count { |e| e['type'] == 'evaluation' },
        'surfaced' => list.count { |e| e['type'] == 'rubric_surfaced' },
        'interventions' => outcomes.values.sum, 'outcomes' => outcomes }
    end.sort_by { |row| row['rule_id'] }
  end

  def proposable_ids
    declared = @rules.select { |_id, rule| PROPOSABLE.include?(rule['kind']) }.keys
    (declared + events.filter_map { |e| e['rule_id'] if e['rule_id'].to_s.start_with?('rubric/') }).uniq.sort
  end

  def fired_at(id)
    events.select { |e| e['rule_id'] == id && %w[intervention rubric_surfaced].include?(e['type']) }
          .filter_map { |e| parse_time(e['ts']) }.max
  end

  def first_seen_at(id)
    events.select { |e| e['rule_id'] == id }.filter_map { |e| parse_time(e['ts']) }.min
  end

  # Idle is measured from the last firing, or the rule's first observation when it
  # never fired, so a young log or a newly installed rule cannot condemn anything,
  # and a rule with no observations is not proposed.
  def idle_row(id, starts, days, sessions)
    since = fired_at(id) || first_seen_at(id)
    return nil unless since

    idle_days = ((@now - since) / 86_400).floor
    idle_sessions = starts.count { |e| (t = parse_time(e['ts'])) && t > since }
    return nil unless idle_days >= days && idle_sessions >= sessions

    { 'rule_id' => id, 'kind' => kind_of(id), 'idle_days' => idle_days, 'idle_sessions' => idle_sessions,
      'ever_fired' => !fired_at(id).nil? }
  end
end

def guard_events_main(argv)
  command = argv.shift
  options = { since_days: 7, days: 60, sessions: 200, json: false }
  OptionParser.new do |o|
    o.on('--since-days N', Integer) { |v| options[:since_days] = v }
    o.on('--days N', Integer) { |v| options[:days] = v }
    o.on('--sessions N', Integer) { |v| options[:sessions] = v }
    o.on('--json') { options[:json] = true }
  end.parse!(argv)
  events = GuardEvents.new
  data = case command
  when 'summary' then events.summary(since_days: options[:since_days])
  when 'idle' then events.idle(days: options[:days], sessions: options[:sessions])
  else
           warn 'usage: guard_events.rb summary --since-days N --json | idle --days 60 --sessions 200 --json'
           return 2
  end
  puts options[:json] ? JSON.pretty_generate(data) : data.to_a.map { |k, v| "#{k}: #{v.is_a?(Array) ? v.size : v}" }
  0
end

exit(guard_events_main(ARGV)) if __FILE__ == $PROGRAM_NAME
