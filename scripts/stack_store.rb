#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require 'open3'
require 'digest'
require 'socket'
require_relative 'contributors_team'
require_relative 'plan_phase_trailer'

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
  SOURCES = %w[plan list sweep].freeze
  # Only the head of line may start being prepared or be handed off.
  HEAD_ONLY = %w[preparing handed_off].freeze
  LEASE_TTL = 900

  class Invalid < StandardError; end

  # The repo's ACTIVE claim or LEASE is held by someone else. `holder` is the
  # parsed holder JSON, or nil when the file is empty or unparseable, which
  # still reads as held, never as free.
  class Held < Invalid
    attr_reader :kind, :holder

    def initialize(kind, holder)
      @kind = kind
      @holder = holder
      super("#{kind} by #{holder ? holder['slug'] : 'an incomplete holder'}")
    end
  end

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

  def self.base_dir(dir) = File.join(root, repo_dir(repo_key(dir)))

  # Holder JSON of a claim or lease file: nil when absent, :incomplete when
  # the file exists but is empty or unparseable (callers treat that as held).
  def self.holder(file)
    return nil unless File.exist?(file)

    data = JSON.parse(File.read(file))
    data.is_a?(Hash) && data['slug'] ? data : :incomplete
  rescue JSON::ParserError, SystemCallError
    :incomplete
  end

  # Publishes `data` at `file` exclusively: temp file, fsync, then link(2),
  # which fails with EEXIST when the name is taken, so a reader never sees a
  # partial file and two writers never both win. Returns false when taken.
  def self.publish_exclusive(file, data)
    FileUtils.mkdir_p(File.dirname(file))
    tmp = "#{file}.#{Process.pid}.#{rand(1 << 30)}.tmp"
    File.open(tmp, File::WRONLY | File::CREAT | File::EXCL) do |io|
      io.write(JSON.generate(data))
      io.fsync
    end
    File.link(tmp, file)
    true
  rescue Errno::EEXIST
    false
  ensure
    FileUtils.rm_f(tmp) if tmp
  end

  # True when `git rev-list --parents -n 1 <oid>` output names more than one
  # parent: a merge commit landed and history is no longer linear.
  def self.merge_commit?(rev_list_output) = rev_list_output.to_s.split.size > 2

  # Which queue a sweep works on, given the base slug sweep-<first>-<last>.
  # ACTIVE wins whatever its suffix; otherwise the highest unfinished
  # base[-N] resumes; otherwise a new record at the first free suffix.
  def self.resolve(dir, base)
    base = segment(base)
    active = holder(File.join(base_dir(dir), 'ACTIVE'))
    return resolve_active(active, base) if active

    records = all_for_dir(dir).select { |r| suffix(r['slug'].to_s, base) }
    open = records.reject { |r| finished?(r) }.max_by { |r| suffix(r['slug'], base) }
    return { 'action' => 'resume', 'slug' => open['slug'] } if open

    taken = records.map { |r| r['slug'] }
    slug = ([ base ] + (2..taken.size + 2).map { |n| "#{base}-#{n}" }).find { |c| !taken.include?(c) }
    { 'action' => 'new', 'slug' => slug }
  end

  def self.resolve_active(active, base)
    raise Held.new('held', nil) if active == :incomplete
    return { 'action' => 'resume', 'slug' => active['slug'] } if suffix(active['slug'].to_s, base)

    raise Held.new('held', active)
  end

  # 1 for the base slug, N for base-N, nil for anything else.
  def self.suffix(slug, base)
    return 1 if slug == base

    match = slug.match(/\A#{Regexp.escape(base)}-(\d+)\z/)
    match && match[1].to_i
  end

  # The resume table: what to do with the head PR given its stored state and
  # what gh reports. gh is the truth; the store is intent.
  def self.resume_action(store_state, gh_state)
    return 'advance' if gh_state == 'MERGED'
    return 'escalate' if gh_state == 'CLOSED'

    { 'pending' => 'drive', 'preparing' => 'redrive', 'handed_off' => 'rewatch' }.fetch(store_state.to_s, 'report')
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

  def active_path = File.join(File.dirname(path), 'ACTIVE')
  def lease_path = File.join(File.dirname(path), 'LEASE')

  # Claims the repo's one active queue for this slug. Resumes when the claim
  # is already ours; raises Held naming the holder otherwise.
  def claim(source: nil)
    data = { 'slug' => @slug, 'source' => source.to_s, 'claimed_at' => Time.now.utc.iso8601 }
    return { 'claim' => 'created', 'slug' => @slug } if StackStore.publish_exclusive(active_path, data)

    holder = StackStore.holder(active_path)
    return { 'claim' => 'resumed', 'slug' => @slug } if holder.is_a?(Hash) && holder['slug'] == @slug

    raise Held.new('held', holder.is_a?(Hash) ? holder : nil)
  end

  def claimed?
    holder = StackStore.holder(active_path)
    holder.is_a?(Hash) && holder['slug'] == @slug
  end

  # Removes ACTIVE only when it names this slug; a non-holder release is a
  # no-op. `stale: true` clears this slug's claim only when it has no record
  # and no live lease holder, and refuses otherwise.
  def release(stale: false)
    if stale
      raise Invalid, "#{@slug} has a record; resume or clear it" if read
      raise Invalid, "#{@slug} lease holder is still live" unless lease_takeable?(StackStore.holder(lease_path))

      FileUtils.rm_f(lease_path)
    end
    remove_claim
  end

  # Acquires the executor lease. Exclusive even for the same slug; only the
  # same session re-acquires its own. Takeover only when the holder's pid is
  # gone on this host or its heartbeat is older than LEASE_TTL.
  def lease(session:, pid: nil, now: Time.now.utc)
    data = { 'slug' => @slug, 'pid' => pid&.to_i, 'host' => Socket.gethostname, 'session_id' => session.to_s,
             'acquired_at' => now.iso8601, 'heartbeat_at' => now.iso8601 }
    return data if StackStore.publish_exclusive(lease_path, data)

    holder = StackStore.holder(lease_path)
    raise Held.new('leased', holder.is_a?(Hash) ? holder : nil) unless own_lease?(holder, session) ||
                                                                       lease_takeable?(holder, now)

    FileUtils.rm_f(lease_path)
    return data if StackStore.publish_exclusive(lease_path, data)

    raise Held.new('leased', nil)
  end

  def heartbeat(session:, now: Time.now.utc)
    holder = StackStore.holder(lease_path)
    raise Invalid, "#{@slug} does not hold the lease for this session" unless own_lease?(holder, session)

    holder['heartbeat_at'] = now.iso8601
    tmp = "#{lease_path}.#{Process.pid}.tmp"
    File.write(tmp, JSON.generate(holder))
    File.rename(tmp, lease_path)
    holder
  end

  def unlease
    holder = StackStore.holder(lease_path)
    FileUtils.rm_f(lease_path) if holder.is_a?(Hash) && holder['slug'] == @slug
    { 'unleased' => @slug }
  end

  def init(repo:, source:, mode:, prs:, plan_dir: nil)
    validate!(SOURCES, source, 'source')
    validate!(MODES, mode, 'mode')
    prs = prs.map { |pr| stringify(pr) }
    prs.each { |pr| validate_phase!(pr) }
    raise Invalid, "claim #{@slug} before init (stack_store.rb claim #{@slug})" unless claimed?

    existing = read
    raise Invalid, "#{@slug} is finished and archived; use the next free suffix" if existing && StackStore.finished?(existing)

    write(
      'slug' => @slug, 'repo' => repo.to_s, 'source' => source.to_s,
      'plan_dir' => plan_dir, 'mode' => mode.to_s,
      'prs' => prs.map { |pr| blank_pr.merge(pr) },
      'current' => 0, 'judged' => []
    )
  end

  # Merges fields into the PR entry numbered `number`.
  def set_pr(number, fields)
    fields = stringify(fields)
    validate!(STATES, fields['state'], 'state') if fields.key?('state')
    validate_phase!(fields)
    update do |record|
      pr = find_pr!(record, number)
      guard_head_of_line!(record, pr) if HEAD_ONLY.include?(fields['state'])
      pr.merge!(fields)
    end
  end

  # Marks the current PR merged and moves `current` to the next unmerged one.
  # With `expect`, refuses unless the current PR is that number, so a
  # duplicate or out-of-order advance is an error rather than a skip.
  def advance(expect: nil)
    update do |record|
      current = StackStore.current_pr(record)
      if expect && current&.dig('number').to_s != expect.to_s
        raise Invalid, "advance expected ##{expect}, current is ##{current&.dig('number') || 'none'}"
      end

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
    remove_claim
    unlease
    nil
  end

  private

  def guard_head_of_line!(record, pr)
    current = StackStore.current_pr(record)
    return if current && current['number'].to_s == pr['number'].to_s

    raise Invalid, "PR ##{pr['number']} is not head of line (current is ##{current&.dig('number') || 'none'})"
  end

  def remove_claim
    return { 'released' => false, 'slug' => @slug } unless claimed?

    FileUtils.rm_f(active_path)
    { 'released' => true, 'slug' => @slug }
  end

  def own_lease?(holder, session)
    holder.is_a?(Hash) && holder['slug'] == @slug && holder['session_id'] == session.to_s
  end

  def lease_takeable?(holder, now = Time.now.utc)
    return true if holder.nil?
    return File.mtime(lease_path) < now - LEASE_TTL if holder == :incomplete
    return true if holder['host'] == Socket.gethostname && holder['pid'] && !pid_alive?(holder['pid'])

    Time.parse(holder['heartbeat_at'].to_s) < now - LEASE_TTL
  rescue ArgumentError, SystemCallError
    true
  end

  def pid_alive?(pid)
    Process.kill(0, pid.to_i)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

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

  # `phase` (`<area>/<slug>#Phase N`) is optional: absent or nil stays valid,
  # so records written before the field existed read unchanged and fall back
  # to position order.
  def validate_phase!(pr)
    phase = pr['phase']
    return if phase.nil? || PlanPhaseTrailer.valid?(phase)

    raise Invalid, "phase must read <area>/<slug>#Phase N, got #{phase.inspect}"
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
    USAGE = 'stack_store.rb claim <slug> [--source S] | release <slug> [--stale] | resolve <base-slug> | ' \
            'lease <slug> --session ID [--pid PID] | heartbeat <slug> --session ID | unlease <slug> | ' \
            'init <slug> --repo o/r --source plan|list|sweep --mode MODE ' \
            '[--plan-dir DIR] --pr N:URL:HEAD:SHA ... | get <slug> | ' \
            'set-pr <slug> <n> key=value ... | advance <slug> [--expect N] | pause <slug> <reason> | ' \
            'judged <slug> <text> | list | clear <slug>'

    # Returns the exit status: 0 on success, 1 on a refusal or usage error, so
    # a shell caller stops on a refused transition.
    def self.run(argv, out: $stdout, dir: Dir.pwd, ctx: method(:ctx_pointer))
      command, slug, *rest = argv
      return emit(out, StackStore.all_for_dir(dir)) if command == 'list'
      return emit(out, { error: 'usage', usage: USAGE }, 1) if slug.to_s.empty?
      return emit(out, StackStore.resolve(dir, slug)) if command == 'resolve'

      result = dispatch(command, StackStore.for_dir(dir, slug), rest, dir, ctx)
      emit(out, result, result.is_a?(Hash) && result[:error] ? 1 : 0)
    rescue Held => e
      emit(out, { error: e.kind, holder: e.holder }, 1)
    rescue Invalid => e
      emit(out, { error: e.message }, 1)
    end

    def self.emit(out, value, status = 0)
      out.puts(JSON.generate(value))
      status
    end

    def self.dispatch(command, store, rest, dir, ctx)
      case command
      when 'claim' then store.claim(source: flag(rest, 'source'))
      when 'release' then store.release(stale: rest.include?('--stale'))
      when 'lease' then store.lease(session: flag(rest, 'session'), pid: flag(rest, 'pid'))
      when 'heartbeat' then store.heartbeat(session: flag(rest, 'session'))
      when 'unlease' then store.unlease
      else record_command(command, store, rest, dir, ctx)
      end
    end

    def self.record_command(command, store, rest, dir, ctx)
      case command
      when 'init' then init(store, rest, dir, ctx)
      when 'get' then store.read
      when 'set-pr' then store.set_pr(rest.first, pairs(rest.drop(1)))
      when 'advance' then advance(store, dir, ctx, flag(rest, 'expect'))
      when 'pause' then store.pause(rest.first)
      when 'judged' then store.add_judged(rest.join(' '))
      when 'clear' then clear(store, dir, ctx)
      else { error: 'usage', usage: USAGE }
      end
    end

    def self.flag(args, name)
      index = args.index("--#{name}")
      index && args[index + 1]
    end

    def self.init(store, rest, dir, ctx)
      flags, prs = parse_init(rest)
      record = store.init(repo: flags['repo'], source: flags['source'], mode: flags['mode'],
                          plan_dir: flags['plan-dir'], prs:)
      ctx.call(dir, store.slug, :capture)
      record
    end

    # A finished stack retires its ctx pointer so SessionStart stops offering a resume.
    def self.advance(store, dir, ctx, expect = nil)
      record = store.advance(expect:)
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

exit(StackStore::CLI.run(ARGV)) if __FILE__ == $PROGRAM_NAME
