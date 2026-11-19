# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require "json"
require_relative "../scripts/change_override"
require_relative "../scripts/change_override_store"
require_relative "support/totp_enrollment"

# The load-bearing control here is not the script's logic, it's that it
# refuses to run at all without a real interactive terminal on stdin: an
# agent's Bash tool call has no TTY, so it cannot satisfy the confirmation
# prompt even though it can run arbitrary shell. Only a human at their own
# real terminal can. These tests inject fake stdin/stdout/stderr so the TTY
# check and the confirmation flow are both exercised without a real terminal.
class ChangeOverrideTest < Minitest::Test
  include TotpEnrollment

  # Answers each gets in turn: the typed confirmation, then the TOTP code.
  FakeStdin = Struct.new(:tty_value, :lines) do
    def tty? = tty_value

    def gets
      @queue ||= Array(lines).dup
      @queue.shift
    end
  end

  SHA = "abcdef1234567890abcdef1234567890abcdef12"

  def setup
    @home = Dir.mktmpdir
    @prev = Dir.home
    ENV["HOME"] = @home
    @store = enroll_totp
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
  end

  def run_override(argv, tty:, typed_confirmation: nil, code: totp_now(@store))
    sha = argv.first
    stdin = FakeStdin.new(tty, [ typed_confirmation || sha.to_s[0, 12], code ])
    out = StringIO.new
    err = StringIO.new
    status = ChangeOverride.run(argv, stdin: stdin, stdout: out, stderr: err)
    [ status, out.string, err.string ]
  end

  def test_refuses_without_a_real_tty
    status, _out, err = run_override(%W[#{SHA} --reason x], tty: false)
    refute_equal 0, status
    assert_match(/real terminal/, err)
    refute ChangeOverrideStore.new("#{SHA}").authorized?
  end

  def test_usage_error_on_missing_sha
    status, _out, err = run_override(%w[--reason x], tty: true)
    refute_equal 0, status
    assert_match(/usage/, err)
  end

  def test_usage_error_on_missing_reason
    status, _out, err = run_override(%W[#{SHA}], tty: true)
    refute_equal 0, status
    assert_match(/usage/, err)
  end

  def test_confirmation_mismatch_refuses_and_records_nothing
    status, _out, err = run_override(%W[#{SHA} --reason x], tty: true, typed_confirmation: "wrong")
    refute_equal 0, status
    assert_match(/did not match/, err)
    refute ChangeOverrideStore.new("#{SHA}").authorized?
  end

  def test_matching_confirmation_records_the_override
    status, out, _err = run_override(%W[#{SHA} --reason "CI green, no reviewer available"], tty: true)
    assert_equal 0, status
    assert_match(/recorded/, out)
    assert ChangeOverrideStore.new("#{SHA}").authorized?
  end

  def test_records_the_profile_when_given
    status, _out, _err = run_override(%W[#{SHA} --reason x --profile staging], tty: true)
    assert_equal 0, status
    assert ChangeOverrideStore.new("#{SHA}", profile: "staging").authorized?
    refute ChangeOverrideStore.new("#{SHA}").authorized?
  end

  def test_records_a_terminal_totp_proof_bound_to_the_exact_override
    run_override(%W[#{SHA} --reason why --profile staging], tty: true)
    path = ChangeOverrideStore.new(SHA, profile: "staging").send(:path)
    proof = JSON.parse(File.read(path))["proof"]
    assert_equal "totp-terminal", proof["kind"]
    body = ApprovalConsole::Canonical.parse(proof["body"])
    assert_equal [ "override", SHA, "staging", "why" ], body.values_at("type", "sha", "profile", "reason")
  end

  def test_refuses_when_no_seed_is_enrolled
    FileUtils.rm_rf(File.dirname(@store.path("totp_seed")))
    status, _out, err = run_override(%W[#{SHA} --reason x], tty: true, code: "123456")
    refute_equal 0, status
    assert_match(/totp-enroll/, err)
    refute ChangeOverrideStore.new(SHA).authorized?
  end

  def test_wrong_malformed_and_missing_codes_record_nothing
    wrong = totp_now(@store) == "000000" ? "000001" : "000000"
    [ [ wrong, /not valid/ ], [ "12", /6 digits/ ], [ nil, /6 digits/ ] ].each do |code, pattern|
      status, _out, err = run_override(%W[#{SHA} --reason x], tty: true, code: code)
      refute_equal 0, status
      assert_match(pattern, err)
    end
    refute ChangeOverrideStore.new(SHA).authorized?
  end

  def test_a_replayed_code_records_nothing
    code = totp_now(@store)
    assert_predicate @store.consume(code), :ok?
    status, _out, err = run_override(%W[#{SHA} --reason x], tty: true, code: code)
    refute_equal 0, status
    assert_match(/already used/, err)
    refute ChangeOverrideStore.new(SHA).authorized?
  end

  def test_a_locked_out_machine_records_nothing
    5.times { @store.consume("000000") }
    status, _out, err = run_override(%W[#{SHA} --reason x], tty: true)
    refute_equal 0, status
    assert_match(/locked until/, err)
    refute ChangeOverrideStore.new(SHA).authorized?
  end

  def test_an_unresolvable_short_sha_is_refused
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        status, _out, err = run_override(%w[abcdef123456 --reason x], tty: true)
        refute_equal 0, status
        assert_match(/full 40-character/, err)
      end
    end
  end

  def test_a_wrong_confirmation_never_spends_the_code
    run_override(%W[#{SHA} --reason x], tty: true, typed_confirmation: "wrong")
    assert_nil @store.status[:last_step]
  end
end
