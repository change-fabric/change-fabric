# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/color_css"

class ColorCssTest < Minitest::Test
  def decl(sheet, name)
    sheet.decls.find { |d| d.name == name }
  end

  def test_basic_declaration_selectors_and_value
    sheet = ColorCss.parse(":root { --bg: #fff; }")
    d = decl(sheet, "--bg")
    refute_nil d
    assert_equal "#fff", d.value
    assert_equal [ ":root" ], d.selectors
    assert_empty d.at_rules
    refute_nil d.block_id
    refute d.important
    assert_empty sheet.errors
  end

  def test_comment_replacement_keeps_line_numbers
    css = ":root {\n  --bg: #fff; /* a\n   multi\n   line */ --text: #000;\n}\n"
    sheet = ColorCss.parse(css)
    bg = decl(sheet, "--bg")
    text = decl(sheet, "--text")
    assert_equal 2, bg.line
    # the comment spans lines 2-4, so --text starts on line 4
    assert_equal 4, text.line
    assert_equal 4, text.value_line
  end

  def test_unterminated_comment_runs_to_eof_and_records_error
    sheet = ColorCss.parse(":root { --bg: #fff; /* never closed")
    assert_nil decl(sheet, "--never")
    assert(sheet.errors.any? { |e| e.include?("unterminated comment") })
    # the declaration before the comment is still kept
    refute_nil decl(sheet, "--bg")
  end

  def test_brace_inside_comment_does_not_close_block
    sheet = ColorCss.parse(":root { --bg: #fff; /* } */ --text: #777; }")
    assert_equal "#777", decl(sheet, "--text").value
    assert_equal [ ":root" ], decl(sheet, "--text").selectors
    assert_empty sheet.errors
  end

  def test_semicolon_inside_comment_does_not_end_declaration
    sheet = ColorCss.parse(":root { --bg: #fff /* ; not a terminator */ ; --text: #000; }")
    assert_equal "#fff", decl(sheet, "--bg").value
  end

  def test_brace_and_semicolon_inside_string_are_data
    sheet = ColorCss.parse(%(.x { content: "a}b;c"; color: red; }))
    content = decl(sheet, "content")
    assert_equal '"a}b;c"', content.value
    assert_equal "red", decl(sheet, "color").value
  end

  def test_brace_and_semicolon_inside_parens_are_data
    sheet = ColorCss.parse(":root { --x: foo(1; 2}3); --y: #000; }")
    assert_equal "foo(1; 2}3)", decl(sheet, "--x").value
    assert_equal "#000", decl(sheet, "--y").value
  end

  def test_string_with_backslash_escaped_quote_is_not_a_terminator
    sheet = ColorCss.parse(%(.x { content: "a\\"b"; color: red; }))
    assert_equal '"a\\"b"', decl(sheet, "content").value
    assert_equal "red", decl(sheet, "color").value
  end

  def test_last_declaration_without_semicolon_is_kept
    sheet = ColorCss.parse(":root { --a: #123; --last: #555 }")
    assert_equal "#555", decl(sheet, "--last").value
    assert_empty sheet.errors
  end

  def test_last_declaration_without_semicolon_at_top_level_eof
    sheet = ColorCss.parse("$brand: #123")
    assert_equal "#123", decl(sheet, "$brand").value
  end

  def test_important_is_stripped_and_flagged
    sheet = ColorCss.parse(":root { --bg: #fff !important; }")
    d = decl(sheet, "--bg")
    assert_equal "#fff", d.value
    assert d.important
  end

  def test_important_case_insensitive_and_spaced
    sheet = ColorCss.parse(":root { --bg: #fff ! ImPorTant; }")
    d = decl(sheet, "--bg")
    assert_equal "#fff", d.value
    assert d.important
  end

  def test_selector_list_splits_only_at_top_level
    sheet = ColorCss.parse(":is(a, b), c { color: red; }")
    assert_equal [ ":is(a, b)", "c" ], decl(sheet, "color").selectors
  end

  def test_selector_list_comma_inside_string_not_split
    sheet = ColorCss.parse(%([data-x="a,b"], c { color: red; }))
    assert_equal [ %([data-x="a,b"]), "c" ], decl(sheet, "color").selectors
  end

  def test_at_rule_stack_for_nested_media_and_layer
    css = "@layer base { @media (prefers-color-scheme: dark) { :root { --bg: #000; } } }"
    sheet = ColorCss.parse(css)
    d = decl(sheet, "--bg")
    assert_equal [ "@layer base", "@media (prefers-color-scheme: dark)" ], d.at_rules
    assert_equal [ ":root" ], d.selectors
  end

  def test_blocks_record_parent_line_and_comment_free_prelude
    sheet = ColorCss.parse("@layer base {\n  :root/* c */.dark { --x: #123; }\n  :root .dark {}\n}")
    layer, compound, descendant = sheet.blocks
    assert_nil layer.parent
    assert_equal "@layer base", layer.prelude
    assert_equal [ layer.id, ":root.dark", 2 ], [ compound.parent, compound.prelude, compound.line ]
    assert_equal ":root .dark", descendant.prelude
    assert_equal compound.id, decl(sheet, "--x").block_id
  end

  def test_scss_line_comment_only_in_scss_dialect
    sheet = ColorCss.parse(":root {\n  --bg: #fff; // --text: #333;\n  --text: #000;\n}\n", dialect: :scss)
    assert_equal "#000", decl(sheet, "--text").value
    assert_equal "#fff", decl(sheet, "--bg").value
  end

  def test_slash_slash_is_literal_in_plain_css_dialect
    sheet = ColorCss.parse(":root { --ratio: 16px//comment-like/1.5; }", dialect: :css)
    assert_equal "16px//comment-like/1.5", decl(sheet, "--ratio").value
  end

  def test_scss_line_comment_never_inside_url
    sheet = ColorCss.parse(
      ".x { background: url(http://example.com/a.png); }",
      dialect: :scss
    )
    assert_equal "url(http://example.com/a.png)", decl(sheet, "background").value
  end

  def test_scan_value_masks_a_quoted_url_body_holding_a_close_paren
    d = decl(ColorCss.parse('a{background:url("a)#abc")}'), "background")
    assert_equal 'url("a)#abc")', d.value
    assert_equal "url(        )", d.scan_value
    assert_equal d.value.length, d.scan_value.length
  end

  def test_scan_value_masks_a_single_quoted_url_body
    d = decl(ColorCss.parse("a{background:url('x#fff') #000}"), "background")
    assert_equal "url(       ) #000", d.scan_value
    assert_equal d.value.length, d.scan_value.length
  end

  def test_scan_value_masks_strings_and_keeps_newlines
    d = decl(ColorCss.parse(%(a{content:"#fff";--x:"a\\\n#abc" red !important}
)), "--x")
    assert_equal d.value.length, d.scan_value.length
    assert_equal d.value.count("\n"), d.scan_value.count("\n")
    refute_includes d.scan_value, "#abc"
    assert d.scan_value.end_with?(" red")
  end

  def test_scan_value_of_a_bare_value
    assert_equal "url(    ) #000 {} ;", ColorCss.scan_value("url(#fff) #000 {} ;")
    assert_equal "     #000", ColorCss.scan_value("'#a' #000")
  end

  def test_scss_line_comment_never_inside_string
    sheet = ColorCss.parse(%(.x { content: "a // not a comment"; color: red; }\n), dialect: :scss)
    assert_equal '"a // not a comment"', decl(sheet, "content").value
    assert_equal "red", decl(sheet, "color").value
  end

  def test_unmatched_closing_brace_recorded_without_raising
    sheet = ColorCss.parse(":root { --bg: #fff; } }")
    assert_equal "#fff", decl(sheet, "--bg").value
    assert(sheet.errors.any? { |e| e.include?("unmatched }") })
  end

  def test_end_of_input_with_open_frames_flushes_pending_decl_and_errors
    sheet = ColorCss.parse(":root { --bg: #fff")
    assert_equal "#fff", decl(sheet, "--bg").value
    assert(sheet.errors.any? { |e| e.include?("open block") })
  end

  def test_line_offset_is_added_to_every_line
    sheet = ColorCss.parse(":root {\n  --bg: #fff;\n}\n", line_offset: 10)
    d = decl(sheet, "--bg")
    assert_equal 12, d.line
    assert_equal 12, d.value_line
  end

  def test_block_id_distinct_per_block_and_shared_within_block
    sheet = ColorCss.parse(":root { --a: #111; --b: #222; } .x { --c: #333; }")
    a = decl(sheet, "--a")
    b = decl(sheet, "--b")
    c = decl(sheet, "--c")
    refute_nil a.block_id
    assert_equal a.block_id, b.block_id
    refute_equal a.block_id, c.block_id
  end

  def test_top_level_declaration_has_no_selectors_and_nil_block_id
    sheet = ColorCss.parse("$brand: #123;")
    d = decl(sheet, "$brand")
    assert_empty d.selectors
    assert_nil d.block_id
  end

  def test_blockless_at_rule_statement
    sheet = ColorCss.parse(".x { @apply bg-red-500; }")
    stmt = sheet.at_rule_stmts.first
    refute_nil stmt
    assert_equal "@apply", stmt.name
    assert_equal "bg-red-500", stmt.prelude
  end

  def test_blockless_at_rule_without_semicolon_before_closing_brace
    sheet = ColorCss.parse(".a { @apply text-red-500 }")
    stmt = sheet.at_rule_stmts.first
    refute_nil stmt
    assert_equal "@apply", stmt.name
    assert_equal "text-red-500", stmt.prelude
  end

  def test_blockless_at_rule_without_semicolon_at_eof
    sheet = ColorCss.parse("@apply text-red-500")
    stmt = sheet.at_rule_stmts.first
    refute_nil stmt
    assert_equal "@apply", stmt.name
    assert_equal "text-red-500", stmt.prelude
  end

  def test_blockless_at_rule_records_enclosing_at_rules
    sheet = ColorCss.parse("@media (min-width: 40em) { @import \"foo.css\"; }")
    stmt = sheet.at_rule_stmts.first
    assert_equal "@import", stmt.name
    assert_equal %("foo.css"), stmt.prelude
    assert_equal [ "@media (min-width: 40em)" ], stmt.at_rules
  end

  def test_unterminated_string_raw_newline_records_error_and_resumes
    sheet = ColorCss.parse(%(.x { content: "unterminated\n; color: red; }))
    assert(sheet.errors.any? { |e| e.include?("unterminated string") })
    assert_equal "red", decl(sheet, "color").value
  end

  def test_split_top_level_respects_parens
    assert_equal [ ":is(a, b)", " c" ], ColorCss.split_top_level(":is(a, b), c")
  end

  def test_split_top_level_respects_strings
    assert_equal [ %([data-x="a,b"]), " c" ], ColorCss.split_top_level(%([data-x="a,b"], c))
  end

  def test_split_top_level_default_sep_is_comma
    assert_equal [ "a", " b", " c" ], ColorCss.split_top_level("a, b, c")
  end

  def test_split_top_level_custom_sep
    assert_equal [ "a", "b" ], ColorCss.split_top_level("a:b", ":")
  end
end
