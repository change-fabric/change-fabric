# frozen_string_literal: true

require_relative "secret_intake_helpers"
require_relative "../scripts/cf_secrets"

class SecretIntakeCfKeyTest < Minitest::Test
  include SecretIntakeHelpers

  KEY = "sk-#{'a' * 48}"

  def stage(home, value, validated_by:)
    project = File.join(home, "project").tap { |dir| FileUtils.mkdir_p(dir) }
    SecretIntake::StagingStore.new(project: CfProjectIdentity.for(project)).put("OPENAI_API_KEY", value, validated_by: validated_by)
    project
  end

  def test_enrolls_into_a_dir_level_that_cf_secrets_resolves
    with_temp_home do |home|
      project = stage(home, KEY, validated_by: "openai")
      validator = FakeValidator.new
      cli = cli_for(FakeAws.new, home: home, key_validator: validator)
      assert_equal 0, cli.run([ "push", "OPENAI_API_KEY", "--to", "cf-key:openai", "--dir", project ])
      assert_nil validator.seen, "an already-validated value is not revalidated"
      assert_equal KEY, CfSecrets.resolve("openai", cwd: project, env: {}, err: StringIO.new)
      assert_includes @out.string, "enrolled OPENAI_API_KEY as the openai key"
      refute_includes @out.string + @err.string, KEY
    end
  end

  def test_an_unvalidated_value_is_validated_and_a_rejection_exits_3
    with_temp_home do |home|
      project = stage(home, KEY, validated_by: "none")
      validator = FakeValidator.new(ok: false)
      cli = cli_for(FakeAws.new, home: home, key_validator: validator)
      assert_equal 3, cli.run(%w[push OPENAI_API_KEY --to cf-key:openai])
      assert_equal [ "openai", KEY ], validator.seen
      refute CfSecretStore.key?(CfProjectIdentity.for(project).slug, "openai")
    end
  end

  def test_an_unknown_provider_is_a_usage_error
    with_temp_home do |home|
      stage(home, KEY, validated_by: "none")
      assert_equal 1, cli_for(FakeAws.new, home: home).run(%w[push OPENAI_API_KEY --to cf-key:nope])
    end
  end
end
