# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "yaml"
require_relative "../scripts/change_apps"

class ChangeAppRegistryTest < Minitest::Test
  def write_root(root, change_config, change_policy = nil)
    front = { "change_config" => change_config }
    front["change_policy"] = change_policy if change_policy
    path = File.join(root, "CHANGE.md")
    File.write(path, "#{YAML.dump(front)}---\n\nbody\n")
    path
  end

  def write_app(path, change_config, change_policy: nil)
    FileUtils.mkdir_p(File.dirname(path))
    doc = { "change_config" => change_config }
    doc["change_policy"] = change_policy if change_policy
    File.write(path, YAML.dump(doc))
  end

  def test_single_app_fallback_returns_one_synthetic_entry_named_for_project
    Dir.mktmpdir do |root|
      change_md = write_root(root, "project" => "my-app", "lanes" => { "k6" => { "enabled" => true } })
      registry = ChangeAppRegistry.load(change_md)

      refute registry.multi_app?
      assert_equal %w[my-app], registry.names
      assert_equal change_md, registry.entries.first.config_path
    end
  end

  def test_explicit_registry_preserves_registry_order
    Dir.mktmpdir do |root|
      write_app(File.join(root, "apps/portal/CHANGE.app.yml"), { "project" => "portal", "lanes" => { "k6" => { "enabled" => true } } })
      write_app(File.join(root, "apps/scattergram/CHANGE.app.yml"), { "project" => "scattergram", "lanes" => { "k6" => { "enabled" => true } } })
      change_md = write_root(root, "project" => "my-repo", "apps" => {
        "portal" => { "config" => "apps/portal/CHANGE.app.yml" },
        "scattergram" => { "config" => "apps/scattergram/CHANGE.app.yml" }
      })

      registry = ChangeAppRegistry.load(change_md)

      assert registry.multi_app?
      assert_equal %w[portal scattergram], registry.names
    end
  end

  def test_unknown_app_name_lists_the_registered_apps
    Dir.mktmpdir do |root|
      write_app(File.join(root, "apps/portal/CHANGE.app.yml"), { "project" => "portal", "lanes" => { "k6" => { "enabled" => true } } })
      change_md = write_root(root, "project" => "my-repo", "apps" => { "portal" => { "config" => "apps/portal/CHANGE.app.yml" } })
      registry = ChangeAppRegistry.load(change_md)

      error = assert_raises(ChangeAppRegistry::RegistryError) { registry.fetch(%w[scattergram]) }
      assert_match(/unknown app 'scattergram'; registered apps: portal/, error.message)
    end
  end

  def test_disabled_app_is_excluded_from_enabled_entries_but_present_in_entries
    Dir.mktmpdir do |root|
      write_app(File.join(root, "apps/portal/CHANGE.app.yml"), { "project" => "portal", "lanes" => { "k6" => { "enabled" => true } } })
      write_app(File.join(root, "apps/wip/CHANGE.app.yml"), { "project" => "wip", "lanes" => { "k6" => { "enabled" => true } } })
      change_md = write_root(root, "project" => "my-repo", "apps" => {
        "portal" => { "config" => "apps/portal/CHANGE.app.yml" },
        "wip" => { "config" => "apps/wip/CHANGE.app.yml", "enabled" => false }
      })

      registry = ChangeAppRegistry.load(change_md)

      assert_equal %w[portal wip], registry.names
      assert_equal %w[portal], registry.enabled_entries.map(&:name)
    end
  end

  def test_root_with_both_apps_and_lanes_raises_naming_both_keys
    Dir.mktmpdir do |root|
      write_app(File.join(root, "apps/portal/CHANGE.app.yml"), { "project" => "portal", "lanes" => { "k6" => { "enabled" => true } } })
      change_md = write_root(root, "project" => "my-repo", "lanes" => { "k6" => { "enabled" => true } },
                                    "apps" => { "portal" => { "config" => "apps/portal/CHANGE.app.yml" } })

      error = assert_raises(ChangeAppRegistry::RegistryError) { ChangeAppRegistry.load(change_md) }
      assert_match(/apps:.*alongside lanes/, error.message)
    end
  end

  def test_root_with_both_apps_and_profiles_raises
    Dir.mktmpdir do |root|
      write_app(File.join(root, "apps/portal/CHANGE.app.yml"), { "project" => "portal", "lanes" => { "k6" => { "enabled" => true } } })
      change_md = write_root(root, "project" => "my-repo", "profiles" => { "local" => {} },
                                    "apps" => { "portal" => { "config" => "apps/portal/CHANGE.app.yml" } })

      error = assert_raises(ChangeAppRegistry::RegistryError) { ChangeAppRegistry.load(change_md) }
      assert_match(/alongside profiles/, error.message)
    end
  end

  def test_an_entry_with_no_config_raises
    Dir.mktmpdir do |root|
      change_md = write_root(root, "project" => "my-repo", "apps" => { "portal" => {} })

      error = assert_raises(ChangeAppRegistry::RegistryError) { ChangeAppRegistry.load(change_md) }
      assert_match(/apps\.portal has no config/, error.message)
    end
  end

  def test_an_entry_whose_config_file_is_missing_names_the_resolved_path
    Dir.mktmpdir do |root|
      change_md = write_root(root, "project" => "my-repo", "apps" => { "portal" => { "config" => "apps/portal/CHANGE.app.yml" } })

      error = assert_raises(ChangeAppRegistry::RegistryError) { ChangeAppRegistry.load(change_md) }
      assert_match(%r{apps\.portal\.config not found}, error.message)
    end
  end

  def test_an_app_file_carrying_change_policy_raises_via_entry_load
    Dir.mktmpdir do |root|
      write_app(File.join(root, "apps/portal/CHANGE.app.yml"), { "project" => "portal", "lanes" => { "k6" => { "enabled" => true } } },
                change_policy: { "protected_branches" => [ "production" ] })
      change_md = write_root(root, "project" => "my-repo", "apps" => { "portal" => { "config" => "apps/portal/CHANGE.app.yml" } })

      registry = ChangeAppRegistry.load(change_md)
      entry = registry.fetch(%w[portal]).first
      error = assert_raises(ChangeConfig::ConfigError) { entry.load }
      assert_match(/change_policy.*repo-wide/, error.message)
    end
  end

  def test_doctor_walks_every_registered_app
    Dir.mktmpdir do |root|
      write_app(File.join(root, "apps/portal/CHANGE.app.yml"), { "project" => "portal", "lanes" => { "k6" => { "enabled" => true } } })
      write_app(File.join(root, "apps/scattergram/CHANGE.app.yml"), { "project" => "scattergram", "lanes" => { "k6" => { "enabled" => true } } })
      change_md = write_root(root, "project" => "my-repo", "apps" => {
        "portal" => { "config" => "apps/portal/CHANGE.app.yml", "description" => "the portal" },
        "scattergram" => { "config" => "apps/scattergram/CHANGE.app.yml" }
      })

      summary = ChangeAppRegistry.doctor(change_md)
      assert_match(/apps: portal \(the portal\), scattergram/, summary)
      assert_match(/app: portal/, summary)
      assert_match(/app: scattergram/, summary)
    end
  end

  def test_doctor_lists_branch_and_tag_promotion_targets
    Dir.mktmpdir do |root|
      change_md = File.join(root, "CHANGE.md")
      File.write(change_md, <<~MD)
        ---
        change_config:
          project: my-app
          lanes:
            k6: { enabled: true }
        change_policy:
          promotion:
            main: { require_change_pass: true }
            tag:staging/v*: { environment: staging, profile: staging }
        ---
        body
      MD

      summary = ChangeAppRegistry.doctor(change_md)
      assert_match(/promotion targets:/, summary)
      assert_match(/branch main: profile=\(none\) apps=every enabled app/, summary)
      assert_match(/tag:staging\/v\* \(staging\): profile=staging apps=every enabled app/, summary)
    end
  end

  def test_doctor_flags_a_tag_promotion_profile_no_required_app_defines
    Dir.mktmpdir do |root|
      write_app(File.join(root, "apps/scattergram/CHANGE.app.yml"), {
        "project" => "scattergram", "default_profile" => "local", "lanes" => { "k6" => { "enabled" => true } },
        "profiles" => { "local" => {} }
      })
      change_md = write_root(
        root,
        { "project" => "my-repo", "apps" => { "scattergram" => { "config" => "apps/scattergram/CHANGE.app.yml" } } },
        { "promotion" => { "tag:production/v*" => { "require_change_pass" => true, "profile" => "production" } } }
      )

      summary = ChangeAppRegistry.doctor(change_md)
      assert_match(/promotion\.tag:production\/v\*\.profile 'production' is unsatisfiable: app 'scattergram' has no such profile/, summary)
    end
  end

  def test_doctor_flags_an_explicitly_empty_apps_list_on_a_tag_rule
    Dir.mktmpdir do |root|
      write_app(File.join(root, "apps/portal/CHANGE.app.yml"), { "project" => "portal", "lanes" => { "k6" => { "enabled" => true } } })
      change_md = write_root(
        root,
        { "project" => "my-repo", "apps" => { "portal" => { "config" => "apps/portal/CHANGE.app.yml" } } },
        { "promotion" => { "tag:production/v*" => { "require_change_pass" => true, "apps" => [] } } }
      )

      summary = ChangeAppRegistry.doctor(change_md)
      assert_match(/change_policy\.promotion\.tag:production\/v\*\.apps is explicitly empty/, summary)
    end
  end

  def test_doctor_warns_on_overlapping_tag_patterns
    Dir.mktmpdir do |root|
      change_md = File.join(root, "CHANGE.md")
      File.write(change_md, <<~MD)
        ---
        change_config:
          project: my-app
          lanes:
            k6: { enabled: true }
        change_policy:
          promotion:
            tag:staging/v*: { require_change_pass: true }
            tag:staging/v1.*: { require_change_pass: true }
        ---
        body
      MD

      summary = ChangeAppRegistry.doctor(change_md)
      assert_match(/tag:staging\/v\* and tag:staging\/v1\.\* can both match the same tag/, summary)
    end
  end

  def test_doctor_warns_on_a_literal_looking_tag_pattern
    Dir.mktmpdir do |root|
      change_md = File.join(root, "CHANGE.md")
      File.write(change_md, <<~MD)
        ---
        change_config:
          project: my-app
          lanes:
            k6: { enabled: true }
        change_policy:
          promotion:
            tag:release-only: { require_change_pass: true }
        ---
        body
      MD

      summary = ChangeAppRegistry.doctor(change_md)
      assert_match(/tag:release-only has no glob metacharacter and no '\/'/, summary)
    end
  end

  def test_doctor_warns_on_trunk_ancestor_and_prior_tag_misplaced_on_a_branch_rule
    Dir.mktmpdir do |root|
      change_md = File.join(root, "CHANGE.md")
      File.write(change_md, <<~MD)
        ---
        change_config:
          project: my-app
          lanes:
            k6: { enabled: true }
        change_policy:
          promotion:
            main: { require_trunk_ancestor: main, require_prior_tag: "staging/v*" }
        ---
        body
      MD

      summary = ChangeAppRegistry.doctor(change_md)
      assert_match(/promotion\.main\.require_trunk_ancestor is set on a branch rule/, summary)
      assert_match(/promotion\.main\.require_prior_tag is set on a branch rule/, summary)
    end
  end

  def test_doctor_flags_a_promotion_profile_no_required_app_defines
    Dir.mktmpdir do |root|
      write_app(File.join(root, "apps/portal/CHANGE.app.yml"), { "project" => "portal", "lanes" => { "k6" => { "enabled" => true } } })
      write_app(File.join(root, "apps/scattergram/CHANGE.app.yml"), {
        "project" => "scattergram", "default_profile" => "local", "lanes" => { "k6" => { "enabled" => true } },
        "profiles" => { "local" => {} }
      })
      change_md = write_root(
        root,
        {
          "project" => "my-repo",
          "apps" => {
            "portal" => { "config" => "apps/portal/CHANGE.app.yml" },
            "scattergram" => { "config" => "apps/scattergram/CHANGE.app.yml" }
          }
        },
        { "promotion" => { "production" => { "require_change_pass" => true, "profile" => "production" } } }
      )

      summary = ChangeAppRegistry.doctor(change_md)
      assert_match(/unsatisfiable: app 'scattergram' has no such profile/, summary)
    end
  end
end
