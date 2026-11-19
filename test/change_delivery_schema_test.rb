# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require "tmpdir"
require "fileutils"
require_relative "../scripts/change_delivery_schema"
require_relative "../scripts/change_schema"
require_relative "../scripts/change_apps"

# change_config.delivery and change_policy.delivery (spec 0.24.0): the shape,
# every schema-fixed floor (one invalid fixture each), and the per-flag file
# merge behind `source:`.
class ChangeDeliverySchemaTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/delivery", __dir__)

  def load(name) = YAML.safe_load_file(File.join(FIXTURES, name))

  def errors_for(doc, root: FIXTURES)
    ChangeDeliverySchema.errors(doc["change_config"], doc["change_policy"], root: root)
  end

  def deep_merge(base, patch)
    base.merge(patch) { |_key, old, new| old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : new }
  end

  def test_inline_fixture_is_valid
    assert_empty errors_for(load("valid.yml"))
  end

  def test_sourced_fixture_is_valid_and_merges_the_flag_file
    doc = load("valid_sourced.yml")
    assert_empty errors_for(doc)

    rollout = ChangeDeliverySchema.rollouts(doc["change_config"], doc["change_policy"], root: FIXTURES).first
    assert_equal 3, rollout.revision
    assert_equal %w[internal hash50 everyone], rollout.stages.map { |stage| stage["cohort"] }
    assert rollout.money_affecting?
    assert_equal "manual", rollout.advance
  end

  def test_absent_blocks_are_valid
    assert_empty ChangeDeliverySchema.errors({ "lanes" => {} }, {}, root: FIXTURES)
  end

  Dir[File.join(FIXTURES, "invalid_*.yml")].each do |path|
    name = File.basename(path, ".yml")
    define_method("test_#{name}_is_rejected") do
      spec = YAML.safe_load_file(path)
      errors = errors_for(deep_merge(load("valid.yml"), spec.fetch("patch")))
      assert errors.any? { |message| message.include?(spec.fetch("expect")) },
             "#{name}: expected an error containing #{spec['expect'].inspect}, got #{errors.inspect}"
    end
  end

  def test_every_floor_has_an_invalid_fixture
    assert_operator Dir[File.join(FIXTURES, "invalid_*.yml")].size, :>=, 20
  end

  def test_missing_flag_file_is_an_error
    doc = load("valid_sourced.yml")
    doc["change_config"]["delivery"]["rollouts"]["new-checkout"]["source"] = "delivery/missing.yml"
    assert(errors_for(doc).any? { |message| message.include?("delivery/missing.yml not found") })
  end

  def test_source_outside_delivery_dir_is_rejected
    doc = load("valid_sourced.yml")
    doc["change_config"]["delivery"]["rollouts"]["new-checkout"]["source"] = "../secrets.yml"
    assert(errors_for(doc).any? { |message| message.include?("source must be a path under delivery/") })
  end

  def test_flag_file_must_name_its_rollout
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "delivery"))
      body = File.read(File.join(FIXTURES, "delivery/new-checkout.yml")).sub("rollout: new-checkout", "rollout: other")
      File.write(File.join(root, "delivery/new-checkout.yml"), body)
      assert(errors_for(load("valid_sourced.yml"), root: root).any? { |message| message.include?(".rollout must be 'new-checkout'") })
    end
  end

  def test_policy_pacing_conflicts_with_a_sourced_rollout
    doc = load("valid_sourced.yml")
    doc["change_policy"]["delivery"]["rollouts"]["new-checkout"]["pacing"] = { "advance" => "manual" }
    assert(errors_for(doc).any? { |message| message.include?("rollouts.new-checkout.pacing is set in CHANGE.md") })
  end

  def test_money_affecting_flag_file_rejects_auto
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "delivery"))
      body = File.read(File.join(FIXTURES, "delivery/new-checkout.yml")).sub("advance: manual", "advance: auto")
      File.write(File.join(root, "delivery/new-checkout.yml"), body)
      assert(errors_for(load("valid_sourced.yml"), root: root).any? { |message| message.include?("advance: auto is not allowed") })
    end
  end

  def test_money_affecting_defaults_to_manual_advance
    doc = load("valid.yml")
    doc["change_policy"]["delivery"]["rollouts"]["new-checkout"]["pacing"] = { "money_affecting" => true }
    assert_empty errors_for(doc)
  end

  def test_human_breach_response_skips_the_reenable_cohort_check
    doc = load("valid.yml")
    rollout = doc["change_config"]["delivery"]["rollouts"]["new-checkout"]
    rollout["stages"] = [ { "cohort" => "hash25" }, { "cohort" => "everyone" } ]
    doc["change_policy"]["delivery"]["rollouts"]["new-checkout"]["on_breach"] = { "immediate" => "flag_off", "then" => "human" }
    assert_empty errors_for(doc)
  end

  def test_revision_must_rise_when_a_rollout_changes
    base = load("valid.yml")
    head = load("valid.yml")
    head["change_config"]["delivery"]["rollouts"]["new-checkout"]["stages"][0]["dwell_minutes"] = 30
    rollouts = ->(doc) { ChangeDeliverySchema.rollouts(doc["change_config"], doc["change_policy"], root: FIXTURES) }

    assert_equal 1, ChangeDeliverySchema.revision_errors(rollouts.(base), rollouts.(head)).size
    head["change_config"]["delivery"]["rollouts"]["new-checkout"]["revision"] = 2
    assert_empty ChangeDeliverySchema.revision_errors(rollouts.(base), rollouts.(head))
    assert_empty ChangeDeliverySchema.revision_errors(rollouts.(base), rollouts.(base))
  end

  def test_digest_is_stable_and_order_independent
    doc = load("valid.yml")
    a = ChangeDeliverySchema.rollouts(doc["change_config"], doc["change_policy"]).first.digest
    reordered = doc["change_config"]["delivery"]["rollouts"]["new-checkout"].to_a.reverse.to_h
    doc["change_config"]["delivery"]["rollouts"]["new-checkout"] = reordered
    b = ChangeDeliverySchema.rollouts(doc["change_config"], doc["change_policy"]).first.digest
    assert_equal a, b
    assert_match(/\A\h{64}\z/, a)
  end

  def doctor_for(doc)
    Dir.mktmpdir do |root|
      FileUtils.cp_r(File.join(FIXTURES, "delivery"), root)
      doc["change_config"]["lanes"] = { "k6" => { "enabled" => true } }
      path = File.join(root, "CHANGE.md")
      File.write(path, "---\n#{YAML.dump(doc).sub(/\A---\n/, '')}---\n\nbody\n")
      ChangeAppRegistry.doctor(path)
    end
  end

  def test_doctor_lists_rollouts
    summary = doctor_for(load("valid.yml"))
    assert_match(/delivery: rollout new-checkout flag=new_checkout owner=@maintainer revision=1 advance=auto stages=internal > pilot > hash25 > hash50 > everyone/, summary)
    refute_match(/error: .*delivery/, summary)
  end

  def test_doctor_reports_missing_owner_and_money_auto
    doc = load("valid.yml")
    doc["change_config"]["delivery"]["rollouts"]["new-checkout"].delete("owner")
    doc["change_policy"]["delivery"]["rollouts"]["new-checkout"]["pacing"]["money_affecting"] = true
    summary = doctor_for(doc)
    assert_match(/error: change_config.delivery.rollouts.new-checkout.owner is required/, summary)
    assert_match(/error: .*money_affecting, so advance: auto is not allowed/, summary)
  end

  def test_doctor_warns_on_fixture_adapters_in_production
    summary = doctor_for(load("valid_sourced.yml"))
    assert_match(/source=delivery\/new-checkout.yml/, summary)
    assert_match(/warning: delivery rollout new-checkout runs on profile production with flags 'main' still kind fixture/, summary)
    assert_match(/with metrics 'otel' still kind fixture/, summary)
  end

  # Every key the validator accepts is a registered, documented field.
  def test_registry_covers_the_delivery_keys
    fields = ChangeSchema::FIELDS
    %w[flags metrics cohorts rollouts verdict_sources].each do |key|
      assert(fields.any? { |field| field.start_with?("change_config.delivery.#{key}.") }, key)
    end
    %w[require_rollout verdicts notify one_way_door_paths rollouts].each do |key|
      assert(fields.any? { |field| field.start_with?("change_policy.delivery.#{key}") }, key)
    end
  end
end
