# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/color_js"

class ColorJsTest < Minitest::Test
  def kinds(text, kind)
    ColorJs.tokens(text).select { |t| t.kind == kind }.map(&:text)
  end

  def test_regex_after_control_condition_paren
    src = "if (x) /'#fff'/.test(v)"
    assert_equal [ "/'#fff'/" ], kinds(src, :regex)
    assert_empty kinds(src, :string)
  end

  def test_regex_after_return
    assert_equal [ "/'#fff'/" ], kinds("return /'#fff'/.test(v)", :regex)
  end

  def test_division_after_call_paren
    assert_empty kinds("f(x) / 2 / 'a'", :regex)
  end

  def test_regex_after_block_brace_then_string
    src = "x = a }\n/[\"]/.test(s); y = \"#123\""
    assert_equal [ '/["]/' ], kinds(src, :regex)
    assert_equal [ '"#123"' ], kinds(src, :string)
  end

  def test_division_after_object_literal_brace
    assert_empty kinds("x = {a: 1} / 2", :regex)
  end

  def test_string_span
    tok = ColorJs.tokens('a = "#abc";').find { |t| t.kind == :string }
    assert_equal [ 4, 10 ], [ tok.start, tok.stop ]
  end

  def test_expression_end_skips_comment_brace
    src = '{ok /* } */ ? "#abc" : x}'
    assert_equal src.length - 1, ColorJs.expression_end(src, 1)
  end

  def test_expression_end_skips_comment_open_brace
    src = "{a /* { */} text"
    assert_equal 10, ColorJs.expression_end(src, 1)
  end

  def test_expression_end_skips_regex_and_strings
    src = '{/}/.test(s) ? "}" : \'{\'} tail'
    assert_equal 24, ColorJs.expression_end(src, 1)
  end

  def test_expression_end_unbalanced_is_nil
    assert_nil ColorJs.expression_end("{ a { b }", 1)
  end

  def test_nested_template_with_brace_in_interpolation
    src = '`a ${ `b ${ {x: "}"}.x }` + "}" } c` + "#fff"'
    templates = kinds(src, :template)
    assert_equal 1, templates.length
    assert templates.first.end_with?(" c`")
    assert_equal [ '"#fff"' ], kinds(src, :string)
  end

  def test_postfix_increment_then_division
    assert_empty kinds("i++ / 2 / 'x'", :regex)
  end

  def test_regex_char_class_with_slash
    assert_equal [ "/[/]/g" ], kinds("s.split(/[/]/g)", :regex)
  end

  def test_unterminated_constructs_do_not_raise
    [ "'abc", "\"abc\nnext", "/* open", "x = /abc", "`abc ${ x", "`abc", "{", "\xff\"a", "" ].each do |src|
      assert_kind_of Array, ColorJs.tokens(src).to_a
      ColorJs.expression_end(src, 1)
    end
  end

  def test_unterminated_string_stops_at_newline
    assert_equal [ "'abc" ], kinds("'abc\n'def'", :string).first(1)
  end
end
