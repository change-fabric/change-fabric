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
end
