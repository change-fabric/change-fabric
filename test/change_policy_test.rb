# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/change_policy"

class ChangePolicyTest < Minitest::Test
  def policy(front)
    Dir.mktmpdir do |root|
      File.write(File.join(root, "CHANGE.md"), "---\n#{front}---\n\nbody\n")
      yield ChangePolicy.for_repo(root)
    end
  end

  def test_absent_change_md_is_ungoverned
    Dir.mktmpdir { |root| assert_nil ChangePolicy.for_repo(root) }
  end

  def test_promotion_branches_are_protected
    front = <<~YAML
      change_policy:
        promotion:
          staging: { require_change_pass: true }
          production: { require_change_pass: false }
    YAML
    policy(front) do |p|
      assert p.protects?("staging")
      assert p.protects?("production")
      refute p.protects?("development")
      assert p.require_change_pass?("staging")
      refute p.require_change_pass?("production")
    end
  end

  def test_admin_bypass_defaults_to_forbidden
    policy("change_policy:\n  protected_branches: [production]\n") do |p|
      refute p.admin_bypass_allowed?
    end
  end

  def test_admin_bypass_allowed_still_requires_change_pass_by_default
    front = <<~YAML
      change_policy:
        admin_bypass:
          allowed: true
    YAML
    policy(front) do |p|
      assert p.admin_bypass_allowed?
      assert p.admin_bypass_requires_change_pass?
    end
  end

  def test_profile_for_reads_the_promotion_rules_profile
    front = <<~YAML
      change_policy:
        promotion:
          staging: { require_change_pass: true, profile: staging }
          production: { require_change_pass: true }
    YAML
    policy(front) do |p|
      assert_equal "staging", p.profile_for("staging")
      assert_nil p.profile_for("production")
      assert_nil p.profile_for("development")
    end
  end

  def test_malformed_frontmatter_falls_back_to_default_protection
    Dir.mktmpdir do |root|
      File.write(File.join(root, "CHANGE.md"), "no frontmatter here\n")
      p = ChangePolicy.for_repo(root)
      assert p.protects?("staging")
      assert p.protects?("production")
      refute p.admin_bypass_allowed?
    end
  end

  def test_apps_for_defaults_to_nil
    front = <<~YAML
      change_policy:
        promotion:
          production: { require_change_pass: true }
    YAML
    policy(front) { |p| assert_nil p.apps_for("production") }
  end

  def test_apps_for_returns_the_explicit_list
    front = <<~YAML
      change_policy:
        promotion:
          production: { require_change_pass: true, apps: [portal] }
    YAML
    policy(front) { |p| assert_equal %w[portal], p.apps_for("production") }
  end

  def test_apps_for_treats_an_empty_list_as_every_app
    front = <<~YAML
      change_policy:
        promotion:
          production: { require_change_pass: true, apps: [] }
    YAML
    policy(front) { |p| assert_nil p.apps_for("production") }
  end

  # --- trunk + tag releases (0.9.0-alpha.1): prefix splitting -------------

  def test_tag_prefixed_promotion_keys_split_into_tag_promotion
    front = <<~YAML
      change_policy:
        promotion:
          main: { require_change_pass: true }
          tag:staging/v*: { require_change_pass: true, profile: staging }
    YAML
    policy(front) do |p|
      assert_equal %w[main], p.branch_promotion.keys
      assert_equal %w[staging/v*], p.tag_promotion.keys
      assert_equal "staging", p.profile_for_rule(p.tag_promotion["staging/v*"])
    end
  end

  def test_branch_prefix_is_a_synonym_for_an_unprefixed_key
    front = <<~YAML
      change_policy:
        promotion:
          branch:main: { require_change_pass: true }
    YAML
    policy(front) do |p|
      assert p.protects?("main")
      assert_equal %w[main], p.branch_promotion.keys
    end
  end

  def test_a_tag_key_never_protects_a_branch_of_the_same_shaped_name
    front = <<~YAML
      change_policy:
        promotion:
          main: { require_change_pass: true }
          tag:staging/v*: { require_change_pass: true }
    YAML
    policy(front) do |p|
      refute p.protects?("staging/v*")
      refute p.protects?("staging")
      assert p.protects_tag?("staging/v1.4.0")
    end
  end

  def test_protected_tag_patterns_from_promotion_and_protected_refs
    front = <<~YAML
      change_policy:
        protected_refs:
          - main
          - "tag:production/v*"
        promotion:
          tag:staging/v*: { require_change_pass: true }
    YAML
    policy(front) do |p|
      assert_equal %w[staging/v* production/v*], p.protected_tag_patterns
      assert p.protects?("main")
    end
  end

  def test_tag_rules_for_matches_fnmatch_semantics
    front = <<~YAML
      change_policy:
        promotion:
          tag:staging/v*: { environment: staging }
          tag:v*-staging: { environment: legacy-staging }
          tag:release/staging/*: { environment: release-staging }
          tag:**/*: { environment: catch-all }
    YAML
    policy(front) do |p|
      assert_equal %w[staging/v* **/*], p.tag_rules_for("staging/v1.4.0").map(&:first)
      assert_equal %w[v*-staging **/*], p.tag_rules_for("v1.4.0-staging").map(&:first)
      assert_equal %w[release/staging/* **/*], p.tag_rules_for("release/staging/v1").map(&:first)
      refute_includes p.tag_rules_for("staging/hotfix/v1.4.0").map(&:first), "staging/v*"
    end
  end

  def test_overlapping_tag_rules_are_all_returned_and_all_required
    front = <<~YAML
      change_policy:
        promotion:
          tag:staging/v*: { profile: staging }
          tag:staging/v1.*: { review_required: true }
    YAML
    policy(front) do |p|
      matched = p.tag_rules_for("staging/v1.4.0").map(&:first)
      assert_equal %w[staging/v* staging/v1.*], matched
    end
  end

  def test_no_tag_rules_means_no_tag_gating
    front = <<~YAML
      change_policy:
        promotion:
          staging: { require_change_pass: true }
    YAML
    policy(front) do |p|
      assert_empty p.protected_tag_patterns
      refute p.protects_tag?("staging/v1.4.0")
    end
  end

  def test_default_protected_applies_only_to_the_branch_set
    front = <<~YAML
      change_policy:
        promotion:
          main: { require_change_pass: true }
          tag:staging/v*: { require_change_pass: true }
          tag:production/v*: { require_change_pass: true }
    YAML
    policy(front) do |p|
      assert_equal %w[main], p.protected_branches
      refute p.protects?("staging")
      refute p.protects?("production")
    end
  end

  def test_default_protected_still_falls_back_when_the_branch_set_is_truly_empty
    front = <<~YAML
      change_policy:
        promotion:
          tag:staging/v*: { require_change_pass: true }
    YAML
    policy(front) do |p|
      assert_equal ChangePolicy::DEFAULT_PROTECTED, p.protected_branches
    end
  end
end
