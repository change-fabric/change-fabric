# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require "json"
require_relative "git_fixture"
require_relative "../scripts/change_approve"
require_relative "support/totp_enrollment"

# The approval tool's load-bearing control is that it refuses without a real
# terminal, so an agent's Bash call cannot approve its own changed steps.
# Stdin is injected so the TTY check and the typed confirmation are both
# exercised without one.
class ChangeApproveTest < Minitest::Test
  include TotpEnrollment

  # Answers each gets in turn: the typed prefix, then the TOTP code.
  FakeStdin = Struct.new(:tty_value, :lines) do
    def tty? = tty_value

    def gets
      @queue ||= Array(lines).dup
      @queue.shift
    end
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
    @store = enroll_totp
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

  def commit_app(staging_up:)
    File.write(File.join(@repo, "CHANGE.md"), "---\nchange_config:\n  apps:\n    web: { config: web.yml }\n---\n")
    File.write(File.join(@repo, "web.yml"), <<~YML)
      change_config:
        boot: { up: "echo web" }
        lanes: { k6: { enabled: true } }
        default_profile: local
        profiles:
          local: {}
          staging: { boot: { up: "#{staging_up}" } }
    YML
    GitFixture.git(@repo, "add", "-A")
    GitFixture.git(@repo, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "app")
    GitFixture.git(@repo, "rev-parse", "HEAD").strip
  end

  def approve(tty:, typed: @sha[0, 12], sha: @sha, code: totp_now(@store))
    out = StringIO.new
    err = StringIO.new
    status = ChangeApprove.run([ sha, "--repo", @repo ], stdin: FakeStdin.new(tty, [ typed, code ]), stdout: out, stderr: err,
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

  def test_prints_the_prefix_to_type_on_its_own_line
    _status, out, _err = approve(tty: true)
    assert_match(/^type: #{@sha[0, 12]}$/, out)
  end

  def test_a_mismatch_names_the_expected_prefix
    _status, _out, err = approve(tty: true, typed: @sha[0, 11])
    assert_match(/expected #{@sha[0, 12]}, got #{@sha[0, 11]}/, err)
  end

  def test_the_full_sha_is_not_accepted_as_the_prefix
    status, _out, _err = approve(tty: true, typed: @sha)
    refute_equal 0, status
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

  def test_monorepo_app_profile_change_is_listed_for_approval
    base = commit_app(staging_up: "echo staging")
    GitFixture.git(@repo, "update-ref", "refs/remotes/origin/main", base)
    sha = commit_app(staging_up: "echo changed")
    pending = ChangeApprove.pending_steps(@repo, sha, ChangeTrust.resolve_base(@repo, fetch: false))
    assert_equal [ [ "web/boot.up", "staging" ] ], pending.map { |item| [ item.step, item.profile ] }
  end

  def test_usage_error_without_a_sha
    err = StringIO.new
    status = ChangeApprove.run([], stdin: FakeStdin.new(true, [ "" ]), stdout: StringIO.new, stderr: err)
    refute_equal 0, status
    assert_match(/usage/, err.string)
  end

  def stored_proof = JSON.parse(File.read(ChangeApprovalStore.new(@sha).path))["approved"].first["proof"]

  def test_records_a_terminal_totp_proof_bound_to_the_shown_steps
    status, = approve(tty: true)
    assert_equal 0, status
    proof = stored_proof
    assert_equal "totp-terminal", proof["kind"]
    assert_nil proof["receipt"]
    body = ApprovalConsole::Canonical.parse(proof["body"])
    assert_equal "step", body["type"]
    assert_equal @sha, body["sha"]
    assert_equal @store.machine_id, body["machine_id"]
    assert_equal [ "boot.up" ], body["items"].map { |item| item["step"] }
  end

  def test_refuses_and_prints_the_enroll_snippet_when_no_seed_is_enrolled
    FileUtils.rm_rf(File.dirname(@store.path("totp_seed")))
    status, _out, err = approve(tty: true, code: "123456")
    refute_equal 0, status
    assert_match(/totp-enroll/, err)
    assert_empty ChangeApprovalStore.new(@sha).approvals
  end

  def test_a_wrong_totp_code_records_nothing
    wrong = totp_now(@store) == "000000" ? "000001" : "000000"
    status, _out, err = approve(tty: true, code: wrong)
    refute_equal 0, status
    assert_match(/not valid/, err)
    assert_empty ChangeApprovalStore.new(@sha).approvals
  end

  def test_a_malformed_or_missing_totp_code_records_nothing
    [ "12345", "abcdef", "", nil ].each do |bad|
      status, _out, err = approve(tty: true, code: bad)
      refute_equal 0, status
      assert_match(/6 digits/, err)
    end
    assert_empty ChangeApprovalStore.new(@sha).approvals
  end

  def test_a_replayed_totp_code_records_nothing
    code = totp_now(@store)
    assert_predicate @store.consume(code), :ok?
    status, _out, err = approve(tty: true, code: code)
    refute_equal 0, status
    assert_match(/already used/, err)
    assert_empty ChangeApprovalStore.new(@sha).approvals
  end

  def test_a_locked_out_machine_records_nothing
    5.times { @store.consume("000000") }
    status, _out, err = approve(tty: true, code: totp_now(@store))
    refute_equal 0, status
    assert_match(/locked until/, err)
    assert_empty ChangeApprovalStore.new(@sha).approvals
  end

  def test_a_wrong_typed_prefix_never_spends_the_code
    approve(tty: true, typed: "000000000000")
    assert_nil @store.status[:last_step]
  end
end

require_relative "support/phone_console"

# `--remote` without a TTY: the agent starts the approval and posts the link;
# only the phone approves, and ApprovalConsole::Recorder writes the record.
class ChangeApproveRemoteTest < Minitest::Test
  include PhoneConsole

  NoTty = Struct.new(:tty?)

  def setup
    @home = File.realpath(Dir.mktmpdir)
    @prev_home = ENV["HOME"]
    ENV["HOME"] = @home
    @repo = Dir.mktmpdir
    GitFixture.git_init(@repo, "-b", "main")
    GitFixture.git(@repo, "update-ref", "refs/remotes/origin/main", commit("echo base"))
    @sha = commit("echo head")
    start_phone_console
  end

  def teardown
    ENV["HOME"] = @prev_home
    FileUtils.remove_entry(@home)
    FileUtils.remove_entry(@repo)
  end

  def commit(up)
    File.write(File.join(@repo, "CHANGE.md"), "---\nchange_config:\n  project: demo\n  boot:\n    up: \"#{up}\"\n  lanes:\n    k6:\n      enabled: true\n---\n")
    GitFixture.git(@repo, "add", "CHANGE.md")
    GitFixture.git(@repo, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "c")
    GitFixture.git(@repo, "rev-parse", "HEAD").strip
  end

  def approve(argv, console: client, auth: authority)
    out = StringIO.new
    err = StringIO.new
    status = ChangeApprove.run(argv, stdin: NoTty.new(false), stdout: out, stderr: err, fetch: false, console: console,
                                     authority: auth, io: remote_io)
    [ status, out.string, err.string ]
  end

  def test_remote_without_a_tty_records_the_phone_approved_steps
    status, out, err = approve([ @sha, "--repo", @repo, "--remote" ])
    assert_equal 0, status, err
    assert_match(/echo head/, out)
    defs = ChangeTrust.snapshot_definitions(@repo, @sha)
    assert_equal [ [ "boot.up", ChangeTrust.digest(defs["boot.up"]) ] ], ChangeApprovalStore.new(@sha).approvals
    entry = ChangeApprovalStore.new(@sha).entries.first
    assert_equal [ POLICY_SHA, "webauthn+totp" ], [ entry["policy_sha"], entry.dig("proof", "kind") ]
  end

  def test_without_remote_a_missing_tty_is_still_refused
    status, _out, err = approve([ @sha, "--repo", @repo ])
    assert_equal 1, status
    assert_match(/real terminal/, err)
    assert_empty ChangeApprovalStore.new(@sha).approvals
  end

  def test_remote_without_a_console_is_refused_without_a_tty
    status, _out, err = approve([ @sha, "--repo", @repo, "--remote" ], console: nil)
    assert_equal 1, status
    assert_match(/no approval console/, err)
    assert_empty ChangeApprovalStore.new(@sha).approvals
  end

  def test_remote_refuses_when_no_authoritative_pins_exist
    status, _out, err = approve([ @sha, "--repo", @repo, "--remote" ], auth: authority(pins: nil))
    assert_equal 1, status
    assert_match(/no approval_pins.*nothing recorded/, err)
    assert_empty ChangeApprovalStore.new(@sha).approvals
  end
end
