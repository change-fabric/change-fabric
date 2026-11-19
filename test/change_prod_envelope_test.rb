# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require_relative "../scripts/change_prod_envelope"

class ChangeProdEnvelopeTest < Minitest::Test
  Envelope = ChangeProdEnvelope
  SHA = "a" * 40
  FIXTURE = File.expand_path("fixtures/prod/runner.yml", __dir__)

  def config = YAML.safe_load_file(FIXTURE)

  def build(overrides = {})
    args = { config: config, op: "rotate_tenant_key", params: { "tenant_id" => "t_101" }, profile: "staging",
             version: SHA, requested_by: "agent:s1" }.merge(overrides)
    Envelope.build(**args)
  end

  def assert_invalid(pattern, &block)
    error = assert_raises(Envelope::Invalid, &block)
    assert_match pattern, error.message
  end

  def test_builds_a_digested_envelope_bound_to_the_environment
    envelope = build
    assert_equal "cf.prod.request/1", envelope["protocol"]
    assert_equal "staging", envelope["environment"]
    assert_match(/\Asha256:\h{64}\z/, envelope["digest"])
    assert_equal envelope, Envelope.validate(envelope, config: config)
  end

  def test_digest_is_canonical_regardless_of_key_order
    envelope = build
    shuffled = envelope.to_a.reverse.to_h
    assert_equal envelope["digest"], Envelope.digest(shuffled)
  end

  def test_digest_changes_with_every_bound_field
    base = build
    other_id = base.merge("request_id" => SecureRandom.uuid)
    refute_equal base["digest"], Envelope.digest(other_id)
    refute_equal base["digest"], Envelope.digest(base.merge("version" => "b" * 40))
    refute_equal base["digest"], Envelope.digest(base.merge("params" => { "tenant_id" => "t_102" }))
    refute_equal base["digest"], Envelope.digest(base.merge("environment" => "production"))
    refute_equal base["digest"], Envelope.digest(base.merge("config_digest" => "sha256:#{'0' * 64}"))
  end

  def test_requested_by_is_not_part_of_the_digest
    base = build
    assert_equal base["digest"], Envelope.digest(base.merge("requested_by" => "agent:other"))
  end

  def test_rejects_an_undeclared_op
    assert_invalid(/not declared/) { build(op: "drop_database") }
    assert_invalid(/not a valid name/) { build(op: "Bad Op") }
  end

  def test_rejects_a_profile_without_an_environment
    assert_invalid(/no environment/) { build(profile: "qa") }
  end

  def test_rejects_undeclared_missing_and_malformed_params
    assert_invalid(/undeclared params: extra/) { Envelope.validate(rebuilt("params" => { "tenant_id" => "t_1", "extra" => "x" }), config: config) }
    assert_invalid(/param tenant_id is missing/) { Envelope.validate(rebuilt("params" => {}), config: config) }
    assert_invalid(/does not match its pattern/) { build(params: { "tenant_id" => "t_1; rm -rf /" }) }
    assert_invalid(/control characters/) { build(params: { "tenant_id" => "t_1\nx" }) }
    assert_invalid(/control characters/) { build(params: { "tenant_id" => "t_1\nt_2" }) }
    assert_invalid(/string values/) { build(params: { "tenant_id" => 101 }) }
    assert_invalid(/empty or over/) { build(params: { "tenant_id" => "" }) }
  end

  def test_rejects_an_argv_placeholder_that_is_not_a_declared_param
    cfg = config
    cfg["change_config"]["operations"]["rotate_tenant_key"]["argv"] << "{shell}"
    assert_invalid(/undeclared params: shell/) { build(config: cfg) }
  end

  def test_rejects_a_param_without_a_typed_pattern
    cfg = config
    cfg["change_config"]["operations"]["rotate_tenant_key"]["params"]["tenant_id"] = { "type" => "string" }
    assert_invalid(/declare type string and a pattern/) { build(config: cfg) }
  end

  def test_rejects_a_tampered_digest_or_extra_fields
    envelope = build
    assert_invalid(/digest does not match/) { Envelope.validate(envelope.merge("op" => "rotate_tenant_key", "params" => { "tenant_id" => "t_999" })) }
    assert_invalid(/unexpected or missing fields: extra/) { Envelope.validate(envelope.merge("extra" => 1)) }
    assert_invalid(/not cf.prod.request\/1/) { Envelope.validate(envelope.merge("protocol" => "cf.prod.request/2")) }
    assert_invalid(/version is malformed/) { Envelope.validate(envelope.merge("version" => "main")) }
    assert_invalid(/envelope is not an object/) { Envelope.validate([]) }
  end

  def test_rejects_a_changed_base_config
    envelope = build
    cfg = config
    cfg["change_config"]["operations"]["rotate_tenant_key"]["timeout_s"] = 1
    assert_invalid(/config_digest does not match/) { Envelope.validate(envelope, config: cfg) }
  end

  def test_rejects_an_environment_that_is_not_the_profile_mapping
    forged = build.merge("environment" => "production")
    forged["digest"] = Envelope.digest(forged)
    assert_invalid(/not the mapping for profile staging/) { Envelope.validate(forged, config: config) }
  end

  def test_load_config_reads_frontmatter_and_refuses_empty
    Dir.mktmpdir do |dir|
      path = File.join(dir, "CHANGE.md")
      File.write(path, "---\nchange_config:\n  x: 1\n---\nbody\n")
      assert_equal({ "x" => 1 }, Envelope.load_config(path)["change_config"])
      File.write(path, "no frontmatter at all")
      assert_invalid(/holds no config|cannot read/) { Envelope.load_config(path) }
      assert_invalid(/cannot read config/) { Envelope.load_config(File.join(dir, "missing.yml")) }
    end
  end

  def test_approval_context_binds_the_digest_through_summary_and_argv
    envelope = build
    context = Envelope.approval_context(envelope, repo: "repo:github.com/o/r", machine_id: "m")
    assert_equal "prod-op", context["type"]
    assert_equal SHA, context["sha"]
    assert_includes context["summary"], envelope["digest"]
    assert_equal [ "cf.prod.request/1", envelope["digest"] ], context["argv"]
    assert_equal 12, Envelope.prefix(envelope).length
  end

  private

  def rebuilt(overrides)
    envelope = build.merge(overrides)
    envelope["digest"] = Envelope.digest(envelope)
    envelope
  end
end
