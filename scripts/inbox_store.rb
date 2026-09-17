#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require_relative 'inbox_paths'
require_relative 'inbox_roster'

# A generic team inbox, as a CLI instead of hand-edited markdown. Every
# failure this replaces was a hand-editing failure: a handoff logged in
# LEDGER.md with no inbox file behind it, a handoff written inside another
# role's status file, and a read-modify-write race that duplicated a ledger
# line. So: LEDGER.md is append-only and this is its only writer, every
# timestamp comes from the real clock, and the role vocabulary is a closed
# set that is validated rather than remembered (from roster.json, never
# hardcoded here).
#
# This file must stay tracked in change-fabric. install.rb's place_hooks
# reconciles ~/.claude/cf/bin against the installed manifest from
# scripts/*.rb alone, so an untracked script living in that directory does
# not survive the next install with no copy anywhere. Do not "tidy" this back
# out of the repo.
module InboxStore
  STATUSES = %w[pending in-progress done blocked note ack].freeze
  MAX_CLAUSE = 200

  def self.root
    raw = InboxPaths.root
    File.realpath(raw)
  rescue StandardError
    File.expand_path(raw)
  end

  def self.root_source = InboxPaths.root_source

  def self.inbox_dir(role) = File.join(root, 'inbox', role)

  def self.done_dir = File.join(root, 'done')

  def self.ledger_path = File.join(root, 'LEDGER.md')

  def self.status_path(role) = File.join(root, 'status', "#{role}.md")

  def self.roles = InboxRoster.roles(root)

  def self.humans = InboxRoster.humans(root)

  def self.actors = InboxRoster.actors(root)

  def self.sessions = InboxRoster.sessions(root)

  def self.session_name(role) = InboxRoster.session_name(root, role)

  def self.no_roster? = InboxRoster.no_roster?(root)

  def self.now = Time.now.utc

  def self.stamp_minute(time = now) = time.strftime('%Y-%m-%d %H:%M')

  def self.file_stamp(time = now) = time.strftime('%Y%m%d-%H%M')

  def self.slugify(text)
    text.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-\z/, '')[0, 48]
  end

  # One open, one write, one close. Two sessions appending concurrently
  # interleave whole lines at worst; neither can lose the other's line, which
  # is exactly what the read-modify-write pattern this replaces could not
  # promise.
  def self.append_ledger(line)
    FileUtils.mkdir_p(root)
    File.open(ledger_path, 'a') { |file| file.write("#{line}\n") }
    line
  end

  # No caller can bypass the cap: this is the only place a clause reaches the
  # ledger line, called from inside ledger_line itself.
  def self.clamp_clause(text)
    flat = text.to_s.gsub(/\s+/, ' ').strip
    return flat if flat.length <= MAX_CLAUSE

    "#{flat[0, MAX_CLAUSE]} ...(truncated, see item body)"
  end

  def self.ledger_line(from, to, status, slug, clause)
    "#{stamp_minute} #{from}->#{to} #{status} #{slug} - #{clamp_clause(clause)}"
  end

  def self.write_atomically(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    tmp = "#{path}.tmp"
    File.write(tmp, content)
    File.rename(tmp, path)
  end

  def self.frontmatter(text)
    match = text.match(/\A---\n(.*?)\n---\n/m)
    return {} unless match

    match[1].each_line.each_with_object({}) do |line, memo|
      key, value = line.split(':', 2)
      memo[key.to_s.strip] = value.to_s.strip if key && value
    end
  rescue StandardError
    {}
  end

  def self.set_status(path, status)
    text = File.read(path)
    updated = text.sub(/^status:.*$/, "status: #{status}")
    write_atomically(path, updated)
    updated
  end

  # Pending items for a role, oldest first. The filename carries the UTC stamp
  # that orders them, so a plain sort is the chronological sort.
  def self.pending(role)
    Dir.glob(File.join(inbox_dir(role), '*.md')).sort.filter_map do |path|
      meta = frontmatter(File.read(path))
      next if meta['status'] == 'done' || meta['status'] == 'fyi'

      { 'path' => path, 'from' => meta['from'], 'to' => meta['to'],
        'subject' => meta['subject'], 'refs' => meta['refs'],
        'status' => meta['status'] || 'pending' }
    end
  rescue StandardError
    []
  end

  def self.ledger_tail(count = 8)
    File.readlines(ledger_path).map(&:chomp).reject { |l| l.empty? || l.start_with?('#') }.last(count)
  rescue StandardError
    []
  end

  # No shell, so no quoting question about the root path at all.
  def self.dirty?
    out = IO.popen([ 'git', '-C', root, 'status', '--porcelain' ], err: File::NULL, &:read)
    !out.to_s.strip.empty?
  rescue StandardError
    false
  end

  def self.commit(role)
    return { 'committed' => false, 'reason' => 'clean' } unless dirty?

    message = "#{role || 'auto'}: #{now.strftime('%Y-%m-%d %H:%M:%S')} UTC"
    system('git', '-C', root, 'add', '-A', out: File::NULL, err: File::NULL)
    ok = system('git', '-C', root, 'commit', '-q', '-m', message, out: File::NULL, err: File::NULL)
    { 'committed' => !!ok, 'message' => message }
  rescue StandardError => e
    { 'committed' => false, 'reason' => e.class.name }
  end

  class CLI
    USAGE = 'inbox_store.rb init --roles A,B,C | root | ' \
            'append <TO> --from <FROM> --subject S [--refs R] [--body-file F] | ' \
            'announce --from <ROLE> --subject S [--body-file F] [--refs R] | ' \
            'bind <ROLE> [--session-name NAME] [--session ID] | ' \
            'list [--role R] [--json] | pick <path> | done <path> [--note N] [--blocked W] | ' \
            'unblock <path> | ' \
            'ledger <FROM> <TO> <status> <slug> <clause> | status [--role R] | stamp <ROLE> | ' \
            'commit [--role R]'

    def self.run(argv, out: $stdout)
      command, *rest = argv
      positional, opts = parse(rest)
      case command
      when 'init' then init(opts, out)
      when 'root' then root_verb(out)
      when 'append' then append(positional, opts, out)
      when 'announce' then announce(opts, out)
      when 'bind' then bind(positional, opts, out)
      when 'list' then list(opts, out)
      when 'pick' then pick(positional, out)
      when 'done' then done(positional, opts, out)
      when 'unblock' then unblock(positional, out)
      when 'ledger' then ledger(positional, out)
      when 'status' then status(opts, out)
      when 'stamp' then stamp(positional, out)
      when 'commit' then commit(opts, out)
      else emit(out, 'error' => 'usage', 'usage' => USAGE)
      end
    end

    def self.emit(out, hash)
      out.puts(JSON.generate(hash))
      hash
    end

    def self.init(opts, out)
      roles = opts['roles'].to_s.split(',').map { |r| r.strip.upcase }.reject(&:empty?)
      return fail(out, 'missing_roles', 'usage' => USAGE) if roles.empty?

      root = InboxStore.root
      return fail(out, 'roster_exists', 'path' => InboxRoster.path(root)) if File.exist?(InboxRoster.path(root))

      FileUtils.mkdir_p(root)
      roles.each { |role| FileUtils.mkdir_p(InboxStore.inbox_dir(role)) }
      FileUtils.mkdir_p(InboxStore.done_dir)
      FileUtils.mkdir_p(File.join(InboxStore.done_dir, 'artifacts'))
      FileUtils.mkdir_p(File.join(root, 'status'))
      FileUtils.mkdir_p(File.join(root, 'ledger'))
      FileUtils.touch(InboxStore.ledger_path)
      InboxRoster.write(root, roles: roles)
      emit(out, 'root' => root, 'source' => InboxStore.root_source, 'roles' => roles)
    end

    def self.root_verb(out)
      emit(out, 'root' => InboxStore.root, 'source' => InboxStore.root_source)
    end

    def self.parse(argv)
      positional = []
      opts = {}
      index = 0
      while index < argv.length
        token = argv[index]
        if token.start_with?('--')
          opts[token.sub(/\A--/, '')] = argv[index += 1]
        else
          positional << token
        end
        index += 1
      end
      [ positional, opts ]
    end

    def self.fail(out, error, extra = {})
      emit(out, { 'error' => error }.merge(extra))
    end

    def self.append(positional, opts, out)
      return fail(out, 'no_roster') if InboxStore.no_roster?

      to = positional[0].to_s.upcase
      from = opts['from'].to_s.upcase
      subject = opts['subject'].to_s
      return fail(out, 'bad_role', 'to' => to, 'roles' => InboxStore.roles) unless InboxStore.roles.include?(to)
      return fail(out, 'bad_actor', 'from' => from, 'actors' => InboxStore.actors) unless InboxStore.actors.include?(from)
      return fail(out, 'missing_subject', 'usage' => USAGE) if subject.empty?

      body = opts['body-file'] && File.exist?(opts['body-file']) ? File.read(opts['body-file']) : ''
      slug = InboxStore.slugify(opts['slug'] || subject)
      name = "#{InboxStore.file_stamp}-#{from}-#{slug}.md"
      path = File.join(InboxStore.inbox_dir(to), name)
      refs = opts['refs'].to_s
      text = +"---\nfrom: #{from}\nto: #{to}\nsubject: #{subject}\nrefs: #{refs}\nstatus: pending\n---\n\n"
      text << body
      text << "\n" unless text.end_with?("\n")
      InboxStore.write_atomically(path, text)
      line = InboxStore.append_ledger(InboxStore.ledger_line(from, to, 'pending', slug, subject))
      recipient = InboxStore.session_name(to)
      emit(out, 'path' => path, 'to' => to, 'from' => from, 'slug' => slug,
                'ledger' => line, 'recipient' => recipient,
                'doorbell' => "Inbox: #{path} - #{subject}")
    end

    # Writes one non-actionable fyi item per configured role (including the
    # sender's own, so the archive is uniform) and appends exactly one
    # ledger line, not one per role. InboxStore.pending skips status: fyi the
    # same way it skips done, so no role's actionable list ever shows it.
    def self.announce(opts, out)
      return fail(out, 'no_roster') if InboxStore.no_roster?

      from = opts['from'].to_s.upcase
      subject = opts['subject'].to_s
      return fail(out, 'bad_actor', 'from' => from, 'actors' => InboxStore.actors) unless InboxStore.actors.include?(from)
      return fail(out, 'missing_subject', 'usage' => USAGE) if subject.empty?

      body = opts['body-file'] && File.exist?(opts['body-file']) ? File.read(opts['body-file']) : ''
      slug = InboxStore.slugify(opts['slug'] || subject)
      refs = opts['refs'].to_s
      roles = InboxStore.roles
      paths = roles.map do |role|
        name = "#{InboxStore.file_stamp}-#{from}-#{slug}.md"
        path = File.join(InboxStore.inbox_dir(role), name)
        text = +"---\nfrom: #{from}\nto: #{role}\nsubject: #{subject}\nrefs: #{refs}\nstatus: fyi\n---\n\n"
        text << body
        text << "\n" unless text.end_with?("\n")
        InboxStore.write_atomically(path, text)
        path
      end
      line = InboxStore.append_ledger(InboxStore.ledger_line(from, 'all', 'note', slug, subject))
      emit(out, 'paths' => paths, 'roles' => roles, 'slug' => slug, 'ledger' => line,
                'doorbell' => "Inbox announce: #{subject} - notify #{roles.join(', ')}")
    end

    # Resolves the calling session's id the same way status_store.rb does:
    # an explicit --session, then CLAUDE_CODE_SESSION_ID, no other fallback.
    def self.resolve_session_id(opts)
      return opts['session'] if opts.key?('session')
      return ENV['CLAUDE_CODE_SESSION_ID'] if ENV.key?('CLAUDE_CODE_SESSION_ID')

      nil
    end

    def self.bind(positional, opts, out)
      return fail(out, 'no_roster') if InboxStore.no_roster?

      role = positional[0].to_s.upcase
      return fail(out, 'bad_role', 'to' => role, 'roles' => InboxStore.roles) unless InboxStore.roles.include?(role)

      session_id = resolve_session_id(opts)
      return fail(out, 'no_session') if session_id.to_s.empty?

      session_dir = File.join(Dir.home, '.claude', 'cf', 'sessions', session_id)
      FileUtils.mkdir_p(session_dir)
      InboxStore.write_atomically(File.join(session_dir, 'inbox-role'), role)

      roster_updated = false
      if opts['session-name']
        roster_updated = InboxRoster.bind_session(InboxStore.root, role: role, name: opts['session-name'])
      end

      emit(out, 'role' => role, 'session' => session_id, 'session_name' => opts['session-name'],
                'roster_updated' => roster_updated,
                'doorbell' => "Bound this session to #{role}. Next: inbox_store.rb list --role #{role}")
    end

    def self.list(opts, out)
      return fail(out, 'no_roster') if InboxStore.no_roster?

      roles = opts['role'] ? [ opts['role'].to_s.upcase ] : InboxStore.roles
      items = roles.flat_map { |role| InboxStore.pending(role) }
      emit(out, 'items' => items, 'count' => items.length,
                'ledger_tail' => InboxStore.ledger_tail)
    end

    def self.pick(positional, out)
      path = positional[0].to_s
      return fail(out, 'no_such_item', 'path' => path) unless File.exist?(path)

      InboxStore.set_status(path, 'in-progress')
      meta = InboxStore.frontmatter(File.read(path))
      line = InboxStore.append_ledger(InboxStore.ledger_line(meta['to'], meta['from'], 'in-progress',
                                                             InboxStore.slugify(meta['subject']),
                                                             'picked up'))
      emit(out, 'path' => path, 'status' => 'in-progress', 'ledger' => line)
    end

    # base-2.md, base-3.md, ... until the name is free. Never overwrites an
    # existing done/ file on a same-minute same-sender same-slug collision.
    def self.unique_destination(dir, basename)
      candidate = File.join(dir, basename)
      return candidate unless File.exist?(candidate)

      ext = File.extname(basename)
      stem = basename[0, basename.length - ext.length]
      suffix = 2
      loop do
        candidate = File.join(dir, "#{stem}-#{suffix}#{ext}")
        return candidate unless File.exist?(candidate)

        suffix += 1
      end
    end

    def self.done(positional, opts, out)
      path = positional[0].to_s
      return fail(out, 'no_such_item', 'path' => path) unless File.exist?(path)

      blocked = opts['blocked']
      final = blocked ? 'blocked' : 'done'
      InboxStore.set_status(path, final)
      meta = InboxStore.frontmatter(File.read(path))
      target = path
      unless blocked
        FileUtils.mkdir_p(InboxStore.done_dir)
        target = unique_destination(InboxStore.done_dir, File.basename(path))
        FileUtils.mv(path, target)
      end
      clause = blocked || opts['note'] || 'completed'
      line = InboxStore.append_ledger(InboxStore.ledger_line(meta['to'], meta['from'], final,
                                                             InboxStore.slugify(meta['subject']), clause))
      emit(out, 'path' => target, 'status' => final, 'ledger' => line)
    end

    def self.unblock(positional, out)
      path = positional[0].to_s
      return fail(out, 'no_such_item', 'path' => path) unless File.exist?(path)

      meta = InboxStore.frontmatter(File.read(path))
      return fail(out, 'not_blocked', 'status' => meta['status']) unless meta['status'] == 'blocked'

      InboxStore.set_status(path, 'pending')
      line = InboxStore.append_ledger(InboxStore.ledger_line(meta['to'], meta['from'], 'pending',
                                                             InboxStore.slugify(meta['subject']),
                                                             'unblocked'))
      emit(out, 'path' => path, 'status' => 'pending', 'ledger' => line)
    end

    def self.ledger(positional, out)
      from, to, status, slug, *clause = positional
      return fail(out, 'no_roster') if InboxStore.no_roster?

      from = from.to_s.upcase == 'ALL' ? 'all' : from.to_s.upcase
      to = to.to_s.upcase == 'ALL' ? 'all' : to.to_s.upcase
      return fail(out, 'bad_actor', 'actors' => InboxStore.actors) unless InboxStore.actors.include?(from) && InboxStore.actors.include?(to)
      return fail(out, 'bad_status', 'statuses' => InboxStore::STATUSES) unless InboxStore::STATUSES.include?(status.to_s)
      return fail(out, 'missing_clause', 'usage' => USAGE) if clause.empty?

      line = InboxStore.append_ledger(InboxStore.ledger_line(from, to, status, slug.to_s, clause.join(' ')))
      emit(out, 'ledger' => line)
    end

    def self.status(opts, out)
      return fail(out, 'no_roster') if InboxStore.no_roster?

      roles = opts['role'] ? [ opts['role'].to_s.upcase ] : InboxStore.roles
      bodies = roles.each_with_object({}) do |role, memo|
        path = InboxStore.status_path(role)
        memo[role] = File.exist?(path) ? File.read(path) : ''
      end
      emit(out, 'status' => bodies)
    end

    # Rewrites only the Updated line, so a role's freeform Notes survive. The
    # notes are the most useful content in the directory; a "status set"
    # command would flatten them, so there is not one.
    def self.stamp(positional, out)
      role = positional[0].to_s.upcase
      path = InboxStore.status_path(role)
      return fail(out, 'no_such_status', 'role' => role) unless File.exist?(path)

      stamped = "Updated #{InboxStore.stamp_minute} UTC."
      text = File.read(path)
      text = text.match?(/^Updated .*$/) ? text.sub(/^Updated .*$/, stamped) : text.sub(/\n/, "\n\n#{stamped}\n")
      InboxStore.write_atomically(path, text)
      emit(out, 'role' => role, 'updated' => stamped)
    end

    def self.commit(opts, out)
      emit(out, InboxStore.commit(opts['role']))
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  response = InboxStore::CLI.run(ARGV)
  exit(response.is_a?(Hash) && response.key?('error') ? 1 : 0)
end
