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
    Install::SettingsFile.new(@settings, managed_dir: @bin)
                         .wire("SessionStart" => "ruby #{@bin}/session_start.rb")
    JSON.parse(File.read(@settings))["hooks"]
  end

  def commands(section)
    Array(section).flat_map { |g| Array(g["hooks"]).map { |h| h["command"] } }
  end

  def test_sweeps_managed_hook_from_an_event_it_does_not_wire
    hooks = wire("hooks" => {
                   "PreToolUse" => [ { "hooks" => [ { "type" => "command", "command" => "ruby #{@bin}/pst-guard.rb" } ] } ]
                 })
    refute hooks.key?("PreToolUse"), "stale managed hook in an unwired event should be removed"
  end

  def test_preserves_unmanaged_hooks
    sonar = "/Users/pst/code/sonar/exe/sonar hook"
    hooks = wire("hooks" => { "Stop" => [ { "hooks" => [ { "type" => "command", "command" => sonar } ] } ] })
    assert_includes commands(hooks["Stop"]), sonar
  end

  def test_wires_target_event_without_duplicating_on_reinstall
    first = wire
    again = Install::SettingsFile.new(@settings, managed_dir: @bin)
    again.wire("SessionStart" => "ruby #{@bin}/session_start.rb")
    hooks = JSON.parse(File.read(@settings))["hooks"]
    assert_equal 1, commands(hooks["SessionStart"]).size
    assert_equal 1, commands(first["SessionStart"]).size
  end
end

class InstallerTest < Minitest::Test
  HOOK_SCRIPTS = %w[
    session_start.rb merge_mode_guard.rb merge_mode_record.rb merge_mode_restate.rb
    skill_detect.rb skill_inject.rb skill_review.rb slop_remind.rb glyph_guard.rb
  ].freeze
  EVENTS = %w[SessionStart PreToolUse PostToolUse UserPromptSubmit Stop].freeze

  def setup
    @home = Dir.mktmpdir
    @repo = File.expand_path("..", __dir__)
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def install
    paths = Install::Paths.new(repo: @repo, home: @home)
    capture_io { Install::Installer.new(paths: paths, ruby: "/usr/bin/ruby").install }
    paths
  end

  def test_copies_every_hook_script_as_executable
    paths = install
    HOOK_SCRIPTS.each do |name|
      dest = paths.script_dest(name)
      assert File.exist?(dest), "#{name} was not copied into bin"
      assert File.executable?(dest), "#{name} should be executable"
    end
  end

  def test_links_every_skill_to_its_repo_source
    paths = install
    paths.skill_sources.each do |source|
      link = paths.skill_link(Install::SkillName.of(source))
      assert File.symlink?(link), "#{File.basename(source)} skill should be a symlink"
      assert_equal source, File.readlink(link)
    end
  end

  def test_links_the_auto_skills_under_the_namespace_keeping_pst_plain
    paths = install
    linked = paths.skill_sources.map { |s| Install::SkillName.of(s) }
    assert_includes linked, "pst:ruby"
    assert_includes linked, "pst:refactoring"
    assert_includes linked, "pst", "the namespace root stays unprefixed, not pst:pst"
  end

  def test_namespace_lives_only_in_frontmatter_not_the_directory
    paths = install
    plain = paths.skill_sources.map { |s| File.basename(s) }
    refute(plain.any? { |base| base.include?(":") }, "on-disk skill dirs must stay colon-free")
  end

  def test_prunes_a_managed_link_whose_source_is_gone
    paths = install
    stale = paths.skill_link("pst:renamed")
    File.symlink(File.join(paths.skills_dir, "renamed"), stale)
    install
    refute File.symlink?(stale), "a link into the repo skills dir with no current source should be pruned"
  end

  def test_leaves_unmanaged_skill_entries_alone
    paths = install
    real = paths.skill_link("vendor-skill")
    FileUtils.mkdir_p(real)
    foreign_target = Dir.mktmpdir
    foreign = paths.skill_link("foreign")
    File.symlink(foreign_target, foreign)
    install
    assert File.directory?(real), "a real (non-symlink) skill dir must be left alone"
    assert File.symlink?(foreign), "a link pointing outside the repo must be left alone"
  ensure
    FileUtils.remove_entry(foreign_target) if foreign_target
  end

  def test_wires_every_event_with_the_interpreter_path
    paths = install
    hooks = JSON.parse(File.read(paths.settings))["hooks"]
    assert_equal EVENTS.sort, hooks.keys.sort
    command = hooks["SessionStart"].dig(0, "hooks", 0, "command")
    assert_equal "/usr/bin/ruby #{paths.script_dest('session_start.rb')}", command
  end

  def test_backs_up_existing_settings_and_stays_idempotent
    paths = install
    install
    hooks = JSON.parse(File.read(paths.settings))["hooks"]
    counts = EVENTS.map { |event| hooks[event].sum { |group| group["hooks"].size } }
    assert_equal [ 2, 3, 2, 1, 1 ], counts
    assert File.exist?("#{paths.settings}.bak"), "second install should back up settings"
  end
end
