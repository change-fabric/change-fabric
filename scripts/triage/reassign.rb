# frozen_string_literal: true

require 'yaml'
require 'json'
require 'digest'
require 'fileutils'
require 'time'
require_relative 'paths'
require_relative 'host_map'
require_relative 'journal'
require_relative 'liveness'

module Triage
  # C8: an explicit, quiesced, versioned host reassignment.
  #
  #   triage.rb reassign <repo> --to <host>
  #
  # Steps, in order, and any failure aborts with the old assignment intact:
  #   1. disable dispatch for the repo on the old host (a marker file);
  #   2. prove nothing runs for it: every unfinished dispatch must read `dead`
  #      under C1, or none may exist (a live or unknown action refuses);
  #   3. revoke the old host's grant for the repo (end its autopilot);
  #   4. write the new host with assignment_version + 1, write-then-rename.
  # Only the old host can prove its own journal quiet, so the command refuses
  # to run anywhere else.
  class Reassign
    Result = Struct.new(:ok, :message, :version, keyword_init: true)

    def self.marker(repo, root = Paths.root) = File.join(Paths.disabled_dir(root), "#{Digest::SHA256.hexdigest(repo)[0, 24]}.json")

    def initialize(root: Paths.root, host: Paths.host, journal: nil, liveness: nil, revoke: nil, now: Time.now.utc)
      @root = root
      @host = host
      @journal = journal || Journal.new(root: root)
      @liveness = liveness || Liveness.new(host: Socket.gethostname)
      @revoke = revoke || method(:end_autopilot)
      @now = now
    end

    def call(repo, to)
      map = HostMap.load(Paths.hosts_file(@root))
      entry = map.entry_for(repo)
      problem = precheck(map, entry, repo, to)
      return refuse(problem) if problem

      disable(repo)
      busy = unquiesced(repo)
      return rollback(repo, "a dispatch is not provably dead: #{busy}") if busy

      revoked = revoke(repo, entry)
      return rollback(repo, revoked) unless revoked == true

      write(repo, to, entry.version + 1)
    rescue StandardError => e
      rollback(repo, "reassign failed: #{e.message}")
    end

    private

    def precheck(map, entry, repo, to)
      return "hosts.yml is invalid: #{map.error}" unless map.valid?
      return "#{repo} is not in hosts.yml" unless entry
      return "unknown host #{to.inspect}" unless Paths::HOSTS.include?(to)
      return "#{repo} is already on #{to}" if entry.host == to
      return "run reassign on #{entry.host}, the repo's current host (this host is #{@host.inspect})" unless entry.host == @host

      nil
    end

    def disable(repo)
      FileUtils.mkdir_p(Paths.disabled_dir(@root))
      File.write(self.class.marker(repo, @root), JSON.generate('repo' => repo, 'at' => @now.iso8601))
    end

    def enable(repo) = FileUtils.rm_f(self.class.marker(repo, @root))

    def unquiesced(repo)
      live = @journal.unfinished.select { |dispatch| dispatch.repo == repo }
      blocked = live.reject { |dispatch| dispatch.handshake && @liveness.verdict(owner(dispatch)).dead? }
      blocked.empty? ? nil : blocked.map(&:id).join(', ')
    end

    def owner(dispatch)
      shake = dispatch.handshake
      { 'host' => shake['host'], 'boot_id' => shake['boot_id'], 'pid' => shake['pid'], 'pid_start' => shake['pid_start'],
        'session_id' => shake['session_id'], 'fence' => shake['fence'] }
    end

    # true, or a reason string.
    def revoke(repo, entry)
      @revoke.call(repo, entry.path) ? true : 'revoking the old host grant failed'
    rescue StandardError => e
      "revoking the old host grant failed: #{e.message}"
    end

    def end_autopilot(_repo, path)
      return true unless path

      require_relative '../change_autopilot'
      ChangeAutopilot.new(project: path).end!(by: 'triage reassign', reason: 'host reassignment')
      true
    end

    def write(repo, to, version)
      path = Paths.hosts_file(@root)
      data = YAML.safe_load(File.read(path), permitted_classes: [])
      data['repos'][repo] = data['repos'][repo].merge('host' => to, 'assignment_version' => version)
      tmp = "#{path}.#{Process.pid}.tmp"
      File.write(tmp, YAML.dump(data))
      File.rename(tmp, path)
      enable(repo)
      Result.new(ok: true, message: "#{repo} reassigned to #{to} at assignment_version #{version}", version: version)
    ensure
      FileUtils.rm_f(tmp) if tmp
    end

    def rollback(repo, message)
      enable(repo)
      refuse(message)
    end

    def refuse(message) = Result.new(ok: false, message: message)
  end
end
