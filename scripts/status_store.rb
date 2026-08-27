#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'

# Session-scoped state for cf:status's own self-status ping, under
# ~/.claude/cf/sessions/<session_id>/. Scope is deliberately session-scoped,
# not durable per-repo like SweepTrustStore: this is one session's own
# progress report on its own work, not a policy meant to outlive the session
# that made it. Two plain text files live under the session directory:
# `status` (key=value config lines) and `status-items` (one NN|label record
# per line, order preserved as written).
class StatusStore
  # Percent bands, defined once so the emoji and the number can never
  # disagree: the skill body states these for the human reader, but this is
  # what actually renders. Inclusive at both ends of each range.
  BANDS = [ [ 0, 33, 'red', "\u{1F534}" ],
            [ 34, 79, 'yellow', "\u{1F7E1}" ],
            [ 80, 100, 'green', "\u{1F7E2}" ] ].freeze

  Item = Struct.new(:percent, :label) do
    def color = StatusStore.band_for(percent)[2]
    def emoji = StatusStore.band_for(percent)[3]
    def to_a = [ percent, label ]
    def to_h = { percent: percent, label: label, color: color, emoji: emoji }
  end

  def self.band_for(percent)
    BANDS.find { |lo, hi,| percent.between?(lo, hi) } || BANDS.last
  end

  def self.render_line(item) = format('%s %s (%d%%)', item.emoji, item.label, item.percent)

  def self.all_green?(items) = !items.empty? && items.all? { |item| item.percent >= 80 }

  def initialize(session_id)
    @session_id = session_id.to_s
  end

  def armed? = persistable? && File.exist?(config_path)

  def config_path = File.join(session_dir, 'status')

  def items_path = File.join(session_dir, 'status-items')

  # Writes the config file and clears any stale items left over from a
  # previous arming. A blank session id is non-persistable: nothing is
  # written and no exception escapes.
  def arm(interval:, cron_job_id:)
    return unless persistable?

    write_config('session_id' => @session_id, 'interval' => interval.to_s,
                  'cron_job_id' => cron_job_id.to_s, 'armed_at' => now_iso)
    write_items([])
  end

  def config
    return {} unless persistable? && File.exist?(config_path)

    File.read(config_path).each_line.each_with_object({}) do |line, memo|
      key, value = line.strip.split('=', 2)
      memo[key] = value if key && !key.empty?
    end
  rescue StandardError
    {}
  end

  # Corrupt or unreadable items read as empty, matching
  # SweepTrustStore#read's fail-soft behavior, rather than raising.
  def items
    return [] unless persistable? && File.exist?(items_path)

    File.read(items_path).each_line.filter_map do |line|
      percent, label = line.strip.split('|', 2)
      next if percent.nil? || label.nil?

      Item.new(percent.to_i, label)
    end
  rescue StandardError
    []
  end

  def write_items(list)
    return unless persistable?

    FileUtils.mkdir_p(session_dir)
    File.write(items_path, list.map { |item| "#{item.percent}|#{item.label}\n" }.join)
  end

  def stamp_tick
    return unless persistable?

    write_config(config.merge('last_tick' => now_iso))
  end

  # Returns the recorded cron job id (nil if never armed) and removes both
  # files. The id is returned precisely so the caller can pass it to
  # CronDelete after the store is gone.
  def disarm
    job_id = config['cron_job_id']
    FileUtils.rm_f(config_path)
    FileUtils.rm_f(items_path)
    job_id
  end

  private

  def persistable? = !@session_id.empty?

  def session_dir = File.join(Dir.home, '.claude', 'cf', 'sessions', @session_id)

  def now_iso = Time.now.utc.iso8601

  def write_config(hash)
    FileUtils.mkdir_p(session_dir)
    File.write(config_path, hash.map { |key, value| "#{key}=#{value}\n" }.join)
  end

  # The thin CLI the cf:status skill drives from Bash. Every subcommand
  # prints JSON so the skill parses one shape regardless of which one ran.
  class CLI
    ITEM_PATTERN = /\A(\d{1,3}):(.+)\z/m

    USAGE = 'status_store.rb resolve|path|show|render|disarm [--session <id>] | ' \
            'arm --interval <minutes> --cron <job_id> [--session <id>] | ' \
            'write [--session <id>] --item "<NN>:<label>" [--item ...]'

    def self.run(argv, out: $stdout)
      command, *rest = argv
      opts = parse_options(rest)
      case command
      when 'resolve' then resolve(opts, out)
      when 'path' then path(opts, out)
      when 'arm' then arm(opts, out)
      when 'show' then show(opts, out)
      when 'write' then write(opts, out)
      when 'render' then render(opts, out)
      when 'disarm' then disarm(opts, out)
      else out.puts(JSON.generate(error: 'usage', usage: USAGE))
      end
    end

    def self.parse_options(argv)
      opts = { 'item' => [] }
      index = 0
      while index < argv.length
        case argv[index]
        when '--session' then opts['session'] = argv[index += 1]
        when '--interval' then opts['interval'] = argv[index += 1]
        when '--cron' then opts['cron'] = argv[index += 1]
        when '--item' then opts['item'] << argv[index += 1]
        end
        index += 1
      end
      opts
    end

    # Session id resolution order, first hit wins: an explicit --session
    # flag, then CLAUDE_SESSION_ID, then the most recently modified
    # directory under ~/.claude/cf/sessions. Presence, not truthiness: an
    # explicitly blank --session or CLAUDE_SESSION_ID must resolve to that
    # blank value (StatusStore then treats it as non-persistable) rather
    # than falling through to the newest-directory guess, which would
    # otherwise read or write an unrelated real session's state.
    def self.resolve_session_id(opts)
      return opts['session'] if opts.key?('session')
      return ENV['CLAUDE_SESSION_ID'] if ENV.key?('CLAUDE_SESSION_ID')

      newest_session_dir
    end

    def self.newest_session_dir
      root = File.join(Dir.home, '.claude', 'cf', 'sessions')
      return nil unless Dir.exist?(root)

      dirs = Dir.children(root).map { |name| File.join(root, name) }.select { |dir| File.directory?(dir) }
      return nil if dirs.empty?

      File.basename(dirs.max_by { |dir| File.mtime(dir) })
    end

    def self.resolve(opts, out)
      out.puts(JSON.generate(session_id: resolve_session_id(opts)))
    end

    def self.path(opts, out)
      store = StatusStore.new(resolve_session_id(opts).to_s)
      out.puts(JSON.generate(config: store.config_path, items: store.items_path))
    end

    def self.arm(opts, out)
      interval = opts['interval']
      cron = opts['cron']
      return out.puts(JSON.generate(error: 'usage', usage: USAGE)) unless positive_int?(interval) && !cron.to_s.empty?

      session_id = resolve_session_id(opts).to_s
      store = StatusStore.new(session_id)
      store.arm(interval: interval.to_i, cron_job_id: cron)
      cfg = store.config
      out.puts(JSON.generate(session_id: session_id, interval: interval.to_i, cron_job_id: cron,
                              armed_at: cfg['armed_at']))
    end

    def self.positive_int?(str) = !str.nil? && str.to_s.match?(/\A\d+\z/) && str.to_i.positive?

    def self.show(opts, out)
      session_id = resolve_session_id(opts).to_s
      store = StatusStore.new(session_id)
      unless store.armed?
        return out.puts(JSON.generate(armed: false, session_id: session_id, items: [], all_green: false,
                                       rendered: []))
      end

      cfg = store.config
      items = store.items
      out.puts(JSON.generate(
        armed: true,
        session_id: cfg['session_id'],
        interval: cfg['interval']&.to_i,
        cron_job_id: cfg['cron_job_id'],
        armed_at: cfg['armed_at'],
        last_tick: cfg['last_tick'],
        items: items.map(&:to_h),
        all_green: StatusStore.all_green?(items),
        rendered: items.map { |item| StatusStore.render_line(item) }
      ))
    end

    def self.write(opts, out)
      parsed = []
      opts['item'].each do |raw|
        match = ITEM_PATTERN.match(raw.to_s)
        return out.puts(JSON.generate(error: 'bad_item', item: raw)) unless match

        parsed << StatusStore::Item.new(clamp_percent(match[1].to_i), sanitize_label(match[2]))
      end

      store = StatusStore.new(resolve_session_id(opts).to_s)
      previous = store.items
      store.write_items(parsed)
      store.stamp_tick
      cfg = store.config

      out.puts(JSON.generate(
        changed: previous.map(&:to_a) != parsed.map(&:to_a),
        previous: previous.map(&:to_h),
        items: parsed.map(&:to_h),
        all_green: StatusStore.all_green?(parsed),
        rendered: parsed.map { |item| StatusStore.render_line(item) },
        cron_job_id: cfg['cron_job_id'],
        last_tick: cfg['last_tick']
      ))
    end

    def self.clamp_percent(value) = value.clamp(0, 100)

    def self.sanitize_label(label) = label.gsub(/[\n\r|]/, '')

    def self.render(opts, out)
      store = StatusStore.new(resolve_session_id(opts).to_s)
      out.puts(JSON.generate(rendered: store.items.map { |item| StatusStore.render_line(item) }))
    end

    def self.disarm(opts, out)
      store = StatusStore.new(resolve_session_id(opts).to_s)
      return out.puts(JSON.generate(cron_job_id: nil, disarmed: false)) unless store.armed?

      out.puts(JSON.generate(cron_job_id: store.disarm, disarmed: true))
    end
  end
end

StatusStore::CLI.run(ARGV) if __FILE__ == $PROGRAM_NAME
