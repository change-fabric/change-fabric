# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../scripts/change_override"
require_relative "../scripts/change_override_store"

# The load-bearing control here is not the script's logic, it's that it
# refuses to run at all without a real interactive terminal on stdin: an
# agent's Bash tool call has no TTY, so it cannot satisfy the confirmation
# prompt even though it can run arbitrary shell. Only a human at their own
# real terminal can. These tests inject fake stdin/stdout/stderr so the TTY
# check and the confirmation flow are both exercised without a real terminal.
class ChangeOverrideTest < Minitest::Test
  FakeStdin = Struct.new(:tty_value, :line) do
    def tty? = tty_value
    def gets = line
  end

  def setup
    @home = Dir.mktmpdir
    @prev = Dir.home
    ENV["HOME"] = @home
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
  end

  def run_override(argv, tty:, typed_confirmation: nil)
    sha = argv.first
    stdin = FakeStdin.new(tty, typed_confirmation || sha.to_s[0, 12])
    out = StringIO.new
    err = StringIO.new
    status = ChangeOverride.run(argv, stdin: stdin, stdout: out, stderr: err)
    [ status, out.string, err.string ]
  end

  def test_refuses_without_a_real_tty
    status, _out, err = run_override(%w[abcdef123456 --reason x], tty: false)
    refute_equal 0, status
    assert_match(/real terminal/, err)
    refute ChangeOverrideStore.new("abcdef123456").authorized?
  end

  def test_usage_error_on_missing_sha
    status, _out, err = run_override(%w[--reason x], tty: true)
    refute_equal 0, status
    assert_match(/usage/, err)
  end

  def test_usage_error_on_missing_reason
    status, _out, err = run_override(%w[abcdef123456], tty: true)
    refute_equal 0, status
    assert_match(/usage/, err)
  end

  def test_confirmation_mismatch_refuses_and_records_nothing
    status, _out, err = run_override(%w[abcdef123456 --reason x], tty: true, typed_confirmation: "wrong")
    refute_equal 0, status
    assert_match(/did not match/, err)
    refute ChangeOverrideStore.new("abcdef123456").authorized?
  end

  def test_matching_confirmation_records_the_override
    status, out, _err = run_override(%w[abcdef123456 --reason "CI green, no reviewer available"], tty: true)
    assert_equal 0, status
    assert_match(/recorded/, out)
    assert ChangeOverrideStore.new("abcdef123456").authorized?
  end

  def test_records_the_profile_when_given
    status, _out, _err = run_override(%w[abcdef123456 --reason x --profile staging], tty: true)
    assert_equal 0, status
    assert ChangeOverrideStore.new("abcdef123456", profile: "staging").authorized?
    refute ChangeOverrideStore.new("abcdef123456").authorized?
  end
end
