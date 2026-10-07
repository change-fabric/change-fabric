# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/color_check"

class ColorScanTest < Minitest::Test
  def findings(path, text, token_file: nil)
    ColorScan.findings_for(path, text, token_file:)
  end

  def kinds(path, text, token_file: nil)
    findings(path, text, token_file:).map { |f| [ f.line, f.kind ] }.sort
  end

  # --- CSS: strings continued across lines --------------------------------

  def test_escaped_newline_keeps_css_string_blanked_on_later_lines
    [
      %(.x { content: "foo\\\n#abcdef"; }\n),
      %(.x { content: 'foo\\\n#abcdef'; }\n),
      %(.x { content: "a\\\nb\\\nrgb(1 2 3)"; }\n),
      %(.x { color: "foo\\\nred"; }\n)
    ].each do |css|
      assert_equal [], kinds("a.css", css), css.inspect
    end
    assert_equal [ [ 2, "literal" ] ], kinds("a.css", %(.x { content: "a\\\nb" #abcdef; }\n))
  end

  # --- JS: escapes and templates ------------------------------------------

  def test_escaped_quote_does_not_end_string_early
    text = %(const a = "a\\"b";\nconst t = "#123456";\n)
    assert_equal [ [ 2, "literal" ] ], kinds("a.js", text)
  end

  def test_template_literal_interpolation_is_skipped_not_scanned
    text = "const c = `color-${getColor()}`;"
    assert_equal [], findings("a.js", text)
  end

  def test_unterminated_string_ends_at_newline_and_scan_continues
    text = %(const a = 'oops\nconst b = "#123456";\n)
    assert_equal [ [ 2, "literal" ] ], kinds("a.js", text)
  end

  def test_whole_string_hex_and_color_functions_are_findings
    [ "const s = { backgroundColor: '#fff' };", "x('#cafe');", "f(\"rgb(1 2 3)\");", "y = 'hsla(0, 0%, 0%, .5)';" ].each do |js|
      assert_equal [ [ 1, "literal" ] ], kinds("a.js", js), js
    end
  end

  def test_partial_strings_named_words_and_templates_are_not_findings
    [ "const u = '/page#feed';", "const t = 'teal';", "const c = `#abcdef`;", "const g = 'color: #abcdef';",
      "const d = `${ { a: '#123456' } }`;" ].each do |js|
      assert_equal [], findings("a.js", js), js
    end
  end

  def test_regex_literal_and_postfix_division_are_lexed
    assert_equal [ [ 1, "literal" ] ], kinds("a.js", "const r = /'/; const c = '#abcdef';")
    assert_equal [ [ 1, "literal" ] ], kinds("a.js", "x = y++ / 2; const c = '#abcdef'; z = w / 3;")
  end

  def test_regex_after_control_condition_paren_is_not_a_finding
    assert_empty kinds("a.js", "if (x) /'#fff'/.test(v);")
    assert_equal [ [ 1, "literal" ] ], kinds("a.js", "if (x) /'/.test(v); const c = '#abcdef';")
  end

  def test_regex_after_return_is_not_a_finding
    assert_empty kinds("a.js", "function f(v) { return /'#fff'/.test(v); }")
  end

  # --- MDX: code fences and scan scope -------------------------------------

  def test_mdx_fenced_code_block_is_never_scanned
    text = "```js\nconst x = '#123456';\n```\n"
    assert_equal [], findings("a.mdx", text)
  end

  def test_mdx_inline_code_span_is_never_scanned
    text = "Use `#123456` as the brand color.\n"
    assert_equal [], findings("a.mdx", text)
  end

  def test_mdx_prose_quote_is_never_scanned
    text = "She picked '#123456' without hesitation.\n"
    assert_equal [], findings("a.mdx", text)
  end

  def test_mdx_brace_expression_is_scanned
    text = "Some prose.\n\n{ '#123456' }\n"
    assert_equal [ [ 3, "literal" ] ], kinds("a.mdx", text)
  end

  BRACE_IN_STRING_VARIANTS = [
    %({ok ? "}" : "#abc"}),
    %({ok ? '}' : "#abc"}),
    %({ok ? `}` : "#abc"}),
    %({ok ? "\\"}" : "#abc"}),
    %({ok ? "{" : "#abc"})
  ].freeze

  def test_svelte_bound_attr_ignores_braces_inside_strings
    BRACE_IN_STRING_VARIANTS.each do |expr|
      found = findings("a.svelte", "<rect fill=#{expr} />")
      assert_equal 1, found.size, "missed #abc after #{expr}"
    end
  end

  def test_mdx_brace_expression_ignores_braces_inside_strings
    BRACE_IN_STRING_VARIANTS.each do |expr|
      found = findings("a.mdx", "Text #{expr} more\n")
      assert_equal 1, found.size, "missed #abc after #{expr}"
    end
  end

  def test_mdx_class_attribute_is_tailwind_scanned
    text = "<p className=\"bg-red-500\">hi</p>\n"
    assert_equal [ [ 1, "tailwind" ] ], kinds("a.mdx", text)
  end

  def test_mdx_import_line_is_scanned
    text = "import { x } from 'x';\nconst y = '#123456';\n"
    # only the import line is in scope; the following plain statement is
    # ordinary prose-adjacent code, not an import/export line or brace
    # expression, so it stays out of scope.
    assert_equal [], findings("a.mdx", text)
  end

  # --- Markup attributes ----------------------------------------------------

  def test_markup_fill_short_hex_counts_as_position_a
    text = '<svg><path fill="#abc"/></svg>'
    assert_equal [ [ 1, "literal" ] ], kinds("a.html", text)
  end

  def test_markup_style_value_is_word_scanned
    text = '<div style="color:red;background:Navy"></div>'
    assert_equal [ [ 1, "literal" ], [ 1, "literal" ] ], kinds("a.html", text)
  end

  def test_markup_class_attribute_is_tailwind_only
    text = '<div class="bg-slate-100 foo"></div>'
    assert_equal [ [ 1, "tailwind" ] ], kinds("a.html", text)
  end

  def test_markup_class_arbitrary_color_is_one_finding_per_utility
    text = '<div class="p-2 bg-[#abcdef] hover:text-white"></div>'
    assert_equal %w[bg-[#abcdef] hover:text-white], findings("a.html", text).map(&:text)
  end

  def test_apply_prelude_is_tokenized_per_utility
    text = ".a { @apply p-2 bg-red-500 border-[color:#fff]; }"
    assert_equal %w[bg-red-500 border-[color:#fff]], findings("a.css", text).map(&:text)
  end

  def test_markup_href_attribute_is_never_scanned
    text = '<a href="#123456">x</a>'
    assert_equal [], findings("a.html", text)
  end

  # --- <style> block line offsets -------------------------------------------

  def test_style_block_reports_true_source_line
    text = "<template><div/></template>\n<div/>\n<style>\n.x { color: #abcdef; }\n</style>\n"
    f = findings("a.vue", text)
    assert_equal [ [ 4, "literal" ] ], f.map { |x| [ x.line, x.kind ] }
  end

  def test_style_block_lang_scss_uses_scss_comments
    text = "<style lang=\"scss\">\n// --bg: #000000;\n.x { color: #abcdef; }\n</style>\n"
    f = findings("a.vue", text)
    assert_equal [ [ 3, "literal" ] ], f.map { |x| [ x.line, x.kind ] }
  end

  def test_style_block_token_declarations_are_exempt_in_token_file
    text = "<style>\n:root { --bg: red; }\n.x { color: #abcdef; }\n</style>\n"
    f = findings("a.vue", text, token_file: "a.vue")
    assert_equal [ [ 3, "literal" ] ], f.map { |x| [ x.line, x.kind ] }
  end

  # --- Sass indented syntax --------------------------------------------------

  def test_sass_declaration_and_comment_handling
    text = "// --bg: #000000\n.x\n  color: red\n"
    assert_equal [ [ 3, "literal" ] ], kinds("a.sass", text)
  end

  # --- Bound attributes and JSX use the same lexer ---------------------------

  def scan_classes(path, text)
    ColorScan.classify_all(path, text).map(&:last)
  end

  def test_bound_attribute_strings_use_the_script_lexer
    { "a.vue" => [ %q(<path :fill="'#abc'"/>), %q(<path v-bind:fill="'#abc'"/>), %q(<p :data-x="'#abc'"/>) ],
      "a.svelte" => [ "<path fill={'#abc'}/>" ],
      "a.tsx" => [ "x = <path fill={'#abc'}/>;", "x = <path fill={f(ok ? x : '#abc')}/>;" ] }.each do |path, texts|
      texts.each { |text| assert_equal [ :finding ], scan_classes(path, text), "#{path}: #{text}" }
    end
    assert_equal [ :finding, :finding ], scan_classes("a.vue", %q(<path :fill="ok ? '#abc' : '#def'"/>))
  end

  def test_script_scan_never_reports_unresolved
    findings, unresolved = ColorScan.scan("a.js", "const c = dark ? '#fff' : base;\n", token_file: nil)
    assert_equal [ "#fff" ], findings.map(&:text)
    assert_equal [], unresolved
  end

  def test_jsx_class_name_is_not_tailwind_scanned
    assert_equal [], findings("a.jsx", '<p className="bg-red-500" />')
  end

  def named_classes(css)
    ColorScan.classify_all("a.css", css).map(&:last)
  end

  def test_named_color_in_color_shorthands_is_a_finding
    [ "a{text-decoration:underline red}", "a{column-rule:1px solid red}", "a{scrollbar-color:red blue}",
      "a{-webkit-text-stroke:1px red}", "a{border-inline-start:1px solid red}" ].each do |css|
      refute_empty named_classes(css), css
      assert(named_classes(css).all?(:finding), css)
    end
  end

  def test_named_color_in_name_valued_property_is_exempt
    [ "a{animation-name:red}", "a{font-family:red}", "a{grid-area:red}" ].each do |css|
      assert_equal [], named_classes(css), css
    end
  end

  def test_named_color_in_unclassified_property_is_unresolved
    findings, unresolved = ColorScan.scan("a.css", "a{foo-bar:red}", token_file: nil)
    assert_equal [], findings
    assert_equal [ "named color in unclassified property foo-bar" ], unresolved.map(&:reason)
  end

  def test_named_color_class_table
    { "color" => :finding, "border-top-color" => :finding, "--x" => :finding, "font" => :exempt,
      "border-radius" => :unresolved, "foo-bar" => :unresolved }.each do |prop, want|
      assert_equal want, ColorScan.named_color_class(prop), prop
    end
  end
end
