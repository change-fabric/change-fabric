# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require_relative "../scripts/design_config"

class DesignConfigTest < Minitest::Test
  def with_repo(front)
    Dir.mktmpdir do |root|
      File.write(File.join(root, "CHANGE.md"), "#{YAML.dump(front)}---\n\nbody\n") if front
      yield root
    end
  end

  def test_missing_change_md_returns_defaults
    with_repo(nil) do |root|
      config = DesignConfig.load(root)
      assert_equal "design/tokens.css", config.tokens
      assert_nil config.tailwind
      assert_nil config.figma
      assert_equal "design/figma-variables.json", config.variables_snapshot
      assert_equal false, config.code_connect
      assert_equal "unreviewed", config.parity_default
      assert_empty config.parity_areas
      assert_equal 2.00, config.roast.max_usd
      assert_equal 8.5, config.roast.target
      assert_equal 4, config.roast.rounds
      assert_equal true, config.roast.auto
      assert_nil config.roast.model
      assert_equal 3, config.critic_rounds
      assert config.frozen?
    end
  end

  def test_missing_block_returns_defaults
    with_repo("change_config" => { "lanes" => { "k6" => {} } }) do |root|
      assert_equal 3, DesignConfig.load(root).critic_rounds
    end
  end

  def test_block_values_override_defaults_and_unset_keys_keep_them
    design = {
      "tokens" => "ui/tokens.css",
      "figma" => { "url" => "https://www.figma.com/design/AbCdEf123/App?node-id=1-2" },
      "parity" => { "areas" => [{ "match" => "Marketing*", "status" => "intentional", "reason" => "campaign" }] },
      "roast" => { "max_usd" => 0.5 },
      "critic_rounds" => 5
    }
    with_repo("change_config" => { "design" => design }) do |root|
      config = DesignConfig.load(root)
      assert_equal "ui/tokens.css", config.tokens
      assert_equal "AbCdEf123", config.figma.file_key
      assert_equal "1:2", config.figma.node_id
      assert_equal "intentional", config.parity_areas.first.status
      assert_equal 0.5, config.roast.max_usd
      assert_equal 4, config.roast.rounds
      assert_equal 5, config.critic_rounds
    end
  end

  def test_malformed_block_raises_naming_the_field
    with_repo("change_config" => { "design" => { "critic_rounds" => 9 } }) do |root|
      error = assert_raises(DesignConfig::Error) { DesignConfig.load(root) }
      assert_match(/critic_rounds/, error.message)
    end
  end
end
