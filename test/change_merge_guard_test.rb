# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../scripts/change_merge_guard"
require_relative "../scripts/change_gate_store"

# A guard with the two shell-backed lookups stubbed, so the decision logic can be
# exercised without a real repo or gh. The CHANGE.md policy read and the gate
# store read stay real (they read files under the stubbed root and HOME).
class StubMergeGuard < ChangeMergeGuard
  def initialize(event, root:, pr:)
    super(event)
    @root = root
    @pr = pr
  end

  private

  def repo_root = @root
  def pr_facts = @pr
end

class ChangeMergeGuardTest < Minitest::Test
  SHA = "deadbeefcafe0000"

  def setup
    @home = Dir.mktmpdir
    @prev = Dir.home
    ENV["HOME"] = @home
    ENV.delete("PST_ALLOW_UNGATED_MERGE")
    @root = Dir.mktmpdir
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
    FileUtils.remove_entry(@root)
  end

  def write_change_md(admin_allowed:, staging_profile: nil)
    profile_line = staging_profile ? ", profile: #{staging_profile}" : ""
    front = <<~YAML
      change_policy:
        promotion:
          staging: { require_change_pass: true#{profile_line} }
          production: { require_change_pass: true }
        admin_bypass:
          allowed: #{admin_allowed}
          require_change_pass: true
    YAML
    File.write(File.join(@root, "CHANGE.md"), "---\n#{front}---\n\nbody\n")
  end

  def record_pass(profile: nil)
    ChangeGateStore.new(SHA, profile: profile).record(
      scope: "all", status: "pass", project: "app", lanes: {}, report: "r.md"
    )
  end

  def decision(command, base:, admin_allowed: false, staging_profile: nil)
    write_change_md(admin_allowed: admin_allowed, staging_profile: staging_profile)
    event = { "tool_name" => "Bash", "tool_input" => { "command" => command } }
    io = StringIO.new
    StubMergeGuard.new(event, root: @root, pr: [ base, SHA ]).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string).dig("hookSpecificOutput", "permissionDecision")
  end

  def test_escape_hatch_suppresses_the_guard
    ENV["PST_ALLOW_UNGATED_MERGE"] = "1"
    assert_nil decision("gh pr merge 12 --squash", base: "production")
  end

  def test_non_merge_command_ignored
    assert_nil decision("gh pr view 12", base: "production")
  end

  def test_unprotected_base_merges_freely
    assert_nil decision("gh pr merge 12 --squash", base: "development")
  end

  def test_protected_merge_without_gate_is_denied
    assert_equal "deny", decision("gh pr merge 12 --squash", base: "staging")
  end

  def test_protected_merge_with_comprehensive_pass_allowed
    record_pass
    assert_nil decision("gh pr merge 12 --squash", base: "staging")
  end

  def test_admin_bypass_denied_when_repo_forbids_it
    record_pass
    assert_equal "deny", decision("gh pr merge 12 --squash --admin", base: "production", admin_allowed: false)
  end

  def test_admin_bypass_allowed_still_needs_the_gate
    assert_equal "deny", decision("gh pr merge 12 --admin", base: "production", admin_allowed: true)
  end

  def test_admin_bypass_allowed_with_gate_passes
    record_pass
    assert_nil decision("gh pr merge 12 --admin", base: "production", admin_allowed: true)
  end

  def test_profile_scoped_promotion_checks_that_profiles_gate_not_the_default
    record_pass
    assert_equal "deny", decision("gh pr merge 12 --squash", base: "staging", staging_profile: "staging")
  end

  def test_profile_scoped_promotion_passes_once_that_profile_recorded
    record_pass(profile: "staging")
    assert_nil decision("gh pr merge 12 --squash", base: "staging", staging_profile: "staging")
  end
end
