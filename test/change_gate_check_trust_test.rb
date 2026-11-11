# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "git_fixture"
require_relative "../scripts/change_gate_check"
require_relative "../scripts/change_gate_store"

# The merge and tag guards share ChangeGateCheck. Given the repo root, a
# passing record satisfies the gate only when its trust block proves every
# host-run step defined at the sha ran as the base branch or an approval
# defines it.
class ChangeGateCheckTrustTest < Minitest::Test
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

  def commit(up)
    File.write(File.join(@repo, "CHANGE.md"), <<~MD)
      ---
      change_config:
        project: demo
        boot:
          up: "#{up}"
        lanes:
          k6:
            enabled: true
      ---
    MD
    GitFixture.git(@repo, "add", "CHANGE.md")
    GitFixture.git(@repo, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "c")
    GitFixture.git(@repo, "rev-parse", "HEAD").strip
  end

  def record_pass(sha, trust: nil)
    manifest = trust ? { "trust" => trust } : nil
    ChangeGateStore.new(sha).record(scope: "all", status: "pass", project: "demo", lanes: { "k6" => "pass" },
                                    report: "r.md", manifest: manifest)
  end

  def trust_for(sha)
    digests = ChangeTrust.digests(ChangeTrust.snapshot_definitions(@repo, sha))
    { "steps" => digests.transform_values { |digest| { "digest" => digest, "source" => "base" } } }
  end

  def test_a_pass_without_a_trust_block_is_not_satisfied_when_boot_is_defined
    sha = commit("docker compose up -d")
    GitFixture.git(@repo, "update-ref", "refs/remotes/origin/main", sha)
    record_pass(sha)
    check = ChangeGateCheck.new(sha: sha, profile: nil, root: @repo)
    refute check.satisfied?
    assert_match(/predates step trust/, check.trust_clause)
  end

  def test_a_pass_with_a_matching_trust_block_is_satisfied
    sha = commit("docker compose up -d")
    GitFixture.git(@repo, "update-ref", "refs/remotes/origin/main", sha)
    record_pass(sha, trust: trust_for(sha))
    assert ChangeGateCheck.new(sha: sha, profile: nil, root: @repo).satisfied?
  end

  def test_a_changed_boot_needs_an_approval_even_with_a_trust_block
    base = commit("docker compose up -d")
    GitFixture.git(@repo, "update-ref", "refs/remotes/origin/main", base)
    sha = commit("true")
    record_pass(sha, trust: trust_for(sha))
    refute ChangeGateCheck.new(sha: sha, profile: nil, root: @repo).satisfied?
    digest = trust_for(sha).dig("steps", "boot.up", "digest")
    ChangeApprovalStore.new(sha).record(steps: [ [ "boot.up", digest ] ], by: "t")
    assert ChangeGateCheck.new(sha: sha, profile: nil, root: @repo).satisfied?
  end

  def test_without_a_root_the_question_is_unchanged
    sha = commit("docker compose up -d")
    record_pass(sha)
    assert ChangeGateCheck.new(sha: sha, profile: nil).satisfied?
  end

  def test_no_record_has_no_trust_clause
    sha = commit("docker compose up -d")
    assert_equal "", ChangeGateCheck.new(sha: sha, profile: nil, root: @repo).trust_clause
  end
end
