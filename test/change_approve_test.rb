# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "git_fixture"
require_relative "../scripts/change_approve"

# The approval tool's load-bearing control is that it refuses without a real
# terminal, so an agent's Bash call cannot approve its own changed steps.
# Stdin is injected so the TTY check and the typed confirmation are both
# exercised without one.
class ChangeApproveTest < Minitest::Test
  FakeStdin = Struct.new(:tty_value, :line) do
    def tty? = tty_value
    def gets = line
  end

  def setup
    @home = Dir.mktmpdir
    @prev_home = ENV["HOME"]
    ENV["HOME"] = @home
    @repo = Dir.mktmpdir
    GitFixture.git_init(@repo, "-b", "main")
    @base = commit("echo base")
    GitFixture.git(@repo, "update-ref", "refs/remotes/origin/main", @base)
    @sha = commit("echo head")
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

  def approve(tty:, typed: @sha[0, 12], sha: @sha)
    out = StringIO.new
    err = StringIO.new
    status = ChangeApprove.run([ sha, "--repo", @repo ], stdin: FakeStdin.new(tty, typed), stdout: out, stderr: err,
                                                         fetch: false)
    [ status, out.string, err.string ]
  end

  def test_refuses_without_a_real_tty
    status, _out, err = approve(tty: false)
    refute_equal 0, status
    assert_match(/real terminal/, err)
    assert_empty ChangeApprovalStore.new(@sha).approvals
  end

  def test_refuses_a_wrong_typed_prefix
    status, _out, err = approve(tty: true, typed: "000000000000")
    refute_equal 0, status
    assert_match(/did not match/, err)
    assert_empty ChangeApprovalStore.new(@sha).approvals
  end

  def test_records_the_changed_step_digest_on_a_correct_prefix
    status, out, _err = approve(tty: true)
    assert_equal 0, status
    assert_match(/echo head/, out)
    assert_match(/echo base/, out)
    defs = ChangeTrust.snapshot_definitions(@repo, @sha)
    assert_equal [ [ "boot.up", ChangeTrust.digest(defs["boot.up"]) ] ], ChangeApprovalStore.new(@sha).approvals
  end

  def test_nothing_to_approve_when_the_step_matches_base
    status, out, _err = approve(tty: true, sha: @base)
    assert_equal 0, status
    assert_match(/nothing to approve/, out)
  end

  def test_usage_error_without_a_sha
    err = StringIO.new
    status = ChangeApprove.run([], stdin: FakeStdin.new(true, ""), stdout: StringIO.new, stderr: err)
    refute_equal 0, status
    assert_match(/usage/, err.string)
  end
end
