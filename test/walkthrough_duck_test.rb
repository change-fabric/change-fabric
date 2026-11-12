# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/walkthrough_duck"

class WalkthroughDuckTest < Minitest::Test
  # Evaluates an FFmpeg volume expression at time t (seconds) by mapping its
  # functions onto Ruby, so the envelope is checked numerically.
  module Expr
    module_function

    def clip(x, lo, hi) = x.clamp(lo, hi)
    def min(*xs) = xs.min
    def pow(b, e) = b**e

    def at(expr, t)
      eval(expr.gsub(/\bt\b/, "(#{Float(t)})"), binding) # rubocop:disable Security/Eval
    end
  end

  def db_at(expr, t) = 20 * Math.log10(Expr.at(expr, t))

  SPAN = { start_ms: 2000, end_ms: 4000, db: -8 }.freeze

  def test_empty_is_unity
    assert_equal "1", WalkthroughDuck.expression([])
  end

  def test_expression_shape
    assert_equal "pow(10,(-8.00*clip(min((t-1.700)/0.300,(4.500-t)/0.500),0,1))/20)",
                 WalkthroughDuck.expression([ SPAN ])
  end

  def test_envelope_samples
    e = WalkthroughDuck.expression([ SPAN ], total_ms: 10_000)
    assert_in_delta 0.0, db_at(e, 1.0), 1e-9        # before attack
    assert_in_delta(-4.0, db_at(e, 1.85), 1e-6)     # mid attack, linear in dB
    assert_in_delta(-8.0, db_at(e, 2.0), 1e-6)      # fully down at speech start
    assert_in_delta(-8.0, db_at(e, 3.0), 1e-6)      # inside
    assert_in_delta(-4.0, db_at(e, 4.25), 1e-6)     # mid release
    assert_in_delta 0.0, db_at(e, 4.6), 1e-9        # after release
  end

  def test_no_step_between_frames
    e = WalkthroughDuck.expression([ SPAN, { start_ms: 6000, end_ms: 7000, db: -8 } ], total_ms: 9000)
    db = (0..9000).step(10).map { |ms| db_at(e, ms / 1000.0) }
    max_step = db.each_cons(2).map { |a, b| (a - b).abs }.max
    assert_operator max_step, :<=, 0.27 # 8 dB over 300 ms is 0.267 dB per 10 ms
  end

  def test_close_spans_merge_without_pumping
    spans = [ SPAN, { start_ms: 4600, end_ms: 5000, db: -10 } ] # gap 600 < 500 + 300
    merged = WalkthroughDuck.merge(spans)
    assert_equal [ { start_ms: 2000, end_ms: 5000, db: -10, attack_ms: 300, release_ms: 500 } ], merged
    e = WalkthroughDuck.expression(spans)
    assert_in_delta(-10.0, db_at(e, 4.3), 1e-6) # the gap stays down
  end

  def test_spans_at_threshold_stay_apart
    spans = [ SPAN, { start_ms: 4800, end_ms: 5000, db: -8 } ] # gap 800 == 500 + 300
    assert_equal 2, WalkthroughDuck.merge(spans).size
    e = WalkthroughDuck.expression(spans)
    assert_in_delta 0.0, db_at(e, 4.5), 1e-9
  end

  def test_merge_sorts_and_keeps_the_later_release
    spans = [ { start_ms: 3000, end_ms: 3500, db: -8, release_ms: 900 }, { start_ms: 1000, end_ms: 2900, db: -6, attack_ms: 100 } ]
    assert_equal [ { start_ms: 1000, end_ms: 3500, db: -8, attack_ms: 100, release_ms: 900 } ], WalkthroughDuck.merge(spans)
  end

  def test_clamps_at_zero_and_end
    e = WalkthroughDuck.expression([ { start_ms: 100, end_ms: 900, db: -8 } ], total_ms: 1000)
    assert_in_delta(-8.0, db_at(e, 0.1), 1e-6)
    assert_in_delta(0.0, db_at(e, 0.0), 1e-9)
    assert_in_delta(-4.0, db_at(e, 0.95), 1e-6) # release shortened to 100 ms
    assert_in_delta 0.0, db_at(e, 1.0), 1e-9
    held = WalkthroughDuck.expression([ { start_ms: 0, end_ms: 1000, db: -8 } ], total_ms: 1000)
    assert_equal "pow(10,(-8.00*1)/20)", held
  end

  def test_zero_ramps_are_a_step_not_an_open_end
    e = WalkthroughDuck.expression([ { start_ms: 1000, end_ms: 2000, db: -8, attack_ms: 0, release_ms: 0 } ], total_ms: 5000)
    assert_in_delta 0.0, db_at(e, 0.5), 1e-9
    assert_in_delta(-8.0, db_at(e, 1.5), 1e-6)
    assert_in_delta 0.0, db_at(e, 3.0), 1e-9
  end
end
