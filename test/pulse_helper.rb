# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "time"
require "stringio"

# Points HOME at a temp dir so session and budget state stay isolated.
module PulseHome
  def setup
    @home = Dir.mktmpdir
    @prev_home = ENV["HOME"]
    ENV["HOME"] = @home
    @session = "s1"
    @dir = File.join(@home, ".claude", "cf", "sessions", @session)
    FileUtils.mkdir_p(@dir)
  end

  def teardown
    ENV["HOME"] = @prev_home
    FileUtils.remove_entry(@home)
  end

  def write_events(*rows) = File.write(File.join(@dir, "pulse_events.jsonl"), rows.map { |r| "#{JSON.generate(r)}\n" }.join)

  def t(minutes) = Time.utc(2026, 11, 22, 12, 0, 0) + minutes * 60
end
