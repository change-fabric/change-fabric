#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require 'open3'
require 'digest'
require_relative 'contributors_team'

# Durable record of one PR stack that cf:sweep stack mode is landing, one PR at
# a time. Modeled on SweepTrustStore: keyed by ContributorsTeam's normalized
# repo_id (slugged into one path segment), durable on disk rather than
# session-scoped, because a stack outlives the session that started it (the
# user may merge #12 tomorrow). The store is a cache of intent, never the
# truth about a PR: stack mode re-derives every PR's state from gh on resume.
#
# File: ~/.claude/cf/stack/<repo_id>-<digest>/<slug>.json. A corrupt or unreadable file
# reads as absent, and every write is atomic (temp file plus rename), so a
# crash mid-write can never leave a half-written record behind.
class StackStore
  STATES = %w[pending preparing handed_off merged paused escalated].freeze
  MODES = %w[merge_ready admin_bypass yolo].freeze
  SOURCES = %w[plan list].freeze

  class Invalid < StandardError; end

  def self.for_dir(dir, slug)
    new(repo_key(dir), slug)
  end

  def self.repo_key(dir)
    ContributorsTeam.new(dir).repo_id || File.expand_path(dir.to_s)
  end

  def self.root = File.join(Dir.home, '.claude', 'cf', 'stack')

  def self.segment(value) = value.to_s.gsub(/[^A-Za-z0-9._-]+/, '-')

  # Readable slug plus a digest of the full repo id, so two ids that slug alike
  # (acme-tools/web and acme/tools-web) never share a directory.
  def self.repo_dir(repo_id) = "#{segment(repo_id)}-#{Digest::SHA256.hexdigest(repo_id.to_s)[0, 12]}"

  # Every readable stack record for the repo `dir` sits in, oldest slug first.
  def self.all_for_dir(dir)
    base = File.join(root, repo_dir(repo_key(dir)))
    Dir.glob(File.join(base, '*.json')).sort.filter_map do |file|
      new(repo_key(dir), File.basename(file, '.json')).read
    end
  end

  # Records whose landing is not finished: some PR is not yet merged.
  def self.unfinished_for_dir(dir)
    all_for_dir(dir).reject { |record| finished?(record) }
  end

  def self.finished?(record)
    prs = Array(record['prs'])
    prs.empty? || prs.all? { |pr| pr['state'] == 'merged' }
  end

  # The PR stack mode is working on: the first one not merged.
  def self.current_pr(record)
    Array(record['prs']).find { |pr| pr['state'] != 'merged' }
  end

  attr_reader :slug

  def initialize(repo_id, slug)
    @repo_id = repo_id.to_s
    @slug = StackStore.segment(slug)
  end

  def path = File.join(StackStore.root, StackStore.repo_dir(@repo_id), "#{@slug}.json")

  def read
    return nil unless persistable? && File.exist?(path)

    record = JSON.parse(File.read(path))
    record.is_a?(Hash) && record['prs'].is_a?(Array) ? record : nil
  rescue JSON::ParserError, SystemCallError
    nil
  end

  def init(repo:, source:, mode:, prs:, plan_dir: nil)
    validate!(SOURCES, source, 'source')
    validate!(MODES, mode, 'mode')
    write(
      'slug' => @slug, 'repo' => repo.to_s, 'source' => source.to_s,
      'plan_dir' => plan_dir, 'mode' => mode.to_s,
      'prs' => prs.map { |pr| blank_pr.merge(stringify(pr)) },
      'current' => 0, 'judged' => []
    )
  end

  # Merges fields into the PR entry numbered `number`.
  def set_pr(number, fields)
    fields = stringify(fields)
    validate!(STATES, fields['state'], 'state') if fields.key?('state')
    update do |record|
      pr = find_pr!(record, number)
      pr.merge!(fields)
    end
  end

  # Marks the current PR merged and moves `current` to the next unmerged one.
  def advance
    update do |record|
      current = StackStore.current_pr(record)
      current['state'] = 'merged' if current
      record['current'] = Array(record['prs']).index { |pr| pr['state'] != 'merged' } || record['prs'].size
    end
  end

  def pause(reason)
    update do |record|
      current = StackStore.current_pr(record)
      raise Invalid, 'no unmerged PR to pause' unless current

      current['state'] = 'paused'
      current['pause_reason'] = reason.to_s
    end
  end

  def add_judged(item)
    update { |record| (record['judged'] ||= []) << item.to_s }
  end

  def clear
    FileUtils.rm_f(path) if persistable?
    nil
  end

  private

  def persistable? = !@repo_id.empty? && !@slug.empty?

  def blank_pr
    { 'number' => nil, 'url' => nil, 'head' => nil, 'old_head_sha' => nil,
      'state' => 'pending', 'pause_reason' => nil }
  end

  def stringify(hash) = hash.to_h.transform_keys(&:to_s)

  def validate!(allowed, value, field)
    return if allowed.include?(value.to_s)

    raise Invalid, "#{field} must be one of #{allowed.join('|')}, got #{value.inspect}"
  end

  def find_pr!(record, number)
    record['prs'].find { |pr| pr['number'].to_s == number.to_s } ||
      raise(Invalid, "PR ##{number} is not in stack #{@slug}")
  end

  def update
    record = read || raise(Invalid, "no stack named #{@slug}")
    yield record
    write(record)
  end

  def write(record)
    return unless persistable?

    record['updated_at'] = Time.now.utc.iso8601
    FileUtils.mkdir_p(File.dirname(path))
    tmp = "#{path}.#{Process.pid}.tmp"
    File.write(tmp, "#{JSON.pretty_generate(record)}\n")
    File.rename(tmp, path)
    record
  end

  # The thin CLI stack mode drives from Bash. Every subcommand prints one JSON
  # line so the skill parses one shape.
  class CLI
    USAGE = 'stack_store.rb init <slug> --repo o/r --source plan|list --mode MODE ' \
            '[--plan-dir DIR] --pr N:URL:HEAD:SHA ... | get <slug> | ' \
            'set-pr <slug> <n> key=value ... | advance <slug> | pause <slug> <reason> | ' \
            'judged <slug> <text> | list | clear <slug>'

    def self.run(argv, out: $stdout, dir: Dir.pwd, ctx: method(:ctx_pointer))
      command, slug, *rest = argv
      return out.puts(JSON.generate(StackStore.all_for_dir(dir))) if command == 'list'
      return usage(out) if slug.to_s.empty?

      store = StackStore.for_dir(dir, slug)
      out.puts(JSON.generate(dispatch(command, store, rest, dir, ctx)))
    rescue Invalid => e
      out.puts(JSON.generate(error: e.message))
    end

    def self.dispatch(command, store, rest, dir, ctx)
      case command
      when 'init' then init(store, rest, dir, ctx)
      when 'get' then store.read
      when 'set-pr' then store.set_pr(rest.first, pairs(rest.drop(1)))
      when 'advance' then advance(store, dir, ctx)
      when 'pause' then store.pause(rest.first)
      when 'judged' then store.add_judged(rest.join(' '))
      when 'clear' then clear(store, dir, ctx)
      else { error: 'usage', usage: USAGE }
      end
    end

    def self.usage(out) = out.puts(JSON.generate(error: 'usage', usage: USAGE))

    def self.init(store, rest, dir, ctx)
      flags, prs = parse_init(rest)
      record = store.init(repo: flags['repo'], source: flags['source'], mode: flags['mode'],
                          plan_dir: flags['plan-dir'], prs:)
      ctx.call(dir, store.slug, :capture)
      record
    end

    # A finished stack retires its ctx pointer so SessionStart stops offering a resume.
    def self.advance(store, dir, ctx)
      record = store.advance
      ctx.call(dir, store.slug, :retire) if StackStore.finished?(record)
      record
    end

    def self.clear(store, dir, ctx)
      store.clear
      ctx.call(dir, store.slug, :retire)
      { cleared: store.slug }
    end

    def self.parse_init(args)
      flags = {}
      prs = []
      args.each_slice(2) do |key, value|
        name = key.to_s.delete_prefix('--')
        name == 'pr' ? prs << pr_spec(value) : flags[name] = value
      end
      [ flags, prs ]
    end

    # N:URL:HEAD:SHA, where URL itself carries colons, so split from both ends.
    def self.pr_spec(value)
      parts = value.to_s.split(':')
      number = parts.shift
      sha = parts.pop if parts.size > 2
      head = parts.pop if parts.size > 2
      { 'number' => number.to_i, 'url' => parts.join(':'), 'head' => head, 'old_head_sha' => sha }
    end

    def self.pairs(args)
      args.to_h { |pair| pair.split('=', 2) }.transform_values { |v| v == 'null' ? nil : v }
    end

    # The ctx pointer that lets SessionStart surface a stack after the session
    # that started it is gone: captured on init, archived once the stack is
    # finished or cleared. Fail-soft: a repo with no ctx store still lands.
    def self.ctx_pointer(dir, slug, action)
      script = File.join(__dir__, 'ctx_store.rb')
      return Open3.capture2e('ruby', script, 'archive', "stack-#{slug}", chdir: dir) if action == :retire

      body = "PR stack #{slug} is landing. Resume with /cf:sweep stack resume.\n"
      Open3.capture2e('ruby', script, 'capture', '--name', "stack-#{slug}", '--class', 'active',
                      '--desc', 'PR stack landing in progress', stdin_data: body, chdir: dir)
    rescue StandardError
      nil
    end
  end
end

StackStore::CLI.run(ARGV) if __FILE__ == $PROGRAM_NAME
