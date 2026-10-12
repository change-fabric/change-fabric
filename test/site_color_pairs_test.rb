# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/color_tokens"

# The contrast checker only grades pairs declared through "--x-text" alias
# tokens, so a background the stylesheet actually paints text on is silently
# unmeasured unless every theme block declares its alias. This test derives
# the surfaces from the real rules instead of a hand list, and requires an
# alias for each one in each theme block.
class SiteColorPairsTest < Minitest::Test
  STYLES = File.expand_path("../site/src/styles.css", __dir__)
  THEMES = {
    "light" => /^:root,\s*:root\[data-theme="light"\]\s*\{(.*?)^\}/m,
    "dark (prefers-color-scheme)" => /:root:not\(\[data-theme="light"\]\)\s*\{(.*?)^  \}/m,
    "dark (data-theme)" => /^:root\[data-theme="dark"\]\s*\{(.*?)^\}/m
  }.freeze

  def css = @css ||= File.read(STYLES)

  # Every token used as a background by a component rule, hover states included.
  def used_surfaces
    css.scan(/^\s*background(?:-color)?:\s*var\((--[\w-]+)\)/).flatten.uniq.sort
  end

  def theme_names(name)
    body = THEMES.fetch(name).match(css) or flunk("theme block #{name} not found")
    body[1].scan(/^\s*(--[\w-]+):/).flatten
  end

  def measured_surfaces(names)
    ColorTokens.pairs(names).map { |_fg, bg| bg }.to_set
  end

  def test_surfaces_are_discovered_from_rules
    %w[--bg --surface --surface-hover --code-bg --btn].each do |s|
      assert_includes used_surfaces, s
    end
  end

  THEMES.each_key do |theme|
    define_method("test_every_used_surface_is_measured_in_#{theme.gsub(/\W+/, '_')}") do
      names = theme_names(theme)
      measured = measured_surfaces(names)
      # --bg is the page, measured as --background via the --background alias.
      measured << "--bg" if names.include?("--background")
      missing = used_surfaces.reject { |s| measured.include?(s) }
      assert_empty missing, "#{theme}: text on #{missing.join(', ')} is never measured; add a --<surface>-text alias"
    end
  end
end
