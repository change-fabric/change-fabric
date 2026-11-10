# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../scripts/diagram_text_fit"
require_relative "../scripts/walkthrough_diagram"

# The shared width estimate and wrap rule, and the lane layer's mirror of
# both: the same shares, the same CJK class, and the same FIT table.
class DiagramTextFitTest < Minitest::Test
  def test_width_at_the_rendered_font
    assert_in_delta 0.0, DiagramTextFit.width("", 19)
    assert_in_delta 3 * 0.74 * 19, DiagramTextFit.width("abc", 19)
    assert_in_delta 2 * 0.74 * 17, DiagramTextFit.width("42", 17)
    assert_in_delta (0.5 + 0.88 + 1.11) * 20, DiagramTextFit.width("iAW", 20)
    assert_in_delta 0.5 * 10, DiagramTextFit.width(" ", 10)
    assert_in_delta 2 * 22.0, DiagramTextFit.width("検査", 22)
    assert_in_delta (2 * 0.74 * 22) + (2 * 22.0), DiagramTextFit.width("ab漢か", 22)
    assert_in_delta 22.0, DiagramTextFit.width("한", 22)
  end

  def test_lines_wrap_at_words
    assert_empty DiagramTextFit.lines("", 19, 196)
    assert_equal [ "Load budget" ], DiagramTextFit.lines("Load budget", 19, 196)
    # 14.06 px a char at 19 px: 13 chars fit 196 px, 14 do not.
    assert_equal [ "a" * 13 ], DiagramTextFit.lines("a" * 13, 19, 196)
    assert_equal [ "aaa bbb ccc", "ddd" ], DiagramTextFit.lines("aaa bbb ccc ddd", 19, 160)
  end

  def test_lines_break_a_long_word_anywhere
    assert_equal [ "a" * 13, "a" ], DiagramTextFit.lines("a" * 14, 19, 196)
    assert_equal [ "ab", "c" * 13, "cc" ], DiagramTextFit.lines("ab #{'c' * 15}", 19, 196)
    assert_equal %w[検査検査検査検査 検査], DiagramTextFit.lines("検査検査検査検査検査", 19, 160)
  end

  def test_exact_budget_boundary
    room = DiagramTextFit.room("lane_label")
    n = DiagramTextFit.chars(room, 22)
    assert_operator DiagramTextFit.width("x" * n, 22), :<=, room
    assert_operator DiagramTextFit.width("x" * (n + 1), 22), :>, room
    assert_equal room - 30, DiagramTextFit.room("lane_label", icon: "gauge")
  end

  # The lane layer keeps the same table, shares, and CJK class; the capture
  # tests prove the two estimates agree in the browser.
  def test_text_fit_mirrors_ruby
    js = File.read(WalkthroughDiagram::LANES_RUNTIME)
    assert_equal DiagramTextFit::FIT, JSON.parse(js[/^\s*const FIT = (\{.*\});$/, 1])
    assert_equal DiagramTextFit::EM, JSON.parse(js[/^\s*const EM = (\{.*\});$/, 1])
    scripts = js[/const CJK = \/\[(.*)\]\/u;/, 1].scan(/\\p\{Script=(\w+)\}/).flatten
    assert_equal DiagramTextFit::CJK.source.scan(/\\p\{(\w+)\}/).flatten, scripts
  end
end
