# frozen_string_literal: true

require "pathname"
require_relative "test_helpers"
require_relative "#{File.expand_path('../scripts', __dir__)}/color_check"

class ColorCheckTest < Minitest::Test
  include SkillTempHome

  def with_dir
    Dir.mktmpdir do |dir|
      yield dir
    end
  end

  def write(dir, rel, content)
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  FOUR_COLOR_TOKENS = <<~CSS
    :root {
      --cream: #f6efe0;
      --plum: #24122a;
      --lilac: #a070c8;
      --pink: #f2c4c4;
      --background: var(--cream);
      --page-text: var(--plum);
    }

    :root[data-theme="dark"] {
      --background: var(--plum);
      --page-text: var(--cream);
    }
  CSS

  # Each row states what the token-file grammar defines, not what the
  # checker does today; pending: true marks a row the current code still
  # fails. Expected ratios come from an independent WCAG calculation, never
  # from the checker.
  CORPUS = [
    # :comments
    { id: "comments-block-comment-not-mid-value", cls: :comments,
      files: { "tokens.css" => ":root{--background:#fff;/* --page-text: #fff; */--page-text:#000;}" },
      palette: [ "#fff", "#000" ],
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "comments-block-comment-with-brace", cls: :comments,
      files: { "tokens.css" => ":root{--background:#fff; /* } */ --page-text:#777;}" },
      contrast: [ [ "light", "--page-text", "--background", 4.48 ] ],
      pending: false },
    # :strings
    { id: "strings-semicolon-and-brace-in-value-string", cls: :strings,
      files: { "tokens.css" => ":root {\n  --background: #fff;\n  --label: \"a;b}c\";\n  --page-text: #000;\n}\n" },
      palette: [ "#fff", "#000" ],
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    # :token_grammar, one row per construct the token-file grammar rejects
    # or accepts, checked through the whole run
    { id: "grammar-media-min-width-is-an-error", cls: :token_grammar,
      files: { "tokens.css" => "@media (min-width: 40em) { :root { --page-text: #777 } }" },
      token_errors: [ "@media (min-width: 40em)" ],
      contrast: [],
      pending: false },
    { id: "grammar-layer-base-wrapper-accepted", cls: :token_grammar,
      files: { "tokens.css" => "@layer base { :root { --background:#fff; --page-text:#000 } }" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "grammar-nested-layer-is-an-error", cls: :token_grammar,
      files: { "tokens.css" => "@layer a{:root{--page-text:#000000} @layer b{:root{--page-text:#777777}}}\n:root{--background:#ffffff}\n" },
      token_errors: [ "@layer b" ],
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "grammar-redeclared-light-value-is-an-error", cls: :token_grammar,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000}\n@layer base{:root{--page-text:#777}}\n" },
      token_errors: [ "--page-text` is declared twice in light" ],
      pending: false },
    { id: "grammar-supports-and-container-are-errors", cls: :token_grammar,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000}\n@supports (color: red){:root{--page-text:#777}}\n@container (min-width: 1px){:root{--page-text:#111}}\n" },
      token_errors: [ "@supports", "@container" ],
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "grammar-root-descendant-dark-is-an-error", cls: :token_grammar,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000}\n:root .dark{--page-text:#fff}\n" },
      token_errors: [ "selector `:root .dark` is not a token block" ],
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "grammar-html-selector-is-an-error", cls: :token_grammar,
      files: { "tokens.css" => "html{--background:#fff;--page-text:#000} html.dark{--background:#000;--page-text:#fff}" },
      token_errors: [ "`html`", "`html.dark`" ],
      contrast: [],
      pending: false },
    { id: "grammar-new-name-in-dark-is-an-error", cls: :token_grammar,
      files: { "tokens.css" => ":root{--background:#fff}\n.dark{--page-text:#fff}\n" },
      token_errors: [ "--page-text` is declared in dark but not in light" ],
      contrast: [],
      pending: false },
    { id: "grammar-two-dark-blocks-disagree-is-an-error", cls: :token_grammar,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000}\n.dark{--page-text:#fff}\n[data-theme=dark]{--page-text:#eee}\n" },
      token_errors: [ "declared twice in dark" ],
      contrast: [ [ "light", "--page-text", "--background", 21.0 ], [ "dark", "--page-text", "--background", 1.0 ] ],
      pending: false },

    # :variants, light and dark from every accepted spelling
    { id: "variants-media-dark-override", cls: :variants,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000;--a:#123;} @media (prefers-color-scheme: dark){:root{--background:#000;--page-text:#777;}}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ], [ "dark", "--page-text", "--background", 4.69 ] ],
      pending: false },
    { id: "variants-shadcn-bare-dark-class", cls: :variants,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000} .dark{--background:#000;--page-text:#fff}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ], [ "dark", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "variants-root-dark-class", cls: :variants,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000} :root.dark{--background:#000;--page-text:#fff}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ], [ "dark", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "variants-split-root-rules-combine", cls: :variants,
      files: { "tokens.css" => ":root { --cream: #ffffff; --plum: #000000; } :root { --background: var(--cream); } :root { --page-text: var(--plum); }" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "variants-four-color-tokens-fixture", cls: :variants,
      files: { "tokens.css" => FOUR_COLOR_TOKENS },
      palette: [ "#f6efe0", "#24122a", "#a070c8", "#f2c4c4" ],
      pending: false },
    { id: "variants-root-selector-case", cls: :variants,
      files: { "tokens.css" => ":ROOT{--background:WHITE;--page-text:BlAcK}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    # :termination
    { id: "termination-repro5-no-mid-semicolons", cls: :termination,
      files: { "tokens.css" => ":root{--a:#123;--background:#fff;--page-text:#000}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "termination-last-declaration-keeps-authored", cls: :termination,
      files: { "tokens.css" => ":root { --background: #fff; --last: #555 }\n.hero { color: #abcdef; }\n" },
      palette: [ "#fff", "#555" ],
      token_errors: [ ".hero" ],
      pending: false },
    # :color_syntax
    { id: "color-syntax-named-white-black", cls: :color_syntax,
      files: { "tokens.css" => ":root{--background:white;--page-text:black}" },
      palette: [ "white", "black" ],
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "color-syntax-rgb-space-and-comma", cls: :color_syntax,
      files: { "tokens.css" => ":root{--background:rgb(255 255 255);--page-text:rgb(0,0,0)}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "color-syntax-important-resolves", cls: :color_syntax,
      files: { "tokens.css" => ":root{--background:#fff !important;--page-text:#000}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "color-syntax-escaped-important-resolves", cls: :color_syntax,
      files: { "tokens.css" => ":root{--background:#fff !\\69mportant;--page-text:#000 !/**/IMPORTANT}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ] ],
      pending: false },
    { id: "color-syntax-oklch-unresolved-reason", cls: :color_syntax,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:oklch(0.5 0.1 90)}" },
      contrast: [ [ "light", "--page-text", "--background", :unresolved, "oklch" ] ],
      pending: false },
    # :value_functions
    { id: "value-functions-color-mix-is-unresolved-not-an-error", cls: :value_functions,
      files: { "tokens.css" => ":root{--background:#fff;--page-text:#000;--muted-text:color-mix(in srgb, var(--page-text) 60%, var(--background))}" },
      contrast: [ [ "light", "--page-text", "--background", 21.0 ],
                  [ "light", "--muted-text", "--background", :unresolved, "color-mix" ] ],
      pending: false },
    { id: "value-functions-var-cycle-no-raise", cls: :value_functions,
      files: { "tokens.css" => ":root { --background: #fff; --page-text: var(--page-text); --a: var(--b); --b: var(--a); }" },
      contrast: [ [ "light", "--page-text", "--background", :unresolved, "cycle" ] ],
      pending: false },
    { id: "value-functions-empty-declaration-is-defined-not-invalid", cls: :value_functions,
      files: { "tokens.css" => ":root{--background:#fff;--a:;--page-text:var(--a, #000)}" },
      contrast: [ [ "light", "--page-text", "--background", :unresolved, "empty value is not a color" ] ],
      pending: false },
    { id: "value-functions-empty-fallback-is-a-fallback", cls: :value_functions,
      files: { "tokens.css" => ":root{--background:#fff;--b:var(--missing,);--page-text:var(--b, #000)}" },
      contrast: [ [ "light", "--page-text", "--background", :unresolved, "empty value is not a color" ] ],
      pending: false },
    # :pairing, the fixed rule: "--x-<suffix>" pairs with "--x" when
    # declared, else with "--background"; no other name pairs
    { id: "pairing-base-text-pairs-with-base", cls: :pairing,
      files: { "tokens.css" => ":root{--gold-btn:#000000;--gold-btn-text:#ffffff;--background:#000000}" },
      contrast: [ [ "light", "--gold-btn-text", "--gold-btn", 21.0 ] ],
      pending: false },
    { id: "pairing-every-suffix-without-surface-pairs-with-background", cls: :pairing,
      files: { "tokens.css" => ":root{--background:#fff;--a-text:#000;--b-fg:#000;--c-foreground:#777;--d-ink:#000}" },
      contrast: [ [ "light", "--a-text", "--background", 21.0 ], [ "light", "--b-fg", "--background", 21.0 ],
                  [ "light", "--c-foreground", "--background", 4.48 ], [ "light", "--d-ink", "--background", 21.0 ] ],
      pending: false },
    { id: "pairing-names-without-a-suffix-do-not-pair", cls: :pairing,
      files: { "tokens.css" => ":root {\n  --background: #ffffff;\n  --context: #112233;\n  --ink-like: #445566;\n  --ink: #000000;\n}\n" },
      contrast: [],
      pending: false },
    { id: "pairing-missing-background-is-unresolved", cls: :pairing,
      files: { "tokens.css" => ":root{--page-text:#000}" },
      contrast: [ [ "light", "--page-text", "--background", :unresolved, "--background: is not declared" ] ],
      pending: false }
  ].freeze

  def contrast_match?(pair, expected_row)
    variant, fg, bg, *rest = expected_row
    return false unless pair.variant == variant && pair.fg == fg && pair.bg == bg

    if rest.first == :unresolved
      !pair.resolved? && (rest[1].nil? || pair.reason.to_s.include?(rest[1]))
    else
      pair.resolved? && (rest.first.nil? || (pair.ratio - rest.first).abs < 0.01)
    end
  end

  def describe_pairs(pairs)
    pairs.map { |p| [ p.variant, p.fg, p.bg, p.ratio, p.status ] }.inspect
  end

  # Each expected row consumes one matching pair, so duplicates must appear
  # as many times as expected and nothing may be left over.
  def assert_contrast_rows(row, pairs)
    remaining = pairs.dup
    row[:contrast].each do |expected_row|
      found_index = remaining.find_index { |pair| contrast_match?(pair, expected_row) }
      assert found_index, "expected contrast row #{expected_row.inspect} not found for #{row[:id]} " \
                          "(actual: #{describe_pairs(remaining)})"
      remaining.delete_at(found_index)
    end
    assert_empty remaining, "unexpected extra contrast rows for #{row[:id]}: #{describe_pairs(remaining)}"
  end

  def assert_token_errors(row, report)
    expected = row[:token_errors]
    expected ||= [] if row[:palette] || row[:contrast]
    return unless expected

    messages = report.token_errors.map(&:message)
    assert_equal expected.size, messages.size, "token errors for #{row[:id]}: #{messages.inspect}"
    expected.each do |fragment|
      assert(messages.any? { |m| m.include?(fragment) }, "#{row[:id]}: no token error mentions #{fragment}: #{messages.inspect}")
    end
  end

  def assert_corpus_row(row, report)
    if row[:palette]
      actual = report.palette ? report.palette.authored.map { |a| a[:value] }.sort : []
      assert_equal row[:palette].sort, actual, "palette mismatch for #{row[:id]}"
    end

    assert_token_errors(row, report)
    assert_contrast_rows(row, report.contrast) if row[:contrast]
  end

  CORPUS.each do |row|
    define_method("test_corpus_#{row[:id].tr('-', '_')}") do
      skip "pending: #{row[:cls]}" if row[:pending]

      with_dir do |dir|
        row[:files].each { |rel, content| write(dir, rel, content) }
        report = ColorCheck.run(dir)
        assert_corpus_row(row, report)
      end
    end
  end

  def test_corpus_has_no_pending_rows
    pending = CORPUS.select { |row| row[:pending] }
    assert_empty pending.map { |row| row[:id] }, "pending corpus rows remain"
  end

  # For every corpus row, the contrast report holds exactly one row per
  # declared pair (ColorTokens.pairs) per checked variant, light always and
  # dark only when the token file declares a dark block, nothing else, and
  # every unresolved row carries a reason.
  def test_corpus_invariant_one_row_per_pair_per_variant
    CORPUS.each do |row|
      with_dir do |dir|
        row[:files].each { |rel, content| write(dir, rel, content) }
        report = ColorCheck.run(dir)
        expected = []
        if report.tokens
          tokens = ColorTokens.read(report.tokens)
          variants = tokens.dark? ? %i[light dark] : %i[light]
          variants.each do |v|
            ColorTokens.pairs(tokens.variants[v]).each { |fg, bg| expected << [ v.to_s, fg, bg ] }
          end
        end
        assert_equal expected.sort, report.contrast.map { |c| [ c.variant, c.fg, c.bg ] }.sort, row[:id]

        report.contrast.reject(&:resolved?).each do |pair|
          refute_empty pair.reason.to_s, "#{row[:id]}: unresolved row for #{pair.fg} has no reason"
        end
      end
    end
  end

  def test_four_authored_colors_reassigned_across_themes_count_as_four
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      report = ColorCheck.run(dir)
      assert_equal 4, report.palette.authored.size
      assert_empty report.token_errors
    end
  end

  def test_error_token_excluded_and_fifth_color_is_a_token_error
    with_dir do |dir|
      css = FOUR_COLOR_TOKENS.sub("--pink: #f2c4c4;", "--pink: #f2c4c4;\n  --error: #ff0000;\n  --extra: #123456;")
      write(dir, "tokens.css", css)
      report = ColorCheck.run(dir, strict: true)
      assert report.palette.error_token
      assert_equal 5, report.palette.authored.size
      refute report.palette.authored.any? { |a| a[:names].include?("--error") }
      assert(report.token_errors.any? { |e| e.message.include?("palette has 5 authored colors") })
      assert_equal 1, report.exit_code
    end
  end

  def test_color_mix_and_var_values_count_as_derived
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      report = ColorCheck.run(dir)
      assert_operator report.palette.derived, :>, 0
    end
  end

  def test_tokens_flag_overrides_the_path_list
    with_dir do |dir|
      write(dir, "tokens.css", ":root { --a: #111111; --b: #222222; --c: #333333; --d: #444444; --e: #555555; }")
      override_path = write(dir, "real-tokens.css", FOUR_COLOR_TOKENS)
      report = ColorCheck.run(dir, tokens_override: override_path)
      assert_equal override_path, report.palette.file
      assert_equal 4, report.palette.authored.size
      assert_empty report.token_errors
    end
  end

  def test_several_conventional_token_files_is_a_token_error
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      write(dir, "src/index.css", FOUR_COLOR_TOKENS)
      report = ColorCheck.run(dir, strict: true)
      assert_nil report.palette
      assert_includes report.token_errors.first.message, "several token files found"
      assert_equal 1, report.exit_code
      assert_includes ColorCheck.render(report), "error: several token files found"
    end
  end

  def test_default_exit_is_zero_even_with_token_errors
    with_dir do |dir|
      write(dir, "tokens.css", "html{--a:#000}")
      report = ColorCheck.run(dir, strict: false)
      refute_empty report.token_errors
      assert_equal 0, report.exit_code
    end
  end

  def test_strict_exits_one_with_token_errors_and_zero_without
    with_dir do |dir|
      write(dir, "tokens.css", "html{--a:#000}")
      assert_equal 1, ColorCheck.run(dir, strict: true).exit_code
    end

    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      assert_equal 0, ColorCheck.run(dir, strict: true).exit_code
    end
  end

  # Two light spellings of one non-color identifier may name different
  # keyframes once substituted, so --strict fails on them, a color name in a
  # value that is not one color included (`1s RED`).
  def test_strict_fails_on_case_differing_custom_ident_redeclaration
    [ %w[FadeIn fadein], [ "1s RED", "1s red" ], [ "RED 1s", "red 1s" ] ].each do |a, b|
      with_dir do |dir|
        write(dir, "tokens.css", FOUR_COLOR_TOKENS.sub("--pink: #f2c4c4;", "--pink: #f2c4c4;\n  --animation: #{a};\n  --animation: #{b};"))
        report = ColorCheck.run(dir, strict: true)
        assert(report.token_errors.any? { |e| e.message.include?("`--animation` is declared twice in light") }, a)
        assert_equal 1, report.exit_code, a
      end
    end
  end

  # Equivalent string spellings are one value, so --strict passes them.
  def test_strict_passes_equivalent_string_redeclaration
    [ [ %("Inter"), %('Inter') ], [ %("\\49 nter"), %("Inter") ] ].each do |a, b|
      with_dir do |dir|
        write(dir, "tokens.css", FOUR_COLOR_TOKENS.sub("--pink: #f2c4c4;") { "--pink: #f2c4c4;\n  --font: #{a};\n  --font: #{b};" })
        assert_equal 0, ColorCheck.run(dir, strict: true).exit_code, a
      end
    end
  end

  # :root.dark, [data-theme=dark] ranks each mechanism by its own member:
  # under the attribute the early black background loses to the later
  # :root, so white text lands on white; under the class it holds. The
  # mechanisms disagree, a token error, so --strict fails.
  def test_strict_fails_when_a_selector_list_splits_mechanisms_by_specificity
    css = ":root{--background:#fff;--page-text:#000}\n:root.dark, [data-theme=dark]{--background:#000}\n" \
          ":root{--background:#fff}\n:root.dark, [data-theme=dark]{--page-text:#fff}"
    with_dir do |dir|
      write(dir, "tokens.css", css)
      report = ColorCheck.run(dir, strict: true)
      assert(report.token_errors.any? { |e| e.message.include?("differ at `--background`") }, report.token_errors.inspect)
      assert_equal 1, report.exit_code
    end
  end

  # An escaped spelling of an accepted selector is that selector, so its
  # declarations are read and --strict passes on a clean palette.
  def test_strict_passes_escaped_selector_spellings
    [ ":r\\6f ot{--background:#fff;--page-text:#000}",
      ":root{--background:#fff;--page-text:#000}\n.d\\61rk{--background:#000;--page-text:#fff}",
      ":root{--background:#fff;--page-text:#000}\n[d\\61ta-theme=\"d\\61rk\"]{--background:#000;--page-text:#fff}" ].each do |css|
      with_dir do |dir|
        write(dir, "tokens.css", css)
        report = ColorCheck.run(dir, strict: true)
        assert_equal 0, report.exit_code, css
      end
    end
    with_dir do |dir|
      write(dir, "tokens.css", ":root{--background:#fff;--page-text:#000}\n.\\2e dark{--background:#000;--page-text:#fff}")
      assert_equal 1, ColorCheck.run(dir, strict: true).exit_code
    end
  end

  # --a is malformed, so the browser ignores it and --b takes red: a 4:1
  # red on white pair, never an invented --a/--b cycle that picks black for
  # 21:1. The malformed var() is a token error, so --strict fails.
  def test_strict_fails_on_malformed_var_and_grades_the_real_fallback
    with_dir do |dir|
      write(dir, "tokens.css", ":root{--a:var(--b junk);--b:var(--a,red);--background:white;--page-text:var(--b,black)}")
      report = ColorCheck.run(dir, strict: true)
      assert_equal 1, report.exit_code
      assert(report.token_errors.any? { |e| e.message.include?("var(--b junk)") })
      row = report.contrast.find { |c| c.fg == "--page-text" }
      assert_equal "large-only", row.status
      assert_in_delta 4.0, row.ratio, 0.01
    end
  end

  def test_strict_exits_one_on_a_failing_contrast_pair
    with_dir do |dir|
      write(dir, "tokens.css", ":root{--background:#fff;--page-text:#eee}")
      report = ColorCheck.run(dir, strict: true)
      assert(report.contrast.any? { |c| c.status == "fail" })
      assert_equal 1, report.exit_code
    end
  end

  # An escaped angle unit decodes, so hsl(0d\65 g 0% 100%) is white and a
  # white-on-white pair is graded 1:1 and fails --strict, in any unit case.
  def test_strict_fails_white_on_white_spelled_with_an_escaped_hue_unit
    [ "0d\\65 g", "0D\\45 G", "0\\64 \\65 \\67 " ].each do |hue|
      with_dir do |dir|
        write(dir, "tokens.css", ":root{--background:#fff;--page-text:hsl(#{hue} 0% 100%)}")
        report = ColorCheck.run(dir, strict: true)
        assert(report.contrast.any? { |c| c.fg == "--page-text" && c.status == "fail" }, hue)
        assert_equal 1, report.exit_code, hue
      end
    end
  end

  # A layered dark override loses to an unlayered light declaration, so a
  # layered .dark --background leaves the page white under an unlayered
  # dark --page-text of white: graded 1:1 in dark and failing --strict.
  def test_strict_fails_a_layered_dark_override_beaten_by_unlayered_light
    with_dir do |dir|
      write(dir, "tokens.css", "@layer base{.dark{--background:#000}}\n" \
                               ":root{--background:#fff;--page-text:#000}\n.dark{--page-text:#fff}")
      report = ColorCheck.run(dir, strict: true)
      pair = report.contrast.find { |c| c.variant.to_s == "dark" && c.fg == "--page-text" }
      assert_equal "fail", pair.status
      assert_in_delta 1.0, pair.ratio, 0.01
      assert_equal 1, report.exit_code
    end
  end

  # Dark media and the .dark class activate independently, so splitting the
  # dark overrides across them leaves no single dark palette: a token error
  # that fails --strict, rather than a merged white-on-black variant no
  # browser renders.
  def test_strict_fails_dark_overrides_split_across_mechanisms
    with_dir do |dir|
      write(dir, "tokens.css", ":root{--background:#fff;--page-text:#000}\n" \
                               "@media (prefers-color-scheme:dark){:root{--background:#000}}\n.dark{--page-text:#fff}")
      report = ColorCheck.run(dir, strict: true)
      assert(report.token_errors.any? { |e| e.message.include?("differ at `--background`") }, report.token_errors.inspect)
      assert_equal 1, report.exit_code
    end
  end

  # Specificity and source order decide between equally ranked light and
  # dark declarations: a later :root beats the earlier, equally specific
  # .dark background, while the more specific :root.dark text still wins,
  # so the dark page is white on white, graded 1:1 and failing --strict.
  def test_strict_fails_a_dark_override_beaten_by_a_later_root
    with_dir do |dir|
      write(dir, "tokens.css", ".dark{--background:#000}\n:root.dark{--page-text:#fff}\n" \
                               ":root{--background:#fff;--page-text:#000}")
      report = ColorCheck.run(dir, strict: true)
      pair = report.contrast.find { |c| c.variant.to_s == "dark" && c.fg == "--page-text" }
      assert_equal "fail", pair.status
      assert_in_delta 1.0, pair.ratio, 0.01
      assert_equal 1, report.exit_code
    end
  end

  # A token set to initial, inherit or unset is guaranteed-invalid on the
  # root element, so a var() to it takes its fallback: a white fallback on
  # a white background is graded 1:1 and fails --strict, in both themes.
  # Without a fallback the pair is unresolved, naming the keyword.
  def test_strict_fails_a_fallback_taken_for_a_guaranteed_invalid_token
    %w[initial inherit unset].each do |kw|
      with_dir do |dir|
        write(dir, "tokens.css", ":root{--a:#{kw};--background:#fff;--page-text:var(--a,#fff)}")
        report = ColorCheck.run(dir, strict: true)
        assert(report.contrast.any? { |c| c.fg == "--page-text" && c.status == "fail" }, kw)
        assert_equal 1, report.exit_code, kw
      end
      with_dir do |dir|
        write(dir, "tokens.css", ":root{--a:#000;--background:#fff;--page-text:var(--a,#000)}\n.dark{--a:#{kw};--background:#000;--page-text:var(--a,#000)}")
        report = ColorCheck.run(dir, strict: true)
        assert(report.contrast.any? { |c| c.fg == "--page-text" && c.status == "fail" }, kw)
        assert_equal 1, report.exit_code, kw
      end
      with_dir do |dir|
        write(dir, "tokens.css", ":root{--a:#{kw};--background:#fff;--page-text:var(--a)}")
        report = ColorCheck.run(dir, strict: true)
        assert_equal 0, report.exit_code, kw
      end
    end
  end

  # An escaped var( is still a var() reference, so the low-contrast pair it
  # names is graded and --strict fails on it instead of skipping it.
  def test_strict_fails_an_escaped_var_reference_pair
    [ "\\76 ar(--white)", "v\\61 r(--white)", "\\56 AR(--white)" ].each do |ref|
      with_dir do |dir|
        write(dir, "tokens.css", ":root{--white:#fff;--background:#fff;--page-text:#{ref}}")
        report = ColorCheck.run(dir, strict: true)
        assert(report.contrast.any? { |c| c.fg == "--page-text" && c.status == "fail" }, ref)
        assert_equal 1, report.exit_code, ref
      end
    end
  end

  # An escaped hex color is that color, so its low-contrast pair is graded
  # and --strict fails on it instead of listing it as unresolved.
  def test_strict_fails_an_escaped_hex_color_pair
    [ "#\\66 ff", "#f\\66 f", "#\\46\\46\\46" ].each do |value|
      with_dir do |dir|
        write(dir, "tokens.css", ":root{--background:#fff;--page-text:#{value}}")
        report = ColorCheck.run(dir, strict: true)
        assert(report.contrast.any? { |c| c.fg == "--page-text" && c.status == "fail" }, value)
        assert_equal 1, report.exit_code, value
      end
    end
  end

  # A normal dark override of an !important light declaration does not
  # apply on the dark root, so the light value stays and the pair it leaves
  # behind (white on white) fails --strict in dark.
  def test_strict_fails_dark_pair_left_by_important_light_value
    with_dir do |dir|
      write(dir, "tokens.css",
            ":root { --background:#fff !important; --page-text:#000 } .dark { --background:#000; --page-text:#fff }")
      report = ColorCheck.run(dir, strict: true)
      pair = report.contrast.find { |c| c.fg == "--page-text" && c.variant == "dark" }
      assert_in_delta 1.0, pair.ratio, 0.01
      assert_equal "fail", pair.status
      assert_equal 1, report.exit_code
    end
  end

  def contrast_for(css, fg = "--page-text", variant: "light")
    with_dir do |dir|
      write(dir, "tokens.css", css)
      ColorCheck.run(dir).contrast.find { |c| c.fg == fg && c.variant == variant }
    end
  end

  def test_contrast_black_on_white_is_21
    pair = contrast_for(":root {\n  --background: #ffffff;\n  --page-text: #000000;\n}\n")
    assert pair.resolved?
    assert_in_delta 21.0, pair.ratio, 0.01
    assert_equal "pass", pair.status
  end

  def test_dark_override_resolves_against_light_palette_tokens
    pair = contrast_for(FOUR_COLOR_TOKENS, variant: "dark")
    assert pair.resolved?
    assert_equal "--background", pair.bg
  end

  # A translucent non-page surface composites over the page background, not
  # white; an opaque one or the page itself is unaffected by the backdrop.
  def test_translucent_surface_composites_over_page_background
    {
      "rgba(0,0,0,.5)" => 1.0,
      "#00000080" => 1.0,
      "hsl(0 0% 0% / 50%)" => 1.0,
      "transparent" => 1.0,
      "#ffffff" => 21.0
    }.each do |card, expected|
      pair = contrast_for(":root {\n  --background: #000;\n  --card: #{card};\n  --card-text: #000;\n}\n", "--card-text")
      assert pair.resolved?, card
      assert_in_delta expected, pair.ratio, 0.01, card
    end
  end

  def test_translucent_surface_with_unresolvable_page_background_is_unresolved
    [ "", "  --background: oklch(0.5 0.1 90);\n" ].each do |page|
      pair = contrast_for(":root {\n#{page}  --card: rgba(0,0,0,.5);\n  --card-text: #000;\n}\n", "--card-text")
      refute pair.resolved?, page
      assert_includes pair.reason, "--background"
    end
  end

  def test_contrast_unresolvable_pair_listed_as_unresolved
    pair = contrast_for(":root {\n  --background: #ffffff;\n  --page-text: oklch(0.5 0.1 90);\n}\n")
    refute pair.resolved?
    assert_equal "unresolved", pair.status
    assert_includes pair.reason, "oklch"
  end

  def test_token_file_without_pairs_reports_no_contrast_rows
    with_dir do |dir|
      write(dir, "tokens.css", ":root {\n  --brand: #123456;\n  --background: #ffffff;\n}\n")
      report = ColorCheck.run(dir, strict: true)
      assert_empty report.contrast
      assert_includes ColorCheck.render(report), "none declared"
      assert_equal 0, report.exit_code
    end
  end

  def test_json_output_shape
    with_dir do |dir|
      write(dir, "tokens.css", FOUR_COLOR_TOKENS)
      report = ColorCheck.run(dir)
      parsed = JSON.parse(ColorCheck.to_json_report(report))
      assert_equal %w[tokens token_errors palette contrast exit_code], parsed.keys
      assert_equal File.join(dir, "tokens.css"), parsed["tokens"]
      assert_equal 4, parsed["palette"].size
      assert_equal %w[variant fg bg ratio status reason], parsed["contrast"].first.keys
      assert_equal %w[light dark], parsed["contrast"].map { |c| c["variant"] }
    end
  end

  def test_empty_directory_reports_no_palette_found
    with_dir do |dir|
      report = ColorCheck.run(dir)
      assert_nil report.palette
      assert_equal 0, report.exit_code
      assert_includes report.token_errors.first.message, "no token file found"
      assert_includes ColorCheck.render(report), "no palette found"
    end
  end

  def test_var_cycle_resolves_to_nil_instead_of_crashing
    pair = contrast_for(":root { --background: #fff; --page-text: var(--page-text); --a: var(--b); --b: var(--a); }\n")
    assert_includes pair.reason, "cycle"
  end

  # Every row of a variant shares one Resolver, so a var() chain many pairs
  # reference is analyzed once per variant rather than once per pair. Only
  # resolvers over the token declarations count; a literal check builds one
  # over no declarations.
  def test_contrast_builds_one_resolver_per_variant
    chain = (1...50).map { |i| "--p#{i}: var(--p#{i - 1});" }.join(" ")
    texts = (0...20).map { |i| "--c#{i}-text: var(--p49);" }.join(" ")
    css = ":root { --background: #fff; --p0: #000; #{chain} #{texts} }\n" \
          ".dark { --background: #000; --p0: #fff; }\n"
    with_dir do |dir|
      write(dir, "tokens.css", css)
      built = 0
      real_new = ColorValue::Resolver.method(:new)
      ColorValue::Resolver.define_singleton_method(:new) do |*args|
        built += 1 unless args.first.empty?
        real_new.call(*args)
      end
      begin
        report = ColorCheck.run(dir)
      ensure
        ColorValue::Resolver.singleton_class.remove_method(:new)
      end
      assert_equal 40, report.contrast.count { |c| c.ratio == 21.0 }
      assert_equal 2, built
    end
  end

  # Thresholds compare the unrounded ratio; only the displayed value rounds.
  # Each case sits just under a threshold where round(2) would cross it.
  def test_status_uses_unrounded_ratio_at_each_threshold
    decls = { "--bg" => "#ffffff" }
    [
      [ "rgb(0 153 255)", 3.0, "fail" ],
      [ "rgb(0 138 41)", 4.5, "large-only" ]
    ].each do |fg, shown, status|
      row = ColorCheck.contrast_row(:light, "--fg", "--bg", decls.merge("--fg" => fg))
      assert_equal shown, row.ratio, fg
      assert_equal status, row.status, fg
    end
  end

  EXAMPLE_PALETTE = File.expand_path("../skills/color/reference/example-palette.md", __dir__)

  # The reference example must pass the checker it demonstrates: every pair
  # its prose names is discovered, in both themes, with no token errors.
  def test_reference_example_palette_passes_the_checker
    css = File.read(EXAMPLE_PALETTE)[/```css\n(.*?)```/m, 1]
    refute_nil css, "example-palette.md has no css block"
    with_dir do |dir|
      write(dir, "tokens.css", css)
      report = ColorCheck.run(dir, strict: true)
      assert_empty report.token_errors
      assert_equal 0, report.exit_code
      rows = report.contrast.map { |c| [ c.variant, c.fg, c.bg ] }
      %w[light dark].product(%w[--page-text --accent-ink --title-text]).each do |variant, fg|
        assert_includes rows, [ variant, fg, "--background" ]
      end
      assert(report.contrast.all?(&:resolved?))
    end
  end

  # Every full token file (a css block with a :root rule) in the color
  # skill's docs is one a reader may copy, so each must pass the checker it
  # demonstrates under --strict. Declaration-only fragments are skipped.
  def test_skill_doc_css_blocks_pass_strict
    docs = Dir[File.expand_path("../skills/color/**/*.md", __dir__)]
    blocks = docs.flat_map do |doc|
      File.read(doc).scan(/^```css\n(.*?)^```/m).map { |(css)| [ doc, css ] }
    end
    blocks.select! { |_doc, css| css.include?(":root") }
    refute_empty blocks
    blocks.each do |doc, css|
      with_dir do |dir|
        write(dir, "tokens.css", css)
        report = ColorCheck.run(dir, strict: true)
        assert_empty report.token_errors.map(&:message), doc
        assert_equal 0, report.exit_code, doc
      end
    end
  end
end
