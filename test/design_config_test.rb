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
      config = DesignConfig.load(root).default
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
      assert_equal 3, DesignConfig.load(root).default.critic_rounds
    end
  end

  def test_block_values_override_defaults_and_unset_keys_keep_them
    design = {
      "tokens" => "ui/tokens.css",
      "figma" => { "url" => "https://www.figma.com/design/AbCdEf123/App?node-id=1-2" },
      "parity" => { "areas" => [ { "match" => "Marketing*", "status" => "intentional", "reason" => "campaign" } ] },
      "roast" => { "max_usd" => 0.5 },
      "critic_rounds" => 5
    }
    with_repo("change_config" => { "design" => design }) do |root|
      config = DesignConfig.load(root).default
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

  def test_roast_kind_and_audience_default_to_nil_and_are_validated
    with_repo("change_config" => { "design" => { "roast" => { "kind" => "demo", "audience" => "Ops" } } }) do |root|
      config = DesignConfig.load(root).default
      assert_equal "demo", config.roast.kind
      assert_equal "Ops", config.roast.audience
    end
    assert_nil DesignConfig.from_hash(nil).roast.kind
    error = assert_raises(DesignConfig::Error) { DesignConfig.from_hash("roast" => { "kind" => "trailer" }) }
    assert_match(/roast\.kind/, error.message)
  end

  def portal_target(extra = {})
    { "source" => "tailwind", "theme" => "apps/portal/src/app/globals.css",
      "components" => "apps/portal/src/components/ui", "kit" => "packages/design-kit" }.merge(extra)
  end

  def test_flat_form_is_synthesized_as_the_default_target
    with_repo("change_config" => { "design" => { "tokens" => "ui/tokens.css" } }) do |root|
      targets = DesignConfig.load(root)
      assert_equal [ "default" ], targets.names
      assert targets.flat?
      config = targets.default
      assert_equal "ui/tokens.css", config.tokens
      assert_equal "default", config.target.name
      assert_equal "ui/tokens.css", config.target.theme
      refute config.target.kit?
      refute config.target.reference?
      assert_same config, targets.target(nil)
    end
  end

  def test_no_target_default_config_is_unchanged
    flat = DesignConfig.from_hash(nil)
    assert_equal "design/tokens.css", flat.tokens
    assert_nil flat.tailwind
    assert_equal "tokens", flat.target.source
  end

  def test_targets_are_read_with_shared_keys_and_default_target
    design = {
      "roast" => { "max_usd" => 0.5 },
      "default_target" => "admin",
      "targets" => {
        "portal" => portal_target("reference" => { "base_url" => "https://staging.example.org",
                                                   "routes" => [ { "path" => "/admin/analytics", "mask" => [ "[data-live-value]" ] } ],
                                                   "auth" => { "login_url" => "/login", "email_env" => "REF_EMAIL", "password_env" => "REF_PASSWORD" } }),
        "admin" => { "source" => "css", "theme" => "apps/admin/theme.css" }
      }
    }
    with_repo("change_config" => { "design" => design }) do |root|
      targets = DesignConfig.load(root)
      assert_equal %w[portal admin], targets.names
      refute targets.flat?
      assert_equal "admin", targets.default.target.name
      assert_equal "apps/admin/theme.css", targets.default.tokens
      portal = targets.target("portal")
      assert portal.tailwind
      assert portal.target.kit?
      assert_equal "packages/design-kit", portal.target.kit
      assert_equal "/admin/analytics", portal.target.reference.routes.first.path
      assert_equal [ "[data-live-value]" ], portal.target.reference.routes.first.mask
      assert_equal 0.5, portal.roast.max_usd
      assert_equal 0.5, targets.default.roast.max_usd
    end
  end

  def test_first_target_is_default_without_default_target
    targets = DesignConfig.targets_from_hash({ "targets" => { "portal" => portal_target, "b" => portal_target } })
    assert_equal "portal", targets.default.target.name
  end

  def test_unknown_target_raises_naming_known_targets
    targets = DesignConfig.targets_from_hash({ "targets" => { "portal" => portal_target } })
    error = assert_raises(DesignConfig::UnknownTarget) { targets.target("nope") }
    assert_match(/nope.*portal/, error.message)
  end

  def test_flat_and_targets_mixed_is_an_error_naming_both_keys
    error = assert_raises(DesignConfig::Error) do
      DesignConfig.targets_from_hash({ "tokens" => "a.css", "targets" => { "portal" => portal_target } })
    end
    assert_match(/change_config\.design\.tokens/, error.message)
    assert_match(/change_config\.design\.targets/, error.message)
  end

  def test_unknown_app_link_is_an_error_when_apps_are_known
    design = { "targets" => { "portal" => portal_target("app" => "portal") } }
    with_repo("change_config" => { "design" => design }) do |root|
      error = assert_raises(DesignConfig::Error) { DesignConfig.load(root) }
      assert_match(/targets\.portal\.app.*change_config\.apps/, error.message)
    end
    with_repo("change_config" => { "apps" => { "portal" => { "config" => "x.yml" } }, "design" => design }) do |root|
      assert_equal "portal", DesignConfig.load(root).default.target.app
    end
  end

  def test_reference_auth_with_a_literal_secret_is_rejected
    literal = { "login_url" => "/login", "email_env" => "REF_EMAIL", "password" => "hunter2" }
    error = assert_raises(DesignConfig::Error) do
      DesignConfig.targets_from_hash({ "targets" => { "portal" => portal_target("reference" => { "routes" => [ { "path" => "/" } ], "auth" => literal }) } })
    end
    assert_match(/reference\.auth sets unknown key\(s\): password/, error.message)
    lowercase = { "login_url" => "/login", "email_env" => "me@example.org" }
    error = assert_raises(DesignConfig::Error) do
      DesignConfig.targets_from_hash({ "targets" => { "portal" => portal_target("reference" => { "routes" => [ { "path" => "/" } ], "auth" => lowercase }) } })
    end
    assert_match(/email_env must name an env var/, error.message)
  end

  def test_reference_auth_lane_name_needs_an_app_link
    ref = { "routes" => [ { "path" => "/" } ], "auth" => "browserless" }
    error = assert_raises(DesignConfig::Error) do
      DesignConfig.targets_from_hash({ "targets" => { "portal" => portal_target("reference" => ref) } })
    end
    assert_match(/needs .*\.app/, error.message)
    ok = DesignConfig.targets_from_hash({ "targets" => { "portal" => portal_target("app" => "portal", "reference" => ref) } })
    assert_equal "browserless", ok.default.target.reference.auth
  end

  def test_target_validation_names_bad_fields
    error = assert_raises(DesignConfig::Error) do
      DesignConfig.targets_from_hash({ "default_target" => "x", "targets" => { "portal" => { "source" => "less", "theme" => "", "extra" => 1 } } })
    end
    assert_match(/portal\.source must be one of tokens, tailwind, css/, error.message)
    assert_match(/portal\.theme must be a non-empty string/, error.message)
    assert_match(/unknown key\(s\): extra/, error.message)
    assert_match(/default_target names unknown target 'x'/, error.message)
  end
end
