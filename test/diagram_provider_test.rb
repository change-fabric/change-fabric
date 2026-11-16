# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../scripts/diagram_lint"
require_relative "styled_measurer"

# Covers provider architecture diagrams beyond the one-fixture-per-check
# rule: the icon body is opaque to the shared checks, provenance is one
# normalized digest plus a fixed g.icon structure, colors come only from the
# pinned Chromium (STYLED cases, skipped without Docker), and group nesting
# follows the profile's depth order.
class DiagramProviderTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/diagram", __dir__)
  FAKE = CloudIcons::Store.new("aws" => File.expand_path("fixtures/cloud_icons/fake-pack", __dir__))
  CLEAN = File.read(File.join(FIXTURES, "clean_architecture_aws.svg"))

  NODE_RECT = '<rect x="104" y="168" width="176" height="56" rx="6"/>'
  SUBNET_PLATE = %(<rect class="plate" x="72" y="120" width="24" height="24" rx="2" fill="#FFFFFF"/>)
  CLOUD_RECT = '<rect x="24" y="40" width="672" height="376" stroke="var(--aws-cloud)"/>'
  UNPLATED = CLEAN.sub(SUBNET_PLATE, "")

  def self.style(svg, rule) = svg.sub(".bg { fill: var(--bg); }", ".bg { fill: var(--bg); }\n    #{rule}")

  # Every SVG whose verdict depends on computed styles, read in one batch.
  STYLED = {
    clean: CLEAN,
    descendant_rect: CLEAN.sub(".node > rect {", ".node rect {"),
    legend_rect: style(CLEAN, ".legend rect { fill: var(--surface); }"),
    bare_path: style(CLEAN, "path { fill: var(--ink); }"),
    inert_path: style(CLEAN, "path { pointer-events: none; }"),
    node_muted: CLEAN.sub(".node > rect { fill: var(--surface);", ".node > rect { fill: var(--muted);"),
    node_important: CLEAN.sub(".node > rect { fill: var(--surface);", ".node > rect { fill: var(--muted) !important;"),
    important_then_normal: CLEAN.sub(".node > rect { fill: var(--surface);", ".node > rect { fill: var(--muted) !important; fill: var(--surface);"),
    inline_important: CLEAN.sub(".node > rect { fill: var(--surface);", ".node > rect { fill: var(--surface) !important;")
                           .sub(NODE_RECT, NODE_RECT.sub("/>", ' style="fill: var(--muted) !important"/>')),
    more_specific: CLEAN.sub(".node > rect {", "g.node > rect { fill: var(--muted); }\n    .node > rect {"),
    plate_css: style(CLEAN, ".plate { fill: var(--bg); }"),
    small_plate: CLEAN.sub('<rect class="plate" x="24" y="40" width="24" height="24"', '<rect class="plate" x="27" y="43" width="18" height="18"'),
    unplated: UNPLATED,
    group_muted: UNPLATED.sub(".group > rect { fill: none;", ".group > rect { fill: var(--muted);"),
    enclosing_muted: UNPLATED.sub(CLOUD_RECT, CLOUD_RECT.sub("/>", ' style="fill: var(--muted)"/>')),
    fallback: CLEAN.sub(%r{<g class="icon" id="api-icon".*?</svg>\s*</g>}m,
                        CloudIcons.inline("aws", "lambda", instance_id: "fb", box: [ 116, 180, 32, 32 ], store: FAKE))
  }.freeze

  def lint_source(svg, packs: FAKE, measurer: DiagramMeasure::Static.new)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "d.svg")
      File.write(path, svg)
      DiagramLint.new(measurer: measurer, packs: packs).lint_file(path)[:findings]
    end
  end

  def styled(name)
    skip "docker not available" unless StyledMeasurer.available?
    self.class.warm
    lint_source(STYLED.fetch(name), measurer: StyledMeasurer.new)
  end

  def self.warm = @warm ||= StyledMeasurer.new.warm(STYLED.values) || true

  def contrast?(findings, prefix) = findings.any? { |f| f.check == "icon-contrast" && f.message.start_with?(prefix) }
  def recolor?(findings) = findings.any? { |f| f.check == "icon-pack-provenance" && f.message.include?("the diagram changes") }

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

  # Without Docker the color checks say so; they never guess.
  def test_without_docker_color_checks_say_docker_is_required
    findings = lint_source(CLEAN).select { |f| f.severity == "error" }
    assert_equal %w[icon-pack-provenance icon-contrast].sort, checks(findings).sort
    assert(findings.all? { |f| f.message.start_with?("Docker is required") })
  end

  def test_an_uncached_pack_warns
    findings = lint_source(CLEAN, packs: CloudIcons::Store.new({}))
    assert(findings.any? { |f| f.severity == "warn" && f.message.include?("aws pack is not cached") })
  end

  def test_the_clean_fixture_passes_with_computed_styles
    assert_empty styled(:clean)
  end

  def test_an_edited_icon_body_fails_its_digest
    [ "#FF00FF", "#ED7100" ].each do |color|
      svg = CLEAN.sub('<path d="M20 48 L32 16 L44 48 Z" fill="#FFFFFF">', %(<path d="M20 48 L32 16 L44 48 Z" fill="#{color}">))
      assert(lint_source(svg).any? { |f| f.check == "icon-pack-provenance" && f.message.include?("differs from the pinned") }, color)
    end
  end

  def test_a_changed_icon_viewbox_fails_its_digest
    svg = CLEAN.sub('<svg class="icon" x="116" y="180" width="32" height="32" viewBox="0 0 64 64">',
                    '<svg class="icon" x="116" y="180" width="32" height="32" viewBox="0 0 1 1">')
    assert(lint_source(svg).any? { |f| f.check == "icon-pack-provenance" && f.message.include?("differs from the pinned") })
  end

  def test_extra_attributes_on_the_icon_root_fail_provenance
    root = '<svg class="icon" x="116" y="180" width="32" height="32" viewBox="0 0 64 64"'
    [ 'opacity="0"', 'style="display:none"', 'filter="url(#f)"' ].each do |attr|
      svg = CLEAN.sub(root, "#{root} #{attr}")
      assert(lint_source(svg).any? { |f| f.check == "icon-pack-provenance" && f.message.include?("svg.icon root carries") }, attr)
    end
  end

  def test_placement_attributes_do_not_change_the_digest
    svg = CLEAN.sub('<svg class="icon" x="116" y="180" width="32" height="32"', '<svg class="icon" x="118" y="182" width="28" height="28"')
    assert(lint_source(svg).none? { |f| f.message.include?("differs from the pinned") })
  end

  def test_g_icon_holds_plate_notice_and_svg_in_order
    plate = '<rect class="plate" x="356" y="292" width="32" height="32" rx="2" fill="#FFFFFF"/>'
    after = CLEAN.sub("            #{plate}\n", "").sub(%r{(<g class="icon" id="db-icon".*?</svg>)}m) { "#{Regexp.last_match(1)}#{plate}" }
    no_notice = CLEAN.sub(%r{(<g class="icon" id="api-icon"[^>]*>\s*)<!--[^>]*-->}m, '\1')
    [ after, no_notice ].each do |svg|
      refute_equal CLEAN, svg
      assert(lint_source(svg).any? { |f| f.check == "icon-pack-provenance" && f.message.include?("in that order") })
    end
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

  # Group borders use AWS's exact colors; the cloud navy on the dark --bg is
  # under 3:1 and is accepted silently.
  def test_official_group_borders_are_not_contrast_graded
    assert_includes CLEAN, "--aws-cloud: #242F3E; --aws-vpc: #8C4FFF; --aws-private-subnet: #00A4A6; }\n    }"
    assert_empty(styled(:clean).select { |f| f.check == "icon-contrast" })
  end

  def test_groups_must_nest_in_profile_depth_order
    svg = CLEAN.sub('data-id="vpc" data-group-kind="vpc"', 'data-id="vpc" data-group-kind="cloud"')
    assert(lint_source(svg).any? { |f| f.check == "group-nesting" && f.message.include?("cannot nest") })
  end

  def test_an_edge_crossing_a_group_border_twice_is_flagged
    svg = CLEAN.sub('d="M432 224 V280"', 'd="M432 224 H700 V250 H432 V280"')
    assert(lint_source(svg).any? { |f| f.check == "group-nesting" && f.message.include?("border") })
  end

  def test_an_edge_leaving_and_reentering_at_a_vertex_is_flagged
    svg = CLEAN.sub('d="M432 224 V280"', 'd="M432 224 H648 H660 V250 H648 H432 V280"')
    assert(lint_source(svg).any? { |f| f.check == "group-nesting" && f.message.include?("subnet border 2 times") })
  end

  # Property: on random rectilinear paths over an integer grid, the border
  # crossing count equals the inside/outside changes seen by sampling the
  # path at quarter steps, skipping samples that lie on the border.
  def test_border_crossings_match_a_sampled_oracle
    rng = Random.new(412)
    box = DiagramSvg::Box.new(x: 4, y: 4, w: 8, h: 8)
    nesting = DiagramProviderChecks::GroupNesting.new
    200.times do
      x = rng.rand(0..16)
      y = rng.rand(0..16)
      d = +"M#{x} #{y}"
      rng.rand(1..6).times { |i| i.even? ? d << " H#{x = rng.rand(0..16)}" : d << " V#{y = rng.rand(0..16)}" }
      segs = DiagramSvg::PathData.segments(d)
      assert_equal oracle_crossings(segs, box), nesting.send(:side_changes, segs, box), d
    end
  end

  def oracle_crossings(segs, box)
    sides = segs.flat_map do |s|
      steps = [ (s.dx.abs + s.dy.abs) * 4, 1 ].max.to_i
      (0..steps).map { |k| [ s.x1 + (s.dx * k / steps.to_f), s.y1 + (s.dy * k / steps.to_f) ] }
    end
    on_border = ->(px, py) { box.edges.any? { |e| e.distance_to_point(px, py) < 1e-9 } }
    seen = sides.reject { |px, py| on_border.call(px, py) }.map { |px, py| box.contains_point?(px, py) }
    seen.each_cons(2).count { |a, b| a != b }
  end

  def test_fallback_glyph_warns
    findings = styled(:fallback)
    fb = findings.find { |f| f.check == "icon-pack-provenance" }
    assert_equal "warn", fb.severity
    assert_match(/Phosphor lightning fallback/, fb.message)
    assert(findings.none? { |f| f.severity == "error" })
  end

  # An opaque tile hides a plate of its own size, so such a plate does not count.
  def test_a_plate_must_show_around_the_icon
    assert(styled(:small_plate).any? { |f| f.check == "icon-contrast" && f.element == "cloud-chip" })
  end

  # Chromium decides what reaches inside an icon; the lint parses no CSS.
  def test_rules_that_repaint_icon_artwork_are_errors
    assert recolor?(styled(:descendant_rect))
    assert recolor?(styled(:bare_path))
    refute recolor?(styled(:legend_rect))
    refute recolor?(styled(:inert_path))
    refute recolor?(styled(:clean))
  end

  def test_icon_contrast_reads_computed_backgrounds
    %i[node_muted node_important important_then_normal inline_important more_specific].each do |name|
      assert contrast?(styled(name), "light: tile #ED7100"), name
    end
    assert contrast?(styled(:plate_css), "dark:")
  end

  def test_a_transparent_owner_shows_what_encloses_it
    refute contrast?(styled(:unplated), "dark: tile #00A4A6")
    assert contrast?(styled(:group_muted), "dark: tile #00A4A6")
    assert contrast?(styled(:enclosing_muted), "dark: tile #00A4A6")
  end

  def test_a_top_level_group_clipped_by_the_viewbox_is_flagged
    svg = CLEAN.sub(CLOUD_RECT, CLOUD_RECT.sub('x="24"', 'x="-24"').sub('width="672" height="376"', 'width="768" height="440"'))
    assert(lint_source(svg).any? { |f| f.check == "viewbox-clip" && f.element == "cloud" })
  end

  def test_offline_cli_says_docker_is_required
    Dir.mktmpdir do |cache|
      old = ENV.fetch("CF_CLOUD_ICONS_CACHE", nil)
      ENV["CF_CLOUD_ICONS_CACHE"] = cache
      out = StringIO.new
      code = DiagramLint.main([ File.join(FIXTURES, "clean_architecture_aws.svg") ], out: out, err: StringIO.new, measurer: DiagramMeasure::Static.new)
      assert_equal 1, code
      assert_match(/icon-pack-provenance:warn: aws pack is not cached/, out.string)
      assert_match(/icon-contrast:error: Docker is required/, out.string)
    ensure
      ENV["CF_CLOUD_ICONS_CACHE"] = old
    end
  end

  def test_a_diagram_without_a_provider_is_unchanged
    assert_empty lint_source(File.read(File.join(FIXTURES, "clean_architecture.svg")))
  end
end
