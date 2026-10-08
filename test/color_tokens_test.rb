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
    ok(":root{--a:VAR(--Ink)}\n:root{--a:var(--Ink)}")
    ok(":root{--a:#ABC}\n:root{--a:#abc}")
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

  # --- values -------------------------------------------------------------------

  def test_authored_derived_and_non_color_values
    result = ok(":root{--a:#000;--b:rgb(1 2 3);--c:hsl(0 0% 50%);--d:red;--e:var(--a);" \
                "--f:color-mix(in srgb, var(--a) 50%, #fff);--radius:0.5rem;--g:oklch(0.2 0 0);--error:#f00}")
    assert_equal [ "#000", "rgb(1 2 3)", "hsl(0 0% 50%)", "red" ], result.authored.map { |a| a[:value] }
    assert_equal 2, result.derived
    assert result.error_token
    assert_equal "0.5rem", result.variants[:light]["--radius"]
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
    spellings = [ "#fff", "#ffffff", "#FFFFFFFF", "white", "WHITE", "rgb(255 255 255)", "rgba(255, 255, 255, 1)",
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

  def test_dark_is_light_merged_with_overrides_in_any_source_order
    result = ok(".dark{--a:#fff}\n:root{--a:#000;--b:#111}")
    assert_equal({ "--a" => "#000", "--b" => "#111" }, result.variants[:light])
    assert_equal({ "--a" => "#fff", "--b" => "#111" }, result.variants[:dark])
  end

  # --- pairs --------------------------------------------------------------------

  def test_pairs_follow_the_fixed_rule
    tokens = { "--background" => "#fff", "--card" => "#000", "--card-foreground" => "#fff",
               "--muted-ink" => "#000", "--fg" => "#000", "--text" => "#000", "--btn-fg" => "#000",
               "--link-text-hover" => "#000" }
    assert_equal [ %w[--card-foreground --card], %w[--muted-ink --background], %w[--btn-fg --background] ],
                 ColorTokens.pairs(tokens)
  end
end
