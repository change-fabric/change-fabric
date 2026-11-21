# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require "stringio"
require_relative "../scripts/change_backup_probe_gen"
require_relative "../scripts/change_apps"

# The generated weekly restore-probe workflow (spec 0.30.0).
class ChangeBackupProbeGenTest < Minitest::Test
  Gen = ChangeBackupProbeGen
  FIXTURE = File.expand_path("fixtures/prod/valid.yml", __dir__)
  GOLDEN = File.expand_path("fixtures/prod/cf-restore-probe.golden.yml", __dir__)

  def config = YAML.safe_load_file(FIXTURE)

  def test_matches_the_golden_file
    assert_equal File.read(GOLDEN), Gen.generate(config)
  end

  def test_is_a_weekly_schedule_with_a_manual_trigger_and_read_only_contents
    doc = YAML.safe_load(Gen.generate(config))
    triggers = doc[true] || doc["on"] # Psych reads a bare `on` key as true
    assert_equal [ { "cron" => "17 5 * * 1" } ], triggers["schedule"]
    assert triggers.key?("workflow_dispatch")
    assert_equal({ "contents" => "read" }, doc["permissions"])
    assert_equal false, doc["concurrency"]["cancel-in-progress"]
  end

  def test_one_job_per_backup_and_profile_with_a_literal_role
    jobs = YAML.safe_load(Gen.generate(config))["jobs"]
    assert_equal [ "probe-main_db-production" ], jobs.keys
    job = jobs.values.first
    assert_equal({ "id-token" => "write", "contents" => "read" }, job["permissions"])
    assert_equal "arn:aws:iam::222222222222:role/cf-probe", job["steps"].find { |step| step["uses"].to_s.start_with?("aws-actions") }["with"]["role-to-assume"]
    assert_match(/default_branch/, job["if"])
  end

  def test_the_result_is_uploaded_even_when_the_probe_fails
    step = YAML.safe_load(Gen.generate(config))["jobs"].values.first["steps"].last
    assert_equal "always()", step["if"]
    assert_equal "cf-probe-main_db-production", step["with"]["name"]
    assert_equal "error", step["with"]["if-no-files-found"]
  end

  def test_the_probe_step_calls_the_vendored_script_on_the_base_checkout
    run = YAML.safe_load(Gen.generate(config))["jobs"].values.first["steps"].find { |step| step["run"] }["run"]
    assert_includes run, "base/.github/cf-prod/scripts/change_backup.rb probe"
    assert_includes run, "--backup main_db --environment production"
    assert_includes ChangeProdRunnerGen::VENDORED, "change_backup.rb"
  end

  def test_backups_that_differ_only_by_underscore_keep_distinct_jobs
    cfg = config
    cfg["change_config"]["backups"]["main-db"] = cfg["change_config"]["backups"]["main_db"].dup
    assert_equal %w[probe-main-db-production probe-main_db-production], YAML.safe_load(Gen.generate(cfg))["jobs"].keys.sort
  end

  def test_refuses_two_probes_that_would_share_a_job_id
    cfg = config
    probe = cfg["change_config"]["backups"]["main_db"]
    cfg["change_config"]["backups"]["main"] = probe.merge("restore_probe" => probe["restore_probe"].merge("oidc_roles" => { "db-production" => "arn:aws:iam::222222222222:role/cf-probe" }))
    cfg["change_config"]["backups"]["main-db"] = probe
    error = assert_raises(Gen::Refused) { Gen.generate(cfg) }
    assert_match(/share one job id/, error.message)
  end

  def test_refuses_with_no_probe_roles
    cfg = config
    cfg["change_config"]["backups"]["main_db"]["restore_probe"].delete("oidc_roles")
    error = assert_raises(Gen::Refused) { Gen.generate(cfg) }
    assert_match(/no backup declares/, error.message)
  end

  def test_refuses_a_bad_role_or_region
    cfg = config
    cfg["change_config"]["backups"]["main_db"]["restore_probe"]["oidc_roles"]["production"] = "role/x\n  - run: evil"
    assert_raises(Gen::Refused) { Gen.generate(cfg) }
    cfg = config
    cfg["change_config"]["runners"]["prod"]["region"] = "us east"
    assert_raises(Gen::Refused) { Gen.generate(cfg) }
  end

  def test_detects_a_hand_edit_and_drift
    text = Gen.generate(config)
    refute Gen.tampered?(text)
    assert Gen.tampered?(text.sub("ubuntu-24.04", "ubuntu-latest"))
    assert Gen.tampered?("name: x")
    refute Gen.drifted?(text, config)
    cfg = config
    cfg["change_config"]["backups"]["main_db"]["restore_probe"]["oidc_roles"]["production"] = "arn:aws:iam::222222222222:role/other"
    assert Gen.drifted?(text, cfg)
  end

  def test_trust_condition_pins_the_default_branch_and_this_workflow
    line = Gen.trust_policy(config, sub_prefix: "repo:acme@1/widgets@2").first
    assert_includes line, "role/cf-probe"
    assert_includes line, "repo:acme@1/widgets@2:ref:refs/heads/main:job_workflow_ref:acme/widgets/.github/workflows/cf-restore-probe.yml@refs/heads/main"
    assert_includes line, "sts.amazonaws.com"
  end

  def test_cli_writes_vendors_and_then_checks
    Dir.mktmpdir do |root|
      out = StringIO.new
      assert_equal 0, Gen.run([ "--config", FIXTURE, "--root", root ], stdout: out, stderr: StringIO.new)
      assert File.exist?(File.join(root, Gen::WORKFLOW))
      assert File.exist?(File.join(root, ".github/cf-prod/scripts/change_backup.rb"))
      assert_includes out.string, "trust condition"
      assert_equal 0, Gen.run([ "--config", FIXTURE, "--root", root, "--check" ], stdout: StringIO.new, stderr: StringIO.new)
      File.write(File.join(root, Gen::WORKFLOW), "edited")
      err = StringIO.new
      assert_equal 1, Gen.run([ "--config", FIXTURE, "--root", root, "--check" ], stdout: StringIO.new, stderr: err)
      assert_match(/edited by hand/, err.string)
    end
  end

  def test_check_flags_a_stale_vendored_script
    Dir.mktmpdir do |root|
      Gen.run([ "--config", FIXTURE, "--root", root ], stdout: StringIO.new, stderr: StringIO.new)
      File.write(File.join(root, ".github/cf-prod/scripts/change_backup.rb"), "# old")
      err = StringIO.new
      assert_equal 1, Gen.run([ "--config", FIXTURE, "--root", root, "--check" ], stdout: StringIO.new, stderr: err)
      assert_match(/vendored scripts/, err.string)
    end
  end

  # --- doctor ---------------------------------------------------------------------

  def doctor_lines(cfg, workflow: nil)
    Dir.mktmpdir do |root|
      path = File.join(root, "CHANGE.md")
      File.write(path, "---\n#{YAML.dump(cfg).delete_prefix("---\n")}---\n")
      if workflow
        FileUtils.mkdir_p(File.join(root, ".github/workflows"))
        File.write(File.join(root, Gen::WORKFLOW), workflow)
      end
      ChangeAppRegistry.send(:probe_workflow_lines, path, cfg)
    end
  end

  def test_doctor_is_quiet_for_a_generated_workflow
    assert_empty doctor_lines(config, workflow: Gen.generate(config))
  end

  def test_doctor_errors_on_a_hand_edited_workflow
    lines = doctor_lines(config, workflow: Gen.generate(config).sub("ubuntu-24.04", "ubuntu-latest"))
    assert_equal 1, lines.size
    assert_match(/error: .*cf-restore-probe.yml was edited by hand/, lines.first)
  end

  def test_doctor_warns_for_a_probe_that_no_workflow_runs
    cfg = config
    cfg["change_config"]["backups"]["main_db"]["restore_probe"].delete("oidc_roles")
    assert_equal [ "warning: prod backup main_db has a restore_probe but no oidc_roles, so no workflow runs it" ], doctor_lines(cfg)
  end
end
