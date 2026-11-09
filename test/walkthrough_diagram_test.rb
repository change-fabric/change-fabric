# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "tmpdir"
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

  private

  def stub(mod, name, value)
    original = mod.method(name)
    mod.define_singleton_method(name) { value }
    yield
  ensure
    mod.define_singleton_method(name, original)
  end
end
