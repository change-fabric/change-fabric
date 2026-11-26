# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require_relative 'paths'

module Triage
  # journal.jsonl: the append-only record of dispatches (C2). Every row is one
  # fsynced line written under an exclusive flock. A dispatch is its rows
  # folded in order: `dispatch` (action id, cap reservation, session UUID,
  # grant), then `handshake`, then one terminal row (`result`, `dead`,
  # `parked`). A terminal row is final: a later row for the same action is
  # refused, which is the fence that stops a stale owner from mutating past it.
  class Journal
    TERMINAL = %w[result dead parked].freeze

    class Fenced < StandardError; end

    Dispatch = Struct.new(:id, :row, :handshake, :terminal, :escalated, keyword_init: true) do
      def finished? = !terminal.nil?
      def session = row['session_id']
      def repo = row['repo']
      def unit = row['unit']
      def at = Time.iso8601(row['at'])
    end

    def initialize(root: Paths.root, clock: -> { Time.now.utc })
      @root = root
      @clock = clock
    end

    def path = Paths.journal_file(@root)

    # Appends one row. A terminal row for an action that already has one, or a
    # non-dispatch row for an unknown action, raises Fenced and writes nothing.
    def append(row)
      locked do
        fence!(row)
        write_line(row.merge('at' => @clock.call.iso8601))
      end
    end

    def rows
      return [] unless File.file?(path)

      File.readlines(path).filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end

    def dispatches
      folded = {}
      rows.each { |row| fold(folded, row) }
      folded.values
    end

    def unfinished = dispatches.reject(&:finished?)
    def find(action_id) = dispatches.find { |dispatch| dispatch.id == action_id }

    private

    def fold(folded, row)
      id = row['action_id']
      case row['type']
      when 'dispatch' then folded[id] ||= Dispatch.new(id: id, row: row, escalated: false)
      when 'handshake' then folded[id]&.handshake ||= row
      when 'escalated' then folded[id]&.escalated = true
      when *TERMINAL then folded[id]&.terminal ||= row
      end
    end

    def fence!(row)
      id = row['action_id']
      current = dispatches.find { |dispatch| dispatch.id == id }
      raise Fenced, "dispatch #{id} already exists" if row['type'] == 'dispatch' && current
      return if row['type'] == 'dispatch'
      raise Fenced, "unknown dispatch #{id}" unless current
      raise Fenced, "dispatch #{id} is already #{current.terminal['type']}" if current.finished? && TERMINAL.include?(row['type'])
      raise Fenced, "dispatch #{id} is already #{current.terminal['type']}" if current.finished? && row['type'] == 'handshake'
    end

    def write_line(row)
      File.open(path, 'a') do |file|
        file.puts(JSON.generate(row))
        file.flush
        file.fsync
      end
    end

    def locked
      FileUtils.mkdir_p(@root)
      File.open(File.join(@root, 'journal.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end
  end
end
