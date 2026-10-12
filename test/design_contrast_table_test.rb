# frozen_string_literal: true

require "minitest/autorun"

# The site/DESIGN.md contrast table must list one token per row. Tokens that
# share a value in one theme can be mixed differently in the other (dark
# --text is navy 15%, --heading navy 5%; dark --link-hover is gold 90%,
# --accent plain gold), so a merged row can only carry one correct ratio.
class DesignContrastTableTest < Minitest::Test
  DESIGN = File.expand_path("../site/DESIGN.md", __dir__)
  ROW = /^\| `(?<pair>[^|]+)` on `--bg` \| (?<light>[\d.]+):1 \| (?<dark>[\d.]+):1 \|$/

  EXPECTED = {
    "--text" => %w[12.67 13.08],
    "--heading" => %w[12.67 15.87],
    "--link" => %w[12.67 9.38],
    "--link-hover" => %w[4.96 10.0],
    "--accent" => %w[4.96 9.38]
  }.freeze

  def rows
    File.readlines(DESIGN, chomp: true).filter_map { |l| ROW.match(l) }
  end

  def test_no_row_merges_tokens
    rows.each { |m| refute_includes m[:pair], "/", "merged contrast row: #{m[0]}" }
  end

  EXPECTED.each do |token, (light, dark)|
    define_method("test_#{token.delete('-').tr('-', '_')}_has_own_row") do
      row = rows.find { |m| m[:pair] == token }
      refute_nil row, "#{token} has no contrast row of its own"
      assert_equal [ light, dark ], [ row[:light], row[:dark] ]
    end
  end
end
