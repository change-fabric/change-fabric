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
end
