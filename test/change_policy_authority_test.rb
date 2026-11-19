# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "git_fixture"
require_relative "../scripts/change_policy"

# ChangePolicy.authoritative (0.26.0): approval policy comes from the fetched
# base or default branch of the claimed repo, never the working tree, and
# every failure to establish it fails closed.
class ChangePolicyAuthorityTest < Minitest::Test
  URL = "https://github.com/acme/widget.git"
  POLICY = <<~MD
    ---
    change_policy:
      require_approval_proof: passkey
      approval_pins:
        receipt_key_fingerprint: "sha256:#{'a' * 64}"
        rp_id: console.example.com
      admin_bypass:
        carve_out_paths: [CHANGE.md, "hooks/**", "scripts/*guard*.rb"]
    ---
  MD

  def setup
    @dir = Dir.mktmpdir
    @upstream = File.join(@dir, "upstream")
    @clone = File.join(@dir, "clone")
    GitFixture.git_init(@upstream, "-b", "main")
    @main_sha = commit(@upstream, POLICY)
    GitFixture.git(@upstream, "checkout", "-qb", "release")
    @release_sha = commit(@upstream, "---\nchange_policy:\n  require_approval_proof: local\n---\n")
    GitFixture.git(@upstream, "checkout", "-q", "main")
    GitFixture.git_init(@clone, "-b", "work")
    GitFixture.git(@clone, "remote", "add", "origin", URL)
    GitFixture.git(@clone, "config", "url.#{@upstream}.insteadOf", URL)
    File.write(File.join(@clone, "CHANGE.md"), "---\nchange_policy: {}\n---\n")
  end

  def teardown = FileUtils.remove_entry(@dir)

  def commit(root, text)
    File.write(File.join(root, "CHANGE.md"), text)
    GitFixture.git(root, "add", "CHANGE.md")
    GitFixture.git(root, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "c")
    GitFixture.git(root, "rev-parse", "HEAD").strip
  end

  def authority(repo: "acme/widget", base: nil, default: "main")
    ChangePolicy.authoritative(root: @clone, repo: repo, base: base, default_branch: ->(_root, _repo) { default })
  end

  def test_reads_the_default_branch_after_a_fetch_never_the_working_tree
    result = authority
    assert_equal @main_sha, result.policy_sha
    assert_equal "origin/main", result.ref
    assert_equal "passkey", result.policy.require_approval_proof
    assert_equal "console.example.com", result.policy.approval_pins["rp_id"]
    assert_nil ChangePolicy.for_repo(@clone).require_approval_proof, "the working tree says otherwise"
  end

  def test_reads_the_pr_base_branch_when_given
    result = authority(base: "release")
    assert_equal @release_sha, result.policy_sha
    assert_equal "local", result.policy.require_approval_proof
  end

  def test_a_missing_ref_fails_closed
    assert_raises(ChangePolicy::Unreadable) { authority(base: "no-such-branch") }
  end

  def test_an_unresolvable_default_branch_fails_closed
    assert_raises(ChangePolicy::Unreadable) { authority(default: nil) }
    assert_raises(ChangePolicy::Unreadable) { authority(default: "--upload-pack=x") }
  end

  def test_a_failed_fetch_fails_closed
    GitFixture.git(@clone, "config", "url.#{File.join(@dir, 'gone')}.insteadOf", URL)
    GitFixture.git(@clone, "config", "--unset", "url.#{@upstream}.insteadOf")
    assert_raises(ChangePolicy::Unreadable) { authority }
  end

  def test_an_origin_naming_another_repo_fails_closed
    error = assert_raises(ChangePolicy::Unreadable) { authority(repo: "acme/other") }
    assert_match(/is not acme\/other/, error.message)
  end

  def test_no_origin_fails_closed
    GitFixture.git(@clone, "remote", "remove", "origin")
    assert_raises(ChangePolicy::Unreadable) { authority }
  end

  def test_origin_repo_and_carve_out_globs
    assert_equal "acme/widget", ChangePolicy.origin_repo(@clone)
    policy = authority.policy
    assert policy.carve_out?("CHANGE.md")
    assert policy.carve_out?("hooks/deep/nested.rb")
    assert policy.carve_out?("scripts/change_merge_guard.rb")
    refute policy.carve_out?("scripts/sub/x_guard_y.rb"), "* stays in one directory"
    refute policy.carve_out?("README.md")
  end

  def test_schema_requires_pins_under_passkey_and_checks_their_shape
    errors = ChangeSchema.approval_proof_errors("require_approval_proof" => "passkey")
    assert_includes errors, "change_policy.approval_pins is required by require_approval_proof: passkey"
    bad = ChangeSchema.approval_proof_errors("approval_pins" => { "receipt_key_fingerprint" => "md5:x", "rp_id" => 3 },
                                             "admin_bypass" => { "carve_out_paths" => "hooks/**" })
    assert_equal 3, bad.size
    assert_empty authority.policy.gate_errors
  end
end
