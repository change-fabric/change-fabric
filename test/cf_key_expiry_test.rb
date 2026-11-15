# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/cf_key_expiry"

class CfKeyExpiryTest < Minitest::Test
  NOW = Time.utc(2026, 11, 15, 12, 0, 0)

  def test_a_bare_date_is_midnight_utc
    assert_equal Time.utc(2026, 12, 1), CfKeyExpiry.parse("2026-12-01")
  end

  def test_full_iso8601_is_normalized_to_utc
    assert_equal Time.utc(2026, 12, 1, 5, 0, 0), CfKeyExpiry.parse("2026-12-01T00:00:00-05:00")
    assert CfKeyExpiry.parse("2026-12-01T00:00:00-05:00").utc?
  end

  def test_unreadable_dates_raise
    [ "", "tomorrow", "2026-13-01", "12/01/2026" ].each do |bad|
      assert_raises(ArgumentError, bad) { CfKeyExpiry.parse(bad) }
    end
  end

  def test_no_date_is_ok
    assert_equal :ok, CfKeyExpiry.state(nil, now: NOW)
    assert_equal :ok, CfKeyExpiry.state("", now: NOW)
    assert_nil CfKeyExpiry.days_remaining(nil, now: NOW)
  end

  def test_an_unreadable_stored_date_never_blocks
    assert_equal :ok, CfKeyExpiry.state("garbage", now: NOW)
  end

  def test_more_than_24h_out_is_ok
    assert_equal :ok, CfKeyExpiry.state((NOW + 86_401).iso8601, now: NOW)
  end

  def test_within_24h_warns_at_both_edges
    assert_equal :warn, CfKeyExpiry.state((NOW + 86_400).iso8601, now: NOW)
    assert_equal :warn, CfKeyExpiry.state((NOW + 1).iso8601, now: NOW)
  end

  def test_at_or_after_expiry_is_expired
    assert_equal :expired, CfKeyExpiry.state(NOW.iso8601, now: NOW)
    assert_equal :expired, CfKeyExpiry.state("2026-11-01", now: NOW)
  end

  def test_comparison_is_utc_whatever_the_clock_zone
    local_now = NOW.getlocal("+09:00")
    assert_equal :warn, CfKeyExpiry.state("2026-11-16", now: local_now)
  end

  def test_days_remaining_rounds_down_and_goes_negative
    assert_equal 15, CfKeyExpiry.days_remaining("2026-12-01", now: NOW)
    assert_equal 0, CfKeyExpiry.days_remaining("2026-11-16", now: NOW)
    assert_equal(-1, CfKeyExpiry.days_remaining("2026-11-15", now: NOW))
  end
end
