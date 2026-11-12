# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/chart_lint"

# Covers cf:chart's linter: the golden charts lint clean with their specs,
# each chart check trips on a broken copy of a golden and only that check
# errors, and the CLI keeps diagram_lint.rb's JSON shape and exit codes.
class ChartLintTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/chart", __dir__)

  def path(type, ext = "svg") = File.join(FIXTURES, "#{type}.#{ext}")
  def spec(type) = JSON.parse(File.read(path(type, "json")))

  def lint_svg(svg, spec: nil)
    Dir.mktmpdir do |dir|
      file = File.join(dir, "c.svg")
      File.write(file, svg)
      ChartLint.new(measurer: DiagramMeasure::Static.new, spec: spec).lint_file(file)[:findings]
    end
  end

  def errors(findings) = findings.select { |f| f.severity == "error" }.map(&:check).uniq

  def run_cli(*argv, measurer: DiagramMeasure::Static.new)
    out = StringIO.new
    err = StringIO.new
    code = ChartLint.main(argv, out: out, err: err, measurer: measurer)
    [ code, out.string, err.string ]
  end

  def test_every_check_has_a_kebab_id
    ids = ChartChecks::ALL.map { |c| c::ID }
    assert_equal ids.uniq, ids
    ids.each { |id| assert_match(/\A[a-z0-9]+(-[a-z0-9]+)*\z/, id) }
  end

  ChartRender::TYPES.each do |type|
    define_method("test_golden_#{type.tr('-', '_')}_is_clean_with_its_spec") do
      assert_empty lint_svg(File.read(path(type)), spec: spec(type))
    end
  end

  BROKEN = {
    "type-declared" => [ "bar", ->(s) { s.sub('data-chart-type="bar"', 'data-chart-type="pie"') } ],
    "axis-label" => [ "bar", ->(s) { s.sub('data-unit="USD"', 'data-unit=""') } ],
    "scale-zero" => [ "bar", ->(s) { s.sub('data-min="0"', 'data-min="0.02"') } ],
    "tick-count" => [ "line", ->(s) { s.gsub(/<line class="tick" data-value="(?!6)[^"]*"[^>]*\/>/, "") } ],
    "series-cap" => [ "bar", ->(s) { s.gsub('class="mark s2"', 'class="mark s7"') } ],
    "legend-or-direct-label" => [ "bar", ->(s) { s.sub(%r{<text class="legend-label" data-series="actual"[^>]*>actual</text>}, "") } ],
    "data-table" => [ "bar", ->(s) { s.sub("<desc>estimate, 1: 0.08</desc>", "") } ],
    "value-fidelity" => [ "bar", ->(s) { s.sub(/(data-key="1" data-value="0.08" x="[^"]*" y="[^"]*" width="[^"]*" height=")[^"]*"/, '\1 1"') } ],
    "heatmap-legend" => [ "heatmap", ->(s) { s.gsub(/<rect class="swatch [^>]*>/, "") } ],
    "sequential-contrast" => [ "heatmap", ->(s) { s.sub(/--ramp-1: #\h{6};/) { "--ramp-1: #{s[/--ramp-5: (#\h{6})/, 1]};" } } ]
  }.freeze

  BROKEN.each do |id, (type, mutate)|
    define_method("test_broken_#{id.tr('-', '_')}_errors_only_on_#{id.tr('-', '_')}") do
      svg = mutate.(File.read(path(type)))
      refute_equal File.read(path(type)), svg, "mutation for #{id} did not apply"
      assert_equal [ id ], errors(lint_svg(svg, spec: spec(type)))
    end
  end

  def test_axis_without_a_title_trips_axis_label
    svg = File.read(path("bar")).sub(%r{<text class="axis-title"[^>]*>Round</text>}, "")
    assert_equal [ "axis-label" ], errors(lint_svg(svg, spec: spec("bar")))
  end

  def test_a_seventh_series_trips_series_cap
    s = spec("bar")
    s["series"] = (1..7).map { |i| { "name" => "s#{i}", "values" => [ [ "1", i ] ] } }
    svg = ChartRender.render(s)
    assert_includes errors(lint_svg(svg, spec: s)), "series-cap"
  end

  def test_shared_svg_checks_run_too
    svg = File.read(path("bar")).sub('role="img" ', "")
    assert_includes errors(lint_svg(svg, spec: spec("bar"))), "a11y"
  end

  def test_no_spec_is_a_notice_not_an_error
    code, out, = run_cli("--json", path("bar"))
    assert_equal 0, code
    report = JSON.parse(out)
    assert_equal 1, report["version"]
    assert_equal({ "files" => 1, "errors" => 0, "warnings" => 0 }, report["summary"])
    assert_equal [ "notice" ], report["files"].first["findings"].map { |f| f["severity"] }
  end

  def test_cli_exit_codes
    assert_equal 0, run_cli("--spec", path("bar", "json"), path("bar")).first
    Dir.mktmpdir do |dir|
      broken = File.join(dir, "b.svg")
      File.write(broken, File.read(path("bar")).sub('data-unit="USD"', 'data-unit=""'))
      code, out, = run_cli(broken)
      assert_equal 1, code
      assert_match(/axis-label:error/, out)
      assert_equal 2, run_cli(File.join(dir, "missing.svg")).first
      File.write(File.join(dir, "bad.svg"), "<svg")
      assert_equal 2, run_cli(File.join(dir, "bad.svg")).first
      File.write(File.join(dir, "bad.json"), "{")
      assert_equal 2, run_cli("--spec", File.join(dir, "bad.json"), path("bar")).first
    end
  end

  # Measurer double that reports Docker missing.
  class Unavailable
    def measured? = true
    def widths(_doc) = raise(DiagramMeasure::Unavailable, "docker is not running")
  end

  def test_unmeasured_exits_three
    code, _, err = run_cli(path("bar"), measurer: Unavailable.new)
    assert_equal 3, code
    assert_match(/--no-measure/, err)
  end

  def test_palette_file_adds_derived_chart_colors
    Dir.mktmpdir do |dir|
      tokens = File.join(dir, "tokens.css")
      File.write(tokens, ":root { --bg: #FFFFFF; --ink: #111111; --accent: #0055AA; }")
      out = File.join(dir, "bar.svg")
      ChartRender.main([ path("bar", "json"), "--repo", dir, "--out", out ])
      code, text, = run_cli("--palette", tokens, "--spec", path("bar", "json"), out)
      assert_equal 0, code
      assert_empty text
    end
  end
end
