# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require_relative "../scripts/change_prod_runner_gen"

class ChangeProdRunnerGenTest < Minitest::Test
  Gen = ChangeProdRunnerGen
  FIXTURE = File.expand_path("fixtures/prod/runner.yml", __dir__)
  GOLDEN = File.expand_path("fixtures/prod/cf-prod.staging.golden.yml", __dir__)
  BLOCKED = [ "blocked in the golden" ].freeze

  def config = YAML.safe_load_file(FIXTURE)

  def generate(cfg = config, blockers: BLOCKED) = Gen.generate(cfg, blockers: blockers)

  def runner(cfg) = cfg["change_config"]["runners"]["prod"]

  def assert_refused(pattern, &block)
    error = assert_raises(Gen::Refused, &block)
    assert_match pattern, error.message
  end

  def test_matches_the_golden_file
    assert_equal File.read(GOLDEN), generate
  end

  def test_production_is_not_emitted_while_anything_blocks_it
    jobs = YAML.safe_load(generate)["jobs"]
    assert_equal %w[claim run-staging validate], jobs.keys.sort
    refute_includes generate, "role/cf-prod"
    assert_includes generate, "# production is not emitted: blocked in the golden"
  end

  def test_the_real_checkout_blocks_production_until_the_executor_lands
    blockers = Gen.production_blockers
    assert_includes blockers.join, "no op executor"
    refute_empty blockers
    assert_empty Gen.production_blockers(executor: true, root: File.expand_path("..", __dir__)).grep(/verifier/)
  end

  def test_blockers_name_a_missing_verifier_and_console_verbs
    Dir.mktmpdir do |root|
      reasons = Gen.production_blockers(root: root, executor: true)
      assert_includes reasons, "approval console offline verifier is missing"
      assert_includes reasons.join, "no enroll verb"
      assert_includes reasons.join, "no request verb"
      FileUtils.mkdir_p(File.join(root, "scripts/approval_console"))
      File.write(File.join(root, "scripts/approval_console/verifier.rb"), "")
      File.write(File.join(root, "scripts/approval_console.rb"), "when 'enroll' then x\nwhen 'request' then y\n")
      assert_empty Gen.production_blockers(root: root, executor: true)
    end
  end

  def test_the_production_job_is_emitted_only_with_no_blockers
    jobs = YAML.safe_load(generate(blockers: []))["jobs"]
    production = jobs["run-production"]
    assert_equal "production", production["environment"]
    assert_equal "needs.validate.outputs.environment == 'production'", production["if"]
    assert_equal "arn:aws:iam::222222222222:role/cf-prod", production["steps"].find { |s| s["with"]&.key?("role-to-assume") }["with"]["role-to-assume"]
  end

  def test_each_job_has_a_literal_environment_and_role_and_least_privilege
    jobs = YAML.safe_load(generate(blockers: []))["jobs"]
    staging = jobs["run-staging"]
    assert_equal "staging", staging["environment"]
    assert_equal({ "id-token" => "write", "contents" => "read" }, staging["permissions"])
    assert_equal({ "contents" => "write" }, jobs["claim"]["permissions"])
    assert_equal({ "contents" => "read" }, jobs["validate"]["permissions"])
    assert_equal %w[validate claim], staging["needs"]
    refute jobs["claim"]["steps"].any? { |step| step["uses"].to_s.include?("configure-aws-credentials") }
  end

  def test_the_workflow_never_cancels_and_only_runs_from_the_default_branch
    yaml = YAML.safe_load(generate)
    assert_equal({ "group" => "cf-prod", "cancel-in-progress" => false }, yaml["concurrency"])
    assert_equal [ "request_id" ], yaml[true]["workflow_dispatch"]["inputs"].keys
    assert_includes yaml["jobs"]["validate"]["if"], "default_branch"
  end

  def test_untrusted_input_reaches_the_shell_only_through_env
    text = generate
    run_lines = text.lines.grep(/\brun:/)
    refute(run_lines.any? { |line| line.include?("${{") })
    assert_includes text, "REQUEST_ID: ${{ inputs.request_id }}"
  end

  def test_the_verify_job_pins_the_allowed_environments
    assert_includes generate, "--allow-environments staging "
    assert_includes generate(blockers: []), "--allow-environments production,staging "
  end

  def test_refuses_a_malformed_role_or_environment_or_region
    bad = config
    runner(bad)["oidc_roles"]["staging"] = "arn:aws:iam::1:role/short"
    assert_refused(/not an IAM role ARN/) { generate(bad) }
    bad = config
    runner(bad)["oidc_roles"]["staging"] = "arn:aws:iam::111111111111:role/x\"\n  evil: 1"
    assert_refused(/not an IAM role ARN/) { generate(bad) }
    bad = config
    runner(bad)["oidc_roles"].delete("staging")
    assert_refused(/missing or not an IAM role ARN/) { generate(bad) }
    bad = config
    runner(bad)["environments"]["staging"] = "stag ing\nx: 1"
    assert_refused(/not a plain name/) { generate(bad) }
    bad = config
    runner(bad)["region"] = "us-east-1\nx: y"
    assert_refused(/region is malformed/) { generate(bad) }
  end

  def test_refuses_a_runner_that_is_not_github_actions_or_another_workflow_path
    bad = config
    runner(bad)["kind"] = "fixture"
    assert_refused(/not github_actions/) { generate(bad) }
    bad = config
    runner(bad)["workflow"] = ".github/workflows/other.yml"
    assert_refused(/must be \.github\/workflows\/cf-prod\.yml/) { generate(bad) }
    assert_refused(/no change_config.runners.prod/) { generate({}) }
    bad = config
    runner(bad).delete("environments")
    assert_refused(/needs environments and oidc_roles/) { generate(bad) }
  end

  def test_refuses_when_nothing_can_be_emitted
    only_production = config
    runner(only_production)["environments"] = { "production" => "production" }
    assert_refused(/no environment can be emitted/) { generate(only_production) }
  end

  def test_detects_a_hand_edit_and_a_missing_header
    text = generate
    refute Gen.tampered?(text)
    assert Gen.tampered?(text.sub("ubuntu-24.04", "ubuntu-latest"))
    assert Gen.tampered?(text.sub("# GENERATED", "# generated"))
    assert Gen.tampered?("name: cf-prod\n")
  end

  def test_cli_writes_the_file_prints_the_oidc_command_and_checks_it
    Dir.mktmpdir do |root|
      out = StringIO.new
      assert_equal 0, Gen.run([ "--config", FIXTURE, "--root", root, "--repo", "acme/app" ], stdout: out)
      assert_includes out.string, "repos/acme/app/actions/oidc/customization/sub -f use_default=false"
      assert_includes out.string, "include_claim_keys[]=job_workflow_ref"
      assert_equal 0, Gen.run([ "--check", "--root", root ], stdout: StringIO.new)
      path = File.join(root, Gen::WORKFLOW)
      File.write(path, File.read(path).sub("ubuntu-24.04", "ubuntu-latest"))
      err = StringIO.new
      assert_equal 1, Gen.run([ "--check", "--root", root ], stderr: err)
      assert_match(/edited by hand/, err.string)
    end
  end

  def test_cli_refuses_a_missing_config
    err = StringIO.new
    assert_equal 1, Gen.run([ "--root", "." ], stderr: err)
    assert_equal 1, Gen.run([ "--config", "/nonexistent.yml" ], stderr: err)
  end
end
