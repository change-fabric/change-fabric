# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../scripts/diagram_lint"

# Covers provider architecture diagrams beyond the one-fixture-per-check
# rule: the icon body is opaque to the shared checks, provenance exempts
# only the pack's own colors, the offline path warns instead of blocking,
# and group nesting follows the profile's depth order.
class DiagramProviderTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/diagram", __dir__)
  FAKE = CloudIcons::Store.new("aws" => File.expand_path("fixtures/cloud_icons/fake-pack", __dir__))
  CLEAN = File.read(File.join(FIXTURES, "clean_architecture_aws.svg"))

  def lint_source(svg, packs: FAKE)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "d.svg")
      File.write(path, svg)
      DiagramLint.new(measurer: DiagramMeasure::Static.new, packs: packs).lint_file(path)[:findings]
    end
  end

  def checks(findings) = findings.map(&:check).uniq

  def test_icon_bodies_are_opaque_boxes
    doc = DiagramSvg::Document.new(CLEAN)
    assert_equal 6, doc.icons.size
    assert(doc.texts.none? { |t| doc.in_icon?(t.element) })
    assert(doc.elements.none? { |el| doc.in_icon?(el) })
    assert_operator doc.all_elements.size, :>, doc.elements.size
  end

  def test_group_tree_follows_document_nesting
    doc = DiagramSvg::Document.new(CLEAN)
    assert_equal [ [ "cloud", nil, 1 ], [ "vpc", "cloud", 2 ], [ "subnet", "vpc", 3 ] ], doc.groups.map { |g| [ g.id, g.parent, g.depth ] }
    assert_equal %w[api worker db], doc.nodes_in(doc.group("subnet")).map(&:id)
  end

  def test_offline_lint_warns_but_passes
    findings = lint_source(CLEAN, packs: CloudIcons::Store.new({}))
    refute_empty findings
    assert_equal [ "icon-pack-provenance" ], checks(findings)
    assert(findings.all? { |f| f.severity == "warn" })
  end

  def test_a_smuggled_color_inside_an_icon_is_an_error
    svg = CLEAN.sub('<path d="M20 48 L32 16 L44 48 Z" fill="#FFFFFF">', '<path d="M20 48 L32 16 L44 48 Z" fill="#FF00FF">')
    findings = lint_source(svg).select { |f| f.check == "icon-pack-provenance" }
    assert(findings.any? { |f| f.message.include?("#FF00FF") && f.severity == "error" })
  end

  def test_a_script_inside_an_icon_is_still_caught
    svg = CLEAN.sub("<title>Synthetic test icon</title>", "<title>Synthetic test icon</title><script>x</script>")
    assert_includes checks(lint_source(svg)), "xml-safety"
  end

  def test_brand_group_roles_are_exempt_only_with_profile_values
    assert_empty lint_source(CLEAN).select { |f| f.check == "palette" }
    off = CLEAN.sub("--aws-vpc: #8C4FFF;", "--aws-vpc: #123456;")
    assert(lint_source(off).any? { |f| f.check == "palette" && f.message.include?("#123456") })
    stray = CLEAN.sub("--link: #2E5AA8;", "--link: #8C4FFF;")
    assert(lint_source(stray).any? { |f| f.check == "palette" && f.message.include?("#8C4FFF") })
  end

  def test_a_provider_role_failing_contrast_is_flagged
    svg = CLEAN.sub("--aws-cloud: #777E87;", "--aws-cloud: #242F3E;")
    assert(lint_source(svg).any? { |f| f.check == "icon-contrast" && f.element == "--aws-cloud" })
  end

  def test_groups_must_nest_in_profile_depth_order
    svg = CLEAN.sub('data-id="vpc" data-group-kind="vpc"', 'data-id="vpc" data-group-kind="cloud"')
    assert(lint_source(svg).any? { |f| f.check == "group-nesting" && f.message.include?("cannot nest") })
  end

  def test_an_edge_crossing_a_group_border_twice_is_flagged
    svg = CLEAN.sub('d="M432 224 V280"', 'd="M432 224 H700 V250 H432 V280"')
    assert(lint_source(svg).any? { |f| f.check == "group-nesting" && f.message.include?("border") })
  end

  def test_fallback_glyph_warns
    fallback = CloudIcons.inline("aws", "lambda", instance_id: "fb", box: [ 116, 180, 32, 32 ], store: FAKE)
    svg = CLEAN.sub(%r{<g class="icon" id="api-icon".*?</svg>\s*</g>}m, fallback)
    findings = lint_source(svg)
    fb = findings.find { |f| f.check == "icon-pack-provenance" }
    assert_equal "warn", fb.severity
    assert_match(/Phosphor lightning fallback/, fb.message)
    assert(findings.none? { |f| f.severity == "error" })
  end

  # An opaque tile hides a plate of its own size, so such a plate does not count.
  def test_a_plate_must_show_around_the_icon
    svg = CLEAN.sub('<rect class="plate" x="24" y="40" width="24" height="24"', '<rect class="plate" x="27" y="43" width="18" height="18"')
    assert(lint_source(svg).any? { |f| f.check == "icon-contrast" && f.element == "cloud-chip" })
  end

  # A descendant selector on a bare shape recolors the pack artwork at render time.
  def test_a_stylesheet_reaching_into_icons_is_an_error
    svg = CLEAN.sub(".node > rect {", ".node rect {")
    leak = lint_source(svg).find { |f| f.element == "style" }
    assert_equal "icon-pack-provenance", leak.check
    assert_match(/\.node > rect/, leak.fix)
    assert(lint_source(CLEAN).none? { |f| f.element == "style" }, "#arrow path anchors on an icon-free id")
  end

  def test_a_scoped_selector_that_matches_no_icon_is_allowed
    svg = CLEAN.sub(".bg { fill: var(--bg); }", ".bg { fill: var(--bg); }\n    .legend rect { fill: var(--surface); }")
    assert(lint_source(svg).none? { |f| f.element == "style" })
  end

  def test_a_bare_shape_selector_reaching_into_icons_is_an_error
    svg = CLEAN.sub(".bg { fill: var(--bg); }", ".bg { fill: var(--bg); }\n    path { fill: var(--ink); }")
    leak = lint_source(svg).find { |f| f.element == "style" }
    assert_equal "icon-pack-provenance", leak.check
  end

  def test_icon_contrast_reads_the_node_fill_from_the_stylesheet
    svg = CLEAN.sub(".node > rect { fill: var(--surface);", ".node > rect { fill: var(--muted);")
    assert(lint_source(svg).any? { |f| f.check == "icon-contrast" && f.message.start_with?("light: tile #ED7100") })
  end

  def test_an_edge_leaving_and_reentering_at_a_vertex_is_flagged
    svg = CLEAN.sub('d="M432 224 V280"', 'd="M432 224 H648 H660 V250 H648 H432 V280"')
    assert(lint_source(svg).any? { |f| f.check == "group-nesting" && f.message.include?("subnet border 2 times") })
  end

  def test_an_inert_rule_reaching_icons_is_allowed
    svg = CLEAN.sub(".bg { fill: var(--bg); }", ".bg { fill: var(--bg); }\n    path { pointer-events: none; }")
    assert(lint_source(svg).none? { |f| f.element == "style" })
  end

  def test_a_top_level_group_clipped_by_the_viewbox_is_flagged
    svg = CLEAN.sub('<rect x="24" y="40" width="672" height="376" stroke="var(--aws-cloud)"/>',
                    '<rect x="-24" y="40" width="768" height="440" stroke="var(--aws-cloud)"/>')
    assert(lint_source(svg).any? { |f| f.check == "viewbox-clip" && f.element == "cloud" })
  end

  def test_offline_cli_exits_zero_with_an_empty_cache
    Dir.mktmpdir do |cache|
      old = ENV.fetch("CF_CLOUD_ICONS_CACHE", nil)
      ENV["CF_CLOUD_ICONS_CACHE"] = cache
      out = StringIO.new
      code = DiagramLint.main([ File.join(FIXTURES, "clean_architecture_aws.svg") ], out: out, err: StringIO.new, measurer: DiagramMeasure::Static.new)
      assert_equal 0, code
      assert_match(/icon-pack-provenance:warn: aws pack is not cached/, out.string)
    ensure
      ENV["CF_CLOUD_ICONS_CACHE"] = old
    end
  end

  def test_a_diagram_without_a_provider_is_unchanged
    assert_empty lint_source(File.read(File.join(FIXTURES, "clean_architecture.svg")))
  end
end
