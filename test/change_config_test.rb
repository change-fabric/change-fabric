# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "yaml"
require_relative "../scripts/change_config"

class ChangeConfigTest < Minitest::Test
  # Writes a CHANGE.md whose frontmatter carries the given change_config hash
  # (dumped as YAML) plus a prose body, then loads it. YAML.dump emits the
  # leading `---`, so appending the closing fence yields valid frontmatter.
  def with_config(config, profile = nil)
    Dir.mktmpdir do |root|
      path = File.join(root, "CHANGE.md")
      File.write(path, "#{YAML.dump("change_config" => config)}---\n\nbody\n")
      yield ChangeConfig.load(path, profile: profile), root
    end
  end

  def test_enabled_lanes_in_fixed_order_and_skips_disabled
    config = { "project" => "app", "lanes" => {
      "browserless" => { "enabled" => true },
      "k6" => { "enabled" => true },
      "zap" => { "enabled" => false }
    } }
    with_config(config) do |loaded, _root|
      assert_equal %w[k6 browserless], loaded.enabled_lanes
    end
  end

  def test_unknown_lane_is_rejected
    error = assert_raises(ChangeConfig::ConfigError) do
      with_config("lanes" => { "bogus" => { "enabled" => true } }) { |_c| }
    end
    assert_match(/unknown lane/, error.message)
  end

  def test_no_enabled_lanes_is_rejected
    assert_raises(ChangeConfig::ConfigError) do
      with_config("lanes" => { "k6" => { "enabled" => false } }) { |_c| }
    end
  end

  def test_repo_root_is_the_change_md_directory
    with_config("lanes" => { "k6" => {} }) do |config, root|
      assert_equal root, config.repo_root
    end
  end

  def test_boot_env_file_resolves_against_repo_root
    with_config("boot" => { "env_file" => ".env.local" }, "lanes" => { "k6" => {} }) do |config, root|
      assert_equal [ File.join(root, ".env.local") ], config.boot.env_files
    end
  end

  def test_boot_env_file_accepts_a_list_in_order
    with_config("boot" => { "env_file" => [ ".env", ".env.local" ] }, "lanes" => { "k6" => {} }) do |config, root|
      assert_equal [ File.join(root, ".env"), File.join(root, ".env.local") ], config.boot.env_files
    end
  end

  def test_boot_env_file_defaults_to_empty
    with_config("lanes" => { "k6" => {} }) { |config, _root| assert_empty config.boot.env_files }
  end

  def test_lane_paths_resolve_against_repo_root
    with_config("lanes" => { "k6" => { "script" => "apps/load/smoke.js" } }) do |config, root|
      assert_equal File.join(root, "apps", "load", "smoke.js"), config.lane("k6").path("script")
    end
  end

  def test_missing_change_config_block_raises
    Dir.mktmpdir do |root|
      path = File.join(root, "CHANGE.md")
      File.write(path, "---\nchange_policy:\n  protected_branches: [production]\n---\n\nbody\n")
      error = assert_raises(ChangeConfig::ConfigError) { ChangeConfig.load(path) }
      assert_match(/no change_config/, error.message)
    end
  end

  # The dogfooding fix: an author who lands on a bare ConfigError has nowhere to
  # go. The message must name the template and spec so it is actionable.
  def test_missing_change_config_block_names_the_template_and_spec
    Dir.mktmpdir do |root|
      path = File.join(root, "CHANGE.md")
      File.write(path, "---\nchange_policy: {}\n---\n\nbody\n")
      error = assert_raises(ChangeConfig::ConfigError) { ChangeConfig.load(path) }
      assert_match(%r{CHANGE\.template\.md}, error.message)
      assert_match(%r{CHANGE-frontmatter-spec\.md}, error.message)
    end
  end

  # A pre-1.0 placeholder-era file (a separate .pst config, since consolidated
  # into CHANGE.md's own frontmatter) gets a migration hint, not a bare error.
  def test_placeholder_era_sibling_config_gets_a_migration_hint
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, ".pst"))
      File.write(File.join(root, ".pst", "change-fabric.yml"), "placeholder: true\n")
      path = File.join(root, "CHANGE.md")
      File.write(path, "---\nchange_policy: {}\n---\n\nbody\n")
      error = assert_raises(ChangeConfig::ConfigError) { ChangeConfig.load(path) }
      assert_match(/pre-1\.0 placeholder layout/, error.message)
    end
  end

  def test_placeholder_era_prose_reference_gets_a_migration_hint
    Dir.mktmpdir do |root|
      path = File.join(root, "CHANGE.md")
      File.write(path, "---\nchange_policy: {}\n---\n\nSee .pst/change-fabric.yml for config.\n")
      error = assert_raises(ChangeConfig::ConfigError) { ChangeConfig.load(path) }
      assert_match(/pre-1\.0 placeholder layout/, error.message)
    end
  end

  def test_missing_file_raises
    assert_raises(ChangeConfig::ConfigError) { ChangeConfig.load("/no/such/CHANGE.md") }
  end

  def test_doctor_summarizes_a_valid_config
    with_config("project" => "app", "lanes" => { "k6" => { "enabled" => true } }) do |_config, root|
      summary = ChangeConfig.doctor(File.join(root, "CHANGE.md"))
      assert_match(/project: app/, summary)
      assert_match(/enabled lanes: k6/, summary)
      assert_match(/no boot\.health\.url set/, summary)
    end
  end

  def test_doctor_raises_the_same_config_error_on_a_bad_file
    assert_raises(ChangeConfig::ConfigError) { ChangeConfig.doctor("/no/such/CHANGE.md") }
  end

  def test_profile_overrides_project_and_boot_and_lane_base_url
    config = {
      "project" => "app", "boot" => { "up" => "docker compose up -d", "target_url" => "http://app:3000" },
      "lanes" => { "k6" => { "enabled" => true, "base_url" => "http://app:3000" } },
      "profiles" => {
        "staging" => {
          "project" => "app-staging",
          "boot" => { "up" => "true", "down" => "true", "target_url" => "https://staging.app" },
          "lanes" => { "k6" => { "base_url" => "https://staging.app" } }
        }
      }
    }
    with_config(config, "staging") do |loaded, _root|
      assert_equal "app-staging", loaded.project
      assert_equal "true", loaded.boot.up
      assert_equal "https://staging.app", loaded.boot.target_url
      assert_equal "https://staging.app", loaded.lane("k6").base_url("fallback")
    end
  end

  def test_unselected_fields_inherit_from_the_base_config
    config = {
      "project" => "app",
      "lanes" => { "a11y" => { "enabled" => true, "routes" => [ "/login" ], "threshold" => "serious" } },
      "profiles" => { "staging" => { "project" => "app-staging" } }
    }
    with_config(config, "staging") do |loaded, _root|
      assert_equal [ "/login" ], loaded.lane("a11y")["routes"]
      assert_equal "serious", loaded.lane("a11y")["threshold"]
    end
  end

  def test_default_profile_is_used_when_none_is_passed
    config = {
      "project" => "app", "default_profile" => "staging",
      "lanes" => { "k6" => { "enabled" => true } },
      "profiles" => { "staging" => { "project" => "app-staging" } }
    }
    with_config(config) do |loaded, _root|
      assert_equal "app-staging", loaded.project
    end
  end

  def test_profiles_present_with_no_selection_and_no_default_raises
    config = {
      "project" => "app", "lanes" => { "k6" => { "enabled" => true } },
      "profiles" => { "staging" => { "project" => "app-staging" } }
    }
    error = assert_raises(ChangeConfig::ConfigError) { with_config(config) { |_c| } }
    assert_match(/no profile was selected/, error.message)
  end

  def test_unknown_profile_name_raises
    config = {
      "project" => "app", "lanes" => { "k6" => { "enabled" => true } },
      "profiles" => { "staging" => { "project" => "app-staging" } }
    }
    error = assert_raises(ChangeConfig::ConfigError) { with_config(config, "prod") { |_c| } }
    assert_match(/unknown profile 'prod'/, error.message)
  end

  def test_profile_lane_key_outside_the_allowed_set_is_rejected
    config = {
      "project" => "app", "lanes" => { "a11y" => { "enabled" => true, "routes" => [ "/" ] } },
      "profiles" => { "staging" => { "lanes" => { "a11y" => { "routes" => [ "/staging" ] } } } }
    }
    error = assert_raises(ChangeConfig::ConfigError) { with_config(config, "staging") { |_c| } }
    assert_match(/profile 'staging'.*a11y.*routes/, error.message)
  end

  def test_profile_lanes_that_is_not_a_mapping_raises_config_error
    config = {
      "project" => "app", "lanes" => { "k6" => { "enabled" => true } },
      "profiles" => { "staging" => { "lanes" => "bogus" } }
    }
    error = assert_raises(ChangeConfig::ConfigError) { with_config(config, "staging") { |_c| } }
    assert_match(/profile 'staging'.*lanes.*mapping/, error.message)
  end

  def test_profile_lane_override_that_is_not_a_mapping_is_rejected
    config = {
      "project" => "app", "lanes" => { "a11y" => { "enabled" => true, "routes" => [ "/" ] } },
      "profiles" => { "staging" => { "lanes" => { "a11y" => "bogus" } } }
    }
    error = assert_raises(ChangeConfig::ConfigError) { with_config(config, "staging") { |_c| } }
    assert_match(/profile 'staging' lane 'a11y'.*mapping/, error.message)
  end

  def test_a_repo_with_no_profiles_block_ignores_a_nil_profile_request
    with_config("project" => "app", "lanes" => { "k6" => { "enabled" => true } }) do |loaded, _root|
      assert_equal "app", loaded.project
    end
  end

  def test_doctor_reports_the_resolved_profile
    config = {
      "project" => "app", "lanes" => { "k6" => { "enabled" => true } },
      "profiles" => { "staging" => { "project" => "app-staging" } }
    }
    with_config(config, "staging") do |_loaded, root|
      summary = ChangeConfig.doctor(File.join(root, "CHANGE.md"), profile: "staging")
      assert_match(/profile: staging/, summary)
      assert_match(/project: app-staging/, summary)
    end
  end
end
