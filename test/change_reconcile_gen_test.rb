# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require "stringio"
require_relative "../scripts/change_reconcile_gen"
require_relative "../scripts/change_apps"

# The generated maintenance reconciler workflow (spec 0.31.0).
class ChangeReconcileGenTest < Minitest::Test
  Gen = ChangeReconcileGen
  FIXTURE = File.expand_path("fixtures/prod/valid.yml", __dir__)
  GOLDEN = File.expand_path("fixtures/prod/cf-prod-reconcile.golden.yml", __dir__)

  def config = YAML.safe_load_file(FIXTURE)

  def doc = YAML.safe_load(Gen.generate(config))

  def test_matches_the_golden_file
    assert_equal File.read(GOLDEN), Gen.generate(config)
  end

  def test_runs_every_ten_minutes_with_a_manual_trigger_and_no_cancel
    triggers = doc[true] || doc["on"]
    assert_equal [ { "cron" => "*/10 * * * *" } ], triggers["schedule"]
    assert triggers.key?("workflow_dispatch")
    assert_equal false, doc["concurrency"]["cancel-in-progress"]
  end

  def test_one_job_on_the_default_branch_with_its_own_role_and_no_environment
    job = doc["jobs"]["reconcile"]
    assert_match(/default_branch/, job["if"])
    refute job.key?("environment"), "the reconciler must never share an Environment with an op"
    assert_equal "arn:aws:iam::333333333333:role/cf-prod-reconcile", job["steps"].find { |step| step["uses"].to_s.start_with?("aws-actions") }["with"]["role-to-assume"]
    refute_includes Gen.generate(config), "role/cf-prod\""
  end

  def test_the_reconcile_step_calls_the_vendored_script_on_the_base_checkout
    run = doc["jobs"]["reconcile"]["steps"].find { |step| step["run"] }["run"]
    assert_includes run, "base/.github/cf-prod/scripts/change_maintenance.rb reconcile"
    assert_includes ChangeProdRunnerGen::VENDORED, "change_maintenance.rb"
  end

  def test_refuses_without_a_valid_reconcile_role_or_region
    cfg = config
    cfg["change_config"]["runners"]["prod"].delete("reconcile_role")
    assert_raises(Gen::Refused) { Gen.generate(cfg) }
    cfg["change_config"]["runners"]["prod"]["reconcile_role"] = "role/x\n  - run: evil"
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
    cfg["change_config"]["runners"]["prod"]["reconcile_role"] = "arn:aws:iam::333333333333:role/other"
    assert Gen.drifted?(text, cfg)
  end

  def test_trust_condition_pins_the_default_branch_and_this_workflow
    line = Gen.trust_policy(config, sub_prefix: "repo:acme@1/widgets@2").first
    assert_includes line, "role/cf-prod-reconcile"
    assert_includes line, "repo:acme@1/widgets@2:ref:refs/heads/main:job_workflow_ref:acme/widgets/.github/workflows/cf-prod-reconcile.yml@refs/heads/main"
  end

  def test_cli_writes_vendors_and_then_checks
    Dir.mktmpdir do |root|
      out = StringIO.new
      assert_equal 0, Gen.run([ "--config", FIXTURE, "--root", root ], stdout: out, stderr: StringIO.new)
      assert File.exist?(File.join(root, ".github/cf-prod/scripts/change_maintenance.rb"))
      assert_includes out.string, "trust condition"
      assert_equal 0, Gen.run([ "--config", FIXTURE, "--root", root, "--check" ], stdout: StringIO.new, stderr: StringIO.new)
      File.write(File.join(root, Gen::WORKFLOW), "edited")
      err = StringIO.new
      assert_equal 1, Gen.run([ "--config", FIXTURE, "--root", root, "--check" ], stdout: StringIO.new, stderr: err)
      assert_match(/edited by hand/, err.string)
    end
  end

  # --- doctor ------------------------------------------------------------------------------

  def doctor_lines(cfg, workflow: nil)
    Dir.mktmpdir do |root|
      path = File.join(root, "CHANGE.md")
      File.write(path, "---\n#{YAML.dump(cfg).delete_prefix("---\n")}---\n")
      if workflow
        FileUtils.mkdir_p(File.join(root, ".github/workflows"))
        File.write(File.join(root, Gen::WORKFLOW), workflow)
      end
      ChangeAppRegistry.send(:reconcile_workflow_lines, path, cfg)
    end
  end

  def test_doctor_is_quiet_for_a_generated_workflow
    assert_empty doctor_lines(config, workflow: Gen.generate(config))
  end

  def test_doctor_flags_a_hand_edit
    lines = doctor_lines(config, workflow: "edited")
    assert(lines.any? { |line| line.start_with?("error:") && line.include?("edited by hand") })
  end

  def test_doctor_warns_when_maintenance_has_an_enter_but_no_reconcile_role
    cfg = config
    cfg["change_config"]["runners"]["prod"].delete("reconcile_role")
    assert(doctor_lines(cfg).any? { |line| line.start_with?("warning:") && line.include?("reconcile_role") })
  end

  def test_doctor_does_not_ask_for_a_role_when_there_is_no_enter_command
    cfg = config
    cfg["change_config"]["runners"]["prod"].delete("reconcile_role")
    cfg["change_config"]["maintenance"].delete("enter")
    assert_empty doctor_lines(cfg)
  end
end
