# frozen_string_literal: true

require "minitest/autorun"

# site/DESIGN.md quotes token recipes as copyable CSS. Review kept finding
# examples that no longer matched the stylesheet, so every declaration in a
# css fence there must appear verbatim in site/src/styles.css.
class SiteDesignDocTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_css_examples_match_the_stylesheet
    doc = File.read(File.join(ROOT, "site/DESIGN.md"))
    css = File.read(File.join(ROOT, "site/src/styles.css"))
    lines = doc.scan(/^```css\n(.*?)^```/m).flatten.flat_map { |block| block.lines.map(&:strip) }
    declarations = lines.grep(/\A--[\w-]+:/)
    refute_empty declarations, "no css example found in DESIGN.md"
    missing = declarations.reject { |line| css.include?(line) }
    assert_empty missing, "DESIGN.md examples not in styles.css: #{missing.join(' | ')}"
  end
  # The spacing exceptions DESIGN.md lists under "Spacing and layout". A new
  # off-scale value fails here until it is documented there and added below.
  OFF_SCALE_PX = [ 0, 1, 2, 3, 4, 5, 6, 7, 36, 60, 80, 112 ].freeze

  def test_off_scale_spacing_is_the_documented_list
    css = File.read(File.join(ROOT, "site/src/styles.css"))
    values = css.scan(/^\s*(?:margin|padding|gap)[\w-]*:([^;]*);/).flatten
    used = values.flat_map { |value| value.scan(/(\d+)px/).flatten.map(&:to_i) }.uniq
    assert_empty used - OFF_SCALE_PX, "undocumented px spacing; add it to DESIGN.md and OFF_SCALE_PX"
  end
end
