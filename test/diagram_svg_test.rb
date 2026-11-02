# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/diagram_svg"

# Text alignment and size resolve as SVG does: own attribute or inline style,
# else the nearest ancestor's, else the SVG initial value.
class DiagramSvgTest < Minitest::Test
  def text(inner, group: "")
    svg = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><g #{group}>#{inner}</g></svg>)
    DiagramSvg::Document.new(svg).texts.first
  end

  def test_text_anchor_variants
    assert_equal "start", text(%(<text x="1" y="1">a</text>)).anchor
    assert_equal "end", text(%(<text x="1" y="1" text-anchor="end">a</text>)).anchor
    assert_equal "middle", text(%(<text x="1" y="1" style="fill:red; text-anchor: middle">a</text>)).anchor
    assert_equal "middle", text(%(<text x="1" y="1">a</text>), group: %(text-anchor="middle")).anchor
    assert_equal "end", text(%(<text x="1" y="1">a</text>), group: %(style="text-anchor:end")).anchor
    assert_equal "start", text(%(<text x="1" y="1" text-anchor="start">a</text>), group: %(text-anchor="middle")).anchor
  end

  def test_font_size_variants
    assert_equal DiagramSvg::DEFAULT_FONT_SIZE, text(%(<text x="1" y="1">a</text>)).font_size
    assert_equal 12.0, text(%(<text x="1" y="1" font-size="12">a</text>)).font_size
    assert_equal 11.0, text(%(<text x="1" y="1" style="font-size:11px">a</text>)).font_size
    assert_equal 18.0, text(%(<text x="1" y="1">a</text>), group: %(font-size="18")).font_size
  end
end
