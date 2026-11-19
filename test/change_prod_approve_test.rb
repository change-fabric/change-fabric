# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require_relative "git_fixture"
require_relative "support/totp_enrollment"
require_relative "../scripts/change_prod_approve"
require_relative "../scripts/change_prod_gate"

class ChangeProdApproveTest < Minitest::Test
  include TotpEnrollment

  Approve = ChangeProdApprove
  FIXTURE = File.expand_path("fixtures/prod/runner.yml", __dir__)

  Stdin = Struct.new(:tty_value, :lines) do
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
    @dir = Dir.mktmpdir
    GitFixture.git_init(@dir, "-b", "main")
    GitFixture.git(@dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "base")
    @sha = GitFixture.git(@dir, "rev-parse", "HEAD").strip
    @store = ChangeProdStore.new(@dir)
    @totp = enroll_totp
  end

  def teardown
    ENV["HOME"] = @prev_home
    [ @home, @dir ].each { |path| FileUtils.remove_entry(path) }
  end

  def request(profile: "staging")
    envelope = ChangeProdEnvelope.build(config: YAML.safe_load_file(FIXTURE), op: "rotate_tenant_key", params: { "tenant_id" => "t_101" },
                                        profile: profile, version: @sha, requested_by: "agent:s1")
    @store.create("requests", envelope["request_id"], envelope, push: false)
    envelope
  end

  def approve(envelope, tty: true, typed: nil, code: nil, argv: nil, env: {}, parents: [])
    out = StringIO.new
    err = StringIO.new
    stdin = Stdin.new(tty, [ typed || ChangeProdEnvelope.prefix(envelope), code || totp_now(@totp) ])
    argv ||= [ envelope["request_id"], "--repo", @dir, "--no-push" ]
    code = Approve.run(argv, stdin: stdin, stdout: out, stderr: err, env: env, parents: -> { parents })
    [ code, out.string, err.string ]
  end

  def test_records_a_totp_terminal_proof_bound_to_the_digest
    envelope = request
    code, out, = approve(envelope)
    assert_equal 0, code
    assert_includes out, "staging only"
    record = @store.read("approvals", envelope["request_id"])
    assert_equal "cf.prod.approval/2", record["protocol"]
    assert_equal envelope["digest"], record["digest"]
    assert_equal "totp-terminal", record.dig("proof", "kind")
    body = ApprovalConsole::Canonical.parse(record.dig("proof", "body"))
    assert_equal ChangeProdEnvelope.approval_context(envelope, repo: body["repo"], machine_id: body["machine_id"]).values_at("summary", "argv", "sha", "profile"),
                 body.values_at("summary", "argv", "sha", "profile")
  end

  def test_the_recorded_proof_verifies_at_the_runner_for_staging
    envelope = request
    approve(envelope)
    record = @store.read("approvals", envelope["request_id"])
    body = ApprovalConsole::Canonical.parse(record.dig("proof", "body"))
    credentials = { "rp_id" => "x.example", "repo" => body["repo"], "machine_ids" => [ body["machine_id"] ], "credentials" => {} }
    result = ChangeProdGate.verify(store: @store, request_id: envelope["request_id"], config: YAML.safe_load_file(FIXTURE),
                                   credentials: credentials, allowed: %w[staging])
    assert_predicate result, :ok?, result.reason
    assert_equal :local, result.level
  end

  def test_refuses_without_a_tty_in_an_agent_harness_and_for_remote
    envelope = request
    code, _, err = approve(envelope, tty: false)
    assert_equal 1, code
    assert_match(/real terminal/, err)
    code, _, err = approve(envelope, env: { "CLAUDECODE" => "1" })
    assert_equal 1, code
    assert_match(/agent harness/, err)
    code, _, err = approve(envelope, parents: [ "claude" ])
    assert_equal 1, code
    assert_match(/agent harness/, err)
    code, _, err = approve(envelope, argv: [ envelope["request_id"], "--remote", "--repo", @dir, "--no-push" ])
    assert_equal 1, code
    assert_match(/console \(phases 5 and 6\)/, err)
    refute @store.exists?("approvals", envelope["request_id"])
  end

  def test_refuses_a_production_request_with_a_terminal_only_proof
    envelope = request(profile: "production")
    code, _, err = approve(envelope)
    assert_equal 1, code
    assert_match(/staging only; production needs the remote console/, err)
    refute @store.exists?("approvals", envelope["request_id"])
  end

  def test_refuses_a_wrong_digest_prefix_and_a_bad_code
    envelope = request
    code, _, err = approve(envelope, typed: "deadbeef0000")
    assert_equal 1, code
    assert_match(/did not match/, err)
    code, _, err = approve(envelope, code: "000000")
    assert_equal 1, code
    assert_match(/nothing recorded/, err)
    refute @store.exists?("approvals", envelope["request_id"])
  end

  def test_refuses_an_unenrolled_machine_and_a_missing_or_tampered_request
    envelope = request
    FileUtils.rm_rf(@totp.dir)
    code, _, err = approve(envelope, code: "123456")
    assert_equal 1, code
    assert_match(/no TOTP seed/, err)
    missing = StringIO.new
    code = Approve.run([ SecureRandom.uuid, "--repo", @dir, "--no-push" ], stdin: Stdin.new(true, []), stdout: StringIO.new, stderr: missing, env: {}, parents: -> { [] })
    assert_equal 1, code
    assert_match(/does not exist/, missing.string)
    assert_equal 2, Approve.run([], stdin: Stdin.new(true, []), stdout: StringIO.new, stderr: StringIO.new, env: {}, parents: -> { [] })
  end

  def test_an_approval_is_created_once
    envelope = request
    assert_equal 0, approve(envelope).first
    code, _, err = approve(envelope, code: totp_now(@totp, offset: 1))
    assert_equal 1, code
    assert_match(/already exists/, err)
  end
end
