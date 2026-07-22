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
end
