# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "fileutils"
require "json"
require "tmpdir"
require_relative "../scripts/walkthrough_assumptions"
require_relative "../scripts/walkthrough_diagram"
require_relative "../scripts/walkthrough_storyboard"

# Diagram swimlanes: the `lanes` block validates (ids, labels, colours, the
# cap, node membership, the lane ops and `travel`), lane colours resolve and
# pass the contrast floors, a laned screen inlines the lane layer around the
# runtime, and a spec without lanes writes exactly the screen it wrote before.
class WalkthroughDiagramLanesTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/walkthrough", __dir__)
  LANES = File.join(FIXTURES, "diagram-swimlanes")

  # sha256 of each laneless fixture screen as generated before lanes existed,
  # with the inlined bundle and runtime text swapped for fixed markers so a
  # later runtime change does not move these.
  LANELESS = {
    "architecture" => "5f405d3125d375177ee403a08892183d006fee2056e7275497a14f46350c207b",
    "diagram-lr" => "46b12a3c892fbd8371d4e80eae2830e96aba75d7333dabd53840a89c07dc14c1",
    "diagram-flow" => "ae510a3d15e634abf11c39a62b7e25649c54fe17a3f2771ef95ec26b32564676",
    "diagram-colors" => "17022d4c40c055ed58f82c9e8df52c52219d46381636b095d3d2b5df18895a08"
  }.freeze

  # The same screens hashed whole, runtime and bundle included, and the
  # runtime file itself: the markers above hide any runtime edit, so these
  # pin it. Update both only with a capture proof that laneless geometry is
  # unchanged (test/walkthrough_diagram_capture_test.rb).
  RUNTIME_SHA = "bfb845a2fb628e93f8ad634a6cb6329e3c451348d76e5ec5f66729f0b1ccd1f2"
  LANELESS_RAW = {
    "architecture" => "1ae996b14ce5df60a5fc0b3f553a9e0bde0f025e725e933c0b52f730a883f650",
    "diagram-lr" => "de9b413a9be0ef40479990e2c21c8aba31dc27c27bb69a77647ff590516d1efd",
    "diagram-flow" => "e2f385e7f664aa3598855a586a17db21e24b554621b73cec76df8e159f21b980",
    "diagram-colors" => "897e086e215d0e6a1aac824f386eeffb5875ca836789196a4b57a69d213d034b"
  }.freeze

  def setup
    @root = Dir.mktmpdir
    FileUtils.cp_r("#{LANES}/.", @root)
    @board = WalkthroughStoryboard.load(File.join(@root, "storyboard.json"))
  end

  def teardown = FileUtils.rm_rf(@root)

  def scene = @board["scenes"].first

  def spec = scene["diagram"]

  def errs = WalkthroughDiagram.spec_errors(spec, 8000).join("\n")

  def html = WalkthroughDiagram.screen(scene, root: @root, board: @board)

  def test_specs_without_lanes_keep_their_screen_bytes
    bundle = File.read(WalkthroughDiagram::XYFLOW_BUNDLE).gsub("</script", "<\\/script")
    runtime = File.read(WalkthroughDiagram::RUNTIME)
    assert_equal RUNTIME_SHA, Digest::SHA256.file(WalkthroughDiagram::RUNTIME).hexdigest,
                 "cf_diagram_runtime.js changed: laneless screen bytes change with it; update RUNTIME_SHA only with a " \
                 "capture proof that laneless geometry is unchanged"
    LANELESS.each do |name, sha|
      Dir.mktmpdir do |root|
        FileUtils.cp_r("#{File.join(FIXTURES, name)}/.", root)
        board = WalkthroughStoryboard.load(File.join(root, "storyboard.json"))
        out = WalkthroughDiagram.screen(board["scenes"].first, root: root, board: board)
        refute_includes out, "cf-diagram-lanes"
        refute_includes out, File.read(WalkthroughDiagram::LANES_RUNTIME)
        assert_equal sha, Digest::SHA256.hexdigest(out.sub(runtime, "RUNTIME").sub(bundle, "BUNDLE")), "#{name} screen changed"
        assert_equal LANELESS_RAW.fetch(name), Digest::SHA256.hexdigest(out), "#{name} raw screen changed"
      end
    end
  end

  def test_fixture_generates_and_validates
    WalkthroughDiagram.write_screens(@board, @root)
    assert_empty WalkthroughStoryboard.validate(@board, root: @root)
  end

  def test_lane_layer_wraps_the_runtime
    out = html
    pre = out.index(File.read(WalkthroughDiagram::LANES_RUNTIME))
    run = out.index(File.read(WalkthroughDiagram::RUNTIME))
    assert_operator out.index("window.CfXyflow"), :<, pre, "lanes load after the bundle"
    assert_operator pre, :<, run, "lanes lay out before the runtime reads the spec"
    assert_operator run, :<, out.index("window.__cfLanes.attach()"), "lanes attach after the runtime"
    data = JSON.parse(out[%r{<script type="application/json" id="cf-diagram-lanes">(.*?)</script>}m, 1])
    assert_equal "horizontal", data["direction"]
    assert_equal %w[load a11y security ux cases], data["lanes"].map { |l| l["id"] }
    assert_equal "#f2b85b", data["lanes"][0]["color"]
  end

  def test_lane_colours_tint_over_the_surface_and_default_to_series
    spec["lanes"][1].delete("color")
    lanes = WalkthroughDiagram.lane_colors(spec, @root)
    surface = WalkthroughDiagram::PALETTE_DARK["surface"]
    mix = ->(hex, share) { DiagramPalette.hex(DiagramPalette.mix(DiagramPalette.rgb(hex), DiagramPalette.rgb(surface), share)).downcase }
    assert_equal mix.("#f2b85b", WalkthroughDiagram::LANE_TINT_SHARE[:dark]), lanes[0]["tint"]
    assert_equal mix.("#f2b85b", WalkthroughDiagram::LANE_HL_SHARE), lanes[0]["tint_hl"]
    assert_equal WalkthroughDiagram::ITEM_DEFAULTS[:dark]["series-2"], lanes[1]["color"]
  end

  def test_lane_contrast_floors
    spec["theme"] = "light"
    spec["lanes"][0]["color"] = "#fff3c4"
    WalkthroughDiagram.write_screens(@board, @root)
    joined = WalkthroughStoryboard.validate(@board, root: @root).join("\n")
    assert_match(/diagram lane "load": color #fff3c4 on the light surface #ffffff is [\d.]+:1, under 3.0/, joined)
    # At the shipped shares no hue drops the theme text under the floor, so
    # a strong highlight share stands in for a token palette that would.
    spec["theme"] = "dark"
    spec["lanes"][0]["color"] = "#ffffff"
    with_hl_share(0.9) do
      WalkthroughDiagram.write_screens(@board, @root)
      assert_match(/diagram lane "load": label text #f1f5f9 on its dark band #[0-9a-f]{6} is [\d.]+:1, under 4.5/,
                   WalkthroughStoryboard.validate(@board, root: @root).join("\n"))
    end
  end

  def with_hl_share(value)
    old = WalkthroughDiagram::LANE_HL_SHARE
    WalkthroughDiagram.send(:remove_const, :LANE_HL_SHARE)
    WalkthroughDiagram.const_set(:LANE_HL_SHARE, value)
    yield
  ensure
    WalkthroughDiagram.send(:remove_const, :LANE_HL_SHARE)
    WalkthroughDiagram.const_set(:LANE_HL_SHARE, old)
  end

  def test_lane_fields
    spec["lanes"] << { "id" => "Bad", "label" => "", "color" => "series-9", "glyph" => "x" }
    spec["lanes"] << { "id" => "pr", "label" => "Dup" }
    joined = errs
    assert_includes joined, 'diagram id "Bad" must match'
    assert_includes joined, 'diagram lane "Bad": unknown keys: glyph'
    assert_includes joined, 'diagram lane "Bad": label must be a non-empty string'
    assert_includes joined, 'diagram lane "Bad": color must be a role'
    assert_includes joined, 'diagram id "pr" is not unique across nodes and edges'
  end

  def test_lane_icons_validate_and_inline
    spec["lanes"][0]["icon"] = "gauge"
    spec["lanes"][0]["icon_weight"] = "duotone"
    assert_empty errs
    data = JSON.parse(html[%r{<script type="application/json" id="cf-diagram-lanes">(.*?)</script>}m, 1])
    assert_equal "gauge/duotone", data["lanes"][0]["icon"]
    icons = JSON.parse(html[%r{<script type="application/json" id="cf-diagram-icons">(.*?)</script>}m, 1])
    assert_includes icons.keys, "gauge/duotone"
    spec["lanes"][1]["icon"] = "nope"
    spec["lanes"][2].delete("icon")
    spec["lanes"][2]["icon_weight"] = "bold"
    assert_includes errs, 'diagram lane "a11y": icon "nope" is not a vendored icon'
    assert_includes errs, 'diagram lane "security": icon_weight needs an icon'
  end

  def test_lane_cap_direction_and_membership
    spec["lanes"] = (1..9).map { |i| { "id" => "l#{i}", "label" => "Lane #{i}" } }
    spec["lane_direction"] = "diagonal"
    assert_includes errs, "diagram has 9 lanes; the cap is 8"
    assert_includes errs, "diagram.lane_direction must be one of horizontal, vertical"
    assert_includes errs, 'diagram node "check-load": lane "load" is not a lane'
    spec["lanes"] = []
    spec["lane_direction"] = "vertical"
    assert_includes errs, "diagram.lane_direction needs lanes"
    spec["lanes"] = "load"
    assert_includes errs, "diagram.lanes must be a list of objects"
  end

  def test_lane_ops_and_travel
    spec["steps"] = [ { "t_ms" => 0, "op" => "highlight", "ids" => %w[load check-load] },
                      { "t_ms" => 0, "op" => "dim", "id" => "a11y" },
                      { "t_ms" => 0, "op" => "remove", "id" => "ux" },
                      { "t_ms" => 0, "op" => "travel", "lane" => "load", "id" => "pr", "duration" => 500 },
                      { "t_ms" => 0, "op" => "travel", "lane" => "cases" } ]
    spec["initial"] << "load"
    assert_empty errs
    spec["steps"] = [ { "t_ms" => 0, "op" => "travel", "id" => "pr" },
                      { "t_ms" => 0, "op" => "travel", "lane" => "check-load", "id" => "load" },
                      { "t_ms" => 0, "op" => "travel", "lane" => "load", "ids" => [ "pr" ], "duration" => 0 },
                      { "t_ms" => 0, "op" => "pulse_edge", "id" => "load" },
                      { "t_ms" => 0, "op" => "fit_view", "ids" => [ "load" ] } ]
    joined = errs
    assert_includes joined, "step 0: nil is not a lane id"
    assert_includes joined, 'step 1: "check-load" is not a lane id'
    assert_includes joined, 'step 1: "load" is not a node id'
    assert_includes joined, "step 2: travel takes one id, not ids"
    assert_includes joined, "step 2: duration must be positive for travel"
    assert_includes joined, 'step 3: "load" is not a edge id'
    assert_includes joined, 'step 4: "load" is not a node id'
  end

  def test_travel_easing_and_result
    spec["steps"][1]["easing"] = "cubic-bezier(0.22, 1, 0.36, 1)"
    spec["steps"][2]["easing"] = "emphasized"
    assert_empty errs
    spec["steps"][1]["easing"] = "bounce"
    spec["steps"][2]["easing"] = "cubic-bezier(1.4, 0, 0.2, 1)"
    spec["steps"][3]["result"] = "nope"
    joined = errs
    assert_includes joined, "step 1: easing must be one of standard, linear"
    assert_includes joined, "step 2: easing must be one of"
    assert_includes joined, 'step 3: "nope" is not a node id'
  end

  # A travel's token and result belong to the lane layer from start to end.
  def test_travel_owns_its_token_and_result
    spec["steps"][2]["result"] = "f-load"
    spec["steps"][3]["result"] = "pr"
    spec["initial"] << "f-ux"
    spec["nodes"].find { |n| n["id"] == "pr" }["lane"] = "load"
    spec["edges"] = [ { "id" => "e1", "source" => "check-cases", "target" => "f-cases" } ]
    spec["steps"] << { "t_ms" => 7500, "op" => "highlight", "ids" => %w[check-load pr] }
    joined = errs
    assert_includes joined, 'diagram node "f-load" is the result of more than one travel'
    assert_includes joined, 'diagram node "pr" cannot be both a travel token and a result'
    assert_includes joined, 'diagram node "pr": a travel token or result sits in no lane'
    assert_includes joined, 'diagram edge "e1": a travel token or result takes no edges'
    assert_includes joined, 'diagram.initial names "f-ux"'
    assert_includes joined, "step 6: highlight names pr, which a travel draws"
  end

  def test_report_panel_fields
    assert_empty errs
    spec["report"] = { "label" => " ", "unit" => 3, "title" => "x" }
    joined = errs
    assert_includes joined, "diagram.report has unknown keys: title"
    assert_includes joined, "diagram.report.label must be a non-empty string"
    assert_includes joined, "diagram.report.unit must be a non-empty string"
    spec["report"] = { "label" => "Report" }
    spec["lane_direction"] = "vertical"
    assert_includes errs, "diagram.report needs horizontal lanes"
    data = JSON.parse(html[%r{<script type="application/json" id="cf-diagram-lanes">(.*?)</script>}m, 1])
    assert_equal({ "label" => "Report" }, data["report"])
    assert_equal "dark", data["theme"]
  end

  # The lane layer re-runs the runtime's layout; its sizing must not drift.
  def test_lane_layout_constants_mirror_the_runtime
    lanes = File.read(WalkthroughDiagram::LANES_RUNTIME)
    runtime = File.read(WalkthroughDiagram::RUNTIME)
    %w[NODE_H NODE_MIN_W NODE_MAX_W CHAR_W NODE_PAD_W ICON_PX ICON_GAP NODE_SEP RANK_SEP FADE_MS DIM_OPACITY].each do |name|
      re = /const #{name} = ([\d.]+);/
      assert_equal runtime[re, 1], lanes[re, 1], name
    end
    # The runtime's ease is the lane layer's `ease-in-out`.
    assert_equal runtime[/const ease = (.*)$/, 1], lanes[/const cubic = (.*)$/, 1]
  end

  # Lane icons inline Phosphor glyphs just like node icons, so a board whose
  # only icons sit on lanes still carries the Phosphor notice.
  def test_lane_icons_alone_need_the_phosphor_notice
    spec["nodes"].each { |n| n.delete("icon") }
    assert_includes html, "gauge/regular"
    assert WalkthroughAssumptions.diagram_icons?(@board), "lane icons are missed by notice detection"
    spec["lanes"].each { |l| l.delete("icon") }
    refute WalkthroughAssumptions.diagram_icons?(@board)
  end

  # The lane layer's camera anchors use underscores, which the id rule keeps
  # out of every authored id, so they can never collide.
  def test_lane_anchor_ids_are_reserved
    anchors = File.read(WalkthroughDiagram::LANES_RUNTIME).scan(/'(__cf_lane_anchor_\w+)'/).flatten
    assert_equal 2, anchors.size
    spec["nodes"].first["id"] = anchors.first
    assert_match(/must match/, errs)
  end

  # Each lane text box holds its budget exactly and rejects one char more.
  def test_text_budgets_pass_at_budget_and_fail_one_over
    node = ->(id) { spec["nodes"].find { |n| n["id"] == id } }
    lane = spec["lanes"].find { |l| l["id"] == "load" }
    lane.delete("icon")
    at_budget = lambda do |box, font, aside: 0|
      "x" * DiagramTextFit.chars(DiagramTextFit.room(box) - aside, font)
    end
    cases = {
      "lane_label" => [ ->(t) { lane["label"] = t }, -> { at_budget.("lane_label", 22) }, 'diagram lane "load": label' ],
      "token" => [ ->(t) { node.("pr")["label"] = t }, -> { at_budget.("token", 17) }, 'diagram node "pr": token label' ],
      "report_row" => [ ->(t) { node.("f-load")["label"] = t },
                        -> { at_budget.("report_row", 18, aside: DiagramTextFit.width(lane["label"], 15)) },
                        'diagram node "f-load": report row' ],
      "report_head" => [ ->(t) { spec["report"]["label"] = t },
                         -> { at_budget.("report_head", 22, aside: DiagramTextFit.width("5/5 checks", 16) + 32) },
                         "diagram.report: label" ]
    }
    cases.each do |box, (set, text, msg)|
      %w[pr f-load].each { |id| node.(id).delete("icon") }
      set.(text.call)
      refute_includes errs, msg, "#{box} at budget"
      set.("#{text.call}x")
      assert_match(/#{Regexp.escape(msg)} "x+" is \d+px wide at \d+px; the budget is \d+px \(about \d+ chars\)/, errs, box)
      set.("ok")
    end
    check = node.("check-load")
    check.delete("icon")
    two = "#{'a' * 13} #{'b' * 13}"
    check["label"] = two
    refute_includes errs, 'diagram node "check-load": checkpoint label'
    check["label"] = "#{two}b"
    assert_includes errs, 'diagram node "check-load": checkpoint label "' + "#{two}b" + '" wraps to 3 lines at 19px; the budget is 2 lines of 196px'
  end

  def test_render_md_lists_lanes
    md = WalkthroughDiagram.md(scene)
    assert_includes md, "- Lane `load`: Load [gauge]"
    assert_includes md, "- Node `check-load`: Load budget (pinned) (lane load)"
    assert_includes md, "| 300 | travel | pr, load |"
  end
end
