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

  def test_selector_list_splits_only_at_top_level_for_blocks
    sheet = ColorCss.parse(":is(a, b), c { color: red; }")
    assert_equal ":is(a, b), c", sheet.blocks.first.prelude
  end

  def test_slash_slash_is_literal_in_plain_css
    sheet = ColorCss.parse(":root { --ratio: 16px//comment-like/1.5; }")
    assert_equal "16px//comment-like/1.5", decl(sheet, "--ratio").value
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

  def test_block_id_distinct_per_block_and_shared_within_block
    sheet = ColorCss.parse(":root { --a: #111; --b: #222; } .x { --c: #333; }")
    a = decl(sheet, "--a")
    b = decl(sheet, "--b")
    c = decl(sheet, "--c")
    refute_nil a.block_id
    assert_equal a.block_id, b.block_id
    refute_equal a.block_id, c.block_id
  end

  def test_top_level_declaration_has_nil_block_id
    sheet = ColorCss.parse("$brand: #123;")
    assert_nil decl(sheet, "$brand").block_id
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

  def test_nonempty_segment_matching_no_grammar_records_error
    [
      ":root { --background: #fff; --page-text #000; }",
      ":root { --a: #fff; color red }",
      ":root { 123; }",
      "garbage;",
      ":root { --a: #fff }\n:root{ : #000; }"
    ].each do |css|
      sheet = ColorCss.parse(css)
      assert(sheet.errors.any? { |e| e.include?("unparsed segment") }, css)
    end
    assert_empty ColorCss.parse(":root { --a: #fff; @apply x; }").errors
  end
end
