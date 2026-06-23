#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"

require_relative "../install"

class SettingsFileTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @bin = File.join(@dir, ".claude", "pst", "bin")
    @settings = File.join(@dir, "settings.json")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def wire(initial = {})
    File.write(@settings, JSON.generate(initial)) unless initial.empty?
    SettingsFile.new(@settings, managed_dir: @bin)
                .wire("SessionStart" => "ruby #{@bin}/session_start.rb")
    JSON.parse(File.read(@settings))["hooks"]
  end

  def commands(section)
    Array(section).flat_map { |g| Array(g["hooks"]).map { |h| h["command"] } }
  end

  def test_sweeps_managed_hook_from_an_event_it_does_not_wire
    hooks = wire("hooks" => {
      "PreToolUse" => [{ "hooks" => [{ "type" => "command", "command" => "ruby #{@bin}/pst-guard.rb" }] }]
    })
    refute hooks.key?("PreToolUse"), "stale managed hook in an unwired event should be removed"
  end

  def test_preserves_unmanaged_hooks
    sonar = "/Users/pst/code/sonar/exe/sonar hook"
    hooks = wire("hooks" => { "Stop" => [{ "hooks" => [{ "type" => "command", "command" => sonar }] }] })
    assert_includes commands(hooks["Stop"]), sonar
  end

  def test_wires_target_event_without_duplicating_on_reinstall
    first = wire
    again = SettingsFile.new(@settings, managed_dir: @bin)
    again.wire("SessionStart" => "ruby #{@bin}/session_start.rb")
    hooks = JSON.parse(File.read(@settings))["hooks"]
    assert_equal 1, commands(hooks["SessionStart"]).size
    assert_equal 1, commands(first["SessionStart"]).size
  end
end
