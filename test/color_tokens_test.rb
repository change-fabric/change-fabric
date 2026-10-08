# frozen_string_literal: true

require "tmpdir"
require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/color_tokens"

# One test per bullet of the "Token file" grammar in skills/color/SKILL.md.
class ColorTokensTest < Minitest::Test
  def read(css)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "tokens.css")
      File.write(path, css)
      ColorTokens.read(path)
    end
  end

  def ok(css)
    result = read(css)
    assert_empty result.errors, css
    result
  end

  def error_messages(css)
    errors = read(css).errors
    refute_empty errors, css
    errors.each { |e| assert_operator e.line, :>, 0, e.inspect }
    errors.map(&:message)
  end

  def assert_error(css, fragment)
    messages = error_messages(css)
    assert(messages.any? { |m| m.include?(fragment) }, "#{fragment} not in #{messages.inspect}")
  end

  # A custom property whose value holds a [] or {} block with ; or } inside
  # is one declaration, not an unparsed segment or a nested rule.
  def test_custom_property_simple_block_values_are_one_declaration
    ok(":root {\n  --syntax: [a;b];\n  --map: {a:b};\n  --x: [ {;} ];\n  --bg: #fff;\n  --text: #000;\n}\n")
  end

  # --- encoding ---------------------------------------------------------------

  def test_bom_prefixed_file_reads_like_plain
    css = ":root { --bg: #fff; --text: #111; }\n.dark { --bg: #000; --text: #eee; }\n"
    plain = ok(css)
    bom = ok("﻿#{css}")
    assert_equal plain.variants, bom.variants
    assert bom.dark
  end

  # --- location ---------------------------------------------------------------

  def test_locate_zero_matches_names_every_candidate
    Dir.mktmpdir do |root|
      err = ColorTokens.locate(root, nil)
      assert_kind_of ColorTokens::Error, err
      ColorTokens::PATHS.each { |rel| assert_includes err.message, rel }
    end
  end

  def test_locate_one_match_in_path_list_order
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "app"))
      File.write(File.join(root, "app/globals.css"), ":root{}")
      assert_equal File.join(root, "app/globals.css"), ColorTokens.locate(root, nil)
    end
  end

  def test_locate_several_matches_names_them
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "src"))
      File.write(File.join(root, "tokens.css"), ":root{}")
      File.write(File.join(root, "src/index.css"), ":root{}")
      err = ColorTokens.locate(root, nil)
      assert_kind_of ColorTokens::Error, err
      assert_includes err.message, "tokens.css"
      assert_includes err.message, "src/index.css"
    end
  end

  def test_locate_override_wins_even_with_several_matches
    Dir.mktmpdir do |root|
      File.write(File.join(root, "tokens.css"), ":root{}")
      assert_equal "custom.css", ColorTokens.locate(root, "custom.css")
    end
  end

  def test_unreadable_file_is_an_error_not_a_raise
    result = ColorTokens.read("/nonexistent/tokens.css")
    assert_includes result.errors.first.message, "cannot read token file"
  end

  # --- top level ----------------------------------------------------------------

  def test_tailwind_entry_statements_are_skipped
    ok("@import 'tailwindcss';\n@charset \"utf-8\";\n@tailwind base;\n@source '../x';\n" \
       "@plugin 'p';\n@custom-variant dark (&:is(.dark *));\n@config './c.js';\n:root{--a:#000}")
  end

  def test_other_statements_are_errors
    assert_error("@layer a, b;\n:root{--a:#000}", "@layer a, b")
  end

  def test_one_layer_wrapper_named_or_anonymous_is_transparent
    named = ok("@layer base { :root{--a:#000} .dark{--a:#fff} }")
    assert_equal({ "--a" => "#fff" }, named.variants[:dark])
    ok("@layer { :root{--a:#000} @media (prefers-color-scheme: dark){ :root{--a:#fff} } }")
  end

  def test_second_top_level_layer_is_an_error
    assert_error("@layer a { :root{--a:#000} } @layer b { :root{--b:#111} }", "second `@layer b`")
    assert_error("@layer { :root{--a:#000} } @layer { .dark{--a:#fff} }", "second `@layer`")
    assert_error("@layer a { :root{--a:#000} } @layer a { .dark{--a:#fff} }", "second `@layer a`")
  end

  def test_layer_wrapper_dotted_name_is_transparent
    named = ok("@layer theme.base { :root{--a:#000} .dark{--a:#fff} }")
    assert_equal({ "--a" => "#fff" }, named.variants[:dark])
  end

  # A layer name is any CSS identifier, non-ASCII and dotted included; the
  # @layer keyword itself is ASCII case-insensitive.
  def test_layer_wrapper_accepts_any_identifier_name
    [ "caf\u00e9", "base.caf\u00e9", "caf\u00e9.th\u00e8me", "_x", "-x", "a.b.c", "caf\\e9", "\u4e2d" ].each do |name|
      result = ok("@layer #{name} { :root{--a:#000} .dark{--a:#fff} }")
      assert_equal "#fff", result.variants[:dark]["--a"], name
    end
    assert_equal "#000", ok("@LAYER base { :root{--a:#000} }").variants[:light]["--a"]
    [ "1x", "a.", ".a", "a..b", "caf\u00e9, b", "a.1b" ].each do |name|
      assert_error("@layer #{name} { :root{--a:#000} }", "not a valid @layer wrapper")
    end
  end

  # Layer names are CSS identifiers: "--" names, escaped starts, and any
  # ident code point; never \w alone.
  def test_layer_wrapper_name_takes_every_ident_code_point
    [ "\u65e5\u672c", "--base", "base-2.caf\u00e9_x", "caf\\e9 .x", "\\31 base", "\\@x" ].each do |name|
      named = ok("@layer #{name} { :root{--a:#000} .dark{--a:#fff} }")
      assert_equal({ "--a" => "#fff" }, named.variants[:dark], name)
    end
    [ "base.", "caf\u00e9 x", "-1x" ].each do |name|
      assert_error("@layer #{name} { :root{--a:#000} }", "not a valid @layer wrapper")
    end
  end

  def test_non_ascii_at_rule_name_is_reported_whole
    assert_error("@l\u0430yer x { :root{--a:#000} }", "`@l\u0430yer` is not allowed")
    assert_error("@caf\u00e9 { :root{--a:#000} }", "`@caf\u00e9` is not allowed")
  end

  def test_layer_wrapper_with_multiple_names_is_an_error
    assert_error("@layer a, b { :root{--a:#000} }", "not a valid @layer wrapper")
  end

  def test_layer_wrapper_with_garbage_prelude_is_an_error
    assert_error("@layer name ??? { :root{--a:#000} }", "not a valid @layer wrapper")
  end

  def test_nested_layer_is_an_error
    assert_error("@layer a { @layer b { :root{--a:#000} } }", "nested `@layer b`")
  end

  def test_theme_block_is_light
    assert_equal({ "--a" => "#000" }, ok("@theme { --a: #000; }").variants[:light])
    assert_equal({ "--a" => "#fff", "--m" => "{x:y}" }, ok("@theme { --a:#fff; --m:{x:y}; }").variants[:light])
    ok("@theme { --metadata: {a:b}; --a: #000; }")
  end

  def test_other_block_at_rules_are_errors
    assert_error("@supports (color: red) { :root{--a:#000} }", "@supports")
    assert_error("@media print { :root{--a:#000} }", "@media print")
    assert_error("@media (prefers-color-scheme: dark) { @media (prefers-color-scheme: dark) { :root{} } }",
                 "prefers-color-scheme")
  end

  def test_declaration_outside_a_block_is_an_error
    assert_error("--a: #000;", "outside a token block")
  end

  # --- selectors ----------------------------------------------------------------

  def test_dark_spellings
    [ ".dark", ":root.dark", "[data-theme=dark]", "[data-theme=\"dark\"]", "[data-theme='dark']",
      ":root[data-theme=dark]", ":root[data-theme='dark']", "[ data-theme = \"dark\" ]" ].each do |sel|
      result = ok(":root{--a:#000}\n#{sel}{--a:#fff}")
      assert_equal({ "--a" => "#fff" }, result.variants[:dark], sel)
      assert result.dark?
    end
  end

  def test_whitespace_inside_attribute_values_is_not_stripped
    [ "[data-theme=\"d a r k\"]", "[data-theme=' dark']", "[data-theme=\"dark \"]",
      "[data-theme=da rk]", ":root[data-theme=\"da\trk\"]" ].each do |sel|
      result = read(":root{--a:#000}\n#{sel}{--a:#fff}")
      refute result.dark?, sel
      refute_empty result.errors, sel
    end
  end

  def test_root_descendant_dark_is_an_error_not_a_dark_block
    result = read(":root{--a:#000}\n:root .dark{--a:#fff}")
    assert_equal [ "selector `:root .dark` is not a token block; only :root and the dark spellings are allowed" ],
                 result.errors.map(&:message)
    refute result.dark?
    assert_equal "#000", result.variants[:dark]["--a"]
  end

  def test_every_combinator_is_an_error
    [ ".dark .card", ".dark > .card", ".dark+.card", ".dark ~ .card", ":root\n.dark" ].each do |sel|
      assert_error(":root{--a:#000}\n#{sel}{--a:#fff}", "is not a token block")
    end
  end

  def test_comment_inside_a_compound_is_not_a_combinator
    ok(":root{--a:#000}\n:root/* x */.dark{--a:#fff}")
  end

  def test_html_and_other_selectors_are_errors
    assert_error("html{--a:#000}", "`html`")
    assert_error(":root{--a:#000}\n[data-theme=light]{--a:#fff}", "[data-theme=light]")
    assert_error(":root{--a:#000}\n.theme-dark{--a:#fff}", ".theme-dark")
  end

  def test_selector_list_must_share_one_variant
    ok(":root{--a:#000}\n.dark, [data-theme=dark]{--a:#fff}")
    assert_error(":root{--a:#000}\n:root, .dark{--a:#fff}", "mixes light and dark")
  end

  def test_nested_rule_inside_token_block_is_an_error
    assert_error(":root{--a:#000; .card{--b:#fff}}", "nested block `.card`")
  end

  # --- comments are token boundaries ------------------------------------------

  def test_comment_that_merges_tokens_fails_closed
    preludes = [ "@me/**/dia (prefers-color-scheme: dark){:root{--a:#fff}}",
                 "@media (prefers-color/**/-scheme: dark){:root{--a:#fff}}",
                 "@media (prefers-color-scheme: da/**/rk){:root{--a:#fff}}",
                 ":ro/**/ot.dark{--a:#fff}", ".da/**/rk{--a:#fff}", "[data-theme=da/**/rk]{--a:#fff}" ]
    preludes.each do |css|
      result = read(":root{--a:#000}\n#{css}")
      assert(result.errors.any? { |e| e.message.include?("joins two tokens across a comment") }, css)
      refute result.dark?, css
      assert_equal "#000", result.variants[:dark]["--a"], css
    end
  end

  def test_comment_inside_a_declaration_name_fails_closed
    [ ":root{--a:#000;--a/**/b:#fff}", ":root{--a:#000;col/**/or:#fff}", ":root{--a:#000}\n@imp/**/ort url(x);" ].each do |css|
      result = read(css)
      refute_empty result.errors, css
      assert_equal({ "--a" => "#000" }, result.variants[:light], css)
    end
  end

  def test_comment_between_tokens_of_a_compound_still_reads
    ok(":root{--a:#000}\n:root/**/.dark{--a:#fff}")
    ok(":root{--a:#000}\n@media/**/(prefers-color-scheme:/**/dark){:root{--a:#fff}}")
  end

  # A comment between two whole tokens reads as whitespace, so the token
  # sequence CSS sees is classified; only a comment splitting one token fails.
  def test_comment_separating_whole_tokens_reads_as_whitespace
    [ "@layer/**/base{:root{--a:#000}}", "@layer/* x */theme.base{:root{--a:#000}}",
      "@layer/**/base/**/{:root{--a:#000}}", "@layer/**/base{:root{--a:#000}}\n.dark{--a:#fff}",
      "@layer/**/base{:root{--a:#000}\n@media/**/(prefers-color-scheme:/**/dark){:root{--a:#fff}}}" ].each do |css|
      assert_equal "#000", ok(css).variants[:light]["--a"], css
    end
  end

  def test_comment_splitting_one_token_fails_closed
    [ "@la/**/yer{:root{--a:#000}}", "@la/**/yer base{:root{--a:#000}}", "@layer ba/**/se{:root{--a:#000}}",
      "@/**/layer{:root{--a:#000}}", "@th/**/eme{--a:#000}", "@layer/**/base/**/x{:root{--a:#000}}" ].each do |css|
      assert_error(css, "joins two tokens across a comment")
    end
  end

  def test_byte_order_mark_is_ignored
    result = ok("﻿:root{--background:#fff;--a:#000}\n.dark{--a:#fff}")
    assert_equal "#000", result.variants[:light]["--a"]
    assert result.dark?
  end

  # --- prefers-color-scheme -----------------------------------------------------

  def test_media_dark_root_means_dark
    result = ok(":root{--a:#000;--b:#111}\n@media (prefers-color-scheme: dark){:root{--a:#fff}}")
    assert_equal({ "--a" => "#fff", "--b" => "#111" }, result.variants[:dark])
  end

  def test_media_light_root_merges_with_light
    result = ok(":root{--a:#000}\n@media (prefers-color-scheme: light){:root{--b:#111;--a:#000}}")
    assert_equal({ "--a" => "#000", "--b" => "#111" }, result.variants[:light])
    refute result.dark?
  end

  def test_media_light_conflict_is_an_error
    assert_error(":root{--a:#000}\n@media (prefers-color-scheme: light){:root{--a:#111}}", "`--a` is declared twice in light")
  end

  def test_redeclaration_compares_custom_property_names_case_sensitively
    [
      ":root{--a:var(--Ink)}\n:root{--a:var(--ink)}",
      ":root{--a:var(--ink, #000)}\n:root{--a:var(--INK, #000)}",
      ":root{--a:color-mix(in srgb, var(--Ink) 50%, #fff)}\n:root{--a:color-mix(in srgb, var(--ink) 50%, #fff)}",
      ".dark{--a:var(--Ink)}\n.dark{--a:var(--ink)}"
    ].each { |css| assert_error(css, "`--a` is declared twice") }
    ok(":root{--a:#ABC}\n:root{--a:#abc}")
  end

  # Non-color values fold only ASCII case-insensitive identifiers; colors
  # compare resolved.
  def test_redeclaration_case_folds_only_resolved_colors
    [
      ":root{--a:url(/A.png)}\n:root{--a:url(/a.png)}",
      ":root{--a:url('/A.png')}\n:root{--a:url('/a.png')}",
      ":root{--a:var(--x, url(/A.png))}\n:root{--a:VAR(--x, url(/a.png))}",
      ":root{--a:var(--x, \"VAR\")}\n:root{--a:var(--x, \"var\")}",
      ":root{--a:\u00e9var(--x)}\n:root{--a:\u00c9var(--x)}"
    ].each { |css| assert_error(css, "`--a` is declared twice") }
    ok(":root{--a:Foo}\n:root{--a:foo}")
    ok(":root{--a:VAR(--Ink)}\n:root{--a:var(--Ink)}")
    ok(":root{--a:Color-Mix(in srgb, var(--x) 50%, #fff)}\n:root{--a:color-mix(in srgb, VAR(--x) 50%, #fff)}")
    ok(":root{--a:URL(/A.png)}\n:root{--a:url(/A.png)}")
    ok(":root{--a:#FFF}\n:root{--a:#fff}")
    ok(":root{--a:RGB(0 0 0)}\n:root{--a:rgb(0 0 0)}")
    ok(":root{--a:url(/A.png)}\n:root{--a:url(/A.png)  }")
  end

  # A value that names a color on its own compares by that color whether or
  # not it is authored (transparent is not), and every keyword, function name
  # and unit compares ASCII case-insensitively. Custom-property names,
  # strings, non-ASCII and a var() that may substitute something else stay
  # distinct.
  def test_redeclaration_folds_keyword_and_color_spellings
    [
      [ "transparent", "TRANSPARENT" ],
      [ "Transparent", "rgb(0 0 0 / 0)" ],
      [ "red", "RED" ],
      [ "BLUE", "#00f" ],
      [ "currentColor", "CURRENTCOLOR" ],
      [ "INHERIT", "inherit" ],
      [ "Unset", "unset" ],
      [ "color-mix(in SRGB, var(--x) 50%, #fff)", "color-mix(in srgb, var(--x) 50%, #fff)" ],
      [ "color-mix(IN srgb, red 50%, BLUE)", "color-mix(in srgb, red 50%, blue)" ],
      [ "oklch(0.5 0.1 120DEG)", "oklch(0.5 0.1 120deg)" ],
      [ "oklch(0.5 0.1 120d\\65 g)", "oklch(0.5 0.1 120deg)" ],
      [ "oklch(0.5 0.1 120\\44 EG)", "oklch(0.5 0.1 120deg)" ],
      [ "1\\70 x solid", "1px solid" ],
      [ "var(--x, TRANSPARENT)", "var(--x, transparent)" ],
      [ "1PX SOLID", "1px solid" ]
    ].each do |a, b|
      ok(":root{--a:#{a}}\n:root{--a:#{b}}")
      ok(":root{--a:#000}\n.dark{--a:#{a}}\n@media (prefers-color-scheme: dark){:root{--a:#{b}}}")
    end
    [
      [ "var(--Ink)", "var(--ink)" ],
      [ "var(--x, red)", "red" ],
      [ "var(--x, transparent)", "transparent" ],
      [ "\"INHERIT\"", "\"inherit\"" ],
      [ "url(/A.png)", "url(/a.png)" ],
      [ "oklch(0.5 0.1 1\\65 3)", "oklch(0.5 0.1 1e3)" ],
      [ "calc(50\\25)", "calc(50%)" ],
      [ "\u00c9t\u00e9", "\u00e9t\u00e9" ]
    ].each { |a, b| assert_error(":root{--a:#{a}}\n:root{--a:#{b}}", "`--a` is declared twice") }
    result = ok(":root{--error:transparent}\n@media (prefers-color-scheme: dark){:root{--error:TRANSPARENT}}")
    assert result.error_token
  end

  # Whitespace that is its own insignificant token (inside parens, around a
  # comma or slash) never makes two spellings of one value conflict.
  def test_redeclaration_ignores_insignificant_whitespace
    [
      [ "var( --ink )", "var(--ink)" ],
      [ "var(\t--ink\n)", "var(--ink)" ],
      [ "var( --ink , #000 )", "var(--ink,#000)" ],
      [ "VAR( --ink )", "var(--ink)" ],
      [ "rgb( var(--r) var(--g) var(--b) )", "rgb(var(--r) var(--g) var(--b))" ],
      [ "rgb(var(--c) / 50%)", "rgb(var(--c)/50%)" ],
      [ "color-mix( in srgb , var( --x ) 50% , #fff )", "color-mix(in srgb,var(--x) 50%,#fff)" ],
      [ "var(--x, \"a\" )", "var(--x,\"a\")" ],
      [ "url( /A.png )", "url(/A.png)" ]
    ].each do |a, b|
      ok(":root{--a:#{a}}\n:root{--a:#{b}}")
      ok(":root{--a:#000}\n.dark{--a:#{a}}\n.dark{--a:#{b}}")
    end
    [
      [ "var(--x) var(--y)", "var(--x)var(--y)" ],
      [ "var(--x, \" a \")", "var(--x, \"a\")" ],
      [ "var(--x, ' , ')", "var(--x, ',')" ],
      [ "url( /A.png )", "url(/a.png)" ],
      [ "foo (x)", "foo(x)" ]
    ].each { |a, b| assert_error(":root{--a:#{a}}\n:root{--a:#{b}}", "`--a` is declared twice") }
  end

  def test_redeclaration_keeps_quoted_strings_verbatim
    [
      %(:root{--a:"A  B"}\n:root{--a:"a b"}),
      %(:root{--a:"A"}\n:root{--a:"a"}),
      %(:root{--a:'x  y'}\n:root{--a:'x y'}),
      %(:root{--a:url("A.png")}\n:root{--a:url("a.png")}),
      %(:root{--a:"it's  A"}\n:root{--a:"it's a"}),
      %(:root{--a:"esc\\"  A"}\n:root{--a:"esc\\" a"})
    ].each { |css| assert_error(css, "`--a` is declared twice") }
    ok(%(:root{--a:foo  "A  B"}\n:root{--a:foo "A  B"}))
  end

  def test_media_takes_only_root
    assert_error(":root{--a:#000}\n@media (prefers-color-scheme: dark){.dark{--a:#fff}}", "only :root is allowed")
  end

  # --- declarations ---------------------------------------------------------------

  def test_normal_property_and_apply_are_errors
    assert_error(":root{--a:#000; color: red}", "property `color`")
    assert_error(":root{--a:#000; @apply bg-black}", "`@apply bg-black`")
  end

  def test_important_is_dropped_from_the_value
    assert_equal "#000", ok(":root{--a:#000 !important}").variants[:light]["--a"]
  end

  def test_escaped_important_is_dropped_from_the_value
    assert_equal "#000", ok(":root{--a:#000 !\\69mportant}").variants[:light]["--a"]
  end

  # --- values -------------------------------------------------------------------

  def test_authored_derived_and_non_color_values
    result = ok(":root{--a:#000;--b:rgb(1 2 3);--c:hsl(0 0% 50%);--d:red;--e:var(--a);" \
                "--f:color-mix(in srgb, var(--a) 50%, #fff);--radius:0.5rem;--g:oklch(0.2 0 0);--error:#f00}")
    assert_equal [ "#000", "rgb(1 2 3)", "hsl(0 0% 50%)", "red" ], result.authored.map { |a| a[:value] }
    assert_equal 2, result.derived
    assert result.error_token
    assert_equal "0.5rem", result.variants[:light]["--radius"]
  end

  def test_derived_count_needs_a_function_token_boundary
    result = ok(":root{--a:VAR(--x);--b:Color-Mix(in srgb, red, blue);--c:my-var(--x);--d:x-color-mix(red);--e:_var(--x)}")
    assert_equal 2, result.derived
    [ "\u00e9var(--x)", "var\u00e9(--x)", "2var(--x)", %("var(--x)"), %('color-mix(in srgb, red, blue)'),
      %(url(var(--x))), %(url("var(--x)")), "\\75 rl(var(--x))" ].each do |v|
      assert_equal 0, ok(":root{--a:#{v}}").derived, v
    end
    [ "\\var(--x)", "v\\61r(--x)", "\\63 olor-mix(in srgb, red, blue)" ].each do |v|
      assert_equal 1, ok(":root{--a:#{v}}").derived, v
    end
  end

  # An escape is part of a compound: an escaped space, >, + or ~ is never a
  # combinator, so the selector is one compound (and not a token block).
  def test_escaped_selector_characters_are_not_combinators
    [ ".dark\\ x", ".dark\\>x", ".dark\\+x", ".dark\\~x", ".d\\61 rk\\ x" ].each do |sel|
      messages = error_messages(":root{--a:#000}\n#{sel}{--a:#fff}")
      assert_equal 1, messages.size, sel
      assert_includes messages.first, "selector `#{sel}` is not a token block", sel
    end
  end

  # CSS decodes escapes in every selector identifier and quoted value, so an
  # escaped spelling of an accepted selector is that selector.
  def test_escaped_selector_spellings_are_accepted
    [ ":r\\6f ot", ":R\\4f OT", ":\\72oot", ":roo\\74" ].each do |sel|
      assert_equal({ "--a" => "#000" }, ok("#{sel}{--a:#000}").variants[:light], sel)
    end
    [ ".d\\61rk", ".d\\61 rk", ".\\64 ark", ":root.\\64 ark", ":r\\6f ot.dark",
      "[data-theme=\"d\\61rk\"]", "[data-theme='d\\61 rk']", "[data-theme=\"dar\\\nk\"]",
      "[data-theme=d\\61rk]", "[d\\61ta-theme=dark]", "[DATA-THEME=dark]", "[Data-Theme=\"dark\"]",
      ":root[d\\61ta-theme=\"d\\61rk\"]" ].each do |sel|
      result = ok(":root{--a:#000}\n#{sel}{--a:#fff}")
      assert_equal({ "--a" => "#fff" }, result.variants[:dark], sel)
    end
  end

  # An escape that decodes to a delimiter is ident content, never structure:
  # .\2e dark is the class ".dark", :root\ x is one pseudo-class. Class names
  # and attribute values stay case-sensitive.
  def test_escaped_delimiters_and_case_sensitive_parts_are_not_accepted
    [ ".\\2e dark", ":r\\6f ot\\ x", ":root\\2e dark", ":root\\.dark", "\\3a root.dark", ".dark\\5b x",
      "[data-theme\\3d dark]", "[data-theme=dark\\5d ]", "[data-theme=\"da\\\"rk\"]",
      "[data-theme=\"dark\\\"]\"]", "[data-theme=\"dark", ".DARK", ".D\\41RK", "[data-theme=DARK]",
      "[data-theme=\"D\\41RK\"]" ].each do |sel|
      result = read(":root{--a:#000}\n#{sel}{--a:#fff}")
      refute result.dark?, sel
      refute_empty result.errors, sel
    end
  end

  def test_escaped_media_query_and_at_rule_spellings_are_accepted
    [ "@m\\65 dia (prefers-color-scheme: d\\61rk)", "@media (prefers-c\\6flor-scheme: dark)" ].each do |media|
      result = ok(":root{--a:#000}\n#{media}{ :r\\6f ot{--a:#fff} }")
      assert_equal({ "--a" => "#fff" }, result.variants[:dark], media)
    end
    result = ok(":root{--a:#000}\n@media (prefers-color-scheme: dark){ :ROOT{--a:#fff} }")
    assert_equal({ "--a" => "#fff" }, result.variants[:dark])
    assert_equal "#000", ok("@layer b\\61se { :root{--a:#000} }").variants[:light]["--a"]
    [ "@t\\61ilwind base;", "@\\69mport \"x.css\";", "@IMPORT \"x.css\";" ].each do |stmt|
      assert_equal "#000", ok("#{stmt}\n:root{--a:#000}").variants[:light]["--a"], stmt
    end
    assert_error("@t\\61ilwind\\2e x;\n:root{--a:#000}", "is not allowed in a token file")
    assert_error(":root{--a:#000}\n@media (prefers-color-scheme: d\\61rk){ .d\\61rk{--a:#fff} }",
                 "only :root is allowed there")
  end

  # Keywords match ASCII case-insensitively only: Ruby's /i and casecmp?
  # fold U+212A KELVIN SIGN to k and U+017F LONG S to s, CSS does not.
  def test_keywords_fold_ascii_case_only
    result = ok(":root{--a:#000}\n@MEDIA (PREFERS-COLOR-SCHEME: DARK){ :ROOT{--a:#fff} }\n:ROOT.dark{--a:#fff}")
    assert_equal({ "--a" => "#fff" }, result.variants[:dark])
    [ "dar\u212a", "d\\61r\\212a", "dar\u212A" ].each do |scheme|
      assert_error(":root{--a:#000}\n@media (prefers-color-scheme: #{scheme}){ :root{--a:#fff} }",
                   "only prefers-color-scheme media is allowed")
    end
    assert_error(":root{--a:#000}\n@media (prefers-color-\u017fcheme: dark){ :root{--a:#fff} }",
                 "only prefers-color-scheme media is allowed")
    [ ".d\u00e2rk", ".dar\u212a", ":root.caf\u00e9" ].each do |sel|
      assert_error(":root{--a:#000}\n#{sel}{--a:#fff}", "is not a token block")
    end
    assert_error("@tailw\u00efnd base;\n:root{--a:#000}", "is not allowed in a token file")
  end

  def test_escaped_function_names_redeclare_alike
    ok(":root{--a:\\56 AR(--x)}\n:root{--a:var(--x)}")
    ok(":root{--a:v\\61r(--x)}\n:root{--a:var(--x)}")
  end

  # Redeclaration compares every identifier by its decoded value: escaped
  # custom-property names, function names and keywords agree with their
  # plain spelling, but decoding never folds case or touches a string.
  def test_escaped_identifiers_redeclare_alike
    [
      [ "var(--\\69 nk)", "var(--ink)" ],
      [ "var(\\2d \\2d ink)", "var(--ink)" ],
      [ "var(-\\2d ink, #000)", "var(--ink, #000)" ],
      [ "r\\67 b(0 0 0)", "rgb(0 0 0)" ],
      [ "R\\47 B(var(--x) 0 0)", "rgb(var(--x) 0 0)" ],
      [ "color-mix(in srgb, var(--\\78) 50%, #fff)", "color-mix(in srgb, var(--x) 50%, #fff)" ],
      [ "f\\6f o", "foo" ],
      [ "#\\66 ff", "#fff" ],
      [ "#f\\66 f", "#fff" ],
      [ "#\\46\\46\\46", "#FFF" ],
      [ "var(--x, #\\66 ff)", "var(--x, #fff)" ]
    ].each { |a, b| ok(":root{--a:#{a}}\n:root{--a:#{b}}") }
    [
      [ "var(--\\49 nk)", "var(--ink)" ],
      [ "var(--Ink)", "var(--\\69 nk)" ],
      [ "var(--x, \"\\69\")", "var(--x, \"i\")" ]
    ].each { |a, b| assert_error(":root{--a:#{a}}\n:root{--a:#{b}}", "`--a` is declared twice") }
  end

  # A custom property declared with escaped hyphens is the decoded name.
  def test_escaped_hyphen_declared_names_are_custom_properties
    result = ok(":root { --background: #fff; \\2d \\2d x: #000; -\\2d x-text: var(\\2d -x); }")
    assert_equal "#000", result.variants[:light]["--x"]
    assert_equal [ %w[--x-text --x] ], ColorTokens.pairs(result.variants[:light])
  end

  def test_unresolved_literal_forms_are_not_authored
    %w[rgb(calc(1+2),0,0) rgba(none,0,0) hsl(calc(10deg),50%,50%) hsla(0,50%,50%,calc(1)) rgb(1,2) hsl(foo) rgb()].each do |v|
      result = ok(":root{--a:#000;--b:#111;--c:#222;--d:#333;--e:#{v}}")
      assert_equal 4, result.authored.size, v
    end
  end

  def test_same_authored_color_counts_once
    result = ok(":root{--a:#000;--b:#000}\n.dark{--a:#000}")
    assert_equal [ { value: "#000", names: %w[--a --b], line: 1 } ], result.authored
  end

  def test_equivalent_spellings_count_as_one_color
    spellings = [ "#fff", "#ffffff", "#FFFFFFFF", "#\\66 ff", "#\\46\\46\\46", "white", "WHITE", "rgb(255 255 255)", "rgba(255, 255, 255, 1)",
                  "rgb(100% 100% 100%)", "hsl(0 0% 100%)", "hsla(120, 50%, 100%, 1)" ]
    css = ":root{#{spellings.each_with_index.map { |v, i| "--c#{i}:#{v}" }.join(";")}}"
    result = ok(css)
    assert_equal 1, result.authored.size
    assert_equal spellings.size, result.authored.first[:names].size
  end

  def test_distinct_alpha_values_stay_distinct
    [ [ "rgba(0 0 0 / .5001)", "rgba(0 0 0 / .5002)" ],
      [ "rgb(0 0 0 / 50.01%)", "rgb(0 0 0 / 50.02%)" ],
      [ "hsl(0 0% 0% / .1234)", "hsl(0 0% 0% / .1235)" ] ].each do |a, b|
      result = ok(":root{--a:#{a};--b:#{b}}")
      assert_equal 2, result.authored.size, "#{a} vs #{b}"
    end
  end

  def test_distinct_fractional_channels_stay_distinct
    [ [ "rgb(0.1 0 0)", "rgb(0.2 0 0)" ],
      [ "rgb(0 0.4 0)", "rgb(0 0.6 0)" ],
      [ "rgb(0 0 0.1%)", "rgb(0 0 0.2%)" ],
      [ "rgb(0.0000001 0 0)", "rgb(0.0000002 0 0)" ],
      [ "rgb(0 0.0000001 0)", "rgb(0 0.0000002 0)" ],
      [ "rgba(0 0 0 / 0.0000001)", "rgba(0 0 0 / 0.0000002)" ],
      [ "hsl(0 100% 0.1%)", "hsl(0 100% 0.2%)" ] ].each do |a, b|
      result = ok(":root{--a:#{a};--b:#{b}}")
      assert_equal 2, result.authored.size, "#{a} vs #{b}"
    end
  end

  def test_equal_fractional_channel_spellings_share_one_color
    [ [ "rgb(50% 0 0)", "rgb(127.5 0 0)" ],
      [ "#ff0000", "rgb(255 0 0)" ],
      [ "#ff0000", "rgb(100% 0 0)" ],
      [ "rgb(255 0 0)", "rgb(100% 0 0)" ],
      [ "rgb(-0 0 0)", "rgb(0 0 0)" ],
      [ "rgb(-0.0 0 0)", "#000" ],
      [ "#800000", "rgb(128 0 0)" ],
      [ "#800000", "rgb(128.0, 0, 0)" ],
      [ "rgb(33.3% 0 0)", "rgb(84.915 0 0)" ],
      [ "hsl(0 100% 25%)", "rgb(127.5 0 0)" ] ].each do |a, b|
      result = ok(":root{--a:#{a};--b:#{b}}")
      assert_equal 1, result.authored.size, "#{a} vs #{b}"
    end
  end

  def test_equal_alpha_spellings_share_one_color
    result = ok(":root{--a:rgba(0 0 0 / .5);--b:rgb(0 0 0 / 50%);--c:rgba(0, 0, 0, 0.50)}")
    assert_equal 1, result.authored.size
  end

  def test_equivalent_error_token_spellings_do_not_conflict
    result = ok(":root{--error:#f00}\n@media (prefers-color-scheme: dark){:root{--error:red}}")
    assert_empty result.authored
    assert result.error_token
  end

  def test_palette_over_target_is_an_error
    assert_error(":root{--a:#000;--b:#111;--c:#222;--d:#333;--e:#444}", "palette has 5 authored colors")
  end

  # --- dark redefinition ----------------------------------------------------------

  def test_new_name_in_dark_is_an_error
    assert_error(":root{--a:#000}\n.dark{--b:#fff}", "`--b` is declared in dark but not in light")
  end

  def test_two_dark_blocks_must_agree
    assert_error(":root{--a:#000}\n.dark{--a:#fff}\n[data-theme=dark]{--a:#eee}", "`--a` is declared twice in dark")
    ok(":root{--a:#000}\n.dark{--a:#fff}\n@media (prefers-color-scheme: dark){:root{--a:#FFF}}")
  end

  def test_dark_is_light_merged_with_overrides
    result = ok(":root{--a:#000;--b:#111}\n.dark{--a:#fff}")
    assert_equal({ "--a" => "#000", "--b" => "#111" }, result.variants[:light])
    assert_equal({ "--a" => "#fff", "--b" => "#111" }, result.variants[:dark])
  end

  # The three dark activation mechanisms apply independently, so each one's
  # dark table is built alone and every pair must agree. Enumerates each
  # pair of mechanisms, in each spelling, splitting the overrides (an
  # error naming both and the first differing name) and repeating them
  # (accepted, one dark variant), plus each mechanism alone and a selector
  # list that is both class and attribute at once.
  def test_dark_mechanisms_must_give_one_dark_palette
    spellings = {
      media: [ "@media (prefers-color-scheme: dark){:root{BODY}}" ],
      class: [ ".dark{BODY}", ":root.dark{BODY}" ],
      attribute: [ "[data-theme=dark]{BODY}", ":root[data-theme=\"dark\"]{BODY}" ]
    }
    light = ":root{--background:#fff;--page-text:#000}\n"
    spellings.keys.combination(2).each do |one, two|
      spellings[one].product(spellings[two]).each do |x, y|
        split = "#{light}#{x.sub('BODY', '--background:#000')}\n#{y.sub('BODY', '--page-text:#fff')}"
        assert_error(split, "dark under #{ColorTokens::MECHANISMS[one]} and under #{ColorTokens::MECHANISMS[two]} differ at `--background`")
        body = "--background:#000;--page-text:#fff"
        same = ok("#{light}#{x.sub('BODY', body)}\n#{y.sub('BODY', body)}")
        assert_equal({ "--background" => "#000", "--page-text" => "#fff" }, same.variants[:dark], same)
      end
    end
    spellings.values.flatten.each do |x|
      result = ok("#{light}#{x.sub('BODY', '--background:#000')}")
      assert_equal({ "--background" => "#000", "--page-text" => "#000" }, result.variants[:dark], x)
    end
    assert_error("#{light}.dark, [data-theme=dark]{--background:#000}\n.dark{--page-text:#fff}",
                 "dark under .dark class and under data-theme attribute differ at `--page-text`")
    ok("#{light}.dark, [data-theme=dark]{--background:#000;--page-text:#fff}")
  end

  # The mechanisms are compared after the cascade, so an override that
  # loses to light under one mechanism (an earlier, equally specific
  # .dark) differs from one that wins under another (a later media :root).
  def test_dark_mechanisms_compare_after_the_cascade
    assert_error(".dark{--a:#000}\n:root{--a:#fff}\n@media (prefers-color-scheme: dark){:root{--a:#000}}",
                 "differ at `--a`")
  end

  # A browser activating one mechanism matches only that mechanism's
  # members of a selector list, so each mechanism's dark table ranks the
  # block at the most specific of its own members. Enumerates each pair of
  # mechanism spellings in one list, in both orders: when the members'
  # specificities differ the less specific mechanism loses to a later
  # :root, so the palettes differ; when they match, the list keeps one
  # palette.
  def test_dark_selector_list_ranks_each_mechanism_by_its_own_members
    light = ":root{--background:#fff;--page-text:#000}\n"
    tail = ":root{--background:#fff}\n.dark, [data-theme=dark]{--page-text:#fff}"
    [ [ ":root.dark", "[data-theme=dark]" ], [ ".dark", ":root[data-theme=dark]" ] ].each do |members|
      [ members, members.reverse ].each do |list|
        css = "#{light}#{list.join(', ')}{--background:#000}\n#{tail}"
        messages = error_messages(css)
        assert(messages.any? { |m| m.include?("differ at `--background`") && m.include?(".dark class") && m.include?("data-theme attribute") },
               "#{css}: #{messages.inspect}")
      end
    end
    [ [ ".dark", "[data-theme=dark]" ], [ ":root.dark", ":root[data-theme=dark]" ] ].each do |members|
      [ members, members.reverse ].each do |list|
        css = "#{light}#{list.join(', ')}{--background:#000}\n#{tail}"
        winner = list.first.start_with?(":root") ? "#000" : "#fff"
        assert_equal winner, ok(css).variants[:dark]["--background"], css
      end
    end
  end

  # Past importance and layer, CSS Cascade 5 sorts by selector specificity
  # and then source order, so dark has no default win: an equally specific
  # dark block before :root loses to it, a more specific one wins from
  # anywhere, and a later dark block beats an earlier :root. Covers every
  # accepted dark spelling on both sides of a :root declaration.
  def test_dark_override_follows_specificity_then_source_order
    darks = {
      ".dark{BODY}" => false, "[data-theme=dark]{BODY}" => false,
      "[data-theme=\"dark\"]{BODY}" => false, "@media (prefers-color-scheme: dark){:root{BODY}}" => false,
      ":root.dark{BODY}" => true, ":root[data-theme=dark]{BODY}" => true, ".dark, :root.dark{BODY}" => true
    }
    darks.each do |dark, more_specific|
      block = dark.sub("BODY", "--a:#000")
      after = ":root{--a:#fff}\n#{block}"
      before = "#{block}\n:root{--a:#fff}"
      assert_equal "#000", ok(after).variants[:dark]["--a"], after
      assert_equal more_specific ? "#000" : "#fff", ok(before).variants[:dark]["--a"], before
    end
    [ "@theme{--a:#fff}\n.dark{--a:#000}", ".dark{--a:#000}\n@theme{--a:#fff}" ].each_with_index do |css, i|
      assert_equal i.zero? ? "#000" : "#fff", ok(css).variants[:dark]["--a"], css
    end
  end

  # An equal-valued redeclaration keeps its latest, most specific copy: a
  # later :root{--a:white} beats an earlier .dark, and a later equal-valued
  # dark copy wins back.
  def test_equal_valued_redeclaration_keeps_latest_source_order
    assert_equal "#fff", ok(":root{--a:#fff}\n.dark{--a:#000}\n:root{--a:white}").variants[:dark]["--a"]
    assert_equal "#000", ok(":root{--a:#fff}\n.dark{--a:#000}\n:root{--a:white}\n.dark{--a:black}").variants[:dark]["--a"]
    assert_equal "#000", ok(":root.dark{--a:#000}\n:root{--a:#fff}\n.dark{--a:black}").variants[:dark]["--a"]
  end

  # A dark declaration replaces light only where the cascade lets it: a
  # normal dark value never beats an !important light one, an !important
  # dark value always does, and with both important the later dark one
  # wins on source order. Every dark spelling (class, attribute,
  # prefers-color-scheme media) and an !important on any equal-valued
  # redeclaration counts.
  def test_dark_override_respects_important_priority
    darks = [ ".dark{BODY}", ":root.dark{BODY}", "[data-theme=dark]{BODY}",
              "@media (prefers-color-scheme: dark){:root{BODY}}" ]
    cases = {
      [ "#fff !important", "#000" ] => "#fff",
      [ "#fff !IMPORTANT", "#000" ] => "#fff",
      [ "#fff ! important", "#000" ] => "#fff",
      [ "#fff", "#000 !important" ] => "#000",
      [ "#fff !important", "#000 !important" ] => "#000",
      [ "#fff", "#000" ] => "#000"
    }
    darks.each do |dark|
      cases.each do |(light_value, dark_value), expected|
        css = ":root{--a:#{light_value}}\n#{dark.sub('BODY', "--a:#{dark_value}")}"
        assert_equal expected, ok(css).variants[:dark]["--a"], css
      end
    end
    css = ":root{--a:#fff;--a:white !important}\n.dark{--a:#000}"
    assert_equal "#fff", ok(css).variants[:dark]["--a"], css
  end

  # Layer origin is ranked with priority, per CSS Cascade 5: among normal
  # declarations an unlayered one beats a layered one, among !important ones
  # a layered one beats an unlayered one, and on an equal rank (same layer,
  # or both unlayered) the later, equally specific dark block wins. Covers
  # every split of light and dark across the one @layer wrapper, named and
  # anonymous, with each priority.
  def test_dark_override_respects_layer_origin
    wrap = ->(layer, rule) { layer ? "#{layer}{#{rule}}" : rule }
    [ "@layer base", "@layer" ].each do |layer|
      cases = {
        # [light layered?, light value, dark layered?, dark value] => dark result
        [ false, "#fff", true, "#000" ] => "#fff",
        [ true, "#fff", false, "#000" ] => "#000",
        [ true, "#fff", true, "#000" ] => "#000",
        [ false, "#fff", false, "#000" ] => "#000",
        [ true, "#fff !important", false, "#000 !important" ] => "#fff",
        [ false, "#fff !important", true, "#000 !important" ] => "#000",
        [ true, "#fff !important", true, "#000 !important" ] => "#000",
        [ false, "#fff", true, "#000 !important" ] => "#000",
        [ true, "#fff !important", false, "#000" ] => "#fff"
      }
      cases.each do |(light_in, light_value, dark_in, dark_value), expected|
        light = ":root{--a:#{light_value}}"
        dark = ".dark{--a:#{dark_value}}"
        both = "#{layer}{#{light}\n#{dark}}"
        split = "#{wrap.call(light_in && layer, light)}\n#{wrap.call(dark_in && layer, dark)}"
        css = light_in && dark_in ? both : split
        assert_equal expected, ok(css).variants[:dark]["--a"], css
      end
    end
  end

  # An equal-valued redeclaration in another layer origin keeps the highest
  # ranked one: an unlayered normal light redeclaration of a layered light
  # value outranks a layered dark override.
  def test_equal_valued_redeclaration_keeps_highest_layer_origin
    css = "@layer base{:root{--a:#fff}\n.dark{--a:#000}}\n:root{--a:white}"
    assert_equal "#fff", ok(css).variants[:dark]["--a"], css
    css = "@layer base{:root{--a:#fff}\n.dark{--a:#000}}\n.dark{--a:black}"
    assert_equal "#000", ok(css).variants[:dark]["--a"], css
  end

  # --- pairs --------------------------------------------------------------------

  def test_pairs_follow_the_fixed_rule
    tokens = { "--background" => "#fff", "--card" => "#000", "--card-foreground" => "#fff",
               "--muted-ink" => "#000", "--fg" => "#000", "--text" => "#000", "--btn-fg" => "#000",
               "--link-text-hover" => "#000" }
    assert_equal [ %w[--card-foreground --card], %w[--muted-ink --background], %w[--btn-fg --background] ],
                 ColorTokens.pairs(tokens)
  end

  # Escaped declared names are the decoded property: --\61-text pairs with
  # --a, and redeclaring --a as --\61 with another value is caught.
  def test_escaped_declared_names_resolve_and_pair_decoded
    result = ok(":root { --background: #fff; --\\61: #000; --\\61-text: var(--\\61); }")
    assert_equal "#000", result.variants[:light]["--a"]
    assert_equal [ %w[--a-text --a] ], ColorTokens.pairs(result.variants[:light])
    assert_error(":root { --a: #000; --\\61: #fff; }", "`--a` is declared twice")
  end

  # A declaration holding a malformed var(), nested fallbacks included, is a
  # token-file error naming the call, and is ignored as the browser ignores
  # it; whitespace, comments and an empty fallback are well formed.
  def test_malformed_var_is_a_token_error_and_the_declaration_is_dropped
    [ "var(--b junk)", "var(--b --c)", "var(--x, var(--b junk))", "var()" ].each do |v|
      assert_error(":root { --b: #000; --x: #fff; --a: #{v}; }", "`--a` has a malformed `var(")
      assert_error(":root { --b: #000; --x: #fff; --a: #{v}; }", v.include?("--x") ? "var(--b junk)" : v)
      result = read(":root { --b: #000; --x: #fff; --a: #fff; }\n.dark { --a: #{v}; }")
      assert_equal "#fff", result.variants[:dark]["--a"], v
    end
    [ "var( --b )", "var(--b,)", "var(--b/**/)", "var(--b /* x */, red)" ].each do |v|
      assert_equal "#000000", ColorValue.resolve("var(--a)", ok(":root { --b: #000; --a: #{v}; }").variants[:light]).color&.then { |c| ColorValue.to_hex(c) }, v
    end
  end

  # U+000B is not CSS whitespace: it neither separates the media query nor
  # pads a bracketed attribute selector.
  def test_vertical_tab_is_not_css_whitespace
    assert_error(":root{--a:#fff}\n@media\v(prefers-color-scheme: dark){:root{--a:#000}}", "is not a token block")
    assert_error(":root{--a:#fff}\n[ data-theme\v= dark]{--a:#000}", "is not a token block")
    assert_equal "#000", ok(":root{--a:#fff}\n@media\f(prefers-color-scheme:\tdark){:root{--a:#000}}").variants[:dark]["--a"]
    assert_equal "#000", ok(":root{--a:#fff}\n[\tdata-theme\n=\fdark ]{--a:#000}").variants[:dark]["--a"]
  end

  # The data-theme attribute name is ASCII case-insensitive; its value is not.
  def test_dark_attribute_name_folds_ascii_case_only
    assert_equal "#000", ok(":root{--a:#fff}\n:root[DATA-Theme=dark]{--a:#000}").variants[:dark]["--a"]
    assert_error(":root{--a:#fff}\n[data-theme=DARK]{--a:#000}", "is not a token block")
    refute_match ColorTokens::DARK_ATTR, "[data-theme\u017F=dark]"
  end
end
