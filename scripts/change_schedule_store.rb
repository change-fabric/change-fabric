#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'time'

# The time-keyed record store for scheduled runs (0.20.0). One
# directory per (repository, schedule, profile) under
# ~/.claude/cf/change/schedules, so two repos with the same schedule and
# profile names never share a latest.json or a retention window; one
# JSON file per run named by its finish time, and a `latest.json` pointer that
# is replaced atomically (written to a temp file, then renamed) so a reader
# never sees a half-written record.
#
# It lives beside the per-sha gate records but never in their namespace: a
# schedule record is keyed by time, not by commit, so it can never satisfy the
# per-PR comprehensive gate (ChangeGateStore reads only <sha>[__<profile>]).
#
# The store is a convenience for the machine that ran the schedule, not an
# attestation: anyone with write access to this directory can write a record.
class ChangeScheduleStore
  RETAIN = 60
  LATEST = 'latest.json'

  def self.default_root = File.join(Dir.home, '.claude', 'cf', 'change', 'schedules')

  # A stable, filesystem-safe identity for a checkout: its directory name
  # plus a digest of its real path.
  def self.repo_key(repo_root)
    real = File.realpath(repo_root.to_s)
    "#{File.basename(real).gsub(/[^A-Za-z0-9._-]/, '_')}-#{Digest::SHA256.hexdigest(real)[0, 12]}"
  end

  def initialize(schedule, profile, repo:, root: self.class.default_root)
    @schedule = schedule.to_s
    @profile = profile.to_s
    @repo = repo.to_s
    @root = root
  end

  def dir = File.join(@root, @repo, "#{@schedule}__#{@profile}")
  def latest_path = File.join(dir, LATEST)

  # Writes one run's record, repoints latest.json at it, prunes past RETAIN,
  # and returns the record's path. An flock on .lock serializes overlapping
  # runs, so pruning sees one consistent listing and never over-deletes.
  def write(record)
    FileUtils.mkdir_p(dir)
    body = JSON.pretty_generate(record)
    File.open(File.join(dir, '.lock'), File::RDWR | File::CREAT) do |lock|
      lock.flock(File::LOCK_EX)
      path = reserve_and_write(stamp(record['finished_at']), body)
      atomic_write(latest_path, body)
      prune
      path
    end
  end

  def latest
    return nil unless File.exist?(latest_path)

    JSON.parse(File.read(latest_path))
  rescue JSON::ParserError
    nil
  end

  # Every run record, oldest first (the file names sort by time).
  def records = Dir.glob(File.join(dir, '*.json')).reject { |path| File.basename(path) == LATEST }.sort

  private

  # ISO 8601 basic format: sortable, and free of the colons some filesystems
  # and tools handle badly.
  def stamp(time)
    parsed = time ? Time.iso8601(time.to_s) : Time.now
    parsed.utc.strftime('%Y%m%dT%H%M%SZ')
  rescue ArgumentError
    Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
  end

  # Exclusive create, so two runs finishing in the same second never pick the
  # same archive name: the loser of the race gets EEXIST and tries the next.
  def reserve_and_write(stamp, body)
    (0..).each do |suffix|
      path = File.join(dir, suffix.zero? ? "#{stamp}.json" : "#{stamp}-#{suffix}.json")
      File.open(path, File::WRONLY | File::CREAT | File::EXCL) { |f| f.write(body) }
      return path
    rescue Errno::EEXIST
      next
    end
  end

  def atomic_write(path, body)
    temp = "#{path}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp"
    File.write(temp, body)
    File.rename(temp, path)
  end

  def prune
    excess = records.size - RETAIN
    # rm_f: an overlapping writer may have pruned the same oldest file first.
    records.first(excess).each { |path| FileUtils.rm_f(path) } if excess.positive?
  end
end
