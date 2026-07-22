#!/usr/bin/env ruby
# frozen_string_literal: true

require 'time'
require 'date'
require 'yaml'
require 'socket'
require 'fileutils'
require_relative 'ctx_paths'
require_relative 'ctx_index'
require_relative 'skill_registry'

# CRUD over .ctx docs: markdown files with a YAML frontmatter block, grouped by
# class (truth/active/ephemeral) under the per-project store. Writes are atomic
# (temp file plus rename) and stamp provenance on every capture. After any
# mutation the INDEX is rebuilt and a local commit is made; pushing to a sync
# remote is a later phase, so a store with no origin simply never pushes.
class CtxStore
  class InvalidDoc < StandardError; end

  NAME_PATTERN = /\A[a-z0-9][a-z0-9-]*\z/

  # The on-disk shape: a YAML frontmatter block, the --- fence, then the body.
  # Doc bodies and archive digests both serialize through here so what gets
  # written stays byte-identical to what Frontmatter.split reads back.
  def self.render(front, body) = "#{YAML.dump(front)}---\n\n#{body}\n"

  # A doc paired with the class directory it sits in, so a caller (retention's
  # structural check) can compare the on-disk class to the frontmatter class.
  Entry = Data.define(:klass_dir, :doc)

  # One ctx doc as a value: frontmatter fields plus the markdown body. Built
  # whole, never mutated, so it doubles as the serialization unit.
  Doc = Data.define(
    :name, :description, :klass, :status, :ttl, :expires, :review_after,
    :last_touched, :origin_session_id, :origin_device, :supersedes, :body
  ) do
    def self.parse(text)
      front, body = SkillRegistry::Frontmatter.split(text)
      meta = (front && YAML.safe_load(front)) || {}
      from_meta(meta, body.to_s.strip)
    end

    def self.from_meta(meta, body)
      new(
        name: meta['name'].to_s, description: meta['description'].to_s,
        klass: meta['class'].to_s, status: (meta['status'] || 'active').to_s,
        ttl: present(meta['ttl']), expires: present(meta['expires']),
        review_after: present(meta['review_after']),
        last_touched: meta['last_touched'].to_s, origin_session_id: meta['originSessionId'].to_s,
        origin_device: meta['originDevice'].to_s, supersedes: present(meta['supersedes']), body:
      )
    end

    def self.present(value) = value.nil? || value.to_s.empty? ? nil : value.to_s

    def to_markdown = CtxStore.render(front, body)

    # String keys in capture order; nils dropped so absent optional fields stay
    # out of the frontmatter. Psych quotes the timestamp and date values, so they
    # reload as strings rather than Time/Date.
    def front
      {
        'name' => name, 'description' => description, 'class' => klass, 'status' => status,
        'ttl' => ttl, 'expires' => expires, 'review_after' => review_after, 'last_touched' => last_touched,
        'originSessionId' => self.class.present(origin_session_id),
        'originDevice' => self.class.present(origin_device), 'supersedes' => supersedes
      }.compact
    end
  end

  # Commits the store locally after a mutation. Push to a sync remote is a later
  # phase, so this only commits. Failures are swallowed: a doc that was written
  # must not be lost because git lacks an identity or the store is not a repo yet.
  #
  # The commit author is a neutral system identity, not a person: the store is
  # private (local plus an optional sync remote), so authorship there is cosmetic,
  # and the `-c` overrides keep a missing global git identity from failing the
  # commit. Set the store's own user.name/user.email if a real author is wanted.
  class GitCommitter
    IDENTITY = { name: 'cf-ctx', email: 'cf-ctx@localhost' }.freeze

    def initialize(store_dir) = @store_dir = store_dir

    def call(message)
      ensure_repo
      git('add', '-A')
      git('-c', "user.name=#{IDENTITY[:name]}", '-c', "user.email=#{IDENTITY[:email]}",
          'commit', '--quiet', '-m', message)
    rescue StandardError
      nil
    end

    private

    def ensure_repo
      return if File.directory?(File.join(@store_dir, '.git'))

      git('init', '--quiet', '--initial-branch=main')
    end

    def git(*args) = system('git', '-C', @store_dir, *args, out: File::NULL, err: File::NULL)
  end

  # Turns a ttl ('14d' or a bare day count) into a count of days, and an expiry
  # date relative to a moment. Retention (a later phase) consumes `expires`.
  module Ttl
    def self.days(ttl)
      match = ttl.to_s.strip.match(/\A(\d+)\s*d?\z/)
      match && match[1].to_i
    end

    def self.expires(at, ttl) = (at.to_date + days(ttl)).iso8601
  end

  def initialize(cwd: Dir.pwd, session_id: '', device: nil, home: Dir.home, committer: nil, now: nil)
    CtxPaths.assert_project!(cwd)
    @cwd = cwd
    @session_id = session_id.to_s
    @home = home
    @device = device
    @now = now
    @store_dir = CtxPaths.store_dir(cwd, home:)
    @committer = committer || GitCommitter.new(@store_dir)
  end

  def write(name:, description:, klass:, body:, status: 'active', ttl: nil, supersedes: nil, review_after: nil)
    klass = klass.to_s
    ttl = ttl&.to_s
    review_after = review_after&.to_s
    validate!(name: name.to_s, description: description.to_s, klass:, ttl:, review_after:)
    doc = build(name.to_s, description.to_s, klass, status.to_s, ttl, review_after, supersedes, body.to_s)
    persist(doc)
    after_mutation("capture #{doc.name}")
    doc
  end

  def read(name)
    path = path_for(name)
    path && Doc.parse(File.read(path))
  end

  def list(klass: nil, status: nil)
    docs = doc_paths(klass).filter_map { |path| safe_parse(path) }
    docs = docs.select { |doc| doc.status == status.to_s } if status
    docs.sort_by(&:name)
  end

  # Each live doc with the class directory it sits in. Retention needs the
  # directory (not just the frontmatter class) to flag a doc filed under the
  # wrong class.
  def entries
    CtxPaths::CLASSES.flat_map do |klass|
      dir = CtxPaths.class_dir(klass, @cwd, home: @home)
      Dir.glob(File.join(dir, '*.md')).sort.filter_map do |path|
        doc = safe_parse(path)
        doc && Entry.new(klass_dir: klass, doc:)
      end
    end
  end

  def delete(name)
    path = path_for(name)
    return false unless path

    File.delete(path)
    after_mutation("remove #{name}")
    true
  end

  # Compact a live doc into a short digest under archive/ and drop the live copy.
  # The verbatim original stays in git history, so archiving means drop-from-live,
  # not lose-forever. archive/ is outside the live classes, so the index and the
  # structural check skip it.
  def archive(name, digest = nil)
    doc = read(name)
    return false unless doc

    File.delete(path_for(name))
    write_archive(doc, digest || default_digest(doc))
    after_mutation("archive #{name}")
    true
  end

  def device = @device ||= read_or_init_device

  private

  def build(name, description, klass, status, ttl, review_after, supersedes, body)
    at = @now || Time.now
    Doc.new(
      name:, description:, klass:, status:, ttl:,
      expires: (Ttl.expires(at, ttl) if klass == 'ephemeral' && ttl), review_after:,
      last_touched: at.iso8601, origin_session_id: @session_id, origin_device: device,
      supersedes: Doc.present(supersedes), body:
    )
  end

  def validate!(name:, description:, klass:, ttl:, review_after:)
    raise InvalidDoc, "unknown class #{klass.inspect}" unless CtxPaths.klass?(klass)
    raise InvalidDoc, 'truth docs may not carry a ttl' if klass == 'truth' && ttl
    raise InvalidDoc, 'ephemeral docs require a ttl' if klass == 'ephemeral' && ttl.nil?
    raise InvalidDoc, "ttl must be a day count like 14d, got #{ttl.inspect}" if ttl && Ttl.days(ttl).nil?
    raise InvalidDoc, "review_after must be a day count like 365d, got #{review_after.inspect}" if review_after && Ttl.days(review_after).nil?
    raise InvalidDoc, "name must be a slug, got #{name.inspect}" unless NAME_PATTERN.match?(name)
    raise InvalidDoc, 'description must not be empty' if description.strip.empty?
  end

  def persist(doc) = write_atomically(doc_path(doc), doc.to_markdown)

  # Temp-file-plus-rename so a crash mid-write leaves a gitignored *.tmp, never a
  # half-written live doc. Shared by every doc write (capture and archive).
  def write_atomically(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    tmp = "#{path}.tmp"
    File.write(tmp, content)
    File.rename(tmp, path)
  end

  def after_mutation(action)
    CtxIndex.rebuild(@store_dir)
    @committer.call("ctx: #{action} [#{device}]")
  end

  def write_archive(doc, digest)
    path = File.join(CtxPaths.class_dir(CtxPaths::ARCHIVE, @cwd, home: @home), "#{doc.name}.md")
    write_atomically(path, archive_markdown(doc, digest))
  end

  def archive_markdown(doc, digest)
    front = { 'name' => doc.name, 'description' => doc.description,
              'class' => CtxPaths::ARCHIVE, 'status' => 'archived',
              'archived_from' => doc.klass, 'last_touched' => doc.last_touched }.compact
    CtxStore.render(front, digest)
  end

  def default_digest(doc)
    first = doc.body.to_s.lines.map(&:strip).find { |line| !line.empty? }.to_s
    [ doc.description, first ].reject(&:empty?).join(' - ')
  end

  def doc_path(doc) = File.join(CtxPaths.class_dir(doc.klass, @cwd, home: @home), "#{doc.name}.md")

  def doc_paths(klass)
    classes = klass ? [ klass.to_s ] : CtxPaths::CLASSES
    classes.flat_map { |k| Dir.glob(File.join(CtxPaths.class_dir(k, @cwd, home: @home), '*.md')).sort }
  end

  def path_for(name)
    doc_paths(nil).find { |path| File.basename(path, '.md') == name.to_s }
  end

  def safe_parse(path)
    Doc.parse(File.read(path))
  rescue StandardError
    nil
  end

  def read_or_init_device
    path = CtxPaths.meta('device', @cwd, home: @home)
    return File.read(path).strip if File.exist?(path)

    name = Socket.gethostname.split('.').first.to_s
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{name}\n")
    name
  end

  # Maps the capture/recall/list verbs to store calls. The agent runs this after
  # following the cf:ctx skill; the session id is an argument because there is no
  # hook event to read it from.
  class CLI
    FLAG_KEYS = %w[name desc class status ttl review-after supersedes session].freeze

    def self.run(argv, out: $stdout, input: $stdin)
      verb, *rest = argv
      flags, positional = parse(rest)
      store = CtxStore.new(cwd: Dir.pwd, session_id: flags['session'].to_s)
      dispatch(verb, store, flags, positional, out:, input:)
    rescue CtxPaths::NotAProject => e
      out.puts("refused: #{e.message}")
    end

    def self.dispatch(verb, store, flags, positional, out:, input:)
      case verb
      when 'capture' then capture(store, flags, out:, input:)
      when 'recall' then recall(store, positional.first, out:)
      when 'list' then list(store, flags, out:)
      when 'archive' then mutate(store, :archive, positional.first, 'archived', out:)
      when 'remove' then mutate(store, :delete, positional.first, 'removed', out:)
      else out.puts('usage: ctx_store.rb capture|recall|list|archive|remove [--flags]')
      end
    end

    # archive and remove share a shape: act on one named doc, report what happened.
    def self.mutate(store, verb, name, past_tense, out:)
      done = name && store.public_send(verb, name)
      out.puts(done ? "#{past_tense} #{name}" : "no ctx doc named #{name.inspect}")
    end

    def self.capture(store, flags, out:, input:)
      doc = store.write(
        name: flags['name'], description: flags['desc'], klass: flags['class'],
        status: flags['status'] || 'active', ttl: flags['ttl'], supersedes: flags['supersedes'],
        review_after: flags['review-after'], body: input.read
      )
      out.puts("captured #{doc.name} (#{doc.klass})")
    rescue InvalidDoc => e
      out.puts("refused: #{e.message}")
    end

    def self.recall(store, name, out:)
      doc = name && store.read(name)
      out.puts(doc ? doc.to_markdown : "no ctx doc named #{name.inspect}")
    end

    def self.list(store, flags, out:)
      docs = store.list(klass: flags['class'], status: flags['status'])
      out.puts(docs.empty? ? '(empty)' : docs.map { |d| "#{d.klass}/#{d.name} - #{d.description}" }.join("\n"))
    end

    def self.parse(args)
      flags = {}
      positional = []
      until args.empty?
        token = args.shift
        key = token.start_with?('--') && token.delete_prefix('--')
        FLAG_KEYS.include?(key) ? flags[key] = args.shift : positional << token
      end
      [ flags, positional ]
    end
  end
end

CtxStore::CLI.run(ARGV) if __FILE__ == $PROGRAM_NAME
