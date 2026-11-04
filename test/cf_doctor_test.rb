# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../scripts/cf_doctor"
require_relative "../scripts/cf_install_manifest"
require_relative "../scripts/cf_cli"
require_relative "../install"

class CfDoctorTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir
  end

  def teardown = FileUtils.remove_entry(@home)

  def test_doctor_reports_missing_installation_without_claiming_discovery
    report = CfDoctor.new(home: @home).report(host: "codex", version: "0.166.0", probe: false)
    assert_equal "$cf-roast", report["invocation"]
    assert_equal 0, report.dig("skills", "files_present")
    assert_equal "not-probed", report.dig("skills", "host_discovery")
    refute report.dig("adapter", "configured")
    assert report["next_steps"].any? { |step| step.include?("/cf:roast") }
  end

  def test_manifest_preserves_modified_files_foreign_files_and_state
    managed = File.join(@home, "managed")
    modified = File.join(@home, "modified")
    state = File.join(@home, "state")
    [ managed, modified, state ].each { |file| File.write(file, "initial") }
    manifest = CfInstallManifest.new(path: File.join(@home, "installation.json"), home: @home)
    manifest.record([ managed, modified ])
    File.write(modified, "user change")
    assert_equal 1, manifest.plan.count { |row| row["action"] == "remove" }
    manifest.remove
    refute File.exist?(managed)
    assert_equal "user change", File.read(modified)
    assert File.exist?(state)
  end

  def test_manifest_does_not_follow_a_replaced_parent_directory
    directory = File.join(@home, "managed")
    FileUtils.mkdir_p(directory)
    path = File.join(directory, "file")
    File.write(path, "data")
    manifest = CfInstallManifest.new(path: File.join(@home, "installation.json"), home: @home)
    manifest.record([ path ])
    Dir.mktmpdir do |outside|
      FileUtils.remove_entry(directory)
      File.write(File.join(outside, "file"), "data")
      File.symlink(outside, directory)
      assert_equal "preserve-modified-or-missing", manifest.plan.first["action"]
      manifest.remove
      assert_equal "data", File.read(File.join(outside, "file"))
    end
  end

  def test_foreign_launcher_is_preserved_and_never_claimed_by_manifest
    launcher = File.join(@home, ".local/bin/cf")
    FileUtils.mkdir_p(File.dirname(launcher))
    File.write(launcher, "foreign tool")
    paths = Install::Paths.new(repo: File.expand_path("..", __dir__), home: @home)
    capture_io { Install::Installer.new(paths: paths, ruby: RbConfig.ruby).install }
    assert_equal "foreign tool", File.read(launcher)
    plan = CfInstallManifest.new(path: File.join(paths.runtime_root, "installation.json"), home: @home).plan
    refute plan.any? { |row| row["path"] == File.realpath(launcher) }
  end

  def test_real_install_doctor_and_uninstall_preserve_unrelated_configuration
    paths = Install::Paths.new(repo: File.expand_path("..", __dir__), home: @home)
    FileUtils.mkdir_p(File.dirname(paths.settings))
    foreign = { "hooks" => [ { "type" => "command", "command" => "echo foreign" } ] }
    File.write(paths.settings, JSON.generate("hooks" => { "Stop" => [ foreign ] }))
    capture_io { Install::Installer.new(paths: paths, ruby: RbConfig.ruby).install }
    report = CfDoctor.new(home: @home).report(host: "codex", version: "0.166.0", probe: false)
    assert_operator report.dig("skills", "files_present"), :>, 60
    assert report.dig("adapter", "configured")
    assert_equal "not-probed", report.dig("adapter", "active")
    launcher = File.join(@home, ".local/bin/cf")
    assert File.executable?(launcher)
    io = StringIO.new
    assert_equal 0, CfCli.run([ "uninstall" ], io: io, home: @home)
    assert File.file?(paths.codex_hooks)
    assert_equal 0, CfCli.run([ "uninstall", "--apply" ], io: StringIO.new, home: @home)
    assert_includes JSON.parse(File.read(paths.settings)).dig("hooks", "Stop"), foreign
    refute File.exist?(File.join(paths.runtime_bin, "cf_host_hook.rb"))
    refute File.exist?(launcher)
    remaining = JSON.parse(File.read(paths.settings)).fetch("hooks").values.flatten.flat_map { |row| row.fetch("hooks", []) }
    assert_equal [ "echo foreign" ], remaining.map { |hook| hook["command"] }
  end
end
