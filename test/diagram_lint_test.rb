# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/diagram_lint"

# Covers the cf:diagram linter: each broken fixture trips exactly its own
# check, clean fixtures carry no errors, and the CLI keeps its JSON shape and
# exit codes.
class DiagramLintTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/diagram", __dir__)

  # Test double for the measurer interface.
  class FixedMeasurer
    def initialize(width) = @width = width
    def measured? = true
    def widths(doc) = doc.texts.to_h { |t| [ t.key, [ @width, t.font_size ] ] }
  end

  def fixture(name) = File.join(FIXTURES, name)

  def lint(name, measurer: DiagramMeasure::Static.new)
    DiagramLint.new(measurer: measurer).lint_file(fixture(name))[:findings]
  end

  def run_cli(*argv)
    out = StringIO.new
    err = StringIO.new
    code = DiagramLint.main(argv, out: out, err: err, measurer: DiagramMeasure::Static.new)
    [ code, out.string, err.string ]
  end

  def test_every_check_has_a_kebab_id_and_a_broken_fixture
    ids = DiagramChecks::ALL.map { |c| c::ID }
    assert_equal 16, ids.uniq.size
    ids.each do |id|
      assert_match(/\A[a-z0-9]+(-[a-z0-9]+)*\z/, id)
      assert File.file?(fixture("broken_#{id.tr('-', '_')}.svg")), "missing broken fixture for #{id}"
    end
  end

  DiagramChecks::ALL.each do |check|
    id = check::ID
    define_method("test_broken_#{id.tr('-', '_')}_yields_only_#{id.tr('-', '_')}") do
      findings = lint("broken_#{id.tr('-', '_')}.svg")
      refute_empty findings
      assert_equal [ id ], findings.map(&:check).uniq
    end
  end

  def test_clean_fixtures_yield_no_findings
    %w[clean_flow.svg clean_architecture.svg].each do |name|
      assert_empty lint(name), name
    end
  end

  DIAGRAM_TYPES = %w[architecture flow sequence state er timeline swimlane layers].freeze

  def test_every_type_has_a_reference_and_a_clean_fixture_with_no_errors
    DIAGRAM_TYPES.each do |type|
      assert_path_exists File.expand_path("../skills/diagram/reference/#{type}.md", __dir__), type
      errors = lint("clean_#{type}.svg").select { |f| f.severity == "error" }
      assert_empty errors, type
    end
  end

  def test_text_overflow_is_an_error_when_measured_and_a_warning_when_estimated
    assert_equal [ "warn" ], lint("broken_text_overflow.svg").map(&:severity)
    measured = lint("clean_flow.svg", measurer: FixedMeasurer.new(150))
    assert_equal %w[error], measured.select { |f| f.check == "text-overflow" }.map(&:severity).uniq
  end

  def test_type_override_replaces_the_declared_type
    findings = DiagramLint.new(measurer: DiagramMeasure::Static.new, type: "flow").lint_file(fixture("broken_type_declared.svg"))
    assert_empty findings[:findings]
  end

  def test_json_shape
    code, out, = run_cli("--json", fixture("broken_spacing.svg"))
    assert_equal 1, code
    report = JSON.parse(out)
    assert_equal 1, report["version"]
    assert_equal false, report["measured"]
    file = report["files"].first
    assert_equal "flow", file["type"]
    assert_equal %w[check element fix message severity], file["findings"].first.keys.sort
    assert_equal({ "files" => 1, "errors" => 1, "warnings" => 0 }, report["summary"])
  end

  def test_exit_zero_on_clean_and_warn_only
    assert_equal 0, run_cli(fixture("clean_flow.svg")).first
    code, out, = run_cli(fixture("broken_grid.svg"))
    assert_equal 0, code
    assert_match(/broken_grid\.svg:grid:warn: .* \(cart\)/, out)
  end

  def test_exit_one_on_error
    assert_equal 1, run_cli(fixture("broken_a11y.svg")).first
  end

  def test_directory_scan_lints_every_svg
    code, out, = run_cli("--json", FIXTURES)
    assert_equal 1, code
    assert_equal Dir.glob(File.join(FIXTURES, "*.svg")).size, JSON.parse(out)["summary"]["files"]
  end

  def test_exit_two_on_usage_missing_file_and_bad_xml
    assert_equal 2, run_cli.first
    assert_equal 2, run_cli("--bogus", fixture("clean_flow.svg")).first
    assert_equal 2, run_cli(fixture("nope.svg")).first
    Dir.mktmpdir do |dir|
      bad = File.join(dir, "bad.svg")
      File.write(bad, "<svg><text>a & b</text></svg>")
      code, _, err = run_cli(bad)
      assert_equal 2, code
      assert_match(/bad\.svg/, err)
    end
  end

  def test_palette_flag_reads_tokens_file
    Dir.mktmpdir do |dir|
      tokens = File.join(dir, "tokens.css")
      File.write(tokens, ":root { --brand: #FF0000; --bg: #FBFBFA; --line: #8A939E; }")
      code, out, = run_cli("--palette", tokens, fixture("broken_palette.svg"))
      assert_equal 0, code
      refute_match(/#FF0000/, out)
    end
  end
end
