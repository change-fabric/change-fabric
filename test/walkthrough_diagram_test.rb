# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "fileutils"
require "json"
require "tmpdir"
require_relative "../scripts/phosphor_vendor"
require_relative "../scripts/walkthrough_diagram"
require_relative "../scripts/walkthrough_storyboard"

# The diagram scene kind: the storyboard block validates against the caps,
# id refs, and the closed op set; the generator writes a self-contained
# screen that inline_screen leaves alone; drift is flagged; and the vendored
# bundle and runtime shas are frames_key material.
class WalkthroughDiagramTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/walkthrough/architecture", __dir__)

  def setup
    @root = Dir.mktmpdir
    FileUtils.cp_r("#{FIXTURE}/.", @root)
    @board = WalkthroughStoryboard.load(File.join(@root, "storyboard.json"))
  end

  def teardown = FileUtils.rm_rf(@root)

  def scene = @board["scenes"].first

  def spec = scene["diagram"]

  def screen_path = File.join(@root, "screens", "overview.html")

  def generate = WalkthroughDiagram.write_screens(@board, @root)

  def errs = WalkthroughStoryboard.validate(@board, root: @root)

  def diagram_errs = WalkthroughDiagram.spec_errors(spec, 2000)

  def test_generated_fixture_validates
    assert_equal [ "screens/overview.html" ], generate
    assert_empty errs
  end

  def test_missing_screen_is_reported
    assert_includes errs.join, "screens/overview.html does not exist"
  end

  def test_generator_output
    generate
    html = File.read(screen_path)
    assert html.start_with?(WalkthroughDiagram::GENERATED)
    assert_includes html, File.read(WalkthroughDiagram::XYFLOW_BUNDLE).gsub("</script", "<\\/script")
    assert_includes html, File.read(WalkthroughDiagram::RUNTIME)
    json = html[%r{<script type="application/json" id="cf-diagram">(.*?)</script>}m, 1]
    assert_equal spec, JSON.parse(json)
    assert_includes html, "--cf-accent:"
    refute_match(/<script[^>]*\ssrc=/, html)
  end

  def test_spec_text_cannot_close_the_json_script
    spec["nodes"][0]["label"] = "</script><b>x"
    generate
    json = File.read(screen_path)[%r{<script type="application/json" id="cf-diagram">(.*?)</script>}m, 1]
    assert_equal "</script><b>x", JSON.parse(json)["nodes"][0]["label"]
  end

  def test_omitted_lists_are_written_as_empty
    spec.delete("edges")
    spec.delete("steps")
    generate
    json = File.read(screen_path)[%r{<script type="application/json" id="cf-diagram">(.*?)</script>}m, 1]
    assert_equal [], JSON.parse(json)["edges"]
    assert_equal [], JSON.parse(json)["steps"]
  end

  def test_markup_in_a_label_survives_inline_screen_as_text
    spec["nodes"][0]["label"] = "<iframe> embed"
    generate
    html = PrototypeCapture.inline_screen(screen_path)
    json = html[%r{<script type="application/json" id="cf-diagram">(.*?)</script>}m, 1]
    assert_equal "<iframe> embed", JSON.parse(json)["nodes"][0]["label"]
  end

  def test_inline_screen_leaves_the_generated_screen_alone
    generate
    assert_equal File.read(screen_path), PrototypeCapture.inline_screen(screen_path)
  end

  # The regression the generator depends on: script text that looks like an
  # attribute is only opaque behind data-cf-inline; a plain inline script is
  # still scanned as before.
  def test_inline_screen_skips_marked_script_bodies_only
    body = %(var a = '<img src="'+x+'">';)
    FileUtils.mkdir_p(File.join(@root, "screens"))
    File.write(File.join(@root, "screens", "marked.html"), "<html><body><script data-cf-inline>#{body}</script></body></html>")
    assert_includes PrototypeCapture.inline_screen(File.join(@root, "screens", "marked.html")), body
    File.write(File.join(@root, "screens", "plain.html"), "<html><body><script>#{body}</script></body></html>")
    assert_raises(Errno::ENOENT, ArgumentError, PrototypeCapture::UnsupportedContentError) do
      PrototypeCapture.inline_screen(File.join(@root, "screens", "plain.html"))
    end
  end

  def test_drift_and_fix
    generate
    File.write(screen_path, File.read(screen_path).sub("Postgres", "MySQL"))
    assert_includes errs.join, "drifted from the storyboard's diagram block"
    generate
    assert_empty errs
    spec["nodes"][1]["label"] = "Gateway"
    assert_includes errs.join, "drifted"
  end

  def test_cli_writes_one_scene
    script = File.expand_path("../scripts/walkthrough_diagram.rb", __dir__)
    out = IO.popen([ RbConfig.ruby, script, File.join(@root, "storyboard.json"), "--scene", "overview" ], &:read)
    assert_includes out, "wrote screens/overview.html"
    assert File.file?(screen_path)
  end

  def test_caps
    spec["nodes"] = (1..13).map { |i| { "id" => "n#{i}", "label" => "N#{i}" } }
    spec["edges"] = (1..17).map { |i| { "id" => "x#{i}", "source" => "n1", "target" => "n2" } }
    spec["initial"] = []
    spec["steps"] = []
    assert_includes diagram_errs, "diagram has 13 nodes; the cap is 12"
    assert_includes diagram_errs, "diagram has 17 edges; the cap is 16"
  end

  def test_ids_and_refs
    spec["nodes"] << { "id" => "api", "label" => "Again" }
    spec["edges"] << { "id" => "e9", "source" => "api", "target" => "ghost" }
    spec["initial"] << "nope"
    joined = diagram_errs.join("\n")
    assert_includes joined, %(diagram id "api" is not unique)
    assert_includes joined, %(edge "e9": target "ghost" is not a node)
    assert_includes joined, "diagram.initial names unknown ids: nope"
  end

  def test_steps_timing_and_ops
    spec["steps"] = [
      { "t_ms" => 500, "op" => "highlight", "id" => "api" },
      { "t_ms" => 100, "op" => "dim", "id" => "api" },
      { "t_ms" => 2000, "op" => "dim", "id" => "api" },
      { "t_ms" => 1.5, "op" => "dim", "id" => "api" },
      { "t_ms" => 600, "op" => "teleport", "id" => "api" }
    ]
    joined = diagram_errs.join("\n")
    assert_includes joined, "step 1: t_ms must be non-decreasing"
    assert_includes joined, "step 2: t_ms 2000 must be below the scene duration (2000 ms)"
    assert_includes joined, "step 3: t_ms must be a non-negative integer"
    assert_includes joined, %(step 4: op "teleport" must be one of)
  end

  def test_op_argument_shapes
    spec["steps"] = [
      { "t_ms" => 0, "op" => "connect", "id" => "api" },
      { "t_ms" => 0, "op" => "pulse_edge", "ids" => [] },
      { "t_ms" => 0, "op" => "move", "id" => "api", "position" => { "x" => 1 } },
      { "t_ms" => 0, "op" => "label", "id" => "e1", "text" => "x" },
      { "t_ms" => 0, "op" => "zoom_to", "zoom" => 9 },
      { "t_ms" => 0, "op" => "fit_view", "padding" => 2, "duration" => -1 },
      { "t_ms" => 0, "op" => "focus", "id" => "db", "zoom" => 1.2, "duration" => 400 },
      { "t_ms" => 0, "op" => "highlight", "id" => "api", "ids" => [ "db" ] }
    ]
    joined = diagram_errs.join("\n")
    assert_includes joined, %(step 0: "api" is not a edge id)
    assert_includes joined, "step 1: pulse_edge needs id or a non-empty ids list"
    assert_includes joined, "step 2: move needs a position"
    assert_includes joined, %(step 3: "e1" is not a node id)
    assert_includes joined, "step 4: zoom must be a number in 0.2..3.0"
    assert_includes joined, "step 5: duration must be a non-negative integer"
    assert_includes joined, "step 5: padding must be a number"
    refute_match(/step 6:/, joined)
    assert_includes joined, "step 7: highlight takes id or ids, not both"
  end

  def test_flow_fields
    edge = spec["edges"].first["id"]
    spec["steps"] = [
      { "t_ms" => 0, "op" => "flow", "id" => edge, "count" => 3, "duration" => 900, "stagger" => 200, "repeat" => 2 },
      { "t_ms" => 0, "op" => "flow", "ids" => [ edge ], "loop" => true },
      { "t_ms" => 0, "op" => "flow", "id" => spec["nodes"].first["id"] },
      { "t_ms" => 0, "op" => "flow", "id" => edge, "count" => 9, "stagger" => -1 },
      { "t_ms" => 0, "op" => "flow", "id" => edge, "repeat" => 0, "loop" => "yes" },
      { "t_ms" => 0, "op" => "flow", "id" => edge, "repeat" => 2, "loop" => true, "duration" => 0 }
    ]
    joined = diagram_errs.join("\n")
    refute_match(/step [01]:/, joined)
    assert_match(/step 2: .* is not a edge id/, joined)
    assert_includes joined, "step 3: count must be an integer in 1..8"
    assert_includes joined, "step 3: stagger must be a non-negative integer"
    assert_includes joined, "step 4: repeat must be a positive integer"
    assert_includes joined, "step 4: loop must be true or false"
    assert_includes joined, "step 5: flow takes loop or repeat, not both"
    assert_includes joined, "step 5: duration must be positive for flow"
  end

  def test_layout_and_unknown_keys
    spec["layout"] = { "engine" => "elk", "direction" => "UP" }
    spec["extra"] = 1
    joined = diagram_errs.join("\n")
    assert_includes joined, "diagram.layout.engine must be one of dagre, manual"
    assert_includes joined, "diagram.layout.direction must be one of TB, LR, BT, RL"
    assert_includes joined, "diagram has unknown keys: extra"
  end

  def test_a_diagram_scene_needs_its_block
    scene.delete("diagram")
    assert_includes errs.join, "a diagram scene needs a diagram object"
  end

  def test_frames_key_carries_the_bundle_and_runtime_shas
    generate
    base = WalkthroughStoryboard.recompute_keys(@board, @root)["overview"]["frames_key"]
    refute_nil base
    stub(WalkthroughDiagram, :key_material, { xyflow: "0" * 64, diagram_runtime: WalkthroughDiagram.runtime_sha256 }) do
      refute_equal base, WalkthroughStoryboard.recompute_keys(@board, @root)["overview"]["frames_key"]
    end
    stub(WalkthroughDiagram, :key_material, { xyflow: WalkthroughDiagram::XYFLOW_SHA256, diagram_runtime: "1" * 64 }) do
      refute_equal base, WalkthroughStoryboard.recompute_keys(@board, @root)["overview"]["frames_key"]
    end
  end

  def test_render_md_lists_nodes_edges_and_steps
    md = WalkthroughStoryboard.render_md(@board)
    assert_includes md, "- Node `db`: Postgres (pinned)"
    assert_includes md, "- Edge `e2`: api -> db (writes)"
    assert_includes md, "| 1600 | focus | db |"
  end

  TOKENS = <<~CSS
    :root { --bg: #fdfcf8; --surface: #f3efe4; --ink: #1b1f24; --muted: #4a5260; --border: #d9d3c4;
            --line: #6b7280; --accent: #0b5e57; }
    @media (prefers-color-scheme: dark) { :root { --bg: #111418; --ink: #f1f1ee; } }
  CSS

  def write_tokens(css = TOKENS) = File.write(File.join(@root, "tokens.css"), css)

  def colors(html) = html[/:root \{([^}]*)\}/, 1].scan(/--cf-([\w-]+): (#\h{6})/).to_h

  def test_without_tokens_the_placeholder_palette_is_written
    generate
    assert_equal WalkthroughDiagram::PALETTE, colors(File.read(screen_path))
  end

  def test_tokens_map_through_the_diagram_palette_roles
    write_tokens
    generate
    roles = DiagramPalette.resolve(File.join(@root, "tokens.css")).light
    got = colors(File.read(screen_path))
    WalkthroughDiagram::PALETTE_ROLES.each { |var, role| assert_equal roles[role], got[var], var }
    assert_equal "#FDFCF8", got["surface"]
    assert_equal "#0B5E57", got["accent"]
    assert_empty errs
  end

  def test_low_contrast_tokens_are_errors
    write_tokens(":root { --bg: #ffffff; --ink: #bbbbbb; --accent: #cccccc; }")
    generate
    joined = errs.join("\n")
    assert_match(/diagram palette from .*tokens\.css: light: --ink on --bg/, joined)
    assert_match(/light: --ink on --accent-tint/, joined)
  end

  def test_unreadable_tokens_are_an_error_but_still_render
    write_tokens(":root { --radius: 4px; }")
    generate
    assert_equal WalkthroughDiagram::PALETTE, colors(File.read(screen_path))
    assert_includes errs.join, "no background or text color found"
  end

  def test_changed_tokens_drift_the_screen_and_its_key
    write_tokens
    generate
    assert_empty errs
    before = WalkthroughStoryboard.recompute_keys(@board, @root)["overview"]["frames_key"]
    write_tokens(TOKENS.sub("#0b5e57", "#7a2e8f"))
    assert_includes errs.join, "drifted from the storyboard's diagram block"
    generate
    refute_equal before, WalkthroughStoryboard.recompute_keys(@board, @root)["overview"]["frames_key"]
  end

  def test_node_role_must_be_a_palette_role
    spec["nodes"][1]["role"] = "danger"
    assert_includes diagram_errs.join, "role must be one of default, accent, muted"
    spec["nodes"][1]["role"] = "muted"
    assert_empty diagram_errs
  end

  def test_item_colors_take_roles_or_css_colours
    spec["nodes"][0]["color"] = "series-1"
    spec["nodes"][1]["color"] = "#0b5e57"
    spec["edges"][0]["color"] = "rgb(190, 18, 60)"
    spec["steps"] = [ { "t_ms" => 0, "op" => "flow", "id" => spec["edges"][0]["id"], "color" => "warning" } ]
    assert_empty diagram_errs
    spec["nodes"][0]["color"] = "series-9"
    spec["nodes"][1]["color"] = "#12345"
    spec["edges"][0]["color"] = "rgb(300, 0, 0)"
    spec["steps"] << { "t_ms" => 0, "op" => "highlight", "id" => spec["nodes"][0]["id"], "color" => "accent" }
    spec["steps"] << { "t_ms" => 0, "op" => "flow", "id" => spec["edges"][0]["id"], "color" => "blue" }
    joined = diagram_errs.join("\n")
    assert_match(/node "\w+": color must be a role \(accent, success, warning, danger, series-1/, joined)
    assert_includes joined, 'not "series-9"'
    assert_includes joined, 'not "#12345"'
    assert_includes joined, 'not "rgb(300, 0, 0)"'
    assert_includes joined, "step 1: color is only for flow steps"
    assert_includes joined, "step 2: color must be a role"
  end

  def test_theme_must_be_light_or_dark
    spec["theme"] = "sepia"
    assert_includes diagram_errs.join, "diagram.theme must be one of light, dark"
    spec["theme"] = "dark"
    assert_empty diagram_errs
  end

  def colors_json(html) = JSON.parse(html[%r{<script type="application/json" id="cf-diagram-colors">(.*?)</script>}m, 1])

  def test_an_uncoloured_screen_carries_no_colour_map
    generate
    refute_includes File.read(screen_path), %(id="cf-diagram-colors">)
  end

  def test_roles_resolve_from_the_theme_and_tint_over_the_surface
    spec["nodes"][0]["color"] = "series-2"
    spec["edges"][0]["color"] = "accent"
    spec["steps"] = [ { "t_ms" => 0, "op" => "flow", "id" => spec["edges"][0]["id"], "color" => "#357" } ]
    generate
    got = colors_json(File.read(screen_path))
    assert_equal WalkthroughDiagram::ITEM_DEFAULTS[:light]["series-2"], got["nodes"][spec["nodes"][0]["id"]]["color"]
    assert_equal WalkthroughDiagram::PALETTE["accent"], got["edges"][spec["edges"][0]["id"]]["color"]
    assert_equal "#335577", got["steps"]["0"]["color"]
    assert_empty errs
    spec["theme"] = "dark"
    generate
    assert_match(/step 0: color #335577 on the dark surface #0f172a is 2.3:1, under 3.0/, errs.join)
    spec["steps"][0]["color"] = "series-3"
    generate
    html = File.read(screen_path)
    assert_equal WalkthroughDiagram::PALETTE_DARK, colors(html)
    node = colors_json(html)["nodes"][spec["nodes"][0]["id"]]
    assert_equal WalkthroughDiagram::ITEM_DEFAULTS[:dark]["series-2"], node["color"]
    assert_operator DiagramPalette.contrast(WalkthroughDiagram::PALETTE_DARK["text"], node["tint"]), :>=, 4.5
    assert_empty errs
  end

  def test_token_variables_override_role_defaults_per_theme
    write_tokens(TOKENS.sub("--accent: #0b5e57;", "--accent: #0b5e57; --chart-1: #1d4ed8; --danger: var(--chart-1);")
                       .sub("--ink: #f1f1ee;", "--ink: #f1f1ee; --chart-1: #93c5fd;"))
    light = WalkthroughDiagram.item_roles(@root, :light)
    dark = WalkthroughDiagram.item_roles(@root, :dark)
    assert_equal "#1d4ed8", light["series-1"]
    assert_equal "#1d4ed8", light["danger"]
    assert_equal "#93c5fd", dark["series-1"]
    assert_equal "#93c5fd", dark["danger"]
    assert_equal WalkthroughDiagram::ITEM_DEFAULTS[:dark]["series-2"], dark["series-2"]
  end

  def test_unreadable_item_colours_are_errors
    write_tokens(":root { --bg: #ffffff; --ink: #6b6b6b; --accent: #1d4ed8; }")
    spec["nodes"][0]["color"] = "#000000"
    spec["edges"][0]["color"] = "#eeeeee"
    generate
    joined = errs.join("\n")
    assert_match(/node "\w+": label text #6B6B6B on its light fill #e6e6e6 is 4.2\d:1, under 4.5/, joined)
    assert_match(/edge "\w+": color #eeeeee on the light surface #(?i:ffffff) is [\d.]+:1, under 3.0/, joined)
    spec["nodes"][0]["color"] = "series-1"
    spec["edges"][0]["color"] = "series-1"
    generate
    refute_match(/label text|color #/, errs.join("\n"))
  end

  # A walkthrough inside a repo whose CHANGE.md points its tokens at another
  # stylesheet still takes its colours from the screens/tokens.css its own
  # screens link; without one the repo's configured tokens apply.
  def test_the_walkthroughs_own_screen_tokens_win_over_the_repo_tokens
    repo = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(repo, "site"))
    File.write(File.join(repo, "CHANGE.md"), "---\nchange_config:\n  design:\n    tokens: site/styles.css\n---\n")
    File.write(File.join(repo, "site", "styles.css"), TOKENS)
    walk = File.join(repo, "walkthrough", "demo")
    FileUtils.mkdir_p(walk)
    assert_equal File.join(repo, "site", "styles.css"), WalkthroughDiagram.tokens_path(walk)
    FileUtils.mkdir_p(File.join(walk, "screens"))
    File.write(File.join(walk, "screens", "tokens.css"), TOKENS.sub("--accent: #0b5e57;", "--accent: #0b5e57; --series-1: #1e40af;"))
    assert_equal File.join(walk, "screens", "tokens.css"), WalkthroughDiagram.tokens_path(walk)
    assert_equal "#1e40af", WalkthroughDiagram.item_roles(walk, :light)["series-1"]
  ensure
    FileUtils.rm_rf(repo)
  end

  def test_layout_max_zoom_is_an_optional_bounded_number
    spec["layout"] = { "engine" => "dagre", "max_zoom" => 2.0 }
    assert_empty diagram_errs
    [ 2.5, 0.2, "2" ].each do |bad|
      spec["layout"]["max_zoom"] = bad
      assert_match(/diagram.layout.max_zoom must be a number in 0.5..2.0/, diagram_errs.join)
    end
  end

  def test_dark_theme_checks_the_dark_tokens
    write_tokens(TOKENS.sub("--ink: #f1f1ee;", "--ink: #222222;"))
    spec["theme"] = "dark"
    generate
    assert_match(/tokens\.css: dark: --ink on --bg/, errs.join("\n"))
  end

  def test_bottom_inset_comes_from_the_caption_band_and_viewport
    generate
    html = File.read(screen_path)
    frame = JSON.parse(html[%r{<script type="application/json" id="cf-diagram-frame">(.*?)</script>}m, 1])
    assert_equal (720 * PrototypeUxLint::CAPTION_BAND).ceil, frame["bottom_inset"]
    @board["viewport"] = { "w" => 1920, "h" => 1080 }
    assert_equal 162, WalkthroughDiagram.frame(@board)["bottom_inset"]
    assert_includes errs.join, "drifted"
  end

  def icons_json(html) = JSON.parse(html[%r{<script type="application/json" id="cf-diagram-icons">(.*?)</script>}m, 1])

  def test_node_icons_take_a_vendored_name_and_a_weight
    node = spec["nodes"][0]
    node["icon"] = "git-pull-request"
    assert_empty diagram_errs
    node["icon_weight"] = "duotone"
    assert_empty diagram_errs
    node["icon_weight"] = "thin"
    assert_match(/icon_weight must be one of regular, bold, duotone, fill/, diagram_errs.join)
    node.delete("icon")
    assert_match(/icon_weight needs an icon/, diagram_errs.join)
    node["icon"] = "git-pull-requests"
    joined = diagram_errs.join
    assert_match(/icon "git-pull-requests" is not a vendored icon; available: check-circle, /, joined)
    assert_includes joined, "seal-check"
  end

  def test_the_vendored_subset_carries_every_weight_and_its_pin
    set = WalkthroughDiagram.icon_set
    assert_equal [ "@phosphor-icons/core", "2.1.1", "MIT" ], set.values_at("package", "version", "license")
    assert_equal PhosphorVendor::NAMES, WalkthroughDiagram.icon_names
    set["icons"].each do |name, weights|
      assert_equal WalkthroughDiagram::ICON_WEIGHTS, weights.keys, name
      weights.each_value { |paths| assert(paths.all? { |d, *| d.match?(/\AM[\d.,\-A-Za-z ]+\z/) }, name) }
    end
    assert(set.dig("icons", "shield-check", "duotone").any? { |_, o| o == 0.2 }, "duotone keeps its second tone")
    assert_includes File.read(File.join(File.dirname(WalkthroughDiagram::ICONS_DATA), "LICENSE.txt")), "Copyright (c) 2023 Phosphor Icons"
  end

  def test_a_screen_inlines_only_the_icons_its_nodes_use
    spec["nodes"][0]["icon"] = "gauge"
    spec["nodes"][1]["icon"] = "lock"
    spec["nodes"][1]["icon_weight"] = "fill"
    generate
    got = icons_json(File.read(screen_path))
    assert_equal %w[gauge/regular lock/fill], got.keys
    assert_equal WalkthroughDiagram.icon_set.dig("icons", "lock", "fill"), got["lock/fill"]
    assert_empty errs
    assert_includes WalkthroughDiagram.md(scene).first, "[gauge]"
  end

  def test_an_icon_must_read_on_its_coloured_fill
    spec["nodes"][0]["icon"] = "gauge"
    spec["nodes"][0]["color"] = "#d0d0d0"
    generate
    assert_match(/icon #d0d0d0 on its light fill #\h{6} is [\d.]+:1, under 3.0/, errs.join("\n"))
    spec["nodes"][0]["color"] = "series-1"
    generate
    refute_match(/icon #/, errs.join("\n"))
  end

  # A screen with no node icon (and, for the uncoloured fixtures, no colour)
  # generates byte for byte what it did before icons existed. The hashes are
  # of each fixture's screen with the vendored bundle and runtime bodies cut
  # out, taken from the generator before icon support; the runtime's own
  # bytes are covered by capture tests, which give the same frames.
  ICONLESS_SCREENS = {
    "architecture" => "227c3d487319e4cb4569d5f96fddf22f4eed5a1b91fcb06460c76317a6e1a23f",
    "diagram-colors" => "1c85190c2f1a6007284cb923c03ce378267376f0762c63226460bbd5b920f195",
    "diagram-flow" => "13f83c885c57aa489d93196624c91567c05d180fc08e07aa7961d46efd9e834d",
    "diagram-lr" => "13a5d7874484a258439441343a555efe98e7ae2379c244e6cf773eeca196ef88"
  }.freeze

  def test_iconless_screens_keep_their_bytes
    ICONLESS_SCREENS.each do |fixture, sha|
      root = File.expand_path("fixtures/walkthrough/#{fixture}", __dir__)
      board = JSON.parse(File.read(File.join(root, "storyboard.json")))
      html = WalkthroughDiagram.screen(board["scenes"].find { |s| WalkthroughDiagram.diagram?(s) }, root: root, board: board)
      refute_includes html, %(id="cf-diagram-icons")
      [ WalkthroughDiagram::RUNTIME, WalkthroughDiagram::XYFLOW_BUNDLE ].each do |file|
        body = File.read(file).gsub("</script", "<\\/script")
        assert_includes html, body
        html = html.sub(body, "")
      end
      assert_equal sha, Digest::SHA256.hexdigest(html), "#{fixture} screen changed"
    end
  end

  private

  def stub(mod, name, value)
    original = mod.method(name)
    mod.define_singleton_method(name) { value }
    yield
  ensure
    mod.define_singleton_method(name, original)
  end
end
