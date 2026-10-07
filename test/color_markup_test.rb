# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/color_markup"

class ColorMarkupTest < Minitest::Test
  def styles(text)
    ColorMarkup.each_node(text).grep(ColorMarkup::Style)
  end

  def test_without_a_block_returns_an_enumerator
    assert_kind_of Enumerator, ColorMarkup.each_node("<p></p>")
  end

  def test_style_inside_a_script_string_is_not_a_style_element
    text = '<script>var a="<style>:root{--text:#000}</style>";</script>'
    assert_empty styles(text)
    raw = ColorMarkup.each_node(text).grep(ColorMarkup::Raw)
    assert_equal [ "script" ], raw.map(&:tag)
  end

  def test_style_inside_a_comment_is_not_a_style_element
    assert_empty styles("<!-- <style>:root{--bg:#fff}</style> -->")
  end

  def test_style_inside_textarea_and_title_is_not_a_style_element
    assert_empty styles("<textarea><style>a{}</style></textarea>")
    assert_empty styles("<title><style>a{}</style></title>")
  end

  def test_style_inside_an_attribute_value_is_not_a_style_element
    assert_empty styles(%(<div title="<style>a{}</style>"></div>))
  end

  def test_style_event_carries_media_and_lang
    text = %(<style media="(prefers-color-scheme: dark)" lang="scss">a{}</style><style>b{}</style>)
    first, second = styles(text)
    assert_equal "(prefers-color-scheme: dark)", first.media
    assert_equal "scss", first.lang
    assert_nil second.media
    assert_nil second.lang
  end

  def test_positions_are_raw_text_offsets
    text = "<!-- x -->\n<p style=\"color:red\"></p>\n<style>a{color:blue}</style>"
    style = styles(text).first
    assert_equal text.index("a{color:blue}"), style.pos
    assert_equal "a{color:blue}", style.body
    attr = ColorMarkup.each_node(text).grep(ColorMarkup::Attr).first
    assert_equal text.index("color:red"), attr.pos
    assert_equal "style", attr.name
    assert_equal "p", attr.tag
  end

  def test_bound_and_curly_attributes
    attrs = ColorMarkup.each_node(%(<a :fill="x" stroke={y}></a>)).grep(ColorMarkup::Attr)
    assert_equal [ [ ":fill", true, false ], [ "stroke", false, true ] ],
                 attrs.map { |a| [ a.name, a.bound, a.curly ] }
  end
end
