# frozen_string_literal: true

require 'yaml'
require_relative 'paths'

module Triage
  # The per-repo host pin: `repos: { <owner/repo>: { host: mini | vm,
  # assignment_version: <int> } }`, plus an optional `hosts: { <host>: { ssh:
  # <alias> } }` for the snapshot pull. A missing file is an empty map (every
  # repo is report-only). A corrupt file is invalid: the report stays
  # report-only everywhere and carries a `host_map_invalid` finding. Map order
  # is the scheduling tie-break order (C4). An optional `path:` names the repo's
  # checkout on its host; actions need it, and without it the repo is report-only.
  class HostMap
    Entry = Struct.new(:repo, :host, :version, :path, keyword_init: true)

    attr_reader :entries, :error

    def self.load(path)
      return new([], {}) unless File.file?(path)

      data = YAML.safe_load(File.read(path), permitted_classes: [])
      return invalid('hosts.yml is not a mapping') unless data.is_a?(Hash)

      parse(data)
    rescue Psych::Exception, SystemCallError => e
      invalid(e.message.lines.first.to_s.strip)
    end

    def self.invalid(message) = new([], {}, message)

    def self.parse(data)
      repos = data.fetch('repos', {})
      return invalid('repos must be a mapping') unless repos.is_a?(Hash)

      entries = repos.map { |repo, spec| entry(repo, spec) }
      bad = entries.grep(String).first
      return invalid(bad) if bad

      new(entries, ssh_aliases(data['hosts']))
    end

    def self.entry(repo, spec)
      return "#{repo}: not a mapping" unless spec.is_a?(Hash)
      return "#{repo}: host must be one of #{Paths::HOSTS.join(', ')}" unless Paths::HOSTS.include?(spec['host'])

      version = spec['assignment_version']
      return "#{repo}: assignment_version must be a positive integer" unless version.is_a?(Integer) && version.positive?

      Entry.new(repo: repo.to_s, host: spec['host'], version: version, path: spec['path'] && File.expand_path(spec['path'].to_s))
    end

    def self.ssh_aliases(hosts)
      return {} unless hosts.is_a?(Hash)

      hosts.each_with_object({}) do |(name, spec), memo|
        memo[name.to_s] = spec['ssh'].to_s if spec.is_a?(Hash) && !spec['ssh'].to_s.empty?
      end
    end

    def initialize(entries, ssh, error = nil)
      @entries = entries
      @ssh = ssh
      @error = error
    end

    def valid? = @error.nil?
    def repos = @entries.map(&:repo)
    def entry_for(repo) = @entries.find { |entry| entry.repo == repo }
    def host_for(repo) = entry_for(repo)&.host
    def version_for(repo) = entry_for(repo)&.version
    def hosts = @entries.map(&:host).uniq
    def ssh_target(host) = @ssh.fetch(host, host)

    # Position in the map; repos outside it sort after every mapped repo.
    def rank(repo) = @entries.index { |entry| entry.repo == repo } || @entries.size
  end
end
