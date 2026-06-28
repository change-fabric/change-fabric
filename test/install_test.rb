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
    foreign = "/usr/local/bin/notify hook"
    hooks = wire("hooks" => { "Stop" => [ { "hooks" => [ { "type" => "command", "command" => foreign } ] } ] })
    assert_includes commands(hooks["Stop"]), foreign
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
    prune_remind.rb skill_detect.rb skill_inject.rb skill_review.rb slop_remind.rb
    glyph_guard.rb review_gate.rb noreply_guard.rb ctx_session_start.rb
    doctrine_digest.rb docker_doctrine_guard.rb
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
    assert_equal [ 4, 6, 2, 2, 1 ], counts
    assert File.exist?("#{paths.settings}.bak"), "second install should back up settings"
  end

  def test_adds_claude_skills_to_pi_settings
    paths = install
    settings = JSON.parse(File.read(paths.pi_settings))
    assert_includes settings["skills"], paths.skills_root
  end

  def test_links_pi_hook_extension
    paths = install
    assert File.symlink?(paths.pi_extension_link), "Pi hook extension should be symlinked"
    assert_equal paths.pi_extension_source, File.readlink(paths.pi_extension_link)
  end

  def test_preserves_unmanaged_pi_extension_dir
    paths = Install::Paths.new(repo: @repo, home: @home)
    FileUtils.mkdir_p(paths.pi_extension_link)
    install
    assert File.directory?(paths.pi_extension_link), "unmanaged Pi extension dir should be preserved"
    refute File.symlink?(paths.pi_extension_link), "unmanaged Pi extension dir should not be replaced"
  end

  def test_mirrors_portable_skill_names_to_opencode
    paths = install
    translated = File.join(paths.opencode_skills_root, "pst-typescript", "SKILL.md")
    assert File.exist?(translated), "OpenCode should get a translated skill copy"
    frontmatter = File.read(translated).match(/\A---\n(.*?)\n---/m)[1]
    assert_includes frontmatter, "name: pst-typescript"
    config = JSON.parse(File.read(paths.opencode_config))
    assert_includes config.dig("skills", "paths"), paths.opencode_skills_root
  end

  def test_preserves_unmanaged_opencode_skill_dirs
    paths = install
    custom = File.join(paths.opencode_skills_root, "custom")
    FileUtils.mkdir_p(custom)
    File.write(File.join(custom, "SKILL.md"), "---\nname: custom\ndescription: Custom\n---\n")
    install
    assert File.directory?(custom), "unmanaged OpenCode skills should be left alone"
  end

  def test_prunes_stale_pi_copies_of_managed_skills
    paths = Install::Paths.new(repo: @repo, home: @home)
    stale = File.join(paths.legacy_pi_roots.first, "pst-typescript")
    FileUtils.mkdir_p(stale)
    File.write(File.join(stale, "SKILL.md"), "---\nname: pst:typescript\ndescription: Old copy\n---\n")
    install
    refute File.exist?(stale), "managed stale Pi skill copy should be removed"
  end

  def test_preserves_unmanaged_pi_skill_dirs
    paths = Install::Paths.new(repo: @repo, home: @home)
    custom = File.join(paths.legacy_pi_roots.first, "custom")
    FileUtils.mkdir_p(custom)
    File.write(File.join(custom, "SKILL.md"), "---\nname: custom\ndescription: Custom\n---\n")
    install
    assert File.directory?(custom), "unmanaged Pi skills should be left alone"
  end

  def test_prunes_old_opencode_generated_marker_dirs
    paths = Install::Paths.new(repo: @repo, home: @home)
    stale = File.join(paths.opencode_skills_root, "pst-old")
    FileUtils.mkdir_p(stale)
    File.write(File.join(stale, ".pst-generated"), "source: old\n")
    install
    refute File.exist?(stale), "old generated OpenCode skill mirror should be removed"
  end

  def test_preserves_opencode_jsonc_strings_with_urls
    paths = Install::Paths.new(repo: @repo, home: @home)
    FileUtils.mkdir_p(File.dirname(paths.opencode_config))
    File.write(paths.opencode_config, %({\n  "$schema": "https://opencode.ai/config.json",\n  // comment\n  "share": "disabled",\n  "username": "quote: \\\" // not a comment"\n}\n))
    install
    config = JSON.parse(File.read(paths.opencode_config))
    assert_equal "https://opencode.ai/config.json", config["$schema"]
    assert_equal "disabled", config["share"]
    assert_equal "quote: \" // not a comment", config["username"]
  end

  def test_jsonc_stripper_removes_line_and_block_comments
    text = %({\n  // line\n  "a": 1, /* block */\n  /* multi\n     line */ "b": 2\n})
    assert_equal({ "a" => 1, "b" => 2 }, JSON.parse(Install::JsoncStripper.strip(text)))
  end

  def test_jsonc_stripper_keeps_comment_markers_inside_strings
    text = %({ "u": "http://x", "c": "/* not a comment */", "e": "esc \\" // still string" })
    parsed = JSON.parse(Install::JsoncStripper.strip(text))
    assert_equal "http://x", parsed["u"]
    assert_equal "/* not a comment */", parsed["c"]
    assert_equal "esc \" // still string", parsed["e"]
  end
end
