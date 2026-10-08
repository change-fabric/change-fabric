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
    color = resolved("hsl(120 100% 25%)")
    assert_rgba 0, 127.5, 0, color
    assert_equal "#008000", ColorValue.to_hex(color)
  end

  def test_hsl_hue_units
    assert_rgba 255, 0, 0, resolved("hsl(360deg 100% 50%)")
    expected = CV.send(:hsl_to_rgb, 180.0, 1.0, 0.25)
    color = resolved("hsl(0.5turn 100% 25%)")
    assert_equal expected, [ color.r, color.g, color.b ]
  end

  def test_hsl_and_rgb_spellings_of_one_color_share_a_key
    {
      "hsl(0 100% 33.3%)" => "rgb(169.83 0 0)",
      "hsl(120 100% 25%)" => "rgb(0 127.5 0)",
      "hsl(0.5turn 100% 25%)" => "hsl(180deg 100% 25%)",
      "hsl(200grad 100% 25%)" => "hsl(180 100% 25%)",
      "hsl(0 100% 33.3% / 33.3%)" => "rgb(169.83 0 0 / 0.333)"
    }.each do |hsl, other|
      assert_equal resolved(other).to_h, resolved(hsl).to_h, "#{hsl} vs #{other}"
    end
    assert_equal Rational("169.83").to_f, resolved("hsl(0 100% 33.3%)").r
  end

  def test_extreme_hue_and_percent_exponents_resolve_quickly
    [ "hsl(1e-999999999 50% 50%)", "hsl(1e-999999999turn 50% 50%)",
      "hsl(0 1e-999999999% 50%)", "hsl(0 50% 1e-999999999%)" ].each do |value|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      resolved(value)
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0, value
    end
    [ "hsl(1e999999999 50% 50%)", "hsl(0 1e999999999% 50%)", "hsl(0 50% 1e999999999%)" ].each { |v| unresolved(v) }
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

  # Text inside a CSS string is not a var() function, so it never forms a
  # cycle edge, never closes the reference early, and never makes a color
  # function non-literal.
  def test_quoted_var_text_is_not_a_dependency
    [
      { "--white" => "#fff", "--page-text" => "var(--white, \"var(--page-text)\")" },
      { "--white" => "#fff", "--page-text" => "var(--white, 'var(--page-text)')" },
      { "--white" => "#fff", "--page-text" => "var(--white, \"a\\\" var(--page-text)\")" }
    ].each do |decls|
      assert_rgba 255, 255, 255, resolved("var(--page-text)", decls), delta: 0.001
    end
    assert_rgba 255, 255, 255, resolved("var(--w, \")\")", { "--w" => "#fff" })
    assert_includes unresolved("var(--a)", { "--a" => "var(--b, \"x\" var(--a))", "--b" => "#000" }), "cycle"
    assert CV.literal?("rgb(0 0 0)")
    refute CV.literal?("rgb(var(--x) 0 0)")
  end

  # Only a real var( function token is a dependency: a name merely ending
  # in var, is not, while VAR( (case-insensitive) and every escaped spelling
  # of var( (CSS decodes escapes before matching a name) are.
  def test_var_scan_requires_function_name_boundary
    %w[xvar my-var _var 2var évar varé ÉVAR -2var].each do |fn|
      decls = { "--white" => "#fff", "--page-text" => "var(--white, #{fn}(--page-text))" }
      assert_rgba 255, 255, 255, resolved("var(--page-text)", decls), delta: 0.001
      assert CV.literal?("rgb(#{fn}(--x) 0 0)"), fn
    end
    [ "VAR", "\\var", "v\\61r", "v\\61 r", "\\76 \\61 \\72", "\\000056AR", "V\\41R" ].each do |fn|
      decls = { "--white" => "#fff", "--page-text" => "var(--white, #{fn}(--page-text))" }
      assert_includes unresolved("var(--page-text)", decls), "cycle", fn
      refute CV.literal?("rgb(#{fn}(--x) 0 0)"), fn
    end
    assert CV.literal?("rgb(\\75 rl(var(--x)) 0 0)")
    refute CV.literal?("rgb(0 calc(var(--x)) 0)")
    assert CV.literal?(%(rgb(0 0 0 / "var(--x)")))
  end

  # An escaped paren never closes the var( it sits in.
  def test_matching_paren_skips_escapes
    assert_equal 5, CV.matching_paren("a(\\)b)", 1)
    assert_equal 7, CV.matching_paren("a(\\29 b)", 1)
    assert_equal 5, CV.matching_paren("a(\\(b))", 1)
    assert_equal 7, CV.matching_paren("a(\")\\\"\")", 1)
    assert_includes unresolved("var(--a\\) var(--b)", { "--a" => "#fff", "--b" => "#000" }), "unrecognized"
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

  # A var() inside an unused fallback still counts as a dependency, so a
  # defined, resolvable primary reference does not hide a cycle closed
  # through its fallback, directly, through another property, or nested.
  def test_var_cycle_through_unused_fallback_is_unresolved
    [
      { "--a" => "var(--b, var(--a))", "--b" => "#000" },
      { "--a" => "var(--b, var(--c))", "--b" => "#000", "--c" => "var(--a)" },
      { "--a" => "var(--b, var(--m, var(--a)))", "--b" => "#000" },
      { "--a" => "var(--b)", "--b" => "var(--c, var(--a))", "--c" => "#000" },
      { "--a" => "var(--b, var(--c))", "--b" => "#000", "--c" => "var(--d, #fff)", "--d" => "var(--a)" }
    ].each do |decls|
      assert_includes unresolved("var(--a)", decls), "cycle", decls.inspect
    end
    assert_rgba 0, 0, 0, resolved("var(--a)", { "--a" => "var(--b, var(--c))", "--b" => "#000", "--c" => "#fff" })
    assert_rgba 0, 0, 0, resolved("var(--a)", { "--a" => "var(--b, var(--missing))", "--b" => "#000" })
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

  # A cycle hidden anywhere in the referenced declaration's value (inside
  # color-mix(), another unsupported function, a channel argument, or a
  # nested fallback) makes that property invalid at computed-value time, so
  # the outer var() fallback applies before any unresolved reason is
  # returned. When the referencing property is itself in the cycle, it stays
  # invalid whatever its fallback.
  def test_cycle_hidden_in_unsupported_function_uses_outer_fallback
    [
      "color-mix(in srgb, red, var(--a))",
      "color-mix(in srgb, red, var(--b))",
      "oklch(var(--a) 0.1 120)",
      "hwb(var(--a) 0% 0%)",
      "lab(50 var(--b, 0) 0)",
      "color(srgb var(--a) 0 0)",
      "rgb(var(--a) 0 0)",
      "light-dark(red, var(--a))",
      "color-mix(in srgb, red, var(--m, oklch(var(--a) 0 0)))",
      "var(--m, color-mix(in srgb, red, var(--a)))",
      "\\63 olor-mix(in srgb, red, v\\61r(--a))"
    ].each do |value|
      decls = { "--a" => value, "--b" => "var(--a)", "--page-text" => "var(--a, white)" }
      color = CV.resolve(decls["--page-text"], decls, seen: Set["--page-text"]).color
      refute_nil color, value
      assert_rgba 255, 255, 255, color
      assert_equal "var() cycle through --a", unresolved("var(--a)", decls), value
      inside = decls.merge("--a" => value.gsub(/--[ab](?=[,)])/, "--page-text"))
      reason = CV.resolve(inside["--page-text"], inside, seen: Set["--page-text"]).reason
      assert_equal "var() cycle through --page-text", reason, value
    end
    acyclic = { "--a" => "color-mix(in srgb, red, var(--c))", "--c" => "#000", "--page-text" => "var(--a, white)" }
    assert_includes CV.resolve(acyclic["--page-text"], acyclic, seen: Set["--page-text"]).reason, "color-mix()"
  end

  # A var() in the referencing property's own fallback is a dependency even
  # when the primary reference is unresolved for another reason.
  def test_cycle_through_fallback_beats_unresolved_primary
    decls = { "--x" => "oklch(0.5 0.1 120)", "--page-text" => "var(--x, color-mix(in srgb, red, var(--page-text)))" }
    reason = CV.resolve(decls["--page-text"], decls, seen: Set["--page-text"]).reason
    assert_equal "var() cycle through --page-text", reason
  end

  # A comma with nothing (or only whitespace) after it is an empty
  # fallback, not an absent one: the empty token sequence is a valid value,
  # so a property that is empty or substitutes an empty fallback is
  # defined, and a var() referencing it takes the empty value (not a
  # color), never its own fallback.
  def test_empty_fallback_is_defined_not_guaranteed_invalid
    assert_equal [ "--x", nil ], CV.parse_var_ref("var(--x)")
    [ "var(--x,)", "var(--x, )", "var(--x,\n\t )" ].each do |v|
      assert_equal [ "--x", "" ], CV.parse_var_ref(v), v
    end
    empty_values = [ "", "   ", "var(--missing,)", "var(--missing, )", "var(--m1, var(--m2,))",
                     "var(--mid)", "var(--empty-fb, #000)" ]
    empty_values.each do |value|
      decls = { "--a" => value, "--mid" => "var(--missing,)", "--empty-fb" => "var(--missing,)",
                "--page-text" => "var(--a, white)" }
      reason = CV.resolve(decls["--page-text"], decls, seen: Set["--page-text"]).reason
      assert_equal CV::EMPTY_REASON, reason, value
      assert_equal CV::EMPTY_REASON, unresolved("var(--a, white)", decls), value
    end
    assert_equal CV::EMPTY_REASON, unresolved("var(--missing,)")
    assert_equal CV::EMPTY_REASON, unresolved("var(--missing, var(--also-missing, ))")
    assert_rgba 0, 0, 0, resolved("var(--x,)", { "--x" => "#000" })
    assert_rgba 0, 0, 0, resolved("var(--x, )", { "--x" => "var(--y,)", "--y" => "#000" })
    # No comma at all is still no fallback: the property is guaranteed-invalid
    # and the outer fallback applies.
    assert_rgba 255, 255, 255, resolved("var(--a, white)", { "--a" => "var(--missing)" })
  end

  # Whether a referenced property is guaranteed-invalid is decided by the
  # var() substitutions in its value, wherever they sit, not by the reason
  # its value fails to be a color: a failing var() inside a function makes
  # the property invalid (so the outer fallback applies), and one rescued by
  # a fallback, empty or not, leaves it valid (so it does not).
  def test_guaranteed_invalid_is_decided_by_substitution_not_reason
    { "rgb(var(--missing) 0 0)" => true, "color-mix(in srgb, red, var(--m, var(--n)))" => true,
      "var(foo)" => true, "rgb(var(--missing,) 0 0)" => false, "rgb(var(--missing, 1) 0 0)" => false,
      "notacolor" => false }.each do |value, invalid|
      result = CV.resolve("var(--bad, #000)", { "--bad" => value })
      if invalid
        assert_rgba 0, 0, 0, result.color
      else
        assert_nil result.color, value
      end
    end
  end

  # One resolution builds the dependency graph and finds cycles once, and
  # walks a long chain without deep recursion: 2000 links resolve in well
  # under a second, and closing the chain into a cycle is still found.
  def test_long_reference_chain_resolves_quickly
    n = 2000
    decls = (0...n).to_h { |i| [ "--c#{i}", "var(--c#{i + 1})" ] }
    decls["--c#{n}"] = "#123456"
    with_fallbacks = decls.transform_values { |v| v.sub(")", ", #fff)") }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_rgba 0x12, 0x34, 0x56, resolved("var(--c0)", decls)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0
    assert_rgba 0x12, 0x34, 0x56, CV.resolve(decls["--c0"], decls, seen: Set["--c0"]).color
    assert_rgba 0x12, 0x34, 0x56, resolved("var(--c0)", with_fallbacks)
    assert_rgba 255, 255, 255, resolved("var(--c0)", with_fallbacks.merge("--c#{n}" => "var(--missing)"))
    assert_equal CV::EMPTY_REASON, unresolved("var(--c0, red)", decls.merge("--c#{n}" => "var(--missing,)"))
    cyclic = decls.merge("--c#{n}" => "var(--c0)")
    assert_equal "var() cycle through --c0", CV.resolve(cyclic["--c0"], cyclic, seen: Set["--c0"]).reason
    assert_includes unresolved("var(--c0)", cyclic), "cycle"
    assert_equal (0..n).map { |i| "--c#{i}" }, CV.dependency_closure("var(--c0)", decls)
  end

  # Resolution stays linear on graphs wider than a chain: a lattice where
  # each hop reaches the rest twice (once through its fallback), closed into
  # one long cycle or into a cycle hidden behind color-mix(), resolves
  # correctly in well under a second without overflowing the stack.
  def test_long_var_lattice_resolves_quickly
    n = 2000
    decls = (0...n).to_h { |i| [ "--t#{i}", "var(--t#{i + 1}, var(--t#{[ i + 2, n ].min}))" ] }.merge("--t#{n}" => "#000")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_rgba 0, 0, 0, CV.resolve(decls["--t0"], decls, seen: Set["--t0"]).color
    ring = decls.merge("--t#{n}" => "var(--t0)")
    assert_equal "var() cycle through --t0", CV.resolve(ring["--t0"], ring, seen: Set["--t0"]).reason
    assert_rgba 0, 0, 255, resolved("var(--t#{n / 2}, blue)", ring)
    mixed = decls.merge("--t#{n}" => "color-mix(in srgb, red, var(--t0))")
    assert_rgba 0, 0, 255, resolved("var(--t#{n / 2}, blue)", mixed)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0
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

  # WCAG 2.2 linearizes with the 0.04045 knee; channels in the band between
  # the obsolete 0.03928 and 0.04045 must take the linear branch.
  def test_relative_luminance_uses_wcag22_knee
    [ 10.1, 10.2, 10.3, 0.04045 * 255 ].each do |channel|
      color = CV::Rgba.new(r: channel, g: channel, b: channel, a: 1.0)
      assert_in_delta (channel / 255.0) / 12.92, CV.relative_luminance(color), 1e-15, channel.to_s
    end
    edge = CV.resolve("rgb(10.1 132.33333 132.33333)", {}).color
    assert_operator CV.contrast_ratio(edge, CV::WHITE), :<, 4.5
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

  def test_non_finite_numbers_are_unresolved_at_every_parse_site
    [
      "rgb(1e999 0 0)", "rgb(0 -1e999 0)", "rgb(1e999% 0% 0%)",
      "hsl(1e999 50% 50%)", "hsl(1e999turn 50% 50%)", "hsl(0 1e999% 50%)", "hsl(0 50% 1e999%)"
    ].each { |value| unresolved(value) }
  end

  def test_fractional_channels_survive_to_luminance_for_every_channel_form
    white = ColorValue.resolve("#fff", {}).color
    {
      "rgb(148.7 148.7 148.7)" => 148.7,
      "rgb(148.7, 148.7, 148.7)" => 148.7,
      "rgb(58.3% 58.3% 58.3%)" => 0.583 * 255,
      "hsl(0 0% 58.3%)" => 0.583 * 255
    }.each do |value, expected|
      color = ColorValue.resolve(value, {}).color
      [ color.r, color.g, color.b ].each { |c| assert_in_delta expected, c, 1e-9, value }
      exact = Struct.new(:r, :g, :b, :a).new(expected, expected, expected, 1.0)
      assert_in_delta ColorValue.contrast_ratio(exact, white), ColorValue.contrast_ratio(color, white), 1e-12, value
    end
    assert_operator ColorValue.contrast_ratio(ColorValue.resolve("rgb(148.7 148.7 148.7)", {}).color, white), :>=, 3.0
    assert_equal "#959595", ColorValue.to_hex(ColorValue.resolve("rgb(148.7 148.7 148.7)", {}).color)
  end

  def test_finite_literals_that_overflow_after_unit_conversion_are_unresolved
    [
      "hsl(1e308turn 50% 50%)", "hsl(-1e308turn 50% 50%)", "hsl(1e308rad 50% 50%)",
      "rgb(1e308% 0% 0%)", "rgb(0% -1e308% 0%)"
    ].each { |value| unresolved(value) }
  end

  def test_large_finite_angles_that_do_not_overflow_still_resolve
    [ "hsl(1e308 50% 50%)", "hsl(1e308deg 50% 50%)", "hsl(1e308grad 50% 50%)" ].each do |value|
      refute_nil ColorValue.resolve(value, {}).color, value
    end
  end

  def test_extreme_alpha_exponents_resolve_quickly
    cases = {
      "rgb(0 0 0 / 1e999999999)" => 1.0,
      "rgb(0 0 0 / 1e999999999%)" => 1.0,
      "rgb(0 0 0 / -1e999999999)" => 0.0,
      "rgb(0 0 0 / -1e999999999%)" => 0.0,
      "rgb(0 0 0 / 1e-999999999)" => 0.0,
      "rgb(0 0 0 / 1e-999999999%)" => 0.0,
      "rgb(0 0 0 / 5e300)" => 1.0,
      "rgb(0 0 0 / 5e-300%)" => 0.0,
      "rgb(0 0 0 / 3.33e1%)" => 0.333
    }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    cases.each do |value, alpha|
      color = CV.resolve(value, {}).color
      assert_in_delta alpha, color.a, 1e-12, value
    end
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0
  end

  def test_huge_hue_exponent_matches_expanded_integer_in_every_exact_unit
    big = "1#{"0" * 33}"
    {
      "1e33deg" => "#{big}deg", "1e33" => big, "-1e33deg" => "-#{big}deg",
      "1.5e33deg" => "15#{"0" * 32}deg", "-2.5e40deg" => "-25#{"0" * 39}deg",
      "1e33grad" => "#{big}grad", "-3e35grad" => "-3#{"0" * 35}grad",
      "1e33turn" => "#{big}turn", "7e40turn" => "7#{"0" * 40}turn"
    }.each do |short, long|
      assert_equal resolved("hsl(#{long} 100% 50%)").to_h, resolved("hsl(#{short} 100% 50%)").to_h, short
    end
    assert_equal resolved("hsl(280deg 100% 50%)").to_h, resolved("hsl(1e33deg 100% 50%)").to_h
    unresolved("hsl(1e0000000000000000001deg 100% 50%)")
  end

  # A small negative exponent stays exact like its expanded decimal, in
  # every unit and in every exact caller (hue, channel, percent, alpha).
  def test_small_exponent_matches_expanded_decimal
    tiny = "0.#{"0" * 32}1"
    {
      "hsl(1e-33deg 100% 50%)" => "hsl(#{tiny}deg 100% 50%)",
      "hsl(1e-33 100% 50%)" => "hsl(#{tiny} 100% 50%)",
      "hsl(-1e-33grad 100% 50%)" => "hsl(-#{tiny}grad 100% 50%)",
      "hsl(1e-33turn 100% 50%)" => "hsl(#{tiny}turn 100% 50%)",
      "hsl(359.5e-33turn 100% 50%)" => "hsl(0.#{"0" * 30}3595turn 100% 50%)",
      "rgb(1e-33 0 0)" => "rgb(#{tiny} 0 0)",
      "rgb(1e-33% 0 0)" => "rgb(#{tiny}% 0 0)",
      "rgb(0 0 0 / 1e-33)" => "rgb(0 0 0 / #{tiny})",
      "hsl(0 1e-33% 50%)" => "hsl(0 #{tiny}% 50%)",
      "hsl(120 100% 1e-33%)" => "hsl(120 100% #{tiny}%)",
      "rgb(0 0 0 / 1e-33%)" => "rgb(0 0 0 / #{tiny}%)",
      "hsl(1e-40grad 100% 50%)" => "hsl(0.#{"0" * 39}1grad 100% 50%)",
      "hsl(1e-50turn 100% 50%)" => "hsl(0.#{"0" * 49}1turn 100% 50%)",
      "hsl(1e-300deg 100% 50%)" => "hsl(0.#{"0" * 299}1deg 100% 50%)",
      "rgb(5e-320 0 0)" => "rgb(0.#{"0" * 319}5 0 0)"
    }.each do |short, long|
      assert_equal resolved(long).to_h, resolved(short).to_h, short
    end
    assert_equal Rational(1, 10**33), CV.bounded_rational("1e-33")
    assert_equal Rational(1, 10**400), CV.bounded_rational("1e-400")
    assert_equal Rational(10**400), CV.bounded_rational("1e401")
    assert_equal 0, CV.bounded_rational("1e-401")
  end

  # Escapes are decoded once, before any dispatch, so every escaped
  # spelling of a var() reference, a named color, a keyword or a color
  # function resolves the way the browser reads it.
  def test_escaped_values_resolve_like_their_decoded_spelling
    decls = { "--white" => "#fff", "--ink" => "#000" }
    {
      "\\76 ar(--white)" => "var(--white)",
      "\\76 \\61 r(--white)" => "var(--white)",
      "\\000076ar(--white)" => "var(--white)",
      "v\\61 r(--white)" => "var(--white)",
      "\\56 AR(--white)" => "var(--white)",
      "var(--wh\\69 te)" => "var(--white)",
      "var(\\2d \\2d ink)" => "var(--ink)",
      "var(--nope, \\72 ed)" => "red",
      "\\72 ed" => "red",
      "r\\65 d" => "red",
      "\\52 ED" => "red",
      "\\74 ransparent" => "transparent",
      "\\72 gb(1 2 3)" => "rgb(1 2 3)",
      "rgb\\61 (1 2 3 / 50%)" => "rgba(1 2 3 / 50%)",
      "\\68 sl(120 100% 50%)" => "hsl(120 100% 50%)"
    }.each do |escaped, plain|
      assert_equal resolved(plain, decls).to_h, resolved(escaped, decls).to_h, escaped
    end
    assert CV.literal?("\\72 ed")
    assert CV.literal?("\\72 gb(1 2 3)")
    refute CV.literal?("\\72 gb(\\76 ar(--x) 0 0)")
    assert_includes unresolved("\\6f klch(0.5 0.1 120)"), "oklch()"
    assert_includes unresolved("\\69 nherit"), "cascade"
    assert_includes unresolved("\\76 ar(--page-text)", { "--page-text" => "\\76 ar(--page-text)" }), "cycle"
  end

  # An escape whose decoded code point would be a delimiter, whitespace, a
  # digit or sign starting a number, or part of a #hash or a number's unit
  # has no plain spelling: unresolved with a reason, never guessed at.
  def test_escapes_without_plain_spelling_are_unresolved
    [
      "rgb\\28 1 2 3)", "rgb\\(1 2 3)", "var\\(--white)", "\\76 ar\\28 --white)",
      "rgb(1\\2c 2, 3)", "rgb(1 2 3\\29", "re\\;d", "\\22 red", "\\20 red",
      "rgb(\\32 55 0 0)", "rgb(1\\65 3 0 0)", "rgb(50\\% 0 0)", "rgb(\\2d 1 0 0)",
      "#\\66 ff", "#f\\66 f", "rgb(0 0 0 / \\31)"
    ].each do |value|
      reason = unresolved(value, { "--white" => "#fff" })
      assert_includes reason, "escape", value
      refute CV.literal?(value), value
    end
    # An escape inside a quoted string is string content, not a name.
    assert_rgba 255, 255, 255, resolved("var(--w, \"\\(\")", { "--w" => "#fff" })
  end

  # Every custom-property name is compared by its decoded value, wherever it
  # is read: the whole-value reference, a nested fallback dependency, or a
  # deeper fallback chain. --\61, --\000061 and --\61 (with its one eaten
  # space) all name --a, so each of these closes a cycle through --a.
  def test_escaped_custom_property_names_compare_decoded
    [ "--\\61", "--\\000061", "--\\61 ", "--\\61\t" ].each do |ref|
      [
        { "--a" => "var(--b, var(--c))", "--b" => "#000", "--c" => "var(#{ref})" },
        { "--a" => "var(--b, var(#{ref}))", "--b" => "#000" },
        { "--a" => "var(--b, var(--c))", "--b" => "#000", "--c" => "var(--d, var(#{ref}))", "--d" => "#fff" },
        { "--a" => "var(#{ref})" }
      ].each do |decls|
        reason = CV.resolve(decls["--a"], decls, seen: Set["--a"]).reason
        assert_equal "var() cycle through --a", reason, decls.inspect
      end
    end
    assert_equal [ "--a", "--b-c", "--\u00e9" ], CV.var_dependencies("var(--\\61) var( --b\\2d c ) var(--\\e9)")
    assert_equal [ "--a", nil ], CV.send(:parse_var_ref, "var(--\\61)")
    assert_rgba 0, 0, 0, resolved("var(--\\61)", { "--a" => "#000" })
  end
end
