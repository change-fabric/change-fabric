# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "fileutils"
require "json"
require "tmpdir"
require_relative "../scripts/change_docker"
require_relative "../scripts/prototype_capture"
require_relative "../scripts/walkthrough_cache"
require_relative "../scripts/walkthrough_clipcheck"
require_relative "../scripts/walkthrough_element"
require_relative "../scripts/walkthrough_storyboard"

# The element scene kind: validation, beat windows (land_at is the frame a
# beat is fully entered on, the entrance clamped with a warning), word
# anchors on beats and steps, the in-memory page, and, with Docker, frame
# determinism and the landing frame in the pinned browserless container.
class WalkthroughElementTest < Minitest::Test
  EXAMPLE = File.expand_path("../skills/walkthrough/reference/examples/element-film.json", __dir__)

  def board = WalkthroughStoryboard.load(EXAMPLE)

  def scene(min_ms: 6000, beats: nil, steps: nil, narration: nil)
    s = { "id" => "s1", "title" => "One", "order" => 1, "kind" => "element",
          "element" => { "beats" => beats || [ statement("a", 1000) ] },
          "assumptions" => [ { "id" => "A-01", "text" => "x" } ],
          "timing" => { "min_ms" => min_ms, "pad_ms" => 0, "transition" => { "type" => "cut", "ms" => 0 } } }
    s["element"]["steps"] = steps if steps
    s["narration"] = { "text" => narration, "measured_ms" => 0 } if narration
    s
  end

  def statement(id, land, **extra) = { "id" => id, "type" => "statement", "lines" => [ "Line #{id}" ], "land_at" => land }.merge(extra.transform_keys(&:to_s))

  def board_with(*scenes) = { "schema_version" => 1, "slug" => "t", "title" => "T", "viewport" => { "w" => 1920, "h" => 1080, "dpr" => 1 },
                              "music" => nil, "scenes" => scenes }

  def errors(s) = WalkthroughStoryboard.validate(board_with(s)).grep(/element|"s1"/)

  # -- validation ------------------------------------------------------------

  def test_example_board_validates_and_defaults_to_60_fps
    b = board
    assert_empty WalkthroughStoryboard.validate(b, root: File.dirname(EXAMPLE))
    assert_empty WalkthroughStoryboard.warnings(b)
    assert_equal 60, PrototypeCapture.board_fps(b)
    assert_includes WalkthroughStoryboard::SCENE_KINDS, "element"
  end

  def test_beat_shapes_are_checked
    beats = [ { "id" => "a", "type" => "poster", "land_at" => 100 }, { "id" => "b", "type" => "statement", "lines" => [ "x" * 37 ], "land_at" => 200 },
              { "id" => "c", "type" => "card", "land_at" => 300 }, { "id" => "d", "type" => "cursor", "rows" => %w[one two], "click" => 3, "land_at" => 400 },
              { "id" => "e", "type" => "number", "value" => "7", "land_at" => 500 }, { "id" => "f", "type" => "statement", "lines" => [ "y" ] } ]
    errs = errors(scene(beats: beats)).join("\n")
    assert_match(/beat "a": type must be one of statement, card, number, line, cursor/, errs)
    assert_match(/beat "b": statement line .* at most 36 characters/, errs)
    assert_match(/beat "c": title must be/, errs)
    assert_match(/beat "d": click must be a row number in 1..2/, errs)
    assert_match(/beat "e": value must be a number/, errs)
    assert_match(/beat "f": land_at is required/, errs)
  end

  def test_an_element_scene_refuses_screen_store_and_interactions
    s = scene.merge("screen" => { "html" => "x.html" }, "interactions" => [], "store" => {})
    errs = errors(s).join("\n")
    %w[screen store interactions].each { |k| assert_match(/takes no #{k}/, errs) }
  end

  def test_steps_name_a_beat_of_their_kind_and_take_one_time
    beats = [ statement("a", 500), { "id" => "n", "type" => "number", "value" => 0, "land_at" => 1000 } ]
    steps = [ { "op" => "count", "id" => "a", "t_ms" => 1000, "from" => 0, "to" => 9 },
              { "op" => "draw", "id" => "n", "t_ms" => 1000 },
              { "op" => "count", "id" => "n", "t_ms" => 1000, "at" => { "word" => "go" }, "from" => 0, "to" => 9 },
              { "op" => "count", "id" => "n", "t_ms" => 1000, "from" => 0, "to" => 9, "format" => { "decimals" => 9 } } ]
    errs = errors(scene(beats: beats, steps: steps)).join("\n")
    assert_match(/step 0: count needs id naming a number beat/, errs)
    assert_match(/step 1: draw needs id naming a line beat/, errs)
    assert_match(/step 2: takes exactly one of t_ms or at/, errs)
    assert_match(/step 3: format.decimals must be an integer in 0..4/, errs)
  end

  def test_anchors_need_narration
    s = scene(beats: [ statement("a", { "word" => "ship" }) ])
    assert_includes errors(s).join("\n"), "an op with at needs this scene to have narration"
  end

  # -- windows ---------------------------------------------------------------

  def windows(beats, min_ms: 6000) = WalkthroughElement.windows(scene(beats: beats, min_ms: min_ms))

  def test_entrance_ends_on_land_and_exit_starts_at_the_next_entrance
    w = windows([ statement("a", 1000), statement("b", 3000, enter_ms: 600, exit_ms: 200) ])
    a, b = w[:windows]
    assert_equal [ 600, 1000, 2400, 2700 ], a.values_at("enter_ms", "land_ms", "exit_start_ms", "exit_end_ms")
    assert_equal [ 2400, 3000, nil, nil ], b.values_at("enter_ms", "land_ms", "exit_start_ms", "exit_end_ms")
    assert_empty w[:warnings]
    assert_empty w[:errors]
  end

  def test_entrance_before_scene_start_clamps_with_a_warning_and_still_lands
    w = windows([ statement("a", 150) ])
    assert_equal [ 0, 150 ], w[:windows].first.values_at("enter_ms", "land_ms")
    assert_match(/beat "a": entrance would start at -250 ms, before 0 ms; clamped to 0 ms \(it still lands at 150 ms\)/, w[:warnings].first)
  end

  def test_entrance_clamps_to_the_previous_explicit_exit_end
    w = windows([ statement("a", 500, exit_at: 1500), statement("b", 1900) ])
    assert_equal [ 1800, 1900 ], w[:windows].last.values_at("enter_ms", "land_ms")
    assert_match(/beat "b": entrance would start at 1500 ms, before 1800 ms; clamped to 1800 ms/, w[:warnings].first)
    assert_empty w[:errors]
  end

  def test_window_errors_name_the_beat
    errs = windows([ statement("a", 500, exit_at: 400), statement("b", 300), statement("c", 7000) ])[:errors].join("\n")
    assert_match(/beat "a": exit_at 400 ms must be after its landing \(500 ms\)/, errs)
    assert_match(/beat "b": lands at 300 ms, before the previous beat "a"/, errs)
    assert_match(/beat "c": lands at 7000 ms, past the scene's 6000 ms/, errs)
    errs = windows([ statement("a", 500, exit_at: 5900) ])[:errors].join("\n")
    assert_match(/exits until 6200 ms, past the scene's 6000 ms/, errs)
  end

  # The next entrance would fade this beat out before it ever lands.
  def test_an_implicit_exit_before_the_landing_is_refused
    errs = windows([ statement("a", 1000), statement("b", 1100) ])[:errors].join("\n")
    assert_match(/beat "a": the next beat's entrance starts at 700 ms, before this beat lands \(1000 ms\)/, errs)
    assert_empty windows([ statement("a", 1000), statement("b", 1400) ])[:errors]
  end

  def test_window_errors_fail_validation_and_clamps_warn
    assert_match(/past the scene's 6000 ms/, errors(scene(beats: [ statement("a", 6500) ])).join("\n"))
    b = board_with(scene(beats: [ statement("a", 100) ]))
    assert_empty WalkthroughStoryboard.validate(b)
    assert(WalkthroughStoryboard.warnings(b).any? { |w| w.include?("clamped to 0 ms") })
  end

  def test_plan_is_in_frames_and_lands_on_the_land_frame
    s = scene(beats: [ statement("a", 1000), { "id" => "n", "type" => "number", "value" => 0, "land_at" => 3000 } ],
              steps: [ { "op" => "count", "id" => "n", "t_ms" => 3000, "from" => 0, "to" => 1280 } ])
    plan = WalkthroughElement.plan(s, board_with(s))
    assert_equal 60, plan["fps"]
    a, n = plan["beats"]
    assert_equal [ 36, 60, 156, 174 ], a.values_at("enter_f", "land_f", "exit_f", "exit_end_f")
    assert_equal 180, n["land_f"]
    assert_equal({ "op" => "count", "id" => "n", "from" => 0, "to" => 1280, "t_f" => 180, "dur_f" => 72 }, plan["steps"].first)
  end

  # -- anchors ---------------------------------------------------------------

  # A synthetic alignment: each character of the text takes 50 ms.
  def seed_alignment(cache, b, s)
    text = s.dig("narration", "text")
    starts = text.chars.each_index.map { |i| i * 0.05 }
    dest = WalkthroughCache.path(cache, :audio, WalkthroughStoryboard.audio_key(b, s), "alignment.json")
    FileUtils.mkdir_p(File.dirname(dest))
    File.write(dest, JSON.generate("characters" => text.chars, "character_start_times_seconds" => starts,
                                   "character_end_times_seconds" => starts.map { |t| t + 0.05 }))
  end

  def test_beat_and_step_anchors_resolve_and_the_authored_copy_drops_them
    s = scene(narration: "We ship the gate today",
              beats: [ statement("a", { "word" => "ship" }), { "id" => "n", "type" => "number", "value" => 0, "land_at" => { "word" => "today" } } ],
              steps: [ { "op" => "count", "id" => "n", "at" => { "word" => "gate" }, "from" => 0, "to" => 5 } ])
    b = board_with(s)
    assert_empty WalkthroughStoryboard.validate(b)
    assert WalkthroughStoryboard.unresolved?(s)
    Dir.mktmpdir do |cache|
      seed_alignment(cache, b, s)
      WalkthroughStoryboard.resolve_anchors(b, cache)
    end
    beats = s["element"]["beats"]
    # "ship" starts at char 3 (150 ms), "gate" at char 12 (600 ms), "today" at char 17 (850 ms); snapped to 60 fps frames.
    assert_equal [ 150, 850 ], beats.map { |x| x["land_t_ms"] }
    assert_equal 600, s["element"]["steps"].first["t_ms"]
    refute WalkthroughStoryboard.unresolved?(s)
    assert_equal 9, WalkthroughElement.plan(s, b)["beats"].first["land_f"]
    authored = WalkthroughStoryboard.authored(b)["scenes"].first["element"]
    refute(authored["beats"].any? { |x| x.key?("land_t_ms") })
    refute authored["steps"].first.key?("t_ms")
  end

  def test_an_anchored_beat_past_the_scene_fails_resolution
    s = scene(min_ms: 500, narration: "We ship the gate today", beats: [ statement("a", { "word" => "today" }) ])
    b = board_with(s)
    Dir.mktmpdir do |cache|
      seed_alignment(cache, b, s)
      err = assert_raises(WalkthroughStoryboard::ValidationError) { WalkthroughStoryboard.resolve_anchors(b, cache) }
      assert_match(/beat "a": lands at 850 ms, past the scene's/, err.message)
    end
  end

  def test_an_unresolved_scene_has_no_page_yet
    s = scene(narration: "We ship", beats: [ statement("a", { "word" => "ship" }) ])
    assert_raises(WalkthroughElement::TimingError) { WalkthroughElement.plan(s, board_with(s)) }
    assert_raises(ArgumentError) { PrototypeCapture.prepare(board_with(s), s, Dir.pwd) }
  end

  # -- the page --------------------------------------------------------------

  def test_page_is_deterministic_and_self_contained
    b = board
    s = b["scenes"].first
    root = File.dirname(EXAMPLE)
    a = WalkthroughElement.screen(s, root: root, board: b)
    assert_equal a, WalkthroughElement.screen(s, root: root, board: b)
    assert_includes a, File.read(WalkthroughDiagram::EASE)
    assert_includes a, File.read(WalkthroughElement::RUNTIME)
    refute_match(/<script[^>]+src=|<link/, a)
    prep = PrototypeCapture.prepare(b, s, File.dirname(EXAMPLE))
    assert_equal a, PrototypeCapture.prepared_html(prep)
    assert_nil PrototypeCapture.skip_reason(s)
  end

  # Frame time comes from the capture clock's frame number only.
  def test_runtime_reads_no_wall_clock
    js = File.read(WalkthroughElement::RUNTIME) + File.read(WalkthroughDiagram::EASE)
    hit = js[/Date\.now|new Date|setTimeout|setInterval|transition:|animation:/]
    assert_nil hit, "the element runtime reads wall time or runs CSS motion (#{hit.inspect})"
    assert js.include?("Math.round((now * FPS) / 1000) - 1"), "frame number from the capture clock"
  end

  # -- capture (Docker) --------------------------------------------------------

  def capture(session, html, out, duration, viewport)
    PrototypeCapture.capture(session: session, html: html, interactions: [], duration_ms: duration, out_dir: out, state: {},
                             prng_seed: 1, viewport: viewport, fps: 60, label: "element")
    Dir[File.join(out, "*.png")].sort
  end

  def test_two_captures_give_identical_frames_and_the_beat_lands_on_its_frame
    skip "docker not available" unless ChangeDocker.available?

    b = board
    s = b["scenes"].first
    s["timing"]["min_ms"] = 1000
    s["element"]["beats"] = [ s["element"]["beats"].first ]
    s["element"].delete("steps")
    html = WalkthroughElement.screen(s, board: b)
    land = WalkthroughElement.plan(s, b)["beats"].first["land_f"]
    Dir.mktmpdir do |root|
      ChangeDocker.with_browserless(network: nil) do |session|
        a, c = 2.times.map { |n| capture(session, html, File.join(root, "run-#{n}"), 1000, b["viewport"]) }
        hashes = ->(list) { list.map { |f| Digest::SHA256.file(f).hexdigest } }
        assert_equal hashes.(a), hashes.(c), "element frames differ between captures"
        assert_equal Digest::SHA256.file(a[land]).hexdigest, Digest::SHA256.file(a[land + 1]).hexdigest, "the beat is fully entered on its land frame"
        refute_equal Digest::SHA256.file(a[land - 1]).hexdigest, Digest::SHA256.file(a[land]).hexdigest, "the entrance is still moving the frame before"
        boxes = JSON.parse(File.read(File.join(root, "run-0", "boxes.json")))
        node = ->(i) { boxes["frames"][i]["boxes"].find { |x| x["kind"] == "node" } }
        assert_operator node.(land - 1)["w"], :<, node.(land)["w"], "scaled in until the land frame"
        assert_equal node.(land)["w"], node.(land + 10)["w"]
        assert_empty WalkthroughClipcheck.check("element", boxes)[:refusals]
      end
    end
  end
end
