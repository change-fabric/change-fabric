# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "open3"
require "rbconfig"
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

  def test_review_object_is_validated_and_absence_only_warns
    b = board
    assert_empty WalkthroughStoryboard.validate(b, root: @root).grep(/review/)
    assert_match(/review is absent/, WalkthroughStoryboard.warnings(b).first)
    b["review"] = { "kind" => "explainer", "audience" => "Engineers", "purpose" => [ "State the flow" ] }
    assert_empty WalkthroughStoryboard.validate(b, root: @root).grep(/review/)
    assert_empty WalkthroughStoryboard.warnings(b)
    b["review"] = { "kind" => "trailer", "audience" => " ", "purpose" => [] }
    errors = WalkthroughStoryboard.validate(b, root: @root).grep(/review/)
    assert_equal 3, errors.size
    b["review"] = { "kind" => "demo" }
    assert_equal 2, WalkthroughStoryboard.warnings(b).size
  end

  def test_zoom_with_pinned_dpr_one_warns
    b = board.merge("review" => { "kind" => "demo", "audience" => "Ops", "purpose" => [ "Ship" ] })
    b["scenes"] = [ { "id" => "s1", "camera" => { "zoom" => 1.5 } }, { "id" => "s2", "camera" => { "zoom" => 0.8 } } ]
    b["viewport"] = { "w" => 1920, "h" => 1080, "dpr" => 1 }
    assert_equal [ "s1" ], WalkthroughStoryboard.warnings(b).map { |w| w[/scene (\S+):/, 1] }
    b["viewport"] = { "w" => 1920, "h" => 1080 }
    assert_empty WalkthroughStoryboard.warnings(b)
  end

  def test_voice_eq_validation
    b = board
    assert_empty errors_for(b).grep(/voice\.eq/)
    b["voice"]["eq"] = "warm"
    assert_empty errors_for(b).grep(/voice\.eq/)
    assert_equal 150, WalkthroughStoryboard.voice_eq(b)["low_shelf_hz"]
    b["voice"]["eq"] = { "cut_hz" => 3500, "cut_db" => -2.5 }
    assert_empty errors_for(b).grep(/voice\.eq/)
    b["voice"]["eq"] = "tinny"
    assert_match(/preset must be one of warm/, errors_for(b).grep(/voice\.eq/).first)
    assert_nil WalkthroughStoryboard.voice_eq(b)
    b["voice"]["eq"] = { "cut_hz" => 3500, "bogus" => 1, "low_shelf_hz" => 5, "low_shelf_db" => 40 }
    errs = errors_for(b).grep(/voice\.eq/)
    assert_equal 4, errs.size
    b["voice"]["eq"] = []
    assert_equal [ "voice.eq must be a preset name or an object" ], errors_for(b).grep(/voice\.eq/)
    b["voice"]["eq"] = {}
    assert_match(/at least one band/, errors_for(b).grep(/voice\.eq/).first)
  end

  def test_voice_pronunciations_validation_and_audio_key
    b = board
    b["scenes"] = [ { "id" => "s1", "narration" => { "text" => "Open CHANGE.md." } } ]
    before = WalkthroughStoryboard.audio_key(b, b["scenes"].first)
    b["voice"]["pronunciations"] = [ { "text" => "CHANGE.md", "say" => "change dot M D" } ]
    assert_empty errors_for(b).grep(/pronunciations/)
    aliased = WalkthroughStoryboard.audio_key(b, b["scenes"].first)
    refute_equal before, aliased, "adding an alias re-voices the scene"
    b["voice"]["pronunciations"][0]["say"] = "change markdown"
    refute_equal aliased, WalkthroughStoryboard.audio_key(b, b["scenes"].first), "changing an alias re-voices"
    b["voice"]["pronunciations"] = [ { "text" => "X", "say" => "" }, { "text" => "X", "say" => "ex", "ipa" => "x" } ]
    errs = errors_for(b).grep(/pronunciations/)
    assert_includes errs, "voice.pronunciations[0].say must be a non-empty string"
    assert_includes errs, "voice.pronunciations[1].ipa is not a known field (text, say)"
    assert_includes errs, %(voice.pronunciations text "X" appears more than once)
    b["voice"]["pronunciations"] = { "text" => "X" }
    assert_equal [ "voice.pronunciations must be a list of { text, say } objects" ], errors_for(b).grep(/pronunciations/)
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

  def test_camera_zoom_is_the_only_declared_resize
    b = board
    b["scenes"][1]["camera"] = { "zoom" => 1.3 }
    assert_equal [], errors_for(b)
    [ { "zoom" => 9 }, { "zoom" => "big" }, { "zoom" => 1.2, "pan" => 1 }, 2 ].each do |bad|
      b["scenes"][1]["camera"] = bad
      assert errors_for(b).any? { |e| e.include?("camera") }, bad.inspect
    end
  end

  def test_music_duck_overrides
    b = board
    b["scenes"][1]["timing"].merge!("music_duck_db" => -6, "music_duck_attack_ms" => 0, "music_duck_release_ms" => 2000)
    assert errors_for(b).none? { |e| e.include?("music_duck") }
    b["scenes"][1]["timing"].merge!("music_duck_db" => 3, "music_duck_attack_ms" => 2001, "music_duck_release_ms" => 1.5)
    errs = errors_for(b).join("\n")
    assert_includes errs, "timing.music_duck_db must be a number in -60..0"
    assert_includes errs, "timing.music_duck_attack_ms must be an integer in 0..2000"
    assert_includes errs, "timing.music_duck_release_ms must be an integer in 0..2000"
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

  # -- narration_start and sfx ---------------------------------------------

  def test_narration_start_validation
    b = board
    b["scenes"][1]["narration_start"] = 4.0
    assert_equal [], errors_for(b)
    [ -1, "4", 61 ].each do |bad|
      b["scenes"][1]["narration_start"] = bad
      assert errors_for(b).any? { |e| e.include?("narration_start must be a number of seconds in 0..60") }, bad.inspect
    end
    b["scenes"][1]["narration_start"] = 2
    b["scenes"][1]["narration"] = { "text" => " " }
    assert errors_for(b).any? { |e| e.include?("narration_start 2 needs narration.text") }
  end

  # The scene grows to fit the offset plus the line: max(min_ms, start + measured + pad).
  def test_narration_start_sizes_the_scene
    scene = { "narration_start" => 4.0, "narration" => { "measured_ms" => 1500 }, "timing" => { "min_ms" => 3000, "pad_ms" => 400 } }
    assert_equal 4000, PrototypeCapture.narration_start_ms(scene)
    assert_equal 5900, PrototypeCapture.scene_duration(scene)
    assert_equal 6000, PrototypeCapture.scene_duration(scene.merge("timing" => { "min_ms" => 6000, "pad_ms" => 400 }))
    assert_equal 0, PrototypeCapture.narration_start_ms({})
  end

  def sfx_board(sfx)
    FileUtils.mkdir_p(File.join(@root, "sfx"))
    File.binwrite(File.join(@root, "sfx", "riser.wav"), "RIFF")
    b = board
    b["scenes"][0]["sfx"] = sfx
    b
  end

  def test_sfx_validation_and_defaults
    assert_equal [], errors_for(sfx_board("file" => "sfx/riser.wav"))
    assert_equal [], errors_for(sfx_board("file" => "sfx/riser.wav", "start" => 0.0, "gain_db" => -17, "duck_db" => -10, "duck_lead" => 0.1))
    spec = WalkthroughStoryboard.sfx_spec(sfx_board("file" => "sfx/riser.wav")["scenes"][0])
    assert_equal({ "start" => 0.0, "gain_db" => -18, "duck_db" => nil, "duck_lead" => 0.1, "file" => "sfx/riser.wav" }, spec)
    [ [ { "file" => "" }, "sfx.file is required" ], [ { "file" => "sfx/none.wav" }, "does not exist" ],
      [ { "file" => "../riser.wav" }, "inside the walkthrough" ], [ { "file" => "sfx/riser.txt" }, "sfx.file must be one of" ],
      [ { "file" => "sfx/riser.wav", "start" => -1 }, "sfx.start" ], [ { "file" => "sfx/riser.wav", "gain_db" => 20 }, "sfx.gain_db" ],
      [ { "file" => "sfx/riser.wav", "duck_db" => 3 }, "sfx.duck_db" ], [ { "file" => "sfx/riser.wav", "duck_lead" => 5 }, "sfx.duck_lead" ],
      [ { "file" => "sfx/riser.wav", "loop" => true }, "unknown keys: loop" ], [ "sfx/riser.wav", "sfx must be an object" ] ].each do |sfx, fragment|
      assert errors_for(sfx_board(sfx)).any? { |e| e.include?(fragment) }, "#{sfx.inspect} should mention #{fragment}"
    end
  end

  # -- ai-broll scenes -----------------------------------------------------

  def broll_scene(extra = {})
    { "id" => "shed", "title" => "Shed", "order" => 3, "kind" => "ai-broll",
      "broll" => { "source_image" => "screens/assets/shed.png", "prompt" => "slow push in", "seconds" => 4,
                   "model" => "gemini-omni-1.1-flash", "fallback" => "kenburns" },
      "narration" => { "text" => "shed narration", "measured_ms" => 2000 },
      "assumptions" => [ { "id" => "A-09", "text" => "generated footage" } ],
      "timing" => { "min_ms" => 3000, "pad_ms" => 400, "transition" => { "type" => "fade", "ms" => 500 } } }.merge(extra)
  end

  def broll_board(extra = {})
    FileUtils.mkdir_p(File.join(@root, "screens", "assets"))
    File.binwrite(File.join(@root, "screens", "assets", "shed.png"), "PNG")
    b = board
    b["scenes"] << broll_scene(extra)
    b
  end

  def test_valid_broll_scene_needs_no_screen
    assert_equal [], errors_for(broll_board)
  end

  def test_broll_scene_rules
    assert errors_for(broll_board("broll" => nil)).any? { |e| e.include?("broll is required") }
    assert errors_for(broll_board("screen" => { "html" => "screens/list.html" })).any? { |e| e.include?("must not carry screen.html") }
    assert errors_for(broll_board("kind" => "movie")).any? { |e| e.include?("kind") }
    [ [ "source_image", "screens/assets/missing.png", "does not exist" ],
      [ "source_image", "../outside.png", "inside the walkthrough" ],
      [ "source_image", "screens/assets/shed.gif", "png, jpg, or webp" ],
      [ "prompt", "", "prompt" ],
      [ "seconds", 0, "seconds" ], [ "seconds", 11, "seconds" ], [ "seconds", "4", "seconds" ],
      [ "model", "veo-3.1-generate-preview", "retired" ],
      [ "fallback", "none", "fallback" ] ].each do |field, value, fragment|
      b = broll_board
      b["scenes"].last["broll"][field] = value
      assert errors_for(b).any? { |e| e.include?(fragment) }, "#{field}=#{value.inspect} should mention #{fragment}"
    end
  end

  def test_broll_keys_include_model_and_screen_scenes_carry_none
    keys = WalkthroughStoryboard.recompute_keys(broll_board, @root)
    assert_match(/\A\h{64}\z/, keys["shed"]["frames_key"])
    assert_match(/\A\h{64}\z/, keys["shed"]["broll_key"])
    refute keys["create"].key?("broll_key")
    other = broll_board
    other["scenes"].last["broll"]["model"] = "gemini-omni-2"
    refute_equal keys["shed"]["broll_key"], WalkthroughStoryboard.recompute_keys(other, @root)["shed"]["broll_key"]
  end

  def test_broll_frames_key_changes_when_the_clip_is_cached
    b = broll_board
    before = WalkthroughStoryboard.recompute_keys(b, @root)["shed"]["frames_key"]
    spec = b["scenes"].last["broll"]
    key = BRoll.asset_key(source_image: File.join(@root, spec["source_image"]), prompt: spec["prompt"], seconds: 4, model: spec["model"])
    path = WalkthroughCache.path(File.join(@root, ".cache"), :broll, key, "mp4")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, "mp4")
    refute_equal before, WalkthroughStoryboard.recompute_keys(b, @root)["shed"]["frames_key"]
  end

  def test_stale_covers_broll_and_ignores_it_on_screen_scenes
    b = broll_board
    WalkthroughStoryboard.fix_keys(b, @root)
    assert_nil WalkthroughStoryboard.stale(b, @root).find { |s| s["id"] == "shed" }
    b["scenes"].last["broll"]["prompt"] = "pull out"
    stale = WalkthroughStoryboard.stale(b, @root).find { |s| s["id"] == "shed" }
    assert_includes stale["kinds"], "broll"
  end

  def test_timeline_and_md_include_the_broll_scene
    b = broll_board
    assert_equal 3, WalkthroughStoryboard.timeline(b)["scenes"].size
    md = WalkthroughStoryboard.render_md(b)
    assert_includes md, "## 3. Shed (`shed`)"
    assert_includes md, "- B-roll: screens/assets/shed.png, 4s, gemini-omni-1.1-flash, fallback kenburns"
    assert_includes md, "- B-roll prompt: slow push in"
    refute_includes md.split("## 3.").last, "- Screen:"
  end

  # -- tokens_css_sha256 --------------------------------------------------

  def tokens_repo
    repo = File.join(@root, "repo")
    walk = File.join(repo, "walkthrough", "demo")
    FileUtils.mkdir_p(File.join(repo, "design"))
    FileUtils.mkdir_p(File.join(repo, ".git"))
    FileUtils.cp_r(Dir.glob(File.join(@root, "{screens,data}")), walk.tap { |w| FileUtils.mkdir_p(w) })
    File.write(File.join(repo, "design", "tokens.css"), ":root { --bg: #fff; }\n")
    [ repo, walk ]
  end

  def test_canonical_tokens_walks_up_to_design_tokens_and_stops_at_repo_root
    repo, walk = tokens_repo
    assert_equal File.join(repo, "design", "tokens.css"), WalkthroughStoryboard.canonical_tokens(walk)
    File.delete(File.join(repo, "design", "tokens.css"))
    assert_nil WalkthroughStoryboard.canonical_tokens(walk)
  end

  def test_tokens_hash_missing_stale_and_fixed
    repo, = tokens_repo
    tokens = File.join(repo, "design", "tokens.css")
    b = board
    assert_match(/tokens_css_sha256 missing/, WalkthroughStoryboard.tokens_hash_errors(b, tokens).join)
    b["tokens_css_sha256"] = "0" * 64
    assert_match(/tokens_css_sha256 stale/, WalkthroughStoryboard.tokens_hash_errors(b, tokens).join)
    WalkthroughStoryboard.fix_tokens_hash(b, tokens)
    assert_equal Digest::SHA256.file(tokens).hexdigest, b["tokens_css_sha256"]
    assert_equal [], WalkthroughStoryboard.tokens_hash_errors(b, tokens)
    assert_equal [], WalkthroughStoryboard.tokens_hash_errors({}, nil)
  end

  def run_cli(*args)
    script = File.expand_path("../scripts/walkthrough_storyboard.rb", __dir__)
    Open3.capture3(RbConfig.ruby, script, *args)
  end

  def test_cli_fix_writes_hash_and_plain_validate_reports_token_edit
    repo, walk = tokens_repo
    path = File.join(walk, "storyboard.json")
    File.write(path, JSON.generate(board))
    _, err, status = run_cli("validate", path)
    refute status.success?
    assert_match(/tokens_css_sha256 missing/, err)

    out, err, status = run_cli("validate", path, "--fix")
    assert status.success?, err
    assert_match(/deps rewritten/, out)
    fixed = JSON.parse(File.read(path))
    assert_equal Digest::SHA256.file(File.join(repo, "design", "tokens.css")).hexdigest, fixed["tokens_css_sha256"]
    _, err, status = run_cli("validate", path)
    assert status.success?, err

    File.write(File.join(repo, "design", "tokens.css"), ":root { --bg: #000; }\n")
    _, err, status = run_cli("validate", path)
    refute status.success?
    assert_match(/tokens_css_sha256 stale/, err)
  end

  def test_token_change_changes_frames_key
    b = board
    b["tokens_css_sha256"] = "a" * 64
    before = WalkthroughStoryboard.recompute_keys(b, @root)
    b["tokens_css_sha256"] = "b" * 64
    after = WalkthroughStoryboard.recompute_keys(b, @root)
    refute_nil before["create"]["frames_key"]
    refute_equal before["create"]["frames_key"], after["create"]["frames_key"]
  end

  def test_music_start_and_fade_in_validation
    b = board.merge("music" => { "prompt" => "calm", "start" => 3.9, "fade_in" => 0.05 })
    assert_empty errors_for(b).grep(/music/)
    assert_equal 3900, WalkthroughStoryboard.music_start_ms(b)
    total = WalkthroughStoryboard.timeline(b)["total_ms"]
    assert_equal total - 3900, WalkthroughStoryboard.music_length_ms(b, total)
    assert_equal total, WalkthroughStoryboard.music_length_ms(board, total)
    [ -1, "3", total / 1000.0 ].each do |bad|
      assert_equal [ "music.start must be a number of seconds >= 0 and below the total length" ],
                   errors_for(board.merge("music" => { "start" => bad })).grep(/music/)
    end
    assert_equal [ "music.fade_in must be a number of seconds in 0..2" ], errors_for(board.merge("music" => { "fade_in" => 3 })).grep(/music/)
  end
end
