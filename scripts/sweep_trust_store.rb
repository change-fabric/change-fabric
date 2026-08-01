#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require_relative 'contributors_team'

# Records the per-contributor trust policy cf:sweep asks for once and then
# reuses on every later sweep of the same repo.
#
# Scope is deliberately (repo, contributor) and durable on disk, not
# session-scoped like MergeModeStore: cf:sweep is meant to run unattended on a
# schedule (`/loop 30m /cf:sweep`), and a session-scoped answer would re-ask the
# trust question on every tick, which is exactly the interruption that breaks an
# unattended loop. A trust call is also a standing judgment about a person's
# work, not a per-session intent like a merge mode, so it belongs to the repo.
#
# The key is ContributorsTeam's normalized `repo_id` (host/path, so SSH and
# HTTPS clones of one repo collapse to one record), slugged into a single path
# segment. A repo with no remote falls back to its absolute root path, which is
# still stable for a local-only checkout.
class SweepTrustStore
  # Ordinal, highest trust first. The ordering is meaningful: cf:sweep sorts
  # merge order by it and resolves a conflict between two PRs in favor of the
  # higher-trust author.
  LEVELS = %w[high standard low blocked].freeze

  class UnknownLevel < StandardError; end

  # Builds a store for whatever repo `dir` sits in. Fail-soft: a directory that
  # is not a git repo, or a repo with no remote, still gets a usable store keyed
  # by its own path.
  def self.for_dir(dir)
    new(ContributorsTeam.new(dir).repo_id || File.expand_path(dir.to_s))
  end

  def initialize(repo_id)
    @repo_id = repo_id.to_s
  end

  # The recorded level for a login, or nil when this contributor has never been
  # ruled on. nil is what makes cf:sweep ask; it never defaults a person to
  # trusted.
  def level(login)
    contributors[login.to_s]&.fetch('level', nil)
  end

  def known?(login) = !level(login).nil?

  # The logins cf:sweep still has to ask about. Order-preserving and
  # deduplicated so the caller can hand it a raw author list straight from
  # `gh pr list`.
  def unknown(logins)
    logins.map(&:to_s).uniq.reject { |login| known?(login) }
  end

  def record(login, level)
    raise UnknownLevel, level.to_s unless LEVELS.include?(level.to_s)

    payload = read || { 'repo_id' => @repo_id, 'contributors' => {} }
    payload['contributors'] ||= {}
    payload['contributors'][login.to_s] = {
      'level' => level.to_s,
      'recorded_at' => Time.now.utc.iso8601
    }
    payload['updated_at'] = Time.now.utc.iso8601
    write(payload)
  end

  # Drops one contributor so the next sweep asks again, the supported way to
  # revise a call that has since proven wrong.
  def forget(login)
    payload = read
    return unless payload && payload['contributors']

    payload['contributors'].delete(login.to_s)
    payload['updated_at'] = Time.now.utc.iso8601
    write(payload)
  end

  # login => level, for handing the whole policy to the sweep in one arg.
  def all
    contributors.transform_values { |entry| entry['level'] }
  end

  def read
    return nil unless persistable? && File.exist?(path)

    JSON.parse(File.read(path))
  rescue JSON::ParserError, SystemCallError
    nil
  end

  def path = File.join(Dir.home, '.claude', 'cf', 'sweep', slug, 'trust.json')

  private

  def persistable? = !@repo_id.empty?

  def contributors
    record = read
    record && record['contributors'].is_a?(Hash) ? record['contributors'] : {}
  end

  # One path segment, so `github.com/acme/web` cannot escape the sweep dir or
  # collide with a sibling repo of the same basename.
  def slug = @repo_id.gsub(/[^A-Za-z0-9._-]+/, '-')

  def write(payload)
    return unless persistable?

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.pretty_generate(payload)}\n")
    payload
  end

  # The thin CLI cf:sweep's SKILL.md drives, since a skill reads and writes this
  # from Bash rather than from Ruby. Every subcommand prints JSON so the skill
  # parses one shape regardless of which one it ran.
  class CLI
    def self.run(argv, out: $stdout, dir: Dir.pwd)
      store = SweepTrustStore.for_dir(dir)
      command = argv.first.to_s
      case command
      when 'show' then out.puts(JSON.generate(store.all))
      when 'unknown' then out.puts(JSON.generate(store.unknown(argv.drop(1))))
      when 'set' then set(store, argv, out)
      when 'forget' then forget(store, argv, out)
      when 'path' then out.puts(JSON.generate(path: store.path))
      else out.puts(JSON.generate(error: 'usage', usage: USAGE))
      end
    end

    USAGE = 'sweep_trust_store.rb show | unknown <login...> | ' \
            "set <login> <#{SweepTrustStore::LEVELS.join('|')}> | forget <login> | path"

    def self.set(store, argv, out)
      login, level = argv[1], argv[2]
      return out.puts(JSON.generate(error: 'usage', usage: USAGE)) if login.to_s.empty?

      store.record(login, level)
      out.puts(JSON.generate(store.all))
    rescue UnknownLevel => e
      out.puts(JSON.generate(error: 'unknown_level', level: e.message, allowed: SweepTrustStore::LEVELS))
    end

    def self.forget(store, argv, out)
      login = argv[1]
      return out.puts(JSON.generate(error: 'usage', usage: USAGE)) if login.to_s.empty?

      store.forget(login)
      out.puts(JSON.generate(store.all))
    end
  end
end

SweepTrustStore::CLI.run(ARGV) if __FILE__ == $PROGRAM_NAME
