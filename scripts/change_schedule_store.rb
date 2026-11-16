#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

# The time-keyed record store for scheduled runs (0.19.0, unreleased). One
# directory per (schedule, profile) under ~/.claude/cf/change/schedules, one
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

  def initialize(schedule, profile, root: self.class.default_root)
    @schedule = schedule.to_s
    @profile = profile.to_s
    @root = root
  end

  def dir = File.join(@root, "#{@schedule}__#{@profile}")
  def latest_path = File.join(dir, LATEST)

  # Writes one run's record, repoints latest.json at it, prunes past RETAIN,
  # and returns the record's path.
  def write(record)
    FileUtils.mkdir_p(dir)
    path = unique_path(stamp(record['finished_at']))
    body = JSON.pretty_generate(record)
    File.write(path, body)
    atomic_write(latest_path, body)
    prune
    path
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

  def unique_path(stamp)
    path = File.join(dir, "#{stamp}.json")
    suffix = 1
    while File.exist?(path)
      path = File.join(dir, "#{stamp}-#{suffix}.json")
      suffix += 1
    end
    path
  end

  def atomic_write(path, body)
    temp = "#{path}.#{Process.pid}.tmp"
    File.write(temp, body)
    File.rename(temp, path)
  end

  def prune
    excess = records.size - RETAIN
    records.first(excess).each { |path| File.delete(path) } if excess.positive?
  end
end
