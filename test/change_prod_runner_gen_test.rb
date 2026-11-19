# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require "open3"
require "rbconfig"
require_relative "../scripts/change_prod_runner_gen"

class ChangeProdRunnerGenTest < Minitest::Test
  Gen = ChangeProdRunnerGen
  FIXTURE = File.expand_path("fixtures/prod/runner.yml", __dir__)
  GOLDEN = File.expand_path("fixtures/prod/cf-prod.staging.golden.yml", __dir__)
  BLOCKED = [ ChangeProdRunnerGen::NOT_EMITTED ].freeze

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
    refute_includes generate, "role/cf-prod\""
    assert_includes generate, Gen::NOT_EMITTED
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

  def test_only_the_staging_allowlist_is_emitted_while_blocked_whatever_production_is_called
    %w[prod live prd production-eu release].each do |name|
      cfg = config
      runner(cfg)["environments"] = { "staging" => "staging", name => "production" }
      runner(cfg)["oidc_roles"][name] = "arn:aws:iam::222222222222:role/cf-prod"
      text = generate(cfg)
      assert_equal %w[claim run-staging validate], YAML.safe_load(text)["jobs"].keys.sort, name
      refute_includes text, "role/cf-prod\"", name
      refute_includes text, "environment: production", name
    end
  end

  def test_a_staging_key_mapped_to_a_production_environment_is_not_emitted
    cfg = config
    runner(cfg)["environments"] = { "staging" => "production" }
    assert_refused(/no environment can be emitted/) { generate(cfg) }
  end

  def test_the_credential_step_comes_after_a_recheck_in_every_environment_job
    jobs = YAML.safe_load(generate(blockers: []))["jobs"]
    %w[run-staging run-production].each do |name|
      steps = jobs[name]["steps"]
      recheck = steps.index { |step| step["run"].to_s.include?("change_prod_gate.rb recheck") }
      credentials = steps.index { |step| step["uses"].to_s.include?("configure-aws-credentials") }
      refute_nil recheck, name
      assert_operator recheck, :<, credentials, name
      assert_includes steps[recheck]["run"], "--version-root version"
    end
  end

  def test_each_job_has_a_literal_environment_and_role_and_least_privilege
    jobs = YAML.safe_load(generate(blockers: []))["jobs"]
    staging = jobs["run-staging"]
    assert_equal "staging", staging["environment"]
    assert_equal({ "id-token" => "write", "contents" => "read" }, staging["permissions"])
    assert_equal({ "id-token" => "write", "contents" => "read" }, jobs["run-production"]["permissions"])
    assert_equal({ "id-token" => "write", "contents" => "read" }, jobs["claim"]["permissions"])
    assert_equal({ "contents" => "read" }, jobs["validate"]["permissions"])
    assert_equal %w[validate claim], staging["needs"]
    claim_role = jobs["claim"]["steps"].find { |step| step["uses"].to_s.include?("configure-aws-credentials") }
    assert_equal "arn:aws:iam::333333333333:role/cf-prod-claim", claim_role["with"]["role-to-assume"]
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

  def test_cli_writes_the_file_prints_no_customization_and_checks_it
    Dir.mktmpdir do |root|
      out = StringIO.new
      assert_equal 0, Gen.run([ "--config", FIXTURE, "--root", root, "--repo", "acme/app" ], stdout: out)
      refute_includes out.string, "-X PUT"
      refute_includes out.string, "include_claim_keys"
      assert_includes out.string, "accepted limit: any default-branch workflow that runs in cf-claim can claim"
      assert_includes out.string, "gh api repos/acme/app/actions/oidc/customization/sub (sub_claim_prefix"
      assert_equal 0, Gen.run([ "--check", "--root", root ], stdout: StringIO.new)
      path = File.join(root, Gen::WORKFLOW)
      File.write(path, File.read(path).sub("ubuntu-24.04", "ubuntu-latest"))
      err = StringIO.new
      assert_equal 1, Gen.run([ "--check", "--root", root ], stderr: err)
      assert_match(/edited by hand/, err.string)
    end
  end

  def test_cli_vendors_every_script_the_workflow_calls_and_they_load
    Dir.mktmpdir do |root|
      out = StringIO.new
      assert_equal 0, Gen.run([ "--config", FIXTURE, "--root", root ], stdout: out)
      Gen::VENDORED.each { |name| assert File.exist?(File.join(root, Gen::SCRIPTS, name)), name }
      gate = File.join(root, Gen::SCRIPTS, "change_prod_gate.rb")
      output, status = Open3.capture2e(RbConfig.ruby, gate, "run")
      assert_equal 1, status.exitstatus, output
      assert_match(/no op executor/, output)
      assert_equal 0, Gen.run([ "--check", "--root", root ], stdout: StringIO.new)
      File.write(File.join(root, Gen::SCRIPTS, "approval_console/verifier.rb"), "# swapped\n")
      err = StringIO.new
      assert_equal 1, Gen.run([ "--check", "--root", root ], stderr: err)
      assert_match(/vendored scripts are missing or differ/, err.string)
    end
  end

  def test_every_required_relative_file_is_vendored
    sources = Gen::VENDORED.flat_map do |name|
      File.read(File.join(Gen.source_root, name)).scan(/require_relative '([^']+)'/).flatten
           .map { |rel| File.join(File.dirname(name), rel).sub(%r{\A\./}, "").then { |path| "#{File.expand_path(path, "/")[1..]}.rb" } }
    end
    assert_empty(sources.uniq - Gen::VENDORED)
  end

  def test_refuses_profiles_that_share_an_environment
    cfg = config
    runner(cfg)["environments"]["preview"] = "staging"
    runner(cfg)["oidc_roles"]["preview"] = "arn:aws:iam::333333333333:role/cf-preview"
    assert_refused(/share an environment \(staging\)/) { generate(cfg) }
    assert_refused(/share an environment/) { generate(cfg, blockers: []) }
  end

  def test_refuses_a_missing_or_malformed_claim_role_or_table
    [ [ "claim_role", nil ], [ "claim_role", "arn:aws:iam::1:role/x" ], [ "claim_table", nil ], [ "claim_table", "bad table\nx: 1" ] ].each do |key, value|
      cfg = config
      value.nil? ? runner(cfg).delete(key) : runner(cfg)[key] = value
      assert_refused(/#{key}/) { generate(cfg) }
    end
  end

  def test_the_validate_job_checks_for_drift_before_anything_else
    steps = YAML.safe_load(generate)["jobs"]["validate"]["steps"]
    check = steps.index { |step| step["run"].to_s.include?("change_prod_runner_gen.rb --check") }
    verify = steps.index { |step| step["run"].to_s.include?("change_prod_gate.rb verify") }
    assert_operator check, :<, verify
  end

  def test_the_environment_job_passes_the_claimed_identity_through_env
    text = generate
    %w[CLAIMED_RUN_ID CLAIMED_ATTEMPT CLAIMED_DIGEST].each { |name| assert_includes text, "#{name}: ${{ needs.claim.outputs" }
    refute(text.lines.grep(/\brun:/).any? { |line| line.include?("${{") })
  end

  def test_check_with_a_config_flags_a_role_that_drifted
    Dir.mktmpdir do |root|
      assert_equal 0, Gen.run([ "--config", FIXTURE, "--root", root ], stdout: StringIO.new)
      path = File.join(root, Gen::WORKFLOW)
      config_path = File.join(root, "base.yml")
      File.write(config_path, File.read(FIXTURE))
      assert_equal 0, Gen.run([ "--check", "--root", root, "--config", config_path ], stdout: StringIO.new)
      drifted = File.read(FIXTURE).sub("role/cf-staging", "role/cf-staging-new")
      File.write(config_path, drifted)
      err = StringIO.new
      assert_equal 1, Gen.run([ "--check", "--root", root, "--config", config_path ], stderr: err)
      assert_match(/drifted from the base config/, err.string)
      File.write(config_path, File.read(FIXTURE).sub("role/cf-prod-claim", "role/cf-prod-claim-new"))
      assert_equal 1, Gen.run([ "--check", "--root", root, "--config", config_path ], stderr: StringIO.new)
    end
  end

  def test_drift_is_judged_the_same_for_a_workflow_generated_with_production
    cfg = config
    text = generate(cfg, blockers: [])
    refute Gen.drifted?(text, cfg)
    assert Gen.drifted?(text, cfg.merge("change_config" => cfg["change_config"].merge("runners" => { "prod" => runner(cfg).merge("region" => "us-west-2") })))
  end

  def test_prints_the_aws_trust_conditions
    out = StringIO.new
    Dir.mktmpdir do |root|
      assert_equal 0, Gen.run([ "--config", FIXTURE, "--root", root, "--repo", "acme/app", "--repo-ids", "11/22" ], stdout: out)
    end
    lines = out.string.lines.grep(/trust condition/)
    assert_equal 2, lines.size
    claim = lines.find { |line| line.include?("cf-prod-claim") }
    assert_includes claim, "\"repo:acme@11/app@22:environment:cf-claim\""
    staging = lines.find { |line| line.include?("cf-staging") }
    assert_includes staging, "\"repo:acme@11/app@22:environment:staging\""
    assert_includes staging, '"token.actions.githubusercontent.com:aud":"sts.amazonaws.com"'
    assert_includes staging, "StringEquals"
    refute_includes out.string, "role/cf-prod\""
    refute_includes out.string, "repo ids for the trust subject"
  end

  def test_change_fabric_claim_subject_matches_its_immutable_sub
    out = StringIO.new
    Dir.mktmpdir do |root|
      args = [ "--config", FIXTURE, "--root", root, "--repo", "change-fabric/change-fabric", "--repo-ids", "311455213/1180238677" ]
      assert_equal 0, Gen.run(args, stdout: out)
    end
    sub = "repo:change-fabric@311455213/change-fabric@1180238677:environment:cf-claim"
    assert_includes out.string.lines.find { |line| line.include?("cf-prod-claim") }, "\"#{sub}\""
  end

  def test_repo_ids_must_be_numeric
    err = StringIO.new
    Dir.mktmpdir do |root|
      assert_equal 1, Gen.run([ "--config", FIXTURE, "--root", root, "--repo", "acme/app", "--repo-ids", "x/*" ], stdout: StringIO.new, stderr: err)
    end
    assert_match(/refused/, err.string)
  end

  def test_claim_job_runs_in_the_dedicated_cf_claim_environment
    claim = YAML.safe_load(generate)["jobs"]["claim"]
    assert_equal "cf-claim", claim["environment"]
    out = StringIO.new
    Dir.mktmpdir { |root| Gen.run([ "--config", FIXTURE, "--root", root, "--repo", "acme/app" ], stdout: out) }
    sub = "\"repo:acme@<owner_id>/app@<repo_id>:environment:cf-claim\""
    assert_includes out.string.lines.find { |line| line.include?("cf-prod-claim") }, sub
    assert_match(/create a cf-claim environment with deployment branch = default only, no reviewers/, out.string)
    reserved = config
    runner(reserved)["environments"]["staging"] = "cf-claim"
    assert_refused(/reserved/) { generate(reserved) }
  end

  def test_cli_refuses_a_missing_config
    err = StringIO.new
    assert_equal 1, Gen.run([ "--root", "." ], stderr: err)
    assert_equal 1, Gen.run([ "--config", "/nonexistent.yml" ], stderr: err)
  end
end
