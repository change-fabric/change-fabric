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

  def test_records_nothing_and_says_why_for_every_profile
    %w[staging production].each do |profile|
      envelope = request(profile: profile)
      code, out, err = approve(envelope)
      assert_equal 1, code
      assert_match(/never accepted; staging waits for the console receipt phase/, err)
      refute_match(/approved/, out)
      refute @store.exists?("approvals", envelope["request_id"])
    end
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

  def test_refuses_a_missing_request_and_bad_usage
    envelope = request
    missing = StringIO.new
    code = Approve.run([ SecureRandom.uuid, "--repo", @dir, "--no-push" ], stdin: Stdin.new(true, []), stdout: StringIO.new, stderr: missing, env: {}, parents: -> { [] })
    assert_equal 1, code
    assert_match(/does not exist/, missing.string)
    assert_equal 2, Approve.run([], stdin: Stdin.new(true, []), stdout: StringIO.new, stderr: StringIO.new, env: {}, parents: -> { [] })
  end
end
