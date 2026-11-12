# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/cf_provider_registry"

class CfProviderRegistryTest < Minitest::Test
  def test_ships_openai_elevenlabs_and_gemini
    assert_equal %w[openai elevenlabs gemini], CfProviderRegistry.names
  end

  def test_every_provider_has_a_hidden_key_file_and_a_validation_request
    CfProviderRegistry.all.each do |provider|
      assert provider.key_file.start_with?("."), provider.name
      assert_equal "GET", provider.validate["method"], provider.name
      assert provider.validate["url"].start_with?("https://"), provider.name
      refute_empty provider.ignored_env, provider.name
    end
  end

  def test_key_shapes_match_their_own_provider_only
    samples = {
      "openai" => "sk-proj-#{'a' * 40}",
      "elevenlabs" => "sk_#{'0f' * 24}",
      "gemini" => "AIza#{'B' * 35}"
    }
    CfProviderRegistry.key_shape_regexes.each do |provider, regex|
      samples.each do |name, sample|
        assert_equal name == provider.name, regex.match?("key: #{sample}"), "#{provider.name} vs #{name}"
      end
    end
  end

  def test_short_sk_mentions_do_not_match
    CfProviderRegistry.key_shape_regexes.each do |_provider, regex|
      refute regex.match?("use the sk- prefix, like sk-abc"), regex.source
    end
  end

  def test_fetch_rejects_an_unknown_provider
    assert_raises(CfProviderRegistry::UnknownProvider) { CfProviderRegistry.fetch("nope") }
  end

  def test_global_ignored_env_names_the_old_pointer
    assert_includes CfProviderRegistry.global_ignored_env, "CF_SECRETS_ENV"
  end
end
