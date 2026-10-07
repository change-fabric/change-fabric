# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/color_value"

class ColorValueTest < Minitest::Test
  CV = ColorValue

  def resolved(value, decls = {})
    result = CV.resolve(value, decls)
    assert_nil result.reason, "expected #{value.inspect} to resolve, got reason #{result.reason.inspect}"
    refute_nil result.color
    result.color
  end

  def unresolved(value, decls = {})
    result = CV.resolve(value, decls)
    assert_nil result.color, "expected #{value.inspect} to be unresolved, got color #{result.color.inspect}"
    refute_nil result.reason
    result.reason
  end

  def assert_rgba(expected_r, expected_g, expected_b, rgba, expected_a: 1.0, delta: 0.001)
    assert_equal expected_r, rgba.r
    assert_equal expected_g, rgba.g
    assert_equal expected_b, rgba.b
    assert_in_delta expected_a, rgba.a, delta
  end

  # --- NAMED table ---

  def test_named_table_has_148_entries
    assert_equal 148, CV::NAMED.size
  end

  def test_named_table_includes_rebeccapurple
    assert_equal [ 102, 51, 153 ], CV::NAMED["rebeccapurple"]
  end

  def test_named_table_excludes_transparent
    refute CV::NAMED.key?("transparent")
  end

  def test_named_table_keys_are_lowercase
    assert CV::NAMED.keys.all? { |k| k == k.downcase }
  end

  # --- resolution table ---

  def test_hex_3_digit
    assert_rgba 255, 255, 255, resolved("#fff")
  end

  def test_hex_4_digit_alpha
    assert_rgba 0, 0, 0, resolved("#000f"), expected_a: 1.0
    assert_in_delta 1.0, resolved("#000f").a, 0.001
  end

  def test_hex_4_digit_alpha_zero
    rgba = resolved("#0000")
    assert_in_delta 0.0, rgba.a, 0.001
  end

  def test_hex_6_digit
    assert_rgba 255, 0, 0, resolved("#ff0000")
  end

  def test_hex_8_digit_alpha
    rgba = resolved("#00000000")
    assert_rgba 0, 0, 0, rgba, expected_a: 0.0
  end

  def test_hex_any_case
    assert_rgba 255, 0, 0, resolved("#FF0000")
  end

  def test_rgb_comma_syntax
    assert_rgba 255, 0, 0, resolved("rgb(255, 0, 0)")
  end

  def test_rgba_comma_syntax_with_alpha
    rgba = resolved("rgba(255, 0, 0, 0.5)")
    assert_rgba 255, 0, 0, rgba, expected_a: 0.5
  end

  def test_rgb_space_syntax
    assert_rgba 255, 0, 0, resolved("rgb(255 0 0)")
  end

  def test_rgb_space_syntax_with_slash_alpha
    rgba = resolved("rgb(255 0 0 / 50%)")
    assert_rgba 255, 0, 0, rgba, expected_a: 0.5
  end

  def test_rgb_percentage_channels
    assert_rgba 255, 0, 0, resolved("rgb(100% 0% 0%)")
  end

  def test_rgb_alpha_as_percent_in_fourth_arg
    rgba = resolved("rgb(255, 0, 0, 50%)")
    assert_in_delta 0.5, rgba.a, 0.001
  end

  def test_hsl_comma_syntax
    assert_rgba 255, 0, 0, resolved("hsl(0, 100%, 50%)")
  end

  def test_hsla_comma_syntax_with_alpha
    rgba = resolved("hsla(0, 100%, 50%, 0.5)")
    assert_rgba 255, 0, 0, rgba, expected_a: 0.5
  end

  def test_hsl_space_syntax_with_deg_unit
    assert_rgba 255, 0, 0, resolved("hsl(0deg 100% 50%)")
  end

  def test_hsl_unitless_hue
    assert_rgba 255, 0, 0, resolved("hsl(0 100% 50%)")
  end

  def test_hsl_white
    assert_rgba 255, 255, 255, resolved("hsl(0 0% 100%)")
  end

  def test_hsl_black
    assert_rgba 0, 0, 0, resolved("hsl(0 0% 0%)")
  end

  def test_hsl_green_120_degrees
    assert_rgba 0, 128, 0, resolved("hsl(120 100% 25%)")
  end

  def test_named_color_lowercase
    assert_rgba 255, 0, 0, resolved("red")
  end

  def test_named_color_is_case_insensitive
    assert_rgba 102, 51, 153, resolved("ReBeccaPurple")
  end

  def test_named_color_white_and_black
    assert_rgba 255, 255, 255, resolved("white")
    assert_rgba 0, 0, 0, resolved("black")
  end

  def test_transparent_is_rgba_zero
    rgba = resolved("transparent")
    assert_rgba 0, 0, 0, rgba, expected_a: 0.0
  end

  # --- var() ---

  def test_var_resolves_defined_token
    assert_rgba 0, 0, 0, resolved("var(--x)", { "--x" => "#000" })
  end

  def test_var_chain
    decls = { "--a" => "var(--b)", "--b" => "#0000ff" }
    assert_rgba 0, 0, 255, resolved("var(--a)", decls)
  end

  def test_var_undefined_no_fallback_is_unresolved_with_reason
    reason = unresolved("var(--missing)")
    assert_includes reason, "--missing is not defined in this theme"
  end

  def test_var_undefined_uses_fallback
    assert_rgba 0, 0, 0, resolved("var(--missing, #000)")
  end

  def test_var_fallback_may_itself_contain_var
    decls = { "--b" => "#00ff00" }
    assert_rgba 0, 255, 0, resolved("var(--missing, var(--b))", decls)
  end

  def test_var_cycle_with_no_fallback_is_unresolved
    decls = { "--a" => "var(--b)", "--b" => "var(--a)" }
    reason = unresolved("var(--a)", decls)
    assert_includes reason, "cycle"
    assert_includes reason, "--a"
  end

  # Per CSS Variables, a custom property that is part of a var() cycle is
  # guaranteed-invalid at computed-value time regardless of any fallback
  # written on a var() reference inside that cycle: the fallback rescues an
  # undefined name, never a cyclic one. A self-reference is a one-node cycle.
  def test_var_self_reference_with_fallback_is_still_a_cycle
    decls = { "--a" => "var(--a, #123456)" }
    reason = unresolved("var(--a)", decls)
    assert_includes reason, "cycle"
    assert_includes reason, "--a"
  end

  # A referenced property that computes to the guaranteed-invalid value lets
  # the referencing var()'s own fallback apply, unless the referencing
  # property is itself inside the cycle.
  def test_var_fallback_rescues_guaranteed_invalid_reference
    cases = {
      "undefined" => { "--bad" => "var(--missing)" },
      "undefined chain" => { "--bad" => "var(--worse)", "--worse" => "var(--missing)" },
      "cycle" => { "--bad" => "var(--c2)", "--c2" => "var(--bad)" },
      "self cycle" => { "--bad" => "var(--bad)" }
    }
    cases.each do |label, decls|
      color = CV.resolve("var(--bad, #000)", decls.merge("--text" => "var(--bad, #000)"), seen: Set["--text"]).color
      refute_nil color, label
      assert_rgba 0, 0, 0, color
    end
  end

  def test_var_fallback_rescues_guaranteed_invalid_channel_token
    decls = { "--h" => "var(--missing)" }
    assert_rgba 0, 0, 0, resolved("rgb(var(--h, 0) 0 0)", decls)
  end

  def test_var_fallback_does_not_rescue_a_non_color_value
    assert_nil CV.resolve("var(--bad, #000)", { "--bad" => "notacolor" }).color
  end

  def test_var_inside_cycle_ignores_fallback
    decls = { "--a" => "var(--b, #000)", "--b" => "var(--a)" }
    assert_nil CV.resolve(decls["--a"], decls, seen: Set["--a"]).color
  end

  def test_var_whole_channel_triplet_resolves_in_hsl
    decls = { "--p" => "222.2 47.4% 11.2%" }
    color = resolved("hsl(var(--p))", decls)
    expected = CV.send(:hsl_to_rgb, 222.2, 0.474, 0.112)
    assert_equal expected, [ color.r, color.g, color.b ]
    assert_in_delta 1.0, color.a, 0.001
  end

  def test_var_partial_channel_groups_substitute_before_splitting
    decls = {
      "--rgb" => "0, 0, 0", "--gb" => "0, 0", "--sp" => "0 0 0",
      "--nested" => "var(--gb)", "--hs" => "0, 0%", "--a" => ".5"
    }
    [
      "rgba(var(--rgb), .5)", "rgb(var(--rgb), var(--a))", "rgba(0, var(--gb), .5)",
      "rgba(0, var(--nested), .5)", "rgb(var(--sp) / .5)", "rgb(var(--sp) / var(--a))",
      "hsla(var(--hs), 0%, .5)"
    ].each do |value|
      color = resolved(value, decls)
      assert_equal [ 0, 0, 0 ], [ color.r, color.g, color.b ], value
      assert_in_delta 0.5, color.a, 0.001, value
    end
    assert_nil CV.resolve("rgba(var(--missing), .5)", decls).color
  end

  def test_var_whole_channel_triplet_resolves_in_rgb_with_alpha
    decls = { "--q" => "10 20 30" }
    color = resolved("rgb(var(--q) / 0.5)", decls)
    assert_rgba 10, 20, 30, color, expected_a: 0.5
  end

  def test_var_cycle_never_raises
    decls = { "--a" => "var(--b)", "--b" => "var(--c)", "--c" => "var(--a)" }
    result = CV.resolve("var(--a)", decls)
    assert_nil result.color
    refute_nil result.reason
  end

  def test_var_fallback_can_contain_a_comma_bearing_function
    decls = {}
    rgba = resolved("var(--missing, rgb(1, 2, 3))", decls)
    assert_rgba 1, 2, 3, rgba
  end

  # --- color-mix(in srgb, ...) ---

  def test_color_mix_both_percentages_given
    rgba = resolved("color-mix(in srgb, #000 60%, #fff 40%)")
    assert_rgba 102, 102, 102, rgba
  end

  def test_color_mix_both_percentages_omitted_is_50_50
    rgba = resolved("color-mix(in srgb, #000, #fff)")
    assert_rgba 128, 128, 128, rgba
  end

  def test_color_mix_one_percentage_omitted_is_complement
    rgba = resolved("color-mix(in srgb, #000 30%, #fff)")
    assert_rgba 179, 179, 179, rgba
  end

  def test_color_mix_percentages_over_100_are_scaled
    rgba = resolved("color-mix(in srgb, #000 70%, #fff 70%)")
    assert_rgba 128, 128, 128, rgba
    assert_in_delta 1.0, rgba.a, 0.001
  end

  def test_color_mix_percentages_sum_to_zero_is_unresolved
    reason = unresolved("color-mix(in srgb, #000 0%, #fff 0%)")
    assert_includes reason, "sum to zero"
  end

  def test_color_mix_percentages_under_100_scale_alpha
    rgba = resolved("color-mix(in srgb, #000 30%, transparent)")
    assert_rgba 0, 0, 0, rgba, expected_a: 0.3
  end

  def test_color_mix_premultiplied_alpha_with_translucent_components
    decls = {}
    rgba = resolved("color-mix(in srgb, rgba(255,0,0,0.5) 50%, rgba(0,0,255,0.5) 50%)", decls)
    assert_in_delta 0.5, rgba.a, 0.001
    assert_rgba 128, 0, 128, rgba, expected_a: 0.5
  end

  def test_color_mix_resolves_var_arguments
    decls = { "--text" => "#000", "--bg" => "#fff" }
    rgba = resolved("color-mix(in srgb, var(--text) 60%, var(--bg))", decls)
    assert_rgba 102, 102, 102, rgba
  end

  def test_color_mix_var_arguments_percentage_before_color
    decls = { "--text" => "#000", "--bg" => "#fff" }
    rgba = resolved("color-mix(in srgb, var(--text), var(--bg) 40%)", decls)
    assert_rgba 102, 102, 102, rgba
  end

  def test_color_mix_other_space_is_unresolved
    reason = unresolved("color-mix(in oklch, red, blue)")
    assert_includes reason, "oklch"
    assert_includes reason, "is not supported"
  end

  def test_color_mix_unresolved_component_propagates_reason
    reason = unresolved("color-mix(in srgb, oklch(0.5 0.1 90) 50%, #fff 50%)")
    assert_includes reason, "oklch"
  end

  # --- unsupported forms ---

  def test_currentcolor_is_unresolved
    reason = unresolved("currentColor")
    assert_includes reason, "currentColor"
  end

  def test_light_dark_is_unresolved
    reason = unresolved("light-dark(#000, #fff)")
    assert_includes reason, "light-dark"
  end

  def test_oklch_is_unresolved
    reason = unresolved("oklch(0.5 0.1 90)")
    assert_includes reason, "oklch"
  end

  def test_oklab_lab_lch_hwb_color_are_unresolved
    assert_includes unresolved("oklab(0.5 0.1 0.1)"), "oklab"
    assert_includes unresolved("lab(50 40 59.5)"), "lab"
    assert_includes unresolved("lch(52 72 50)"), "lch"
    assert_includes unresolved("hwb(0 0% 0%)"), "hwb"
    assert_includes unresolved("color(srgb 1 0 0)"), "color"
  end

  def test_cascade_keywords_are_unresolved
    %w[inherit initial unset revert revert-layer].each do |keyword|
      reason = unresolved(keyword)
      assert_includes reason, "depends on the cascade"
    end
  end

  def test_calc_inside_rgb_is_unresolved
    reason = unresolved("rgb(calc(1 + 2), 0, 0)")
    assert_includes reason, "calc"
  end

  def test_none_channel_is_unresolved
    reason = unresolved("rgb(none 0 0)")
    assert_includes reason, "none"
  end

  def test_relative_color_syntax_is_unresolved
    reason = unresolved("rgb(from var(--c) r g b)")
    assert_includes reason, "relative color"
  end

  def test_unrecognized_value_truncated_to_40_chars
    long_value = "not-a-color-#{'x' * 60}-END-MARKER"
    reason = unresolved(long_value)
    assert_includes reason, long_value[0, 40]
    refute_includes reason, "END-MARKER"
  end

  def test_resolve_never_raises_on_garbage_input
    [ "", "   ", ")))", "var(", "color-mix(", "rgb(", nil.to_s ].each do |bad|
      result = CV.resolve(bad, {})
      refute_nil result
      assert(result.color || result.reason)
    end
  end

  # --- literal? ---

  def test_literal_hex_is_literal
    assert CV.literal?("#fff")
    assert CV.literal?("#ff0000")
    assert CV.literal?("#ff00ff00")
  end

  def test_literal_named_color_is_literal
    assert CV.literal?("red")
    assert CV.literal?("ReBeccaPurple")
  end

  def test_literal_transparent_and_currentcolor_are_not_literal
    refute CV.literal?("transparent")
    refute CV.literal?("currentColor")
  end

  def test_literal_color_function_without_var_is_literal
    assert CV.literal?("rgb(255, 0, 0)")
    assert CV.literal?("hsl(0, 100%, 50%)")
    assert CV.literal?("oklch(0.5 0.1 90)")
  end

  def test_literal_color_function_with_var_is_not_literal
    refute CV.literal?("rgb(var(--x), 0, 0)")
    refute CV.literal?("color-mix(in srgb, var(--a), #fff)")
  end

  def test_literal_non_color_function_is_not_literal
    refute CV.literal?("calc(1 + 2)")
    refute CV.literal?("url(image.png)")
  end

  def test_literal_bare_word_that_is_not_a_named_color_is_not_literal
    refute CV.literal?("banana")
  end

  # --- flatten / to_hex ---

  def test_flatten_opaque_color_is_unchanged
    rgba = CV.flatten(CV::Rgba.new(r: 10, g: 20, b: 30, a: 1.0), over: CV::WHITE)
    assert_rgba 10, 20, 30, rgba
  end

  def test_flatten_fully_transparent_color_becomes_the_background
    rgba = CV.flatten(CV::Rgba.new(r: 10, g: 20, b: 30, a: 0.0), over: CV::WHITE)
    assert_rgba 255, 255, 255, rgba
  end

  def test_flatten_matches_todays_mix_hex_rounding
    # #ff000080 over white: alpha 128/255 ~ 0.50196, matches
    # today's mix_hex("#ff0000", "#ffffff", alpha * 100).
    translucent = CV.resolve("#ff000080", {}).color
    rgba = CV.flatten(translucent, over: CV::WHITE)
    assert_rgba 255, 127, 127, rgba
  end

  def test_to_hex_is_lowercase_opaque_hex
    assert_equal "#ff0000", CV.to_hex(CV::Rgba.new(r: 255, g: 0, b: 0, a: 1.0))
    assert_equal "#000000", CV.to_hex(CV::Rgba.new(r: 0, g: 0, b: 0, a: 1.0))
  end

  # --- contrast_ratio ---

  def test_contrast_ratio_black_on_white_is_21
    assert_in_delta 21.0, CV.contrast_ratio(CV::Rgba.new(r: 0, g: 0, b: 0, a: 1.0), CV::WHITE), 0.001
  end

  def test_contrast_ratio_is_symmetric
    black = CV::Rgba.new(r: 0, g: 0, b: 0, a: 1.0)
    assert_in_delta CV.contrast_ratio(black, CV::WHITE), CV.contrast_ratio(CV::WHITE, black), 0.001
  end

  def test_contrast_ratio_same_color_is_1
    gray = CV::Rgba.new(r: 128, g: 128, b: 128, a: 1.0)
    assert_in_delta 1.0, CV.contrast_ratio(gray, gray), 0.001
  end
end
