# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/approval_console/totp"

class ApprovalConsoleTotpTest < Minitest::Test
  Totp = ApprovalConsole::Totp
  SEED = "12345678901234567890"

  # RFC 6238 Appendix B, SHA-1 column (8 digits).
  VECTORS = {
    59 => "94287082", 1_111_111_109 => "07081804", 1_111_111_111 => "14050471",
    1_234_567_890 => "89005924", 2_000_000_000 => "69279037", 20_000_000_000 => "65353130"
  }.freeze

  def test_rfc6238_appendix_vectors
    VECTORS.each do |time, expected|
      assert_equal expected, Totp.code(SEED, Totp.step_for(time), digits: 8), "time #{time}"
    end
  end

  def test_six_digit_code_is_the_low_digits
    assert_equal "287082", Totp.code(SEED, Totp.step_for(59))
  end

  def test_accepts_the_current_step_and_returns_it
    result = Totp.check(SEED, "287082", now: 59)
    assert_predicate result, :ok?
    assert_equal 1, result.step
  end

  def test_accepts_plus_and_minus_one_window
    assert_equal 0, Totp.check(SEED, Totp.code(SEED, 0), now: 59).step
    assert_equal 2, Totp.check(SEED, Totp.code(SEED, 2), now: 59).step
  end

  def test_rejects_outside_the_window
    assert_equal :invalid, Totp.check(SEED, Totp.code(SEED, 3), now: 59).reason
    assert_equal :invalid, Totp.check(SEED, Totp.code(SEED, 100), now: 59).reason
  end

  def test_rejects_a_wrong_code
    assert_equal :invalid, Totp.check(SEED, "000000", now: 59).reason
  end

  def test_rejects_a_wrong_seed
    assert_equal :invalid, Totp.check("another seed 12345678", "287082", now: 59).reason
  end

  def test_rejects_malformed_codes
    [ "", "28708", "2870822", "abcdef", "28708 ", nil ].each do |code|
      assert_equal :malformed, Totp.check(SEED, code, now: 59).reason, code.inspect
    end
  end

  def test_replay_of_the_same_step_is_rejected
    first = Totp.check(SEED, "287082", now: 59)
    assert_predicate first, :ok?
    again = Totp.check(SEED, "287082", now: 59, last_step: first.step)
    assert_equal :replay, again.reason
  end

  def test_an_older_step_than_the_last_accepted_is_a_replay
    assert_equal :replay, Totp.check(SEED, Totp.code(SEED, 0), now: 59, last_step: 1).reason
  end

  def test_a_later_step_than_the_last_accepted_passes
    assert_equal 2, Totp.check(SEED, Totp.code(SEED, 2), now: 59, last_step: 1).step
  end

  def test_base32_round_trip
    assert_equal "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", ApprovalConsole::Base32.encode(SEED)
    assert_equal SEED, ApprovalConsole::Base32.decode("gezd gnbv-GY3TQOJQGEZDGNBVGY3TQOJQ====")
    assert_raises(ArgumentError) { ApprovalConsole::Base32.decode("not*base32") }
  end
end
