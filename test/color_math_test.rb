# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/color_math"

class ColorMathTest < Minitest::Test
  def test_parse_three_channel_color_srgb
    rgba = ColorMath.parse("color(srgb 1 0 0)")
    assert_equal ColorMath::Rgba.new(r: 1.0, g: 0.0, b: 0.0, a: 1.0), rgba
  end

  def test_parse_four_channel_color_srgb_with_alpha
    rgba = ColorMath.parse("color(srgb 0.2 0.4 0.6 / 0.5)")
    assert_in_delta 0.2, rgba.r
    assert_in_delta 0.4, rgba.g
    assert_in_delta 0.6, rgba.b
    assert_in_delta 0.5, rgba.a
  end

  def test_parse_clips_out_of_gamut_channels_to_0_1
    rgba = ColorMath.parse("color(srgb 1.4 -0.2 0.5 / 1.6)")
    assert_equal ColorMath::Rgba.new(r: 1.0, g: 0.0, b: 0.5, a: 1.0), rgba
  end

  def test_parse_returns_nil_for_nil_or_unrecognized_strings
    assert_nil ColorMath.parse(nil)
    assert_nil ColorMath.parse("rgb(1, 2, 3)")
    assert_nil ColorMath.parse("")
  end

  def test_relative_luminance_white_is_one_black_is_zero
    assert_in_delta 1.0, ColorMath.relative_luminance(ColorMath::WHITE)
    assert_in_delta 0.0, ColorMath.relative_luminance(ColorMath::Rgba.new(r: 0, g: 0, b: 0, a: 1))
  end

  def test_contrast_ratio_black_on_white_is_21
    black = ColorMath::Rgba.new(r: 0, g: 0, b: 0, a: 1)
    assert_in_delta 21.0, ColorMath.contrast_ratio(black, ColorMath::WHITE), 0.01
  end

  def test_contrast_ratio_is_order_independent
    a = ColorMath::Rgba.new(r: 0.2, g: 0.2, b: 0.2, a: 1)
    b = ColorMath::Rgba.new(r: 0.8, g: 0.8, b: 0.8, a: 1)
    assert_in_delta ColorMath.contrast_ratio(a, b), ColorMath.contrast_ratio(b, a), 0.0001
  end

  def test_flatten_opaque_color_is_unchanged
    red = ColorMath::Rgba.new(r: 1, g: 0, b: 0, a: 1)
    assert_equal red, ColorMath.flatten(red, over: ColorMath::WHITE)
  end

  def test_flatten_half_alpha_black_over_white_is_mid_gray
    half_black = ColorMath::Rgba.new(r: 0, g: 0, b: 0, a: 0.5)
    flattened = ColorMath.flatten(half_black, over: ColorMath::WHITE)
    assert_in_delta 0.5, flattened.r, 0.001
    assert_in_delta 0.5, flattened.g, 0.001
    assert_in_delta 0.5, flattened.b, 0.001
    assert_in_delta 1.0, flattened.a
  end

  def test_flatten_fully_transparent_takes_the_backdrop
    transparent = ColorMath::Rgba.new(r: 0.1, g: 0.2, b: 0.3, a: 0)
    backdrop = ColorMath::Rgba.new(r: 0.9, g: 0.8, b: 0.7, a: 1)
    assert_equal backdrop.r, ColorMath.flatten(transparent, over: backdrop).r
  end
end
