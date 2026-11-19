# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "timeout"
require_relative "../install"

# Upgrading from a release that still wired the SessionStart key prompt: the
# stale entry must not block startup while its script is gone, and a reinstall
# must drop it on every host while every remaining SessionStart hook stays
# quick, silent about keys, and non-interactive.
class InstallUpgradeTest < Minitest::Test
  OLD = "key_enrollment_prompt.rb"
  KEY_TEXT = /enroll|expir|api key/i
  RUBY = RbConfig.ruby

  def setup
    @home = Dir.mktmpdir
    @project = File.join(@home, "project")
    FileUtils.mkdir_p(@project)
    @paths = Install::Paths.new(repo: File.expand_path("..", __dir__), home: @home)
  end

  def teardown = FileUtils.remove_entry(@home)

  def install = capture_io { Install::Installer.new(paths: @paths, ruby: RUBY).install }

  def stale_command = "#{RUBY} #{File.join(@paths.bin, OLD)}"

  def plant_stale_entry
    data = JSON.parse(File.read(@paths.settings))
    data["hooks"]["SessionStart"] << { "hooks" => [ { "type" => "command", "command" => stale_command } ] }
    File.write(@paths.settings, JSON.generate(data))
    FileUtils.rm_f(File.join(@paths.bin, OLD))
  end

  def session_start_commands(path)
    hooks = JSON.parse(File.read(path)).fetch("hooks", {})
    groups = hooks["SessionStart"] || hooks["sessionStart"] || []
    groups.flat_map { |group| group["hooks"] || [ group ] }.filter_map { |hook| hook["command"] || hook["bash"] }
  end

  def run_hook(command, event = {})
    payload = JSON.generate({ "session_id" => "upgrade", "sessionId" => "upgrade", "cwd" => @project,
                              "hook_event_name" => "SessionStart", "source" => "startup" }.merge(event))
    Timeout.timeout(10) do
      Open3.capture3({ "HOME" => @home }, command, stdin_data: payload, chdir: @project)
    end
  end

  def test_stale_entry_with_missing_script_never_blocks_startup
    install
    plant_stale_entry
    out, _err, status = run_hook(stale_command)
    refute_equal 2, status.exitstatus, "a missing hook script must stay a non-blocking error"
    assert_empty out
  end

  def test_reinstall_drops_the_stale_entry_and_keeps_the_rest
    install
    plant_stale_entry
    install
    [ @paths.settings, @paths.codex_hooks, @paths.copilot_hooks ].each do |path|
      refute_includes File.read(path), OLD, path
    end
    remaining = session_start_commands(@paths.settings)
    %w[skill_detect.rb ctx_session_start.rb doctrine_digest.rb secret_alert_poll.rb].each do |name|
      assert(remaining.any? { |c| c.include?(name) }, "#{name} still wired")
    end
    refute File.exist?(File.join(@paths.bin, OLD))
  end

  def test_every_remaining_session_start_hook_is_quick_and_silent_about_keys
    install
    plant_stale_entry
    install
    commands = [ @paths.settings, @paths.codex_hooks, @paths.copilot_hooks ].flat_map { |p| session_start_commands(p) }
    commands += %w[opencode pi].map { |host| "#{RUBY} #{File.join(@paths.runtime_bin, 'cf_host_hook.rb')} #{host} SessionStart" }
    refute_empty commands
    commands.each do |command|
      out, err, status = run_hook(command)
      assert status.success?, "#{command} failed: #{err}"
      refute_match KEY_TEXT, out, command
    end
  end

  # minitest/mock is not bundled; swap a singleton method for one block.
  def with_singleton(object, name, impl)
    original = object.method(name)
    object.singleton_class.send(:define_method, name, &impl)
    yield
  ensure
    object.singleton_class.send(:define_method, name, &original)
  end

  def manifest_entry(path)
    JSON.parse(File.read(File.join(@paths.runtime_root, "installation.json")))["entries"].find { |e| e["path"] == File.realpath(File.dirname(path)) + "/" + File.basename(path) }
  end

  def point_links_at_old_checkout(pi_target, oc_target)
    [ [ @paths.pi_extension_link, pi_target ], [ @paths.opencode_plugin_link, oc_target ] ].each do |link, target|
      FileUtils.rm_f(link)
      File.symlink(target, link)
    end
    path = File.join(@paths.runtime_root, "installation.json")
    data = JSON.parse(File.read(path))
    data["entries"].each do |entry|
      entry["link"] = pi_target if entry["path"].end_with?("/extensions/cf-hooks")
      entry["link"] = oc_target if entry["path"].end_with?("/plugins/cf-hooks.ts")
    end
    File.write(path, JSON.generate(data))
  end

  def test_old_recorded_links_are_replaced_by_runtime_copies
    install
    point_links_at_old_checkout("/old/Cellar/change-fabric/0.1.0/extensions/pi-cf-hooks",
                                "/old/Cellar/change-fabric/0.1.0/extensions/opencode-cf-hooks/index.ts")
    install
    assert_equal @paths.pi_extension_copy, File.readlink(@paths.pi_extension_link)
    assert_equal @paths.opencode_plugin_target, File.readlink(@paths.opencode_plugin_link)
    entry = manifest_entry(@paths.pi_extension_link)
    assert_equal @paths.pi_extension_copy, entry["link"]
  end

  def test_user_edited_link_is_kept_with_a_warning
    install
    mine = File.join(@home, "my-pi-extension")
    FileUtils.mkdir_p(mine)
    FileUtils.rm_f(@paths.pi_extension_link)
    File.symlink(mine, @paths.pi_extension_link)
    _out, err = install
    assert_equal mine, File.readlink(@paths.pi_extension_link)
    assert_includes err, @paths.pi_extension_link
    assert_nil manifest_entry(@paths.pi_extension_link)
    assert_equal @paths.opencode_plugin_target, File.readlink(@paths.opencode_plugin_link)
  end

  def backups
    Dir.glob(File.join(@paths.runtime_root, "backups", "extensions-*"))
  end

  def test_edited_and_added_extension_files_are_backed_up_not_deleted
    install
    edited = File.join(@paths.pi_extension_copy, "index.ts")
    added = File.join(@paths.opencode_plugin_copy, "mine.ts")
    File.write(edited, "// my edit\n")
    File.write(added, "// my addition\n")
    _out, err = install
    assert_equal 1, backups.size
    assert_equal "// my edit\n", File.read(File.join(backups.first, "pi-cf-hooks", "index.ts"))
    assert_equal "// my addition\n", File.read(File.join(backups.first, "opencode-cf-hooks", "mine.ts"))
    assert_includes err, edited
    assert_includes err, added
    assert_includes err, backups.first
    assert_equal 2, Dir.glob(File.join(backups.first, "**", "*")).count { |f| File.file?(f) }
    assert_equal File.binread(File.join(@paths.pi_extension_source, "index.ts")), File.binread(edited)
    refute File.exist?(added)
    assert Dir.glob("#{@paths.extensions_copy_root}/*.new-*").empty?
  end

  def test_a_second_backup_in_the_same_directory_never_overwrites_the_first
    install
    edited = File.join(@paths.pi_extension_copy, "index.ts")
    manifest = CfInstallManifest.new(path: File.join(@paths.runtime_root, "installation.json"), home: @home)
    dir = File.join(@paths.runtime_root, "backups", "extensions-fixed")
    File.write(edited, "// first edit\n")
    capture_io { Install::ExtensionCopy.new(source: @paths.pi_extension_source, dest: @paths.pi_extension_copy, label: "pi-cf-hooks", backup_dir: dir, manifest: manifest).sync }
    File.write(edited, "// second edit\n")
    capture_io { Install::ExtensionCopy.new(source: @paths.pi_extension_source, dest: @paths.pi_extension_copy, label: "pi-cf-hooks", backup_dir: dir, manifest: manifest).sync }
    kept = Dir.glob(File.join(dir, "pi-cf-hooks", "index.ts*")).map { |f| File.read(f) }
    assert_equal [ "// first edit\n", "// second edit\n" ], kept.sort
  end

  def test_unedited_rerun_creates_no_backup_and_prints_no_warning
    install
    _out, err = install
    assert_empty backups
    refute_includes err, "backed up"
  end

  def test_existing_directory_without_a_manifest_is_backed_up_whole
    FileUtils.mkdir_p(@paths.pi_extension_copy)
    File.write(File.join(@paths.pi_extension_copy, "index.ts"), "// pre-existing\n")
    install
    assert_equal "// pre-existing\n", File.read(File.join(backups.first, "pi-cf-hooks", "index.ts"))
  end

  def test_failed_staging_leaves_the_old_copy_and_links_untouched
    install
    before = Dir.glob(File.join(@paths.extensions_copy_root, "**", "*")).select { |f| File.file?(f) }.to_h { |f| [ f, File.binread(f) ] }
    links = [ File.readlink(@paths.pi_extension_link), File.readlink(@paths.opencode_plugin_link) ]
    real = FileUtils.method(:cp_r)
    boom = lambda do |src, dest, **opts|
      raise Errno::ENOSPC, "staging" if dest.to_s.include?(".new-")

      real.call(src, dest, **opts)
    end
    error = nil
    with_singleton(FileUtils, :cp_r, boom) { error = assert_raises(RuntimeError) { install } }
    assert_includes error.message, "could not stage"
    after = Dir.glob(File.join(@paths.extensions_copy_root, "**", "*")).select { |f| File.file?(f) }.to_h { |f| [ f, File.binread(f) ] }
    assert_equal before, after
    assert_equal links, [ File.readlink(@paths.pi_extension_link), File.readlink(@paths.opencode_plugin_link) ]
    assert Dir.glob("#{@paths.extensions_copy_root}/*.new-*").empty?
    assert_empty backups
  end
end
