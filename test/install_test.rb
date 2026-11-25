#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"

require_relative "../install"
require_relative "../scripts/cf_state"
require_relative "../scripts/change_lane_a11y"
require_relative "../scripts/walkthrough_diagram"
require_relative "../scripts/walkthrough_render"

class CfRubyPathTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def executable(*parts)
    path = File.join(@dir, *parts)
    FileUtils.mkdir_p(File.dirname(path))
    FileUtils.touch(path)
    FileUtils.chmod(0o755, path)
    path
  end

  def test_prefers_the_stable_opt_symlink_over_a_versioned_cellar_path
    cellar_ruby = executable("Cellar", "ruby", "3.4.5", "bin", "ruby")
    opt_ruby = executable("opt", "ruby", "bin", "ruby")

    assert_equal opt_ruby, CfRubyPath.stable(cellar_ruby)
  end

  def test_missing_opt_link_is_a_hard_error_naming_the_cellar_path_and_the_repair
    cellar_ruby = executable("Cellar", "ruby", "3.4.5", "bin", "ruby")

    error = assert_raises(CfRubyPath::UnstableInterpreter) { CfRubyPath.stable(cellar_ruby) }
    assert_includes error.message, cellar_ruby
    assert_includes error.message, "brew link ruby"
    assert_includes error.message, "opt/ruby/bin/ruby"
  end

  def test_a_non_homebrew_ruby_is_returned_unchanged
    rbenv_ruby = executable("rbenv", "versions", "3.4.10", "bin", "ruby")

    assert_equal rbenv_ruby, CfRubyPath.stable(rbenv_ruby)
  end

  def test_install_script_exits_before_writing_settings_for_an_unstable_ruby
    home = File.join(@dir, "home")
    FileUtils.mkdir_p(home)
    fake = executable("Cellar", "ruby", "3.4.5", "bin", "ruby")
    script = "require 'rbconfig'; RbConfig::CONFIG['bindir'] = #{File.dirname(fake).dump}; RbConfig::CONFIG['ruby_install_name'] = 'ruby'; " \
             "$PROGRAM_NAME = #{File.expand_path("../install.rb", __dir__).dump}; load $PROGRAM_NAME"
    _out, err, status = Open3.capture3({ "HOME" => home }, RbConfig.ruby, "-e", script)

    refute status.success?
    assert_includes err, "brew link ruby"
    refute File.exist?(File.join(home, ".claude", "settings.json"))
  end
end

class SettingsFileTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @bin = File.join(@dir, ".claude", "cf", "bin")
    @legacy_bin = File.join(@dir, ".claude", "pst", "bin")
    @settings = File.join(@dir, "settings.json")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def wire(initial = {})
    File.write(@settings, JSON.generate(initial)) unless initial.empty?
    Install::SettingsFile.new(@settings, managed_dir: @bin, legacy_dirs: [ @legacy_bin ])
                         .wire("SessionStart" => "ruby #{@bin}/session_start.rb")
    JSON.parse(File.read(@settings))["hooks"]
  end

  def commands(section)
    Array(section).flat_map { |g| Array(g["hooks"]).map { |h| h["command"] } }
  end

  def test_sweeps_managed_hook_from_an_event_it_does_not_wire
    hooks = wire("hooks" => {
                   "PreToolUse" => [ { "hooks" => [ { "type" => "command", "command" => "ruby #{@bin}/cf-guard.rb" } ] } ]
                 })
    refute hooks.key?("PreToolUse"), "stale managed hook in an unwired event should be removed"
  end

  def test_sweeps_legacy_bin_hook_entries_so_they_are_not_left_firing
    hooks = wire("hooks" => {
                   "PreToolUse" => [ { "hooks" => [ { "type" => "command", "command" => "ruby #{@legacy_bin}/glyph_guard.rb" } ] } ]
                 })
    refute hooks.key?("PreToolUse"), "a hook under the pre-rename ~/.claude/pst/bin must be swept"
    session = commands(hooks["SessionStart"])
    assert_equal 1, session.size
    assert_includes session.first, @bin
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
    review_gate.rb noreply_guard.rb ctx_session_start.rb
    doctrine_digest.rb docker_doctrine_guard.rb change_merge_guard.rb change_tag_guard.rb
    telemetry_emit.rb presence_probe.rb secret_alert_poll.rb secret_ack.rb
    mode_command.rb away_guard.rb away_restate.rb
    key_paste_guard.rb secrets_read_guard.rb prod_approval_guard.rb model_role_guard.rb
    resource_floor_guard.rb glyph_guard.rb
  ].freeze
  EVENTS = %w[SessionStart PreToolUse PostToolUse UserPromptSubmit Stop SessionEnd SubagentStart SubagentStop].freeze

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

  # The a11y lane reads its pinned axe-core bundle from a path relative to the
  # script's own directory, and refuses to fetch axe over the network when it
  # is missing. An install that shipped only the .rb files would turn every
  # a11y run into that named failure.
  # Each installed script copy resolves the registry from its own ../config.
  def test_installs_the_provider_registry_where_both_script_copies_look
    paths = install
    [ paths.bin, paths.runtime_bin ].each do |bin|
      registry = File.expand_path("../config/providers.yml", bin)
      assert File.exist?(registry), "providers.yml missing beside #{bin}"
      assert_equal File.read(paths.provider_registry), File.read(registry)
    end
  end

  # The gate reads its shipped defaults from its own ../config. The copy is named
  # *.defaults.yml so an install never overwrites the user's resource_floors.yml.
  def test_installs_resource_floor_defaults_beside_both_script_copies_without_touching_the_user_file
    user_file = File.join(@home, ".claude", "cf", "config", "resource_floors.yml")
    FileUtils.mkdir_p(File.dirname(user_file))
    File.write(user_file, "floors:\n  ram_mb: 8192\n")
    paths = install
    [ paths.bin, paths.runtime_bin ].each do |bin|
      copy = File.expand_path("../config/resource_floors.defaults.yml", bin)
      assert_equal File.read(paths.resource_floors), File.read(copy), "defaults missing beside #{bin}"
    end
    assert_equal "floors:\n  ram_mb: 8192\n", File.read(user_file)
  end

  def test_copies_the_vendored_run_time_assets_beside_the_scripts
    paths = install
    refute_empty paths.vendor_glob, "the repo should carry at least one vendored asset"
    paths.vendor_glob.each do |source|
      dest = paths.vendor_dest(source)
      assert File.exist?(dest), "#{source} was not copied into bin/vendor"
      assert_equal File.size(source), File.size(dest)
    end
  end

  # Hooks and the cf launcher run from the runtime bin, so the walkthrough
  # renderer resolves cursor.png there; it used to get only the .rb files.
  def test_runtime_bin_carries_the_vendored_assets_too
    paths = install
    cursor = WalkthroughRender::CURSOR_PNG.delete_prefix("#{File.join(@repo, 'scripts')}/")
    assert File.exist?(File.join(paths.runtime_bin, cursor)), "runtime bin is missing scripts/#{cursor}"
    paths.vendor_glob.each do |source|
      assert File.exist?(paths.vendor_dest(source, paths.runtime_bin)), "#{source} was not copied into the runtime bin"
    end
  end

  # Every file a script reads relative to its own __dir__ (a literal
  # File.join(__dir__, ...) or File.expand_path(..., __dir__) that resolves
  # inside scripts/) must sit at the same place in both installed bins. The
  # walkthrough JS helpers once shipped in neither.
  def test_every_dir_relative_file_a_script_loads_is_installed
    paths = install
    scripts = File.join(@repo, "scripts")
    needed = dir_relative_reads(scripts)
    assert_includes needed, File.join(scripts, "walkthrough_ease.js")
    needed.each do |path|
      relative = path.delete_prefix("#{scripts}/")
      [ paths.bin, paths.runtime_bin ].each do |bin|
        assert File.exist?(File.join(bin, relative)), "#{bin} is missing scripts/#{relative}"
      end
    end
  end

  def dir_relative_reads(scripts)
    found = Dir.glob(File.join(scripts, "**", "*.rb")).flat_map do |file|
      src = File.read(file)
      dir = File.dirname(file)
      joins = src.scan(/File\.join\(__dir__,\s*((?:'[^'#]*'\s*,?\s*)+)\)/).map do |(args)|
        File.join(dir, *args.scan(/'([^']*)'/).flatten)
      end
      joins + src.scan(/File\.expand_path\('([^'#]*)',\s*__dir__\)/).map { |(rel)| File.expand_path(rel, dir) }
    end
    found.uniq.select { |path| path.start_with?("#{scripts}/") && File.file?(path) }
  end

  def test_the_installed_axe_bundle_is_where_the_a11y_lane_looks_for_it
    paths = install
    relative = ChangeLaneA11y::AXE_BUNDLE.delete_prefix("#{File.join(@repo, 'scripts')}/")
    assert File.exist?(File.join(paths.bin, relative)),
           "the a11y lane resolves its bundle at scripts/#{relative}; install must mirror that layout"
  end

  # Diagram scenes inline the xyflow bundle, the Phosphor icon subset, and
  # their license files from the same scripts-relative layout, so install
  # must carry them all.
  def test_the_installed_xyflow_bundle_mirrors_the_scripts_layout
    paths = install
    bundle = WalkthroughDiagram::XYFLOW_BUNDLE.delete_prefix("#{File.join(@repo, 'scripts')}/")
    icons = WalkthroughDiagram::ICONS_DATA.delete_prefix("#{File.join(@repo, 'scripts')}/")
    [ bundle, "vendor/xyflow/LICENSES.txt", icons, "vendor/phosphor/LICENSE.txt" ].each do |relative|
      assert File.exist?(File.join(paths.bin, relative)), "install did not place scripts/#{relative}"
    end
  end

  def test_links_every_skill_to_its_compiled_claude_source
    paths = install
    paths.skill_sources.each do |source|
      link = paths.skill_link(Install::SkillName.of(source))
      assert File.symlink?(link), "#{File.basename(source)} skill should be a symlink"
      assert_equal File.join(paths.compiled_claude_root, Install::SkillName.of(source)), File.readlink(link)
    end
  end

  # cloud_icons.rb reads provider pack manifests from the installed
  # cf:diagram skill when it runs outside the repo.
  def test_installs_the_diagram_provider_pack_manifests
    paths = install
    Dir.glob(File.join(@repo, "skills", "diagram", "packs", "*.yml")).each do |src|
      dest = File.join(paths.skill_link("cf:diagram"), "packs", File.basename(src))
      assert File.exist?(dest), "install did not place #{File.basename(src)} with cf:diagram"
      assert_equal File.read(src), File.read(dest)
    end
  end

  def test_links_the_auto_skills_under_the_namespace_keeping_cf_plain
    paths = install
    linked = paths.skill_sources.map { |s| Install::SkillName.of(s) }
    assert_includes linked, "cf:ruby"
    assert_includes linked, "cf:refactoring"
    assert_includes linked, "cf:usability"
    assert_includes linked, "cf", "the namespace root stays unprefixed, not cf:cf"
  end

  def test_namespace_lives_only_in_frontmatter_not_the_directory
    paths = install
    plain = paths.skill_sources.map { |s| File.basename(s) }
    refute(plain.any? { |base| base.include?(":") }, "on-disk skill dirs must stay colon-free")
  end

  def test_prunes_a_managed_link_whose_source_is_gone
    paths = install
    stale = paths.skill_link("cf:renamed")
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
    assert_equal "/usr/bin/ruby #{paths.script_dest('skill_detect.rb')}", command
  end

  def test_wires_the_key_guards_first_in_their_events
    hooks = JSON.parse(File.read(install.settings))["hooks"]
    first = ->(event) { hooks[event].dig(0, "hooks", 0, "command") }
    assert first.call("UserPromptSubmit").end_with?("/key_paste_guard.rb")
    assert first.call("PreToolUse").end_with?("/secrets_read_guard.rb")
  end

  def test_backs_up_existing_settings_and_stays_idempotent
    paths = install
    install
    hooks = JSON.parse(File.read(paths.settings))["hooks"]
    counts = EVENTS.map { |event| hooks[event].sum { |group| group["hooks"].size } }
    assert_equal [ 5, 17, 5, 4, 2, 2, 2, 1 ], counts
    assert File.exist?("#{paths.settings}.bak"), "second install should back up settings"
  end

  def test_wires_the_pulse_stamp_for_claude_on_its_four_events
    hooks = JSON.parse(File.read(install.settings))["hooks"]
    %w[PostToolUse SubagentStart SubagentStop Stop].each do |event|
      commands = hooks.fetch(event).flat_map { |group| group["hooks"].map { |hook| hook["command"] } }
      assert_equal 1, commands.count { |command| command.end_with?("/pulse_stamp.rb") }, event
    end
    adapter = hooks["SubagentStart"].flat_map { |group| group["hooks"].map { |hook| hook["command"] } }
    assert adapter.any? { |command| command.include?("cf_host_hook.rb") }, "the adapter entry survives"
  end

  # C8: Pulse::ACTIVATED is true, so an install with every ready part present
  # engages; a missing part keeps the hook silent. Every trigger is run through
  # the installed hook.
  def pulse_hook(paths, event, extra = {})
    project = File.join(@home, "proj")
    FileUtils.mkdir_p(project)
    payload = { "hook_event_name" => event, "session_id" => "s-c8", "cwd" => project }.merge(extra)
    out, = Open3.capture2({ "HOME" => @home, "CF_STATE_HOME" => nil }, RbConfig.ruby, File.join(paths.runtime_bin, "pulse_stamp.rb"),
                          stdin_data: JSON.generate(payload))
    out
  end

  def engage_every_trigger(paths)
    project = File.join(@home, "proj")
    FileUtils.mkdir_p(project)
    record = CfState.new(host: "claude", project: project, session_id: "s-c8", root: File.join(@home, ".local", "state", "change-fabric"), home: @home)
    record.update({ "mode" => "admin-bypass", "availability" => "away" })
    plan = File.join(@home, ".claude", "cf", "plans", "a", "b")
    FileUtils.mkdir_p(plan)
    File.write(File.join(plan, "goal.md"), "Goal.\n")
    outputs = [ pulse_hook(paths, "SubagentStart", "agent_id" => "a1"), pulse_hook(paths, "SubagentStart", "agent_id" => "a2"),
                pulse_hook(paths, "PostToolUse", "tool_name" => "Workflow", "tool_input" => { "script" => "#{plan}/workflow.js" }),
                pulse_hook(paths, "PostToolUse", "tool_name" => "Bash", "tool_input" => { "run_in_background" => true }) ]
    [ outputs, record.pulse ]
  end

  def test_every_ready_part_is_installed_and_the_flag_is_on
    paths = install
    require_relative "../scripts/pulse_stamp"
    assert_empty PulseStamp.missing_parts(bin: paths.runtime_bin, home: @home)
    assert_includes File.read(File.join(paths.runtime_bin, "pulse_store.rb")), "ACTIVATED = true"
  end

  def test_install_with_every_part_and_trigger_dispatches
    paths = install
    outputs, record = engage_every_trigger(paths)
    assert outputs.any? { |out| out.include?("pulse engaged: arm watcher") }, outputs.inspect
    assert record["engaged_at"]
    assert record["arm_requested_at"]
  end

  def test_install_missing_one_part_stays_silent
    paths = install
    FileUtils.rm(File.join(paths.runtime_bin, "pulse_act.rb"))
    outputs, record = engage_every_trigger(paths)
    assert_equal [ "" ] * 4, outputs
    assert record["detected_trigger"], "the trigger is recorded"
    refute record["engaged_at"]
    assert_includes File.read(File.join(@home, ".claude", "cf", "logs", "pulse.log")), "pulse_act"
  end

  def test_upgrade_from_a_phase_3_install_dispatches_only_after_the_executor_lands
    paths = install
    FileUtils.rm(File.join(paths.runtime_bin, "pulse_act.rb"))
    outputs, = engage_every_trigger(paths)
    assert_equal [ "" ] * 4, outputs
    install
    assert pulse_hook(paths, "PostToolUse", "tool_name" => "Bash", "tool_input" => {}).include?("arm watcher")
  end

  def test_reinstall_leaves_an_unmanaged_file_in_bin_alone
    paths = install
    foreign = File.join(paths.bin, "inbox_store.rb")
    File.write(foreign, "# not part of this repo\n")

    install
    assert File.exist?(foreign), "a file bin/ never installed should survive a reinstall"
  end

  def test_reinstall_removes_a_script_this_installer_previously_placed_but_no_longer_ships
    paths = install
    ghost = paths.script_dest("ghost_script.rb")
    File.write(ghost, "# stands in for a script removed from scripts/\n")
    File.write(paths.manifest, "#{File.read(paths.manifest)}ghost_script.rb\n")

    install
    refute File.exist?(ghost), "a script this installer's own manifest names, but scripts/ no longer has, should be pruned"
  end

  def test_adds_claude_skills_to_pi_settings
    paths = install
    settings = JSON.parse(File.read(paths.pi_settings))
    assert_includes settings["skills"], paths.pi_skills_root
  end

  def test_retires_the_previously_wired_claude_skills_path_from_pi_settings
    paths = Install::Paths.new(repo: @repo, home: @home)
    FileUtils.mkdir_p(File.dirname(paths.pi_settings))
    user_path = File.join(@home, "my-pi-skills")
    variants = [ paths.skills_root, "#{paths.skills_root}/", File.join(paths.skills_root, "..", "skills") ]
    variants.each do |legacy|
      File.write(paths.pi_settings, JSON.generate("skills" => [ legacy, user_path ]))
      install
      skills = JSON.parse(File.read(paths.pi_settings))["skills"]
      refute_includes skills, legacy, "the Claude skills dir an earlier install wired (#{legacy}) should leave Pi"
      # "-path" entries are #309's exclusions of Codex shared copies, not wired dirs.
      assert_equal [ user_path, paths.pi_skills_root ], skills.reject { |path| path.start_with?("-") }
    end
  end

  def test_links_pi_hook_extension
    paths = install
    assert File.symlink?(paths.pi_extension_link), "Pi hook extension should be symlinked"
    assert_equal paths.pi_extension_copy, File.readlink(paths.pi_extension_link)
  end

  def cellar_repo
    repo = File.join(@home, "Cellar", "change-fabric", "9.9.9")
    FileUtils.mkdir_p(repo)
    %w[skills scripts config extensions].each { |dir| File.symlink(File.join(@repo, dir), File.join(repo, dir)) }
    repo
  end

  def test_links_point_at_runtime_copies_never_the_cellar
    repo = cellar_repo
    paths = Install::Paths.new(repo: repo, home: @home)
    capture_io { Install::Installer.new(paths: paths, ruby: "/usr/bin/ruby").install }
    root = paths.runtime_root
    [ paths.pi_extension_link, paths.opencode_plugin_link ].each do |link|
      target = File.readlink(link)
      assert target.start_with?("#{root}/"), "#{target} should live under #{root}"
      refute_includes target, "Cellar"
    end
    %w[pi-cf-hooks/index.ts opencode-cf-hooks/index.ts shared/cf-client.ts shared/mode-slug.ts].each do |rel|
      assert_equal File.binread(File.join(@repo, "extensions", rel)), File.binread(File.join(root, "extensions", rel))
    end
    markers = Dir.glob(File.join(@home, "**", ".cf-generated-from-claude"), File::FNM_DOTMATCH)
    refute_empty markers
    markers.each do |marker|
      text = File.read(marker)
      refute_includes text, "Cellar"
      refute_includes text, repo
      assert_match(%r{\Asource: skills/[^/\n]+\n\z}, text)
    end
  end

  def test_preserves_unmanaged_pi_extension_dir
    paths = Install::Paths.new(repo: @repo, home: @home)
    FileUtils.mkdir_p(paths.pi_extension_link)
    install
    assert File.directory?(paths.pi_extension_link), "unmanaged Pi extension dir should be preserved"
    refute File.symlink?(paths.pi_extension_link), "unmanaged Pi extension dir should not be replaced"
  end

  def test_links_opencode_hook_plugin
    paths = install
    assert File.symlink?(paths.opencode_plugin_link), "OpenCode hook plugin should be symlinked"
    assert_equal ".ts", File.extname(paths.opencode_plugin_link), "OpenCode only loads top-level .ts/.js plugins"
    assert_equal paths.opencode_plugin_target, File.readlink(paths.opencode_plugin_link)
    install
    assert_equal paths.opencode_plugin_target, File.readlink(paths.opencode_plugin_link)
  end

  def test_opencode_paths_follow_xdg_config_home
    xdg = File.join(@home, "xdg")
    paths = Install::Paths.new(repo: @repo, home: @home, xdg_config: xdg)
    assert_equal File.join(xdg, "opencode", "plugins", "cf-hooks.ts"), paths.opencode_plugin_link
    assert_equal File.join(xdg, "opencode", "skills"), paths.opencode_skills_root
    assert_equal File.join(xdg, "opencode", "opencode.jsonc"), paths.opencode_config
    assert_equal File.join(@home, ".config", "opencode", "plugins", "cf-hooks.ts"),
                 Install::Paths.new(repo: @repo, home: @home, xdg_config: "").opencode_plugin_link
  end

  def test_preserves_unmanaged_opencode_plugin_file
    paths = Install::Paths.new(repo: @repo, home: @home)
    FileUtils.mkdir_p(paths.opencode_plugins_root)
    File.write(paths.opencode_plugin_link, "// user plugin\n")
    install
    assert_equal "// user plugin\n", File.read(paths.opencode_plugin_link), "unmanaged OpenCode plugin should be preserved"
    refute File.symlink?(paths.opencode_plugin_link), "unmanaged OpenCode plugin should not be replaced"
  end

  def test_mirrors_portable_skill_names_to_opencode
    paths = install
    translated = File.join(paths.opencode_skills_root, "cf-typescript", "SKILL.md")
    assert File.exist?(translated), "OpenCode should get a translated skill copy"
    frontmatter = File.read(translated).match(/\A---\n(.*?)\n---/m)[1]
    assert_includes frontmatter, "name: cf-typescript"
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

  def test_mirrors_portable_skill_names_to_copilot
    paths = install
    translated = File.join(paths.copilot_skills_root, "cf-typescript", "SKILL.md")
    assert File.exist?(translated), "Copilot should get a translated skill copy"
    assert_includes File.read(translated).match(/\A---\n(.*?)\n---/m)[1], "name: cf-typescript"
  end

  def test_codex_discovers_every_skill_with_portable_metadata_and_resources
    paths = install
    assert_equal File.join(@home, ".agents", "skills"), paths.codex_skills_root
    paths.skill_sources.each do |source|
      dest = paths.codex_skill(Install::SkillName.of(source))
      front, = SkillRegistry::Frontmatter.split(File.read(File.join(dest, "SKILL.md")))
      meta = YAML.safe_load(front)
      assert_match(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, meta.fetch("name"))
      refute_empty meta.fetch("description")
      Dir.glob(File.join(source, "**", "*")).select { |p| File.file?(p) }.each do |file|
        assert File.file?(File.join(dest, file.delete_prefix("#{source}/"))), "missing resource #{file}"
      end
    end
  end

  def test_codex_mode_overrides_replace_claude_hook_assumptions
    paths = install
    %w[cf merge-ready local-only admin-bypass yolo active away].each do |mode|
      name = mode == "cf" ? "cf" : "cf:#{mode}"
      text = File.read(File.join(paths.codex_skill(name), "SKILL.md"))
      refute_includes text, "has already persisted"
      refute_includes text, "AskUserQuestion"
      refute_match(%r{/cf(?::|\b)}, text)
      assert_includes text, "$#{Install::SkillName.portable(name)}"
    end
  end

  def test_codex_mirror_survives_reinstall_and_only_prunes_owned_skills
    paths = install
    target = File.join(paths.codex_skill("cf:merge-ready"), "SKILL.md")
    expected = File.read(target)
    File.write(target, "stale generated copy")
    stale = paths.codex_skill("cf:removed")
    FileUtils.mkdir_p(stale)
    File.write(File.join(stale, Install::PortableSkillMirror::MARKER), "source: old\n")
    custom = paths.codex_skill("custom")
    collision = paths.codex_skill("cf:ruby")
    FileUtils.mkdir_p(custom)
    FileUtils.remove_entry(collision)
    FileUtils.mkdir_p(collision)
    File.write(File.join(collision, "SKILL.md"), "user-owned skill\n")

    install
    assert_equal expected, File.read(target)
    refute File.exist?(stale)
    assert File.directory?(custom)
    assert_equal "user-owned skill\n", File.read(File.join(collision, "SKILL.md"))
  end

  def test_codex_translates_commands_without_rewriting_hook_paths
    paths = install
    text = File.read(File.join(paths.codex_skill("cf:design"), "SKILL.md"))
    original = File.read(File.join(@repo, "skills", "design", "SKILL.md"))
    original.scan(%r{[\w~./-]+/cf/[\w./-]+}).each do |path|
      assert_includes text, path
    end
    refute_match(%r{`/cf:}, text)
  end

  def test_copilot_mirror_is_idempotent_and_prunes_stale
    paths = Install::Paths.new(repo: @repo, home: @home)
    stale = File.join(paths.copilot_skills_root, "gone")
    FileUtils.mkdir_p(stale)
    File.write(File.join(stale, ".cf-generated-from-claude"), "source: old\n")
    custom = File.join(paths.copilot_skills_root, "custom")
    FileUtils.mkdir_p(custom)
    install
    before = Dir.glob(File.join(paths.copilot_skills_root, "*")).sort
    install
    assert_equal before, Dir.glob(File.join(paths.copilot_skills_root, "*")).sort
    refute File.exist?(stale), "stale generated Copilot skill should be pruned"
    assert File.directory?(custom), "unmanaged Copilot skills should be left alone"
  end

  def test_refreshes_owned_pi_copies_of_managed_skills
    paths = Install::Paths.new(repo: @repo, home: @home)
    stale = File.join(paths.legacy_pi_roots.first, "cf-typescript")
    FileUtils.mkdir_p(stale)
    File.write(File.join(stale, "SKILL.md"), "---\nname: cf:typescript\ndescription: Old copy\n---\n")
    File.write(File.join(stale, Install::PortableSkillMirror::MARKER), "source: old\n")
    install
    refute_includes File.read(File.join(stale, "SKILL.md")), "Old copy"
  end

  def test_preserves_unmanaged_pi_skill_dirs
    paths = Install::Paths.new(repo: @repo, home: @home)
    custom = File.join(paths.legacy_pi_roots.first, "custom")
    FileUtils.mkdir_p(custom)
    File.write(File.join(custom, "SKILL.md"), "---\nname: custom\ndescription: Custom\n---\n")
    install
    assert File.directory?(custom), "unmanaged Pi skills should be left alone"
  end

  # The legacy `.pst-generated` marker from a pre-rename install must still be
  # recognized so those old mirrors are pruned; it stays in LEGACY_MARKERS.
  def test_prunes_legacy_pst_marked_opencode_dirs
    paths = Install::Paths.new(repo: @repo, home: @home)
    stale = File.join(paths.opencode_skills_root, "legacy-old")
    FileUtils.mkdir_p(stale)
    File.write(File.join(stale, ".pst-generated"), "source: old\n")
    install
    refute File.exist?(stale), "legacy generated OpenCode skill mirror should be removed"
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

# Exercises the pre-rename state-root carry-over against a temp HOME only; the
# real ~/.claude is never touched.
class StateRootMigrationTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir
    @repo = File.expand_path("..", __dir__)
    @legacy = File.join(@home, ".claude", "pst")
    @current = File.join(@home, ".claude", "cf")
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def install
    paths = Install::Paths.new(repo: @repo, home: @home)
    capture_io { Install::Installer.new(paths: paths, ruby: "/usr/bin/ruby").install }
    paths
  end

  def test_moves_legacy_state_root_to_the_cf_location
    FileUtils.mkdir_p(File.join(@legacy, "teams"))
    File.write(File.join(@legacy, "teams", "marker"), "carry me over\n")
    install
    refute File.exist?(@legacy), "legacy ~/.claude/pst should be gone after migration"
    moved = File.join(@current, "teams", "marker")
    assert File.exist?(moved), "state should now live under ~/.claude/cf"
    assert_equal "carry me over\n", File.read(moved)
  end

  def test_is_a_no_op_when_both_roots_already_exist
    FileUtils.mkdir_p(@legacy)
    File.write(File.join(@legacy, "marker"), "legacy\n")
    FileUtils.mkdir_p(@current)
    File.write(File.join(@current, "marker"), "current\n")
    install
    assert File.exist?(File.join(@legacy, "marker")), "legacy root must be left untouched"
    assert_equal "legacy\n", File.read(File.join(@legacy, "marker"))
    assert_equal "current\n", File.read(File.join(@current, "marker"))
  end
end

# Exercises the retroactive merge-mode slug migration against a temp HOME only;
# the real ~/.claude is never touched.
class MergeModeSlugMigrationTest < Minitest::Test
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

  def session_file(name)
    File.join(@home, ".claude", "cf", "sessions", name, "merge-mode")
  end

  def seed(name, content)
    FileUtils.mkdir_p(File.dirname(session_file(name)))
    File.write(session_file(name), content)
  end

  def test_migrates_legacy_labels_and_leaves_unrecognized_content_untouched
    seed("a", "Local only")
    seed("b", "Admin bypass (recommended)")
    seed("c", "yolo")
    seed("d", "something else entirely")

    install

    assert_equal "local-only", File.read(session_file("a")).strip
    assert_equal "admin-bypass", File.read(session_file("b")).strip
    assert_equal "yolo", File.read(session_file("c")).strip
    assert_equal "something else entirely", File.read(session_file("d")).strip
  end

  def test_second_run_is_a_no_op
    seed("a", "Local only")
    seed("b", "Admin bypass (recommended)")
    seed("c", "yolo")
    seed("d", "something else entirely")

    install
    install

    assert_equal "local-only", File.read(session_file("a")).strip
    assert_equal "admin-bypass", File.read(session_file("b")).strip
    assert_equal "yolo", File.read(session_file("c")).strip
    assert_equal "something else entirely", File.read(session_file("d")).strip
  end
end
