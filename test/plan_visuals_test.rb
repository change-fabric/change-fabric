# frozen_string_literal: true

require_relative "test_helpers"
require "fileutils"
require_relative "#{File.expand_path('../scripts', __dir__)}/plan_check"

class PlanVisualsTest < Minitest::Test
  include SkillTempHome
  # Built from a codepoint so this file never carries the glyph it tests for.
  EM = [ 0x2014 ].pack("U")
  GOOD_SVG = '<svg xmlns="http://www.w3.org/2000/svg" data-diagram-type="flow"><title>Flow</title></svg>'
  VISUALS = "## Visuals\n\n- diagrams/flow.svg, flow, the phase order.\n"

  def with_plan(plan:, files: {})
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "plan.md"), plan)
      files.each do |rel, body|
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
      end
      lines = []
      ok = PlanCheck.check_visuals(dir, lines)
      yield ok, lines
    end
  end

  def test_no_diagrams_and_no_section_skips_the_check
    with_plan(plan: "## Phases\n\nP1.\n") do |ok, lines|
      assert ok
      assert_empty lines
    end
  end

  def test_a_listed_svg_that_is_missing_fails
    with_plan(plan: VISUALS) do |ok, lines|
      refute ok
      assert_includes lines, "visuals: diagrams/flow.svg named in ## Visuals is MISSING or empty"
    end
  end

  def test_an_svg_with_no_type_attribute_fails
    with_plan(plan: VISUALS, files: { "diagrams/flow.svg" => "<svg><title>x</title></svg>" }) do |ok, lines|
      refute ok
      assert_includes lines, "diagrams/flow.svg: MISSING data-diagram-type or data-chart-type"
    end
  end

  def test_an_em_dash_in_an_svg_fails
    svg = GOOD_SVG.sub("Flow</title>", "Flow #{EM} x</title>")
    with_plan(plan: VISUALS, files: { "diagrams/flow.svg" => svg }) do |ok, lines|
      refute ok
      assert_includes lines, "diagrams/flow.svg: contains a banned AI-slop glyph"
    end
  end

  def test_a_home_path_in_an_svg_fails
    svg = GOOD_SVG.sub("Flow</title>", "#{File.join(Dir.home, 'x')}</title>")
    with_plan(plan: VISUALS, files: { "diagrams/flow.svg" => svg }) do |ok, lines|
      refute ok
      assert(lines.any? { |l| l.start_with?("diagrams/flow.svg: contains a literal absolute home path") })
    end
  end

  def test_a_roast_round_without_its_response_fails
    files = { "diagrams/flow.svg" => GOOD_SVG, "roast/round-1.json" => "{}" }
    with_plan(plan: VISUALS, files:) do |ok, lines|
      refute ok
      assert_includes lines, "roast/round-1.json: MISSING round-1.response.json"
    end
  end

  def test_a_complete_set_passes
    chart = '<svg data-chart-type="bar"><title>Cost</title></svg>'
    files = { "diagrams/flow.svg" => GOOD_SVG, "diagrams/cost.svg" => chart,
              "roast/round-1.json" => "{}", "roast/round-1.response.json" => "{}" }
    with_plan(plan: "#{VISUALS}- diagrams/cost.svg, bar, cost.\n\n## Roast\n\nOne round.\n", files:) do |ok, lines|
      assert ok, lines.join("\n")
      assert_includes lines, "visuals: diagrams/cost.svg present"
      assert_includes lines, "roast/round-1.json: response present"
    end
  end

  def test_a_section_with_no_visuals_passes
    with_plan(plan: "## Visuals\n\nNone (single-PR, single-subsystem plan).\n") do |ok, _lines|
      assert ok
    end
  end
end
