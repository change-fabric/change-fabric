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

  def test_template_literal_interpolation_nested_string_is_scanned
    text = 'const d = `${ { a: "#123456" } }`;'
    # a "${...}" interpolation is ordinary JS, not template text: the
    # six-digit hex string inside it is a plain JS string and counts like
    # any other, and the walk still terminates correctly (no raise, no hang).
    assert_equal [ [ 1, "literal" ] ], kinds("a.js", text)
  end

  def test_unterminated_string_ends_at_newline_and_scan_continues
    text = %(const a = 'oops\nconst b = "#123456";\n)
    assert_equal [ [ 2, "literal" ] ], kinds("a.js", text)
  end

  def test_color_bearing_key_allows_short_hex
    text = "const s = { backgroundColor: '#fff' };"
    assert_equal [ [ 1, "literal" ] ], kinds("a.jsx", text)
  end

  def test_non_color_key_rejects_short_hex_but_allows_named_color
    text = %(const a = '#abc';\nconst b = 'teal';\n)
    assert_equal [ [ 2, "literal" ] ], kinds("a.js", text)
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
end
