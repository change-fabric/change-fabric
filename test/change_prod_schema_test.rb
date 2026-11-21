# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require "tmpdir"
require "fileutils"
require_relative "../scripts/change_prod_envelope"
require_relative "../scripts/change_prod_schema"
require_relative "../scripts/change_prod_runner_gen"
require_relative "../scripts/change_schema"
require_relative "../scripts/change_apps"

# The bounded prod runner keys (spec 0.29.0): the shape, every schema-fixed
# floor (one invalid fixture each), the generator reading the keys, and the doctor lines.
class ChangeProdSchemaTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/prod", __dir__)

  def load(name) = YAML.safe_load_file(File.join(FIXTURES, name))

  def deep_merge(base, patch)
    base.merge(patch) { |_key, old, new| old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : new }
  end

  def test_valid_fixture_has_no_errors
    assert_empty ChangeProdSchema.errors(load("valid.yml"))
  end

  def test_absent_blocks_are_valid
    assert_empty ChangeProdSchema.errors({ "change_config" => { "lanes" => {} } })
    assert_empty ChangeProdSchema.errors({})
  end

  def test_config_and_policy_may_be_passed_separately
    doc = load("valid.yml")
    assert_empty ChangeProdSchema.errors(doc["change_config"], doc["change_policy"])
    refute_empty ChangeProdSchema.errors(doc["change_config"], {})
  end

  Dir[File.join(FIXTURES, "invalid_*.yml")].each do |path|
    name = File.basename(path, ".yml")
    define_method("test_#{name}_is_rejected") do
      spec = YAML.safe_load_file(path)
      errors = ChangeProdSchema.errors(deep_merge(load("valid.yml"), spec.fetch("patch")))
      assert errors.any? { |message| message.include?(spec.fetch("expect")) },
             "#{name}: expected an error containing #{spec['expect'].inspect}, got #{errors.inspect}"
    end
  end

  def test_every_floor_has_an_invalid_fixture
    assert_operator Dir[File.join(FIXTURES, "invalid_*.yml")].size, :>=, 30
  end

  def test_integer_params_are_rejected_because_the_envelope_carries_strings
    doc = load("valid.yml")
    doc["change_config"]["operations"]["rotate_tenant_key"]["params"]["tenant_id"] = { "type" => "integer", "min" => 1, "max" => 9 }
    assert ChangeProdSchema.errors(doc).any? { |message| message.include?("params.tenant_id.type must be string") }
  end

  def test_every_valid_op_can_build_an_envelope
    doc = load("valid.yml")
    params = { "rotate_tenant_key" => { "tenant_id" => "t_1" }, "redeploy_previous" => { "previous_release" => "v1.2" } }
    params.each do |op, given|
      definition = doc["change_config"]["operations"][op]
      ChangeProdEnvelope.check_params(definition["params"], given)
    end
  end

  def test_claim_settings_are_required_for_a_github_actions_runner
    %w[claim_role claim_table].each do |key|
      doc = load("valid.yml")
      doc["change_config"]["runners"]["prod"].delete(key)
      assert ChangeProdSchema.errors(doc).any? { |message| message.include?("runners.prod.#{key}") }, key
    end
    doc = load("valid.yml")
    doc["change_config"]["runners"]["prod"]["region"] = "nowhere"
    assert ChangeProdSchema.errors(doc).any? { |message| message.include?("region must be") }
  end

  def test_the_valid_fixture_generates_the_staging_workflow
    assert_match(/environment: staging/, ChangeProdRunnerGen.generate(load("valid.yml")))
  end

  def test_pitr_defaults_to_the_floor
    doc = load("valid.yml")
    doc["change_config"]["backups"]["main_db"].delete("pitr")
    assert_empty ChangeProdSchema.errors(doc)
  end

  def test_non_mapping_blocks_do_not_raise
    %w[runners backups maintenance operations].each do |key|
      errors = ChangeProdSchema.errors({ "change_config" => { key => "x" }, "change_policy" => {} })
      assert errors.any? { |message| message.include?("change_config.#{key} must be a mapping") }
    end
  end

  def test_operations_need_a_guard
    doc = load("valid.yml")
    doc["change_policy"] = {}
    assert ChangeProdSchema.errors(doc).any? { |message| message.include?("prod_guard is required") }
  end

  def test_online_safe_ops_and_missing_probes
    doc = load("valid.yml")
    assert_equal [ { op: "redeploy_previous", reason: "redeploys an already-released build" } ], ChangeProdSchema.online_safe_ops(doc)
    assert_equal [ "dump_db" ], ChangeProdSchema.missing_probes(doc)
  end

  def test_generator_reads_the_staging_job_from_a_runner_only_config
    config = YAML.safe_load_file(File.join(FIXTURES, "runner.yml"))
    assert_match(/environment: staging/, ChangeProdRunnerGen.generate(config))
  end

  def with_repo(doc)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "CHANGE.md"), "---\nspec_version: #{ChangeSchema::VERSION}\n#{YAML.dump(doc).delete_prefix("---\n")}---\n")
      yield dir
    end
  end

  def doctor_lines(dir) = ChangeAppRegistry.send(:prod_schema_lines, File.join(dir, "CHANGE.md"))

  def test_doctor_reports_opt_outs_and_missing_probes_without_errors
    with_repo(load("valid.yml")) do |dir|
      lines = doctor_lines(dir)
      assert_includes lines, "notice: prod op redeploy_previous is online_safe: redeploys an already-released build"
      assert_includes lines, "warning: prod backup dump_db has no restore_probe"
      assert_empty lines.grep(/\Aerror:/)
    end
  end

  def test_doctor_reports_schema_errors
    doc = load("valid.yml")
    doc["change_policy"]["prod_guard"]["max_concurrent_ops"] = 3
    with_repo(doc) do |dir|
      assert doctor_lines(dir).any? { |line| line.start_with?("error:") && line.include?("max_concurrent_ops") }
    end
  end

  def test_doctor_flags_a_hand_edited_workflow
    with_repo(load("valid.yml")) do |dir|
      path = File.join(dir, ChangeProdRunnerGen::WORKFLOW)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, ChangeProdRunnerGen.generate(load("valid.yml")))
      assert_empty doctor_lines(dir).grep(/hand/)
      File.write(path, "#{File.read(path)}# edit\n")
      assert doctor_lines(dir).any? { |line| line.include?("edited by hand") }
    end
  end

  def test_doctor_is_silent_without_the_blocks
    with_repo({ "change_config" => { "lanes" => {} } }) { |dir| assert_empty doctor_lines(dir) }
  end
end
