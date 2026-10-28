# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../scripts/walkthrough_storyboard"

class WalkthroughStoryboardTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@root, "screens"))
    FileUtils.mkdir_p(File.join(@root, "data"))
    File.write(File.join(@root, "screens", "list.html"), "<html><body><p id='a'>list</p></body></html>")
    File.write(File.join(@root, "screens", "create.html"), "<html><body><button id='go'>go</button></body></html>")
    File.write(File.join(@root, "data", "seed.json"), '{"invoices":[]}')
  end

  def teardown = FileUtils.rm_rf(@root)

  def scene(id, order, extra = {})
    { "id" => id, "title" => id.capitalize, "order" => order, "screen" => { "html" => "screens/#{id}.html" },
      "interactions" => [ { "t_ms" => 0, "op" => "move", "target" => "#go", "duration_ms" => 300 },
                          { "t_ms" => 400, "op" => "wait", "duration_ms" => 200 } ],
      "narration" => { "text" => "#{id} narration", "measured_ms" => 2000 },
      "requirements" => [ { "source" => "docs/prd.md", "anchor" => "##{id}" } ], "hypotheses" => [ "H-01" ],
      "timing" => { "min_ms" => 3000, "pad_ms" => 400, "transition" => { "type" => "cut", "ms" => 0 } } }.merge(extra)
  end

  def board
    { "schema_version" => 1, "slug" => "demo", "title" => "Demo", "fps" => 30,
      "viewport" => { "w" => 1920, "h" => 1080, "dpr" => 1 },
      "voice" => { "voice_id" => "v1", "model" => "eleven_multilingual_v2", "output_format" => "mp3_44100_128" },
      "hypotheses" => [ { "id" => "H-01", "text" => "People find invoices", "dimension" => "role" } ],
      "scenes" => [ scene("create", 1, "store" => { "seed" => "data/seed.json" }),
                    scene("list", 2, "store" => { "seed" => "data/seed.json", "from_scene" => "create",
                                                  "patch" => [ { "op" => "set", "path" => "flag", "value" => true } ] },
                                     "narration" => { "text" => "list narration", "measured_ms" => 4000 },
                                     "timing" => { "min_ms" => 1000, "pad_ms" => 500,
                                                   "transition" => { "type" => "fade", "ms" => 500 } }) ] }
  end

  def errors_for(b) = WalkthroughStoryboard.validate(b, root: @root)

  def test_valid_board_has_no_errors
    assert_equal [], errors_for(board)
  end

  def test_authored_duration_rejected
    b = board
    b["scenes"][0]["duration_ms"] = 5000
    assert errors_for(b).any? { |e| e.include?("duration_ms is derived") }
    b = board
    b["scenes"][1]["timing"]["duration_ms"] = 5000
    assert errors_for(b).any? { |e| e.include?("duration_ms is derived") }
  end

  def test_id_order_transition_and_op_rules
    b = board
    b["scenes"][0]["id"] = "Bad_Id"
    b["scenes"][1]["order"] = 3
    b["scenes"][1]["timing"]["transition"] = { "type" => "fade", "ms" => 50 }
    b["scenes"][0]["interactions"] = [ { "t_ms" => 500, "op" => "click", "target" => "#a" },
                                       { "t_ms" => 100, "op" => "jump" }, { "t_ms" => 600, "op" => "hover" } ]
    errs = errors_for(b).join("\n")
    assert_includes errs, "must match"
    assert_includes errs, "contiguous from 1"
    assert_includes errs, "fade transition ms"
    assert_includes errs, "non-decreasing"
    assert_includes errs, "op \"jump\""
    assert_includes errs, "target is required for hover"
  end

  def test_duplicate_ids_and_unknown_hypothesis_and_provenance
    b = board
    b["scenes"][1]["id"] = "create"
    b["scenes"][1]["store"].delete("from_scene")
    b["scenes"][0]["hypotheses"] = [ "H-99" ]
    b["scenes"][0]["requirements"] = []
    errs = errors_for(b).join("\n")
    assert_includes errs, "not unique"
    assert_includes errs, "H-99"
    assert_includes errs, "requirement or assumption"
  end

  def test_store_rules
    b = board
    b["scenes"][0]["store"] = { "seed" => "seed.json", "from_scene" => "list", "patch" => [ { "op" => "zap", "path" => "x" } ],
                                "prng_seed" => "1" }
    errs = errors_for(b).join("\n")
    assert_includes errs, "must be under data/"
    assert_includes errs, "must be an earlier scene"
    assert_includes errs, "store.patch 0"
    assert_includes errs, "prng_seed must be an integer"
    b["scenes"][0]["store"] = { "seed" => "data/missing.json", "from_scene" => "nope" }
    errs = errors_for(b).join("\n")
    assert_includes errs, "does not exist"
    assert_includes errs, "is not a scene"
  end

  def test_derived_duration_math
    assert_equal({ "create" => 3000, "list" => 4500 }, WalkthroughStoryboard.derive_durations(board))
  end

  def test_timeline_offsets_with_fade_overlap
    line = WalkthroughStoryboard.timeline(board)
    assert_equal [ 0, 90 - 15 ], line["scenes"].map { |s| s["start_frame"] }
    assert_equal 75 + 135, line["total_frames"]
  end

  def test_editing_narration_changes_only_that_scene_audio_key_and_later_offsets
    three = board
    three["scenes"] << scene("done", 3)
    three["scenes"][2]["screen"]["html"] = "screens/list.html"
    before_keys = WalkthroughStoryboard.recompute_keys(three, @root)
    before_line = WalkthroughStoryboard.timeline(three)
    three["scenes"][1]["narration"] = { "text" => "a longer list narration", "measured_ms" => 6000 }
    after_keys = WalkthroughStoryboard.recompute_keys(three, @root)
    after_line = WalkthroughStoryboard.timeline(three)
    changed = before_keys.keys.reject { |id| before_keys[id]["audio_key"] == after_keys[id]["audio_key"] }
    assert_equal [ "list" ], changed
    starts = ->(line) { line["scenes"].map { |s| s["start_frame"] } }
    assert_equal starts.call(before_line)[0, 2], starts.call(after_line)[0, 2]
    refute_equal starts.call(before_line)[2], starts.call(after_line)[2]
  end

  def test_frames_key_nil_until_dependency_captured_then_stale_and_fix
    b = board
    keys = WalkthroughStoryboard.recompute_keys(b, @root)
    assert_match(/\A\h{64}\z/, keys["create"]["frames_key"])
    assert_nil keys["list"]["frames_key"]
    stale = WalkthroughStoryboard.stale(b, @root, keys)
    assert_equal [ "create", "list" ], stale.map { |s| s["id"] }
    assert_includes stale[0]["kinds"], "frames"
    assert_includes stale[0]["kinds"], "audio"

    WalkthroughStoryboard.fix_keys(b, @root, keys)
    assert_equal keys["create"], b["scenes"][0]["deps"]
    assert_equal [ "list" ], WalkthroughStoryboard.stale(b, @root, keys).map { |s| s["id"] }

    out = File.join(@root, ".cache", "frames", keys["create"]["frames_key"])
    FileUtils.mkdir_p(out)
    File.write(File.join(out, "end-state.json"), '{"invoices":[{"id":"inv-1"}]}')
    assert_match(/\A\h{64}\z/, WalkthroughStoryboard.recompute_keys(b, @root)["list"]["frames_key"])
  end

  def test_stale_reports_edited_scene_only
    b = board
    WalkthroughStoryboard.fix_keys(b, @root)
    b["scenes"][0]["narration"]["text"] = "changed"
    stale = WalkthroughStoryboard.stale(b, @root).find { |s| s["id"] == "create" }
    assert_includes stale["kinds"], "audio"
  end

  def test_asset_keys_from_images
    b = board
    b["scenes"][0]["images"] = [ { "prompt" => "a hero", "size" => "1024x1024", "quality" => "medium" } ]
    keys = WalkthroughStoryboard.recompute_keys(b, @root)
    assert_equal 1, keys["create"]["asset_keys"].size
    assert_equal [], keys["list"]["asset_keys"]
  end

  def test_render_md_golden
    expected = <<~MD
      <!-- Generated from storyboard.json; do not edit -->

      # Demo

      ## Hypotheses

      - H-01 (role): People find invoices

      ## 1. Create (`create`)

      - Duration: 3000 ms
      - Screen: screens/create.html
      - Hypotheses: H-01
      - Requirement: docs/prd.md#create

      > create narration

      ## 2. List (`list`)

      - Duration: 4500 ms
      - Screen: screens/list.html
      - Starts from: create
      - Hypotheses: H-01
      - Requirement: docs/prd.md#list

      > list narration
    MD
    assert_equal expected, WalkthroughStoryboard.render_md(board)
  end

  def test_validate_bang_raises
    b = board
    b["schema_version"] = 2
    assert_raises(WalkthroughStoryboard::ValidationError) { WalkthroughStoryboard.validate!(b, root: @root) }
  end
end
