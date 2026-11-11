# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "git_fixture"
require_relative "../scripts/change_trust"

# Base-branch trust: a step runs when its definition equals the base
# branch's, or when a human approved that exact definition for that exact
# commit. Everything else is refused, so the gate cannot be satisfied by a
# pull request that rewrites its own checks.
class ChangeTrustTest < Minitest::Test
  BOOT = { "run" => "docker compose up -d", "env" => [], "env_file" => [], "timeout_seconds" => nil }.freeze

  def setup
    @home = Dir.mktmpdir
    @prev_home = ENV["HOME"]
    ENV["HOME"] = @home
    @repo = Dir.mktmpdir
    GitFixture.git_init(@repo, "-b", "main")
  end

  def teardown
    ENV["HOME"] = @prev_home
    FileUtils.remove_entry(@home)
    FileUtils.remove_entry(@repo)
  end

  def change_md(up:, down: "docker compose down", policy: "")
    <<~MD
      ---
      change_config:
        project: demo
        boot:
          up: "#{up}"
          down: "#{down}"
        lanes:
          k6:
            enabled: true
      #{policy}
      ---
    MD
  end

  def commit(text)
    File.write(File.join(@repo, "CHANGE.md"), text)
    GitFixture.git(@repo, "add", "CHANGE.md")
    GitFixture.git(@repo, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "c")
    GitFixture.git(@repo, "rev-parse", "HEAD").strip
  end

  def point_origin(branch, sha) = GitFixture.git(@repo, "update-ref", "refs/remotes/origin/#{branch}", sha)

  def test_digest_is_stable_across_key_order
    a = ChangeTrust.digest("run" => "x", "env" => %w[A B], "timeout_seconds" => 5)
    b = ChangeTrust.digest("timeout_seconds" => 5, "env" => %w[A B], "run" => "x")
    assert_equal a, b
    assert_match(/\Asha256:[0-9a-f]{64}\z/, a)
    refute_equal a, ChangeTrust.digest("run" => "y", "env" => %w[A B], "timeout_seconds" => 5)
  end

  def test_equal_digest_is_trusted_from_base
    digest = ChangeTrust.digest(BOOT)
    verdict = ChangeTrust.verify(head_digests: { "boot.up" => digest }, base_digests: { "boot.up" => digest }, approvals: [])
    assert verdict.trusted?("boot.up")
    assert_equal :base, verdict.sources["boot.up"]
    assert_empty verdict.untrusted
  end

  def test_step_missing_on_base_is_untrusted
    verdict = ChangeTrust.verify(head_digests: { "boot.up" => "sha256:a" }, base_digests: {}, approvals: [],
                                 head_sha: "abc123")
    refute verdict.trusted?("boot.up")
    assert_equal [ "boot.up" ], verdict.untrusted
    assert_match(/new step/, verdict.refusal("boot.up"))
    assert_match(/change_approve\.rb abc123/, verdict.refusal("boot.up"))
  end

  def test_matching_approval_trusts_the_step
    verdict = ChangeTrust.verify(head_digests: { "boot.up" => "sha256:a" }, base_digests: { "boot.up" => "sha256:b" },
                                 approvals: [ [ "boot.up", "sha256:a" ] ])
    assert_equal :approved, verdict.sources["boot.up"]
  end

  def test_approval_for_a_different_digest_does_not_trust
    verdict = ChangeTrust.verify(head_digests: { "boot.up" => "sha256:a" }, base_digests: {},
                                 approvals: [ [ "boot.up", "sha256:other" ] ])
    refute verdict.trusted?("boot.up")
  end

  def test_approval_for_a_different_sha_does_not_trust
    base_sha = commit(change_md(up: "echo base"))
    point_origin("main", base_sha)
    head_sha = commit(change_md(up: "echo head"))
    head_defs = ChangeTrust.snapshot_definitions(@repo, head_sha)
    ChangeApprovalStore.new(base_sha).record(steps: [ [ "boot.up", ChangeTrust.digest(head_defs["boot.up"]) ] ], by: "t")
    verdict = ChangeTrust.evaluate(root: @repo, head_sha: head_sha, head_definitions: head_defs, fetch: false)
    assert_equal [ "boot.up" ], verdict.untrusted
    assert verdict.trusted?("boot.down")
  end

  def test_head_equal_to_base_trusts_everything
    sha = commit(change_md(up: "echo up"))
    point_origin("main", sha)
    defs = ChangeTrust.snapshot_definitions(@repo, sha)
    verdict = ChangeTrust.evaluate(root: @repo, head_sha: sha, head_definitions: defs, fetch: false)
    assert_empty verdict.untrusted
    assert_equal %w[boot.down boot.up], verdict.sources.keys.sort
    assert_equal sha, verdict.base_sha
    assert_equal "origin/main", verdict.base_ref
  end

  def test_no_base_ref_leaves_every_step_untrusted
    sha = commit(change_md(up: "echo up"))
    defs = ChangeTrust.snapshot_definitions(@repo, sha)
    verdict = ChangeTrust.evaluate(root: @repo, head_sha: sha, head_definitions: defs, fetch: false)
    assert_equal %w[boot.down boot.up], verdict.untrusted.sort
    assert_match(/no base ref resolves/, verdict.note)
  end

  def test_trunk_is_read_from_the_default_branch
    policy = "change_policy:\n  gate:\n    trunk: develop"
    base = commit(change_md(up: "echo up", policy: policy))
    point_origin("main", base)
    point_origin("develop", base)
    assert_equal "origin/develop", ChangeTrust.resolve_base(@repo, fetch: false).ref
  end

  def test_manifest_lists_executed_trusted_steps
    verdict = ChangeTrust.verify(head_digests: { "boot.up" => "sha256:a", "boot.down" => "sha256:b" },
                                 base_digests: { "boot.up" => "sha256:a", "boot.down" => "sha256:b" }, approvals: [])
    manifest = verdict.manifest([ "boot.up" ])
    assert_equal({ "boot.up" => { "digest" => "sha256:a", "source" => "base" } }, manifest["steps"])
  end

  def test_record_problem_requires_a_trust_block
    sha = commit(change_md(up: "echo up"))
    point_origin("main", sha)
    assert_match(/predates step trust/, ChangeTrust.record_problem(root: @repo, sha: sha, record: { "scope" => "all" }))
    record = trust_record(sha, "base")
    assert_nil ChangeTrust.record_problem(root: @repo, sha: sha, record: record)
  end

  def test_record_problem_rejects_an_unapproved_changed_step
    base = commit(change_md(up: "echo base"))
    point_origin("main", base)
    sha = commit(change_md(up: "true"))
    record = trust_record(sha, "approved")
    assert_match(/has no approval/, ChangeTrust.record_problem(root: @repo, sha: sha, record: record))
    digest = record.dig("manifest", "trust", "steps", "boot.up", "digest")
    ChangeApprovalStore.new(sha).record(steps: [ [ "boot.up", digest ] ], by: "t")
    assert_nil ChangeTrust.record_problem(root: @repo, sha: sha, record: record)
  end

  def test_record_problem_rejects_a_record_of_a_different_definition
    sha = commit(change_md(up: "echo up"))
    point_origin("main", sha)
    record = { "manifest" => { "trust" => { "steps" => { "boot.up" => { "digest" => "sha256:x" } } } } }
    assert_match(/not the definition the recorded run executed/,
                 ChangeTrust.record_problem(root: @repo, sha: sha, record: record))
  end

  private

  def trust_record(sha, source)
    digests = ChangeTrust.digests(ChangeTrust.snapshot_definitions(@repo, sha))
    steps = digests.transform_values { |digest| { "digest" => digest, "source" => source } }
    { "manifest" => { "trust" => { "steps" => steps } } }
  end
end
