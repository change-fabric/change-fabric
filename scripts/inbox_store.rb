#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'

# The AMFM team inbox at ~/1-areas/servant/amfm/329CFEEE35CE, as a CLI instead
# of hand-edited markdown. Every failure this replaces was a hand-editing
# failure: a handoff logged in LEDGER.md with no inbox file behind it, a
# handoff written inside another role's status file, and a read-modify-write
# race that duplicated a ledger line. So: LEDGER.md is append-only and this is
# its only writer, every timestamp comes from the real clock, and the role
# vocabulary is a closed set that is validated rather than remembered.
#
# This file must stay tracked in change-fabric. install.rb's place_hooks does
# FileUtils.rm_rf on ~/.claude/cf/bin and rebuilds it from scripts/*.rb alone,
# so an untracked script living in that directory is destroyed by the next
# install with no copy anywhere. That is exactly how the original was lost on
# 2026-09-17; do not "tidy" this back out of the repo.
module InboxStore
  ROLES = %w[PLAN BUILD PULLS DEPLOY QA LOCAL].freeze
  ACTORS = (ROLES + %w[all PATRICK]).freeze
  STATUSES = %w[pending in-progress done blocked note ack].freeze

  def self.root
    raw = ENV['INBOX_ROOT'] || File.join(Dir.home, '1-areas', 'servant', 'amfm', '329CFEEE35CE')
    File.realpath(raw)
  rescue StandardError
    File.expand_path(raw)
  end

  def self.inbox_dir(role) = File.join(root, 'inbox', role)

  def self.done_dir = File.join(root, 'done')

  def self.ledger_path = File.join(root, 'LEDGER.md')

  def self.status_path(role) = File.join(root, 'status', "#{role}.md")

  def self.roster
    JSON.parse(File.read(File.join(root, 'roster.json')))['roles']
  rescue StandardError
    {}
  end

  def self.session_name(role) = roster[role] || role

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

  def self.ledger_line(from, to, status, slug, clause)
    "#{stamp_minute} #{from}->#{to} #{status} #{slug} - #{clause}"
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
      next if meta['status'] == 'done'

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
    USAGE = 'inbox_store.rb append <TO> --from <FROM> --subject S [--refs R] [--body-file F] | ' \
            'list [--role R] [--json] | pick <path> | done <path> [--note N] [--blocked W] | ' \
            'ledger <FROM> <TO> <status> <slug> <clause> | status [--role R] | stamp <ROLE> | ' \
            'commit [--role R]'

    def self.run(argv, out: $stdout)
      command, *rest = argv
      positional, opts = parse(rest)
      case command
      when 'append' then append(positional, opts, out)
      when 'list' then list(opts, out)
      when 'pick' then pick(positional, out)
      when 'done' then done(positional, opts, out)
      when 'ledger' then ledger(positional, out)
      when 'status' then status(opts, out)
      when 'stamp' then stamp(positional, out)
      when 'commit' then commit(opts, out)
      else out.puts(JSON.generate('error' => 'usage', 'usage' => USAGE))
      end
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
      out.puts(JSON.generate({ 'error' => error }.merge(extra)))
      false
    end

    def self.append(positional, opts, out)
      to = positional[0].to_s.upcase
      from = opts['from'].to_s.upcase
      subject = opts['subject'].to_s
      return fail(out, 'bad_role', 'to' => to, 'roles' => InboxStore::ROLES) unless InboxStore::ROLES.include?(to)
      return fail(out, 'bad_actor', 'from' => from, 'actors' => InboxStore::ACTORS) unless InboxStore::ACTORS.include?(from)
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
      out.puts(JSON.generate('path' => path, 'to' => to, 'from' => from, 'slug' => slug,
                             'ledger' => line, 'recipient' => recipient,
                             'doorbell' => "Inbox: #{path} - #{subject}"))
    end

    def self.list(opts, out)
      roles = opts['role'] ? [ opts['role'].to_s.upcase ] : InboxStore::ROLES
      items = roles.flat_map { |role| InboxStore.pending(role) }
      out.puts(JSON.generate('items' => items, 'count' => items.length,
                             'ledger_tail' => InboxStore.ledger_tail))
    end

    def self.pick(positional, out)
      path = positional[0].to_s
      return fail(out, 'no_such_item', 'path' => path) unless File.exist?(path)

      InboxStore.set_status(path, 'in-progress')
      meta = InboxStore.frontmatter(File.read(path))
      line = InboxStore.append_ledger(InboxStore.ledger_line(meta['to'], meta['from'], 'in-progress',
                                                             InboxStore.slugify(meta['subject']),
                                                             'picked up'))
      out.puts(JSON.generate('path' => path, 'status' => 'in-progress', 'ledger' => line))
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
        target = File.join(InboxStore.done_dir, File.basename(path))
        FileUtils.mv(path, target)
      end
      clause = blocked || opts['note'] || 'completed'
      line = InboxStore.append_ledger(InboxStore.ledger_line(meta['to'], meta['from'], final,
                                                             InboxStore.slugify(meta['subject']), clause))
      out.puts(JSON.generate('path' => target, 'status' => final, 'ledger' => line))
    end

    def self.ledger(positional, out)
      from, to, status, slug, *clause = positional
      from = from.to_s.upcase == 'ALL' ? 'all' : from.to_s.upcase
      to = to.to_s.upcase == 'ALL' ? 'all' : to.to_s.upcase
      return fail(out, 'bad_actor', 'actors' => InboxStore::ACTORS) unless InboxStore::ACTORS.include?(from) && InboxStore::ACTORS.include?(to)
      return fail(out, 'bad_status', 'statuses' => InboxStore::STATUSES) unless InboxStore::STATUSES.include?(status.to_s)
      return fail(out, 'missing_clause', 'usage' => USAGE) if clause.empty?

      line = InboxStore.append_ledger(InboxStore.ledger_line(from, to, status, slug.to_s, clause.join(' ')))
      out.puts(JSON.generate('ledger' => line))
    end

    def self.status(opts, out)
      roles = opts['role'] ? [ opts['role'].to_s.upcase ] : InboxStore::ROLES
      bodies = roles.each_with_object({}) do |role, memo|
        path = InboxStore.status_path(role)
        memo[role] = File.exist?(path) ? File.read(path) : ''
      end
      out.puts(JSON.generate('status' => bodies))
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
      out.puts(JSON.generate('role' => role, 'updated' => stamped))
    end

    def self.commit(opts, out)
      out.puts(JSON.generate(InboxStore.commit(opts['role'])))
    end
  end
end

InboxStore::CLI.run(ARGV) if __FILE__ == $PROGRAM_NAME
