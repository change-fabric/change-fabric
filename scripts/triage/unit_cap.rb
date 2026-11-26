# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require_relative 'paths'

module Triage
  # The daily cap on model launches (C5): CF_TRIAGE_DAILY_CAP, default 20, per
  # host per America/Chicago day. A slot is reserved under a file lock before
  # every launch, recovery included, and never given back: a reservation whose
  # outcome is ambiguous after a crash stays counted. Ledger:
  # units/<YYYY-MM-DD>.jsonl, one row per reservation.
  class UnitCap
    DEFAULT = 20

    Reservation = Struct.new(:granted, :action_id, :used, :cap, :day, keyword_init: true)

    # The Chicago calendar date of a UTC time. US rules: CDT (UTC-5) from the
    # second Sunday of March 02:00 local to the first Sunday of November 02:00
    # local, CST (UTC-6) otherwise.
    def self.chicago_day(time)
      utc = time.utc
      offset = daylight?(utc) ? -5 : -6
      (utc + (offset * 3600)).strftime('%Y-%m-%d')
    end

    def self.daylight?(utc)
      start = nth_sunday(utc.year, 3, 2) + (8 * 3600)  # 02:00 CST is 08:00 UTC
      finish = nth_sunday(utc.year, 11, 1) + (7 * 3600) # 02:00 CDT is 07:00 UTC
      utc >= start && utc < finish
    end

    def self.nth_sunday(year, month, nth)
      first = Time.utc(year, month, 1)
      first + (((7 - first.wday) % 7) + ((nth - 1) * 7)) * 86_400
    end

    def self.configured
      value = Integer(ENV.fetch('CF_TRIAGE_DAILY_CAP', DEFAULT.to_s), 10)
      value.negative? ? DEFAULT : value
    rescue ArgumentError
      DEFAULT
    end

    def initialize(root: Paths.root, clock: -> { Time.now.utc }, cap: self.class.configured)
      @root = root
      @clock = clock
      @cap = cap
    end

    # Reserves a slot for action_id, or refuses at the cap. Reserving the same
    # action id again is idempotent (a restart replaying a dispatch).
    def reserve(action_id)
      locked do |day|
        rows = read(day)
        next result(true, action_id, rows.size, day) if rows.any? { |row| row['action_id'] == action_id }
        next result(false, action_id, rows.size, day) if rows.size >= @cap

        append(day, 'action_id' => action_id, 'reserved_at' => @clock.call.iso8601)
        result(true, action_id, rows.size + 1, day)
      end
    end

    def used = read(self.class.chicago_day(@clock.call)).size
    attr_reader :cap

    def status = { 'day' => self.class.chicago_day(@clock.call), 'used' => used, 'cap' => @cap }

    private

    def result(granted, action_id, used, day) = Reservation.new(granted: granted, action_id: action_id, used: used, cap: @cap, day: day)

    def file(day) = File.join(Paths.units_dir(@root), "#{day}.jsonl")

    def read(day)
      return [] unless File.file?(file(day))

      File.readlines(file(day)).filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end

    def append(day, row)
      File.open(file(day), 'a') do |out|
        out.puts(JSON.generate(row))
        out.flush
        out.fsync
      end
    end

    def locked
      FileUtils.mkdir_p(Paths.units_dir(@root))
      File.open(File.join(Paths.units_dir(@root), 'cap.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield self.class.chicago_day(@clock.call)
      end
    end
  end
end
