# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../scripts/cf_doctor"
require_relative "../scripts/model_roles"
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

  def test_doctor_reports_the_project_change_md
    Dir.mktmpdir do |project|
      File.write(File.join(project, "CHANGE.md"), "---\nchange_config:\n  project: demo\n  lanes:\n    k6: { enabled: true }\n---\nbody\n")
      report = CfDoctor.new(home: @home).report(host: "codex", version: "0.166.0", probe: false, project: project)
      assert_equal File.join(project, "CHANGE.md"), report.dig("change_md", "path")
      assert report.dig("change_md", "ok")
      assert(report.dig("change_md", "lines").any? { |line| line.start_with?("policy: protected_branches") })
    end
  end

  def test_doctor_reports_a_broken_change_md_as_not_ok
    Dir.mktmpdir do |project|
      File.write(File.join(project, "CHANGE.md"), "---\nchange_policy: {}\n---\nbody\n")
      report = CfDoctor.new(home: @home).report(host: "codex", version: "0.166.0", probe: false, project: project)
      refute report.dig("change_md", "ok")
      assert_match(/change_config/, report.dig("change_md", "lines").join)
    end
  end

  def test_doctor_omits_change_md_when_the_project_has_none
    Dir.mktmpdir do |project|
      report = CfDoctor.new(home: @home).report(host: "codex", version: "0.166.0", probe: false, project: project)
      assert_nil report["change_md"]
    end
  end

  def drift_report(env)
    CfDoctor.new(home: @home, env: env).report(host: "claude", version: "2.1.0", probe: false)
  end

  def install_snapshot
    root = CfState.root(home: @home)
    ModelRoles.write_snapshot(host: "claude", path: ModelRoles.default_snapshot_path(root),
                              roles: ModelRoles.table(host: "claude", env: {}, user_file: nil), sources: {})
    root
  end

  def test_doctor_is_silent_about_model_roles_without_drift
    install_snapshot
    report = drift_report({})
    assert_empty report.dig("model_roles", "drift")
    refute(report["next_steps"].any? { |step| step.include?("model roles") })
  end

  def test_doctor_names_each_drifted_role_and_says_to_rerun_install
    install_snapshot
    report = drift_report("CF_MODEL_WORKER" => "opus", "CF_MODEL_CRITIC" => "haiku")
    line = report["next_steps"].find { |step| step.include?("model roles") }
    assert line, "doctor prints a drift line"
    assert_includes line, "worker sonnet -> opus"
    assert_includes line, "critic opus -> haiku"
    assert_includes line, "re-run ruby install.rb"
    assert_equal %w[worker critic].sort, report.dig("model_roles", "drift").keys.sort
  end

  def test_doctor_reports_user_file_drift
    root = install_snapshot
    File.write(ModelRoles.default_user_file(root), YAML.dump("hosts" => { "claude" => { "author" => "sonnet" } }))
    assert_equal [ "author" ], drift_report({}).dig("model_roles", "drift").keys
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
    pi_skills = JSON.parse(File.read(paths.pi_settings))["skills"]
    assert_includes pi_skills, "-#{File.join(paths.codex_skill('cf:roast'), 'SKILL.md')}"
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
    refute JSON.parse(File.read(paths.pi_settings))["skills"].any? { |entry| entry.start_with?("-") }
    remaining = JSON.parse(File.read(paths.settings)).fetch("hooks").values.flatten.flat_map { |row| row.fetch("hooks", []) }
    assert_equal [ "echo foreign" ], remaining.map { |hook| hook["command"] }
  end

  def test_uninstall_then_reinstall_regenerates_skills_and_keeps_the_original_backup
    paths = Install::Paths.new(repo: File.expand_path("..", __dir__), home: @home)
    FileUtils.mkdir_p(File.dirname(paths.settings))
    File.write(paths.settings, JSON.generate("theme" => "original"))
    capture_io { Install::Installer.new(paths: paths, ruby: RbConfig.ruby).install }
    backup = File.read("#{paths.settings}.bak")
    assert_equal 0, CfCli.run([ "uninstall", "--apply" ], io: StringIO.new, home: @home)
    assert_equal backup, File.read("#{paths.settings}.bak")
    assert Dir.exist?(File.dirname(paths.codex_skill("cf:roast"))), "the shared skills root stays"
    capture_io { Install::Installer.new(paths: paths, ruby: RbConfig.ruby).install }
    report = CfDoctor.new(home: @home).report(host: "codex", version: "0.166.0", probe: false)
    assert_operator report.dig("skills", "files_present"), :>, 60
  end

  def test_doctor_reads_opencode_from_xdg_config_home
    xdg = File.join(@home, "xdg")
    paths = Install::Paths.new(repo: File.expand_path("..", __dir__), home: @home, xdg_config: xdg)
    capture_io { Install::Installer.new(paths: paths, ruby: RbConfig.ruby).install }
    report = CfDoctor.new(home: @home, xdg_config: xdg).report(host: "opencode", probe: false)
    assert_operator report.dig("skills", "files_present"), :>, 60
    assert report.dig("adapter", "configured")
  end
end
