# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/chart_render"

# Covers cf:chart's renderer: every type matches its golden SVG byte for
# byte, output is deterministic, the text alternative is present, ticks stay
# in range, the repo palette is honored, and bad specs fail with exit 2.
class ChartRenderTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/chart", __dir__)

  def spec(type) = JSON.parse(File.read(File.join(FIXTURES, "#{type}.json")))

  ChartRender::TYPES.each do |type|
    define_method("test_#{type.tr('-', '_')}_matches_its_golden") do
      golden = File.read(File.join(FIXTURES, "#{type}.svg"))
      assert_equal golden, ChartRender.render(spec(type)), "re-render #{type}.json to update the golden only on purpose"
    end
  end

  def test_rendering_is_deterministic
    ChartRender::TYPES.each { |t| assert_equal ChartRender.render(spec(t)), ChartRender.render(JSON.parse(JSON.generate(spec(t)))) }
  end

  def test_root_carries_type_title_desc_and_data_table
    svg = ChartRender.render(spec("bar"))
    assert_match(/<svg [^>]*data-chart-type="bar"/, svg)
    assert_match(%r{<title id="t">Roast cost per round</title>}, svg)
    assert_match(/<desc id="d">Three roast rounds/, svg)
    assert_match(%r{<g data-role="data-table"[^>]*>\s*<desc>estimate, 1: 0.08</desc>}, svg)
  end

  def test_horizontal_bars_swap_axes
    s = spec("bar").merge("orientation" => "horizontal")
    svg = ChartRender.render(s)
    assert_match(/data-axis="x" data-role="category"/, svg)
    assert_match(/data-axis="y" data-role="value-x"/, svg)
  end

  def test_ticks_stay_between_three_and_eight
    [ [ 0, 0.08 ], [ 0, 7 ], [ -3, 12 ], [ 5, 5 ], [ 0, 1234 ], [ 0.001, 0.0042 ] ].each do |lo, hi|
      s = { "type" => "line", "title" => "t", "x" => { "label" => "k" }, "y" => { "label" => "v", "unit" => "u" },
            "series" => [ { "name" => "a", "values" => [ [ "a", lo ], [ "b", hi ] ] } ] }
      count = ChartRender.render(s).scan('class="tick"').size
      assert_includes 3..8, count, "#{lo}..#{hi} gave #{count} ticks"
    end
  end

  def test_one_day_schedule_keeps_three_ticks
    s = { "type" => "schedule", "title" => "t", "x" => { "label" => "Date" }, "y" => { "label" => "Task" },
          "tasks" => [ { "name" => "a", "start" => "2026-11-02", "end" => "2026-11-03" } ] }
    assert_operator ChartRender.render(s).scan('class="tick"').size, :>=, 3
  end

  def test_tiny_domains_keep_finite_distinct_ticks
    s = { "type" => "scatter", "title" => "t", "x" => { "label" => "x" }, "y" => { "label" => "y" },
          "series" => [ { "name" => "a", "points" => [ [ 1e-12, 1e-12 ], [ 2e-12, 2e-12 ] ] } ] }
    svg = ChartRender.render(s)
    refute_match(/Inf|NaN/, svg)
  end

  def test_repo_tokens_replace_the_default_skin
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "tokens.css"), ":root { --bg: #FFFFFF; --ink: #111111; --accent: #0055AA; }")
      svg = ChartRender.render(spec("bar"), roles: ChartPalette.roles(repo: dir))
      assert_includes svg, "--s1: #0055AA;"
      refute_includes svg, "#B5401C"
    end
  end

  def test_no_tokens_means_the_default_skin
    Dir.mktmpdir { |dir| assert_equal ChartPalette::DEFAULT, ChartPalette.roles(repo: dir) }
    assert_equal ChartPalette::DEFAULT, ChartPalette.roles
  end

  def test_bad_specs_raise
    assert_raises(ChartRender::Error) { ChartRender.render({ "type" => "pie", "title" => "x" }) }
    assert_raises(ChartRender::Error) { ChartRender.render({ "type" => "bar" }) }
    assert_raises(ChartRender::Error) { ChartRender.render({ "type" => "bar", "title" => "x", "series" => [] }) }
    assert_raises(ChartRender::Error) { ChartRender.render(spec("heatmap").merge("cells" => [ [ 1 ] ])) }
    assert_raises(ChartRender::Error) { ChartRender.render(spec("schedule").merge("tasks" => [ { "name" => "a", "start" => "soon", "end" => "later" } ])) }
    assert_raises(ChartRender::Error) { ChartRender.render(spec("table").merge("rows" => [ [ "only one" ] ])) }
  end

  def test_cli_writes_the_file_and_exits_two_on_error
    Dir.mktmpdir do |dir|
      out = File.join(dir, "nested", "bar.svg")
      assert_equal 0, ChartRender.main([ File.join(FIXTURES, "bar.json"), "--out", out ], err: StringIO.new)
      assert_equal ChartRender.render(spec("bar")), File.read(out)
      bad = File.join(dir, "bad.json")
      File.write(bad, '{"type":"pie","title":"x"}')
      err = StringIO.new
      assert_equal 2, ChartRender.main([ bad ], err: err)
      assert_match(/pie/, err.string)
    end
  end
end
