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

  def test_one_leading_bom_is_dropped
    sheet = ColorCss.parse("﻿:root { --bg: #fff; }")
    assert_equal ":root", sheet.blocks.first.prelude.strip
    assert_equal 1, decl(sheet, "--bg").line
    doubled = ColorCss.parse("﻿﻿:root { --bg: #fff; }")
    assert_equal "﻿:root", doubled.blocks.first.prelude.strip
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

  def test_important_is_found_by_its_decoded_token
    [ "#fff !\\69mportant", "#fff !IMPORTANT", "#fff !\\49 MPORTANT", "#fff!important",
      "#fff ! /* note */ important", "#fff !/**/\\69 mportant" ].each do |value|
      d = decl(ColorCss.parse(":root { --bg: #{value}; }"), "--bg")
      assert_equal "#fff", d.value, value
      assert d.important, value
    end
  end

  def test_priority_lookalikes_stay_in_the_value
    [ "\"a !important\"", "'!important'", "a \\!important", "f(a !important)",
      "#fff !importantx", "#fff !-important", "#fff important", "#fff !important x" ].each do |value|
      d = decl(ColorCss.parse(":root { --bg: #{value}; }"), "--bg")
      refute d.important, value
      assert_equal value, d.value, value
    end
    assert_equal [ "f(!important", false ], ColorCss.split_priority("f(!important")
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

  # CSS Syntax 3: a comment is a token boundary, so deleting one must never
  # merge the text on either side into one token.
  def test_comment_that_would_merge_tokens_marks_the_prelude_glued
    glued = [ "@me/**/dia (prefers-color-scheme: dark)", "@/**/media x", ":ro/**/ot", ".da/**/rk",
              "[data-theme=da/**/rk]", "@media (prefers-color/**/-scheme: dark)", "#a/**/b", ".a\\61/**/b",
              "a:nth-child(1/**/.5)", "a:nth-child(1/**/%)", "a:nth-child(+/**/1)", "a //**/* b" ]
    glued.each do |prelude|
      block = ColorCss.parse("#{prelude} { }").blocks.first
      assert block.glued, prelude
    end
    apart = [ ":root/**/.dark", ":root/**/[data-theme=dark]", "@media/**/(prefers-color-scheme: dark)",
              ":root /**/ .dark", "/**/:root", ":root/**/" ]
    apart.each do |prelude|
      block = ColorCss.parse("#{prelude} { }").blocks.first
      refute block.glued, prelude
    end
    assert_equal ":root.dark", ColorCss.parse(":root/**/.dark { }").blocks.first.prelude
  end

  def test_glued_flag_resets_for_each_prelude
    blocks = ColorCss.parse(":ro/**/ot { } :root { }").blocks
    assert_equal [ true, false ], blocks.map(&:glued)
  end

  def test_leading_byte_order_mark_is_dropped
    sheet = ColorCss.parse("﻿:root { --bg: #fff; }")
    assert_equal ":root", sheet.blocks.first.prelude
    assert_equal "#fff", decl(sheet, "--bg").value
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

  def test_every_css_newline_ends_a_quoted_value
    [ "\n", "\r", "\r\n", "\f" ].each do |nl|
      sheet = ColorCss.parse(%(.x { content: "a#{nl}; } :root { --bg: #fff; }))
      assert(sheet.errors.any? { |e| e.include?("unterminated string (line 1)") }, nl.inspect)
      assert_equal "#fff", decl(sheet, "--bg")&.value, nl.inspect
      assert_equal 2, decl(sheet, "--bg").line, nl.inspect
      assert_equal [ ".x", ":root" ], sheet.blocks.map(&:prelude), nl.inspect
      assert_empty sheet.errors.grep(/open block/), nl.inspect
    end
  end

  def test_every_css_newline_counts_as_one_line
    [ "\n", "\r", "\r\n", "\f" ].each do |nl|
      sheet = ColorCss.parse(":root {#{nl}  --bg: #fff;#{nl}/* a#{nl}b */ --text: #000;#{nl}}")
      assert_equal 2, decl(sheet, "--bg").line, nl.inspect
      assert_equal 4, decl(sheet, "--text").line, nl.inspect
      assert_empty sheet.errors, nl.inspect
    end
  end

  def test_preprocess_follows_css_syntax
    assert_equal "a\nb\nc\n\nd\ne", ColorCss.preprocess("a\r\nb\rc\n\rd\fe")
    assert_equal "a\uFFFDb", ColorCss.preprocess("a\0b")
    surrogate = "a\xED\xA0\x80b".dup.force_encoding(Encoding::UTF_8)
    assert_equal "a\uFFFD\uFFFD\uFFFDb", ColorCss.preprocess(surrogate)
    assert_equal "#\uFFFD", decl(ColorCss.parse(":root { --bg: #\0; }"), "--bg").value
  end

  # CSS Syntax 3 simple blocks: ; } and ! inside (), [] or a custom
  # property's value-level {} are value text, never a terminator.
  def test_semicolon_and_brace_inside_simple_blocks_are_data
    {
      "--syntax: [a;b]" => [ "--syntax", "[a;b]" ],
      "--map: {a:b}" => [ "--map", "{a:b}" ],
      "--x: [ {;} ]" => [ "--x", "[ {;} ]" ],
      "--x: {a;b}" => [ "--x", "{a;b}" ],
      "--x: ([;)]; x)" => [ "--x", "([;)]; x)" ],
      "--x: [ } ]" => [ "--x", "[ } ]" ],
      "--x: { ] ; }" => [ "--x", "{ ] ; }" ],
      "--\\2d x: {a;b}" => [ "---x", "{a;b}" ],
      "--x :\n{\n a;\n}" => [ "--x", "{\n a;\n}" ]
    }.each do |decl_src, (name, value)|
      css = ":root {\n  #{decl_src};\n  --y: #000;\n}\n"
      sheet = ColorCss.parse(css)
      assert_empty sheet.errors, css
      assert_equal value, decl(sheet, name)&.value, css
      assert_equal 2, decl(sheet, name).line, css
      assert_equal 3 + decl_src.count("\n"), decl(sheet, "--y").line, css
      assert_equal [ ":root" ], sheet.blocks.map(&:prelude), css
    end
  end

  def test_braces_outside_a_custom_property_value_still_open_rules
    sheet = ColorCss.parse("a { color: red; &:hover { color: blue } }\n--x: {b:c}")
    assert_equal [ "a", "&:hover", "--x:" ], sheet.blocks.map(&:prelude)
    assert_equal [ "red", "blue", "c" ], sheet.decls.map(&:value)
    assert_empty sheet.errors
  end

  def test_mismatched_block_closers_do_not_raise
    sheet = ColorCss.parse("a { color: red ] ; --c: x } }")
    assert_equal [ "red ]", "x" ], sheet.decls.map(&:value)
    assert_equal [ "unmatched } (line 1)" ], sheet.errors
    open = ColorCss.parse("a { --x: [ ;\n}\nb { --c: red }")
    assert_equal [ "unexpected end of input with 1 open block(s)" ], open.errors
  end

  def test_priority_inside_a_simple_block_stays_in_the_value
    sheet = ColorCss.parse(":root { --x: [a] !important; --y: [!important]; --z: {!important} }")
    assert_equal [ [ "[a]", true ], [ "[!important]", false ], [ "{!important}", false ] ],
                 sheet.decls.map { |d| [ d.value, d.important ] }
  end

  def test_split_top_level_respects_every_simple_block
    assert_equal [ "[a, b]", " {c, d}", " (e, [)], f)", " g" ], ColorCss.split_top_level("[a, b], {c, d}, (e, [)], f), g")
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

  def names(text)
    ColorCss.function_tokens(text).map(&:name)
  end

  # Only real function tokens count: the full ident run before "(" is the
  # name (ASCII lowercased), and strings, comments, url() contents, hashes,
  # at-keywords and numbers never yield one.
  def test_function_tokens_follow_css_syntax
    {
      "var(--x)" => %w[var],
      "VAR(--x) Color-Mix(in srgb, red, blue)" => %w[var color-mix],
      "a(b(c()))" => %w[a b c],
      "\u00e9var(--x) var\u00e9(--x) \u00c9VAR(--x)" => [ "\u00e9var", "var\u00e9", "\u00c9var" ],
      "xvar(--x) my-var(--x) _var(--x) -var(--x) --var(--x)" => %w[xvar my-var _var -var --var],
      "2var(--x) -2var(--x) 1e5var(--x) .5var(--x)" => [],
      "#var(--x) @var(--x)" => [],
      "\\var(--x) v\\61 r(--x) v\\61r(--x) \\56 AR(--x) \\000076ar(--x)" => %w[var var var var var],
      "\\75 rl(\\29 var(--x)) u\\72 l(a)" => %w[url url],
      %("var(--x)" 'var(--x)' "a\\" var(--x)") => [],
      "/* var(--x) */ rgb(0 0 0)" => %w[rgb],
      "url(var(--x)) URL(\"var(--y)\")" => %w[url url],
      "var (--x) - (1)" => []
    }.each { |text, expected| assert_equal expected, names(text), text }
  end

  def test_function_tokens_report_positions
    tok = ColorCss.function_tokens("a VAR(--x)").first
    assert_equal [ "var", 2, 5 ], [ tok.name, tok.start, tok.open ]
  end

  # Every identifier CSS reads ASCII case-insensitively folds; custom-property
  # names, #hash names, strings, url() contents and non-ASCII stay exact.
  def test_downcase_keywords_folds_only_case_insensitive_identifiers
    {
      %(VAR(--Ink, URL(/A.png) "VAR(x)") Color-Mix(in SRGB, RED, Blue)) =>
        %(var(--Ink, url(/A.png) "VAR(x)") color-mix(in srgb, red, blue)),
      "currentColor CURRENTCOLOR INHERIT TRANSPARENT" => "currentcolor currentcolor inherit transparent",
      "10PX 1E3 #ABC #Foo" => "10px 1e3 #ABC #Foo",
      "var(-\\2d Ink) \\56 AR(--x) \\31 X(--x)" => "var(-\\2d Ink) \\56 ar(--x) \\31 x(--x)",
      "url( /A.png ) URL('/A.png') /* KEEP */" => "url( /A.png ) url('/A.png') /* KEEP */",
      "\u00c9VAR(--x) \u00c9" => "\u00c9var(--x) \u00c9"
    }.each { |text, expected| assert_equal expected, ColorCss.downcase_keywords(text), text }
  end

  # One identifier code point set everywhere: ASCII letters, digits, _ and -,
  # anything >= U+0080, never Ruby's ASCII-only \w.
  def test_ident_code_points_include_non_ascii
    [ "a", "Z", "0", "_", "-", "\u00e9", "\u4e2d", "\u{1F600}" ].each { |c| assert_match ColorCss::IDENT_CP, c }
    [ " ", ".", "(", "\\", "@", "#" ].each { |c| refute_match ColorCss::IDENT_CP, c }
    [ "caf\u00e9", "_x", "-x", "--", "--x", "\u00e9t\u00e9", "\\31 x" ].each do |ident|
      assert_match(/\A#{ColorCss::IDENT_SRC}\z/, ident)
    end
    [ "1x", "-1x", "" ].each { |ident| refute_match(/\A#{ColorCss::IDENT_SRC}\z/, ident) }
  end

  # A non-ASCII property or at-rule name is a declaration or statement, not
  # an unparsed segment.
  def test_non_ascii_declaration_and_statement_names_parse
    sheet = ColorCss.parse(":root { caf\u00e9: red; _x: blue; }\n@tailw\u00efnd base;")
    assert_empty sheet.errors
    assert_equal [ "caf\u00e9", "_x" ], sheet.decls.map(&:name)
    assert_equal [ "@tailw\u00efnd" ], sheet.at_rule_stmts.map(&:name)
  end

  # Every identifier slot reads non-ASCII ident code points, never \w alone.
  def test_non_ascii_identifiers_in_every_name_slot
    sheet = ColorCss.parse(".x { --caf\u00e9: red; $caf\u00e9: blue; c\u00f6lor: green; @caf\u00e9-rule a; }")
    assert_empty sheet.errors
    assert_equal [ "--caf\u00e9", "$caf\u00e9", "c\u00f6lor" ], sheet.decls.map(&:name)
    assert_equal [ "@caf\u00e9-rule" ], sheet.at_rule_stmts.map(&:name)
    assert_equal "@layer caf\u00e9", ColorCss.canonical_idents("@layer caf\\e9")
  end

  # CSS Syntax 3 4.3.7: 1-6 hex digits plus one optional whitespace; zero,
  # a surrogate or anything past U+10FFFF is U+FFFD; any other code point
  # but a newline is itself; a backslash before a newline is no escape.
  def test_decode_escape_follows_css_syntax
    {
      "\\61" => [ "a", 3 ], "\\61 x" => [ "a", 4 ], "\\61\r\nx" => [ "a", 5 ], "\\61\tx" => [ "a", 4 ],
      "\\61  x" => [ "a", 4 ], "\\0000611" => [ "a", 7 ], "\\0" => [ "\uFFFD", 2 ],
      "\\d800" => [ "\uFFFD", 5 ], "\\110000" => [ "\uFFFD", 7 ], "\\10ffff" => [ [ 0x10FFFF ].pack("U"), 7 ],
      "\\;" => [ ";", 2 ], "\\g" => [ "g", 2 ], "\\ " => [ " ", 2 ], "\\" => [ "\uFFFD", 1 ]
    }.each { |text, expected| assert_equal expected, ColorCss.decode_escape(text, 0), text.inspect }
    [ "\\\n", "\\\r\n", "\\\f", "a" ].each { |text| assert_nil ColorCss.decode_escape(text, 0), text.inspect }
  end

  # An escaped delimiter is value text to the declaration scanner: it never
  # ends a declaration, opens or closes a block, or moves paren depth.
  def test_escaped_delimiters_are_value_text
    sheet = ColorCss.parse(":root { --a: foo\\;bar; --b: x\\{y; --c: x\\}y; --d: f\\(x; --e: \\\"q; --f: #fff; }")
    assert_empty sheet.errors
    assert_equal %w[--a --b --c --d --e --f], sheet.decls.map(&:name)
    assert_equal [ "foo\\;bar", "x\\{y", "x\\}y", "f\\(x", "\\\"q", "#fff" ], sheet.decls.map(&:value)
    assert_equal 1, sheet.blocks.size
    assert_equal [ 1 ], sheet.decls.map(&:block_id).uniq

    sheet = ColorCss.parse(":root { --a: f(\\)); --b: #000; }")
    assert_empty sheet.errors
    assert_equal [ "f(\\))", "#000" ], sheet.decls.map(&:value)

    # An escaped ; inside a name keeps the segment whole: one declaration of
    # the property CSS names --foo;bar, never a stray "bar: red" declaration.
    sheet = ColorCss.parse(":root { --foo\\;bar: red; }")
    assert_equal [ "--foo;bar" ], sheet.decls.map(&:name)
    assert_empty sheet.errors
  end

  def test_split_top_level_skips_escapes
    assert_equal [ "a\\,b", " c" ], ColorCss.split_top_level("a\\,b, c")
    assert_equal [ "f(\\), c)" ], ColorCss.split_top_level("f(\\), c)")
    assert_equal [ "f(\\29 , c)" ], ColorCss.split_top_level("f(\\29 , c)")
    assert_equal [ "\\(a", " b" ], ColorCss.split_top_level("\\(a, b")
    assert_equal [ "\\\"a", " b" ], ColorCss.split_top_level("\\\"a, b")
    assert_equal [ "\"a\\\", b\"", " c" ], ColorCss.split_top_level("\"a\\\", b\", c")
  end

  # A declared custom-property name is stored decoded, so --\61 declares --a
  # and every lookup by name sees the property CSS sees.
  def test_escaped_declared_custom_property_names_are_decoded
    {
      "--\\61: red;" => "--a",
      "--\\000061 : red;" => "--a",
      "--b\\2d c: red;" => "--b-c",
      "--caf\\e9: red;" => "--caf\u00e9",
      "--caf\u00e9: red;" => "--caf\u00e9",
      "--a\\:b: red;" => "--a:b",
      "\\2d \\2d x: red;" => "--x",
      "\\2d -x: red;" => "--x",
      "-\\2d x: red;" => "--x",
      "\\-\\-x: red;" => "--x"
    }.each do |css, name|
      sheet = ColorCss.parse(":root { #{css} }")
      assert_empty sheet.errors, css
      assert_equal [ name ], sheet.decls.map(&:name), css
      assert_equal "red", sheet.decls.first.value, css
    end
  end

  # An escaped name that does not decode to a custom property is no
  # declaration the token grammar accepts; nor is a bare "--".
  def test_escaped_names_that_are_not_custom_properties_are_unparsed
    [ "\\63 olor: red;", "-\\2d : red;", "\\2d x: red;" ].each do |css|
      sheet = ColorCss.parse(":root { #{css} }")
      assert_empty sheet.decls, css
      refute_empty sheet.errors, css
    end
  end

  # The one custom-property test: a complete identifier token, decoded, then
  # checked for "--". Every escaped spelling of the two hyphens counts; a
  # raw "--" followed by more than one token, or a lone "--", does not.
  def test_custom_property_ref_decodes_before_checking_hyphens
    {
      "--a" => "--a", "\\2d \\2d a" => "--a", "\\2d -a" => "--a", "-\\2d a" => "--a",
      "\\-\\-a" => "--a", "--\\61" => "--a", "\\00002d\\00002d a" => "--a",
      "--a b" => nil, "--" => nil, "-\\2d " => nil, "-a" => nil, "a" => nil, "" => nil, "\\2d a" => nil
    }.each do |run, name|
      name ? assert_equal(name, ColorCss.custom_property_ref(run), run) : assert_nil(ColorCss.custom_property_ref(run), run)
    end
    assert_equal "--a", ColorCss.leading_custom_property_name("  \\2d \\2d a, x")
    assert_nil ColorCss.leading_custom_property_name("\\2d a")
  end

  # Escaped identifiers get one canonical spelling; case, strings, numbers
  # and unquoted url() contents are left as written.
  def test_canonical_idents
    {
      "var(--\\69 nk)" => "var(--ink)",
      "var(\\2d \\2d ink)" => "var(--ink)",
      "r\\67 b(0 0 0)" => "rgb(0 0 0)",
      "var(--\\49 nk)" => "var(--Ink)",
      "\\31 a" => "\\31 a",
      "\\31\\61" => "\\31 a",
      "a\\ b" => "a\\20 b",
      "\"\\69\" x" => "\"\\69\" x",
      "url(\\41)" => "url(\\41)",
      "#\\66 ff" => "#fff"
    }.each { |text, canon| assert_equal canon, ColorCss.canonical_idents(text), text }
  end
end
