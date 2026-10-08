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

  def test_named_table_excludes_transparent
    refute CV::NAMED.key?("transparent")
  end

  def test_named_table_keys_are_lowercase
    assert CV::NAMED.keys.all? { |k| k == k.downcase }
  end

  # --- resolution table ---

  def test_hex_3_4_6_and_8_digit
    assert_rgba 255, 255, 255, resolved("#fff")
    assert_in_delta 1.0, resolved("#000f").a, 0.001
    assert_rgba 255, 0, 0, resolved("#ff0000")
    assert_rgba 0, 0, 0, resolved("#00000000"), expected_a: 0.0
  end

  def test_hex_any_case
    assert_rgba 255, 0, 0, resolved("#FF0000")
  end

  def test_rgb_comma_and_space_syntax
    assert_rgba 255, 0, 0, resolved("rgb(255, 0, 0)")
    assert_rgba 255, 0, 0, resolved("rgb(255 0 0)")
  end

  def test_rgba_alpha_as_fraction_and_percent
    assert_rgba 255, 0, 0, resolved("rgba(255, 0, 0, 0.5)"), expected_a: 0.5
    assert_rgba 255, 0, 0, resolved("rgb(255, 0, 0, 50%)"), expected_a: 0.5
  end

  def test_rgb_space_syntax_with_slash_alpha
    assert_rgba 255, 0, 0, resolved("rgb(255 0 0 / 50%)"), expected_a: 0.5
  end

  def test_rgb_comma_syntax_with_slash_alpha_is_unresolved
    assert_nil CV.resolve("rgb(255, 0, 0 / 50%)", {}).color
  end

  def test_legacy_comma_syntax_with_an_empty_field_is_unresolved
    %w[rgb rgba hsl hsla].each do |fn|
      ch = fn.start_with?("hsl") ? %w[0 0% 0%] : %w[0 0 0]
      [
        "#{fn}(#{ch.join(",")},)",
        "#{fn}(#{ch.join(",")},0.5,)",
        "#{fn}(,#{ch.join(",")})",
        "#{fn}(#{ch[0]},,#{ch[1]},#{ch[2]})",
        "#{fn}(#{ch[0]},,#{ch[2]})",
        "#{fn}(#{ch.join(",")}, )"
      ].each do |value|
        assert_nil CV.resolve(value, {}).color, value
      end
    end
  end

  def test_rgb_percentage_channels
    assert_rgba 255, 0, 0, resolved("rgb(100% 0% 0%)")
  end

  def test_rgb_mixed_number_and_percentage_legacy_channels_is_unresolved
    assert_nil CV.resolve("rgb(100%, 0, 0)", {}).color
  end

  def test_hsl_comma_and_space_syntax
    assert_rgba 255, 0, 0, resolved("hsl(0, 100%, 50%)")
    assert_rgba 255, 0, 0, resolved("hsl(0deg 100% 50%)")
  end

  def test_hsla_comma_syntax_with_alpha
    assert_rgba 255, 0, 0, resolved("hsla(0, 100%, 50%, 0.5)"), expected_a: 0.5
  end

  def test_hsl_green_120_degrees
    assert_rgba 0, 128, 0, resolved("hsl(120 100% 25%)")
  end

  def test_hsl_hue_units
    assert_rgba 255, 0, 0, resolved("hsl(360deg 100% 50%)")
    expected = CV.send(:hsl_to_rgb, 180.0, 1.0, 0.25)
    color = resolved("hsl(0.5turn 100% 25%)")
    assert_equal expected, [ color.r, color.g, color.b ]
  end

  def test_hsl_invalid_hue_unit_is_unresolved
    reason = unresolved("hsl(0.5foo 100% 25%)")
    assert_includes reason, "invalid hue"
  end

  def test_named_color_case_insensitive_and_keywords
    assert_rgba 255, 0, 0, resolved("red")
    assert_rgba 102, 51, 153, resolved("ReBeccaPurple")
    assert_rgba 255, 255, 255, resolved("white")
  end

  def test_transparent_is_rgba_zero
    assert_rgba 0, 0, 0, resolved("transparent"), expected_a: 0.0
  end

  # --- var() ---

  def test_var_resolves_defined_token_and_chains
    assert_rgba 0, 0, 0, resolved("var(--x)", { "--x" => "#000" })
    assert_rgba 0, 0, 255, resolved("var(--a)", { "--a" => "var(--b)", "--b" => "#0000ff" })
  end

  def test_var_undefined_no_fallback_is_unresolved_with_reason
    reason = unresolved("var(--missing)")
    assert_includes reason, "--missing is not defined in this theme"
  end

  def test_var_undefined_uses_fallback_which_may_itself_contain_var
    assert_rgba 0, 0, 0, resolved("var(--missing, #000)")
    assert_rgba 0, 255, 0, resolved("var(--missing, var(--b))", { "--b" => "#00ff00" })
  end

  # An undefined name is never traversed, so it cannot be part of a cycle:
  # repeating it inside its own fallback chain is not a cycle.
  def test_var_undefined_name_repeated_in_fallback_is_not_a_cycle
    assert_rgba 0, 0, 0, resolved("var(--missing, var(--missing, #000))")
    assert_rgba 0, 0, 0, resolved("var(--missing, var(--missing, var(--missing, #000)))")
    assert_rgba 0, 0, 0, resolved("var(--m1, var(--m2, var(--m1, #000)))")
    assert_rgba 0, 0, 0, resolved("var(--a)", { "--a" => "var(--missing, var(--missing, #000))" })
    assert_includes unresolved("var(--missing, var(--missing))"), "--missing is not defined in this theme"
  end

  def test_var_with_malformed_name_stays_unresolved_despite_fallback
    [ "var(foo, #000)", "var(-x, #000)", "var(, #000)", "var(--, #000)", "var(--a b, #000)",
      "var(#000, #000)", "var(--a(), #000)" ].each do |v|
      assert_includes unresolved(v, { "foo" => "#000" }), "unrecognized color value", v
    end
    assert_rgba 0, 0, 0, resolved("var(--a_1-b, #000)")
  end

  def test_var_cycle_with_no_fallback_is_unresolved
    decls = { "--a" => "var(--b)", "--b" => "var(--a)" }
    reason = unresolved("var(--a)", decls)
    assert_includes reason, "cycle"
  end

  # Per CSS Variables, a custom property that is part of a var() cycle is
  # guaranteed-invalid at computed-value time regardless of any fallback
  # written on a var() reference inside that cycle: the fallback rescues an
  # undefined name, never a cyclic one. A self-reference is a one-node cycle.
  def test_var_self_reference_with_fallback_is_still_a_cycle
    reason = unresolved("var(--a)", { "--a" => "var(--a, #123456)" })
    assert_includes reason, "cycle"
  end

  # A referenced property that computes to the guaranteed-invalid value lets
  # the referencing var()'s own fallback apply, unless the referencing
  # property is itself inside the cycle.
  def test_var_fallback_rescues_guaranteed_invalid_reference
    cases = {
      "undefined" => { "--bad" => "var(--missing)" },
      "cycle" => { "--bad" => "var(--c2)", "--c2" => "var(--bad)" }
    }
    cases.each do |label, decls|
      color = CV.resolve("var(--bad, #000)", decls.merge("--text" => "var(--bad, #000)"), seen: Set["--text"]).color
      refute_nil color, label
      assert_rgba 0, 0, 0, color
    end
  end

  def test_var_fallback_does_not_rescue_a_non_color_value
    assert_nil CV.resolve("var(--bad, #000)", { "--bad" => "notacolor" }).color
  end

  def test_var_inside_cycle_ignores_fallback
    decls = { "--a" => "var(--b, #000)", "--b" => "var(--a)" }
    assert_nil CV.resolve(decls["--a"], decls, seen: Set["--a"]).color
  end

  def test_var_used_inside_a_function_argument_is_unresolved
    assert_nil CV.resolve("rgb(var(--r), 0, 0)", { "--r" => "255" }).color
  end

  def test_var_fallback_can_contain_a_comma_bearing_function
    assert_rgba 1, 2, 3, resolved("var(--missing, rgb(1, 2, 3))", {})
  end

  def test_back_to_back_var_refs_are_not_one_reference
    assert_nil CV.send(:parse_var_ref, "var(--r) var(--g)")
    assert_equal [ "--r", nil ], CV.send(:parse_var_ref, "var(--r)")
  end

  # --- unsupported forms: unresolved, never an error ---

  def test_currentcolor_light_dark_and_cascade_keywords_are_unresolved
    assert_includes unresolved("currentColor"), "currentColor"
    assert_includes unresolved("light-dark(#000, #fff)"), "light-dark"
    assert_includes unresolved("inherit"), "depends on the cascade"
  end

  def test_color_mix_is_unresolved
    reason = unresolved("color-mix(in srgb, #000 60%, #fff 40%)")
    assert_includes reason, "color-mix"
    assert_includes reason, "not resolved"
  end

  def test_oklch_oklab_lab_lch_hwb_color_are_unresolved
    assert_includes unresolved("oklch(0.5 0.1 90)"), "oklch"
    assert_includes unresolved("oklab(0.5 0.1 0.1)"), "oklab"
    assert_includes unresolved("lab(50 40 59.5)"), "lab"
    assert_includes unresolved("lch(52 72 50)"), "lch"
    assert_includes unresolved("hwb(0 0% 0%)"), "hwb"
    assert_includes unresolved("color(srgb 1 0 0)"), "color"
  end

  def test_calc_and_none_and_relative_syntax_are_unresolved_not_errors
    refute_nil unresolved("rgb(calc(1 + 2), 0, 0)")
    refute_nil unresolved("rgb(none 0 0)")
    refute_nil unresolved("rgb(from var(--c) r g b)")
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

  def test_literal_hex_and_named_color
    assert CV.literal?("#fff")
    assert CV.literal?("red")
    assert CV.literal?("ReBeccaPurple")
  end

  def test_literal_transparent_and_currentcolor_are_not_literal
    refute CV.literal?("transparent")
    refute CV.literal?("currentColor")
  end

  def test_literal_color_function_without_var_is_literal
    assert CV.literal?("rgb(255, 0, 0)")
    assert CV.literal?("oklch(0.5 0.1 90)")
  end

  def test_literal_color_function_with_var_is_not_literal
    refute CV.literal?("rgb(var(--x), 0, 0)")
  end

  def test_literal_non_color_function_and_bare_word_are_not_literal
    refute CV.literal?("calc(1 + 2)")
    refute CV.literal?("banana")
  end

  # --- flatten / to_hex ---

  def test_flatten_opaque_and_transparent
    assert_rgba 10, 20, 30, CV.flatten(CV::Rgba.new(r: 10, g: 20, b: 30, a: 1.0), over: CV::WHITE)
    assert_rgba 255, 255, 255, CV.flatten(CV::Rgba.new(r: 10, g: 20, b: 30, a: 0.0), over: CV::WHITE)
  end

  def test_flatten_keeps_fractional_channels_for_contrast
    # Each translucent variant composites to a non-integer channel; rounding
    # it would move the ratio across a grading threshold.
    [ [ 0.4172, 148.614 ], [ 0.5, 127.5 ], [ 0.333, 170.085 ] ].each do |alpha, channel|
      flat = CV.flatten(CV::Rgba.new(r: 0, g: 0, b: 0, a: alpha), over: CV::WHITE)
      [ flat.r, flat.g, flat.b ].each { |c| assert_in_delta channel, c, 1e-9 }
    end
    flat = CV.flatten(CV::Rgba.new(r: 0, g: 0, b: 0, a: 0.4172), over: CV::WHITE)
    assert_operator CV.contrast_ratio(flat, CV::WHITE), :>=, 3.0
    assert_equal "#959595", CV.to_hex(flat)
  end

  def test_to_hex_is_lowercase_opaque_hex
    assert_equal "#ff0000", CV.to_hex(CV::Rgba.new(r: 255, g: 0, b: 0, a: 1.0))
  end

  # --- contrast_ratio ---

  def test_contrast_ratio_black_on_white_is_21_and_symmetric
    black = CV::Rgba.new(r: 0, g: 0, b: 0, a: 1.0)
    assert_in_delta 21.0, CV.contrast_ratio(black, CV::WHITE), 0.001
    assert_in_delta CV.contrast_ratio(black, CV::WHITE), CV.contrast_ratio(CV::WHITE, black), 0.001
  end

  def test_contrast_ratio_same_color_is_1
    gray = CV::Rgba.new(r: 128, g: 128, b: 128, a: 1.0)
    assert_in_delta 1.0, CV.contrast_ratio(gray, gray), 0.001
  end

  def test_equivalent_alpha_spellings_resolve_to_one_float
    spellings = [ "rgba(0 0 0 / .333)", "rgba(0 0 0 / 0.333)", "rgba(0 0 0 / 33.3%)",
                  "rgba(0 0 0 / 3.33e1%)", "rgba(0 0 0 / 333e-3)", "hsl(0 0% 0% / 33.3%)" ]
    alphas = spellings.map { |v| CV.resolve(v, {}).color.a }
    assert_equal [ 0.333 ], alphas.uniq
  end

  def test_alpha_clamps_exactly_at_bounds
    assert_in_delta 1.0, CV.resolve("rgb(0 0 0 / 150%)", {}).color.a, 0.0
    assert_in_delta 0.0, CV.resolve("rgb(0 0 0 / -1e400)", {}).color.a, 0.0
  end
end
