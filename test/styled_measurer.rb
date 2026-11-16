# frozen_string_literal: true

require "tmpdir"
require_relative "../scripts/diagram_measure"

# Static text boxes plus real computed styles from the pinned Chromium. The
# styles cache lives for the test process, so `warm` reads a whole batch of
# SVGs in one container and every later lint of those SVGs is a cache hit.
class StyledMeasurer < DiagramMeasure::Static
  CACHE = Dir.mktmpdir("cf-diagram-styles")

  def self.available? = ChangeDocker.available?

  def initialize
    super
    @browser = DiagramMeasure::Browserless.new(cache_dir: CACHE)
  end

  def styles(doc) = @browser.styles(doc)

  def warm(svgs) = @browser.prefetch(svgs.map { |svg| DiagramSvg::Document.new(svg) })
end
