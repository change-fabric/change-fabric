# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../scripts/walkthrough_render"

# Fluid phone motion: gliding scrolls (one eased offset per frame), taps
# with a pressed state before the real click, and a tap that navigates
# straight into the next scene with the cursor carried across the cut.
class WalkthroughFluidMotionTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/walkthrough", __dir__)
  LEGACY_PLAN_KEYS = %w[frame move hover click dblclick type key scroll].freeze

  def live(id, order, extra = {})
    { "id" => id, "order" => order, "title" => id, "device" => "phone-fullbleed",
      "screen" => { "url" => "https://app.localhost/#{id}" },
      "narration" => { "text" => "Scene #{id} speaks.", "measured_ms" => 0 },
      "assumptions" => [ { "id" => "A-0#{order}", "text" => "x" } ],
      "timing" => { "min_ms" => 2000, "pad_ms" => 200 } }.merge(extra)
  end

  def board(scenes)
    { "schema_version" => 1, "slug" => "demo", "title" => "Demo", "fps" => 30,
      "viewport" => { "w" => 1080, "h" => 1920 },
      "voice" => { "voice_id" => "v1", "model" => "eleven_multilingual_v2", "output_format" => "mp3_44100_128" },
      "music" => nil, "scenes" => scenes }
  end

  def nav_board(first_ops: nil, second: {})
    ops = first_ops || [ { "t_ms" => 0, "op" => "scroll", "target" => "html", "dy" => 220, "ms" => 900, "ease" => "ease-in-out" },
                         { "t_ms" => 1000, "op" => "tap", "target" => "#next", "navigate" => true } ]
    board([ live("feed", 1, "interactions" => ops),
            live("detail", 2, { "session_from_scene" => "feed" }.merge(second)) ])
  end

  def errors(b) = WalkthroughStoryboard.validate(b).join("\n")

  # -- validation --------------------------------------------------------

  def test_valid_glide_and_navigate_tap
    assert_empty WalkthroughStoryboard.validate(nav_board)
  end

  def test_glide_and_tap_shapes_are_validated
    bad = [
      [ { "op" => "scroll", "target" => "html", "dy" => 10, "ms" => 0 }, "scroll ms must be an integer in 1..10000" ],
      [ { "op" => "scroll", "target" => "html", "dy" => 10, "ms" => 1.5 }, "scroll ms must be an integer" ],
      [ { "op" => "scroll", "target" => "html", "ms" => 400 }, "needs dx or dy" ],
      [ { "op" => "scroll", "target" => "html", "dy" => 10, "ease" => "ease-in" }, "scroll ease needs ms" ],
      [ { "op" => "scroll", "target" => "html", "dy" => 10, "ms" => 400, "ease" => "bounce" }, "scroll ease must be one of" ],
      [ { "op" => "tap", "target" => "#a", "press_ms" => 0 }, "tap press_ms must be an integer in 1..1000" ],
      [ { "op" => "tap", "target" => "#a", "navigate" => "yes" }, "tap navigate must be true or false" ],
      [ { "op" => "tap", "target" => "#a", "ms" => 200 }, "ms applies only to a scroll op" ],
      [ { "op" => "click", "target" => "#a", "press_ms" => 200 }, "press_ms applies only to a tap op" ],
      [ { "op" => "tap" }, "target is required for tap" ]
    ]
    bad.each do |op, want|
      b = board([ live("one", 1, "interactions" => [ { "t_ms" => 0 }.merge(op) ]) ])
      assert_includes errors(b), want, op.inspect
    end
  end

  def test_navigate_tap_rules
    after = [ { "t_ms" => 0, "op" => "tap", "target" => "#next", "navigate" => true }, { "t_ms" => 200, "op" => "hover", "target" => "#x" } ]
    assert_includes errors(nav_board(first_ops: after)), "a navigate tap must be the last input: op 1 (hover #x)"
    # A wait acts on nothing, so it may follow the navigate.
    waits = [ { "t_ms" => 0, "op" => "tap", "target" => "#next", "navigate" => true }, { "t_ms" => 300, "op" => "wait", "duration_ms" => 100 } ]
    refute_includes errors(nav_board(first_ops: waits)), "last input"
    assert_includes errors(nav_board(second: { "session_from_scene" => nil, "persona" => nil })), "next scene to be live with session_from_scene \"feed\""
    alone = board([ live("feed", 1, "interactions" => [ { "t_ms" => 0, "op" => "tap", "target" => "#n", "navigate" => true } ]) ])
    assert_includes errors(alone), "next scene to be live"
    proto = { "id" => "p", "order" => 1, "title" => "p", "screen" => { "html" => "screens/p.html" },
              "interactions" => [ { "t_ms" => 0, "op" => "tap", "target" => "#n", "navigate" => true } ],
              "narration" => { "text" => "x", "measured_ms" => 0 }, "assumptions" => [ { "id" => "A-1", "text" => "x" } ] }
    assert_includes errors(board([ proto ])), "a navigate tap needs a live scene"
    b = nav_board
    b["scenes"] << live("later", 3, "session_from_scene" => "feed")
    assert_includes errors(b), "only the next scene may start from a navigate tap's session (later)"
    # A press that releases on the navigate frame acts on the destination.
    early = [ { "t_ms" => 0, "op" => "tap", "target" => "#a", "press_ms" => 200 },
              { "t_ms" => 100, "op" => "tap", "target" => "#next", "press_ms" => 100, "navigate" => true } ]
    assert_includes errors(nav_board(first_ops: early)), "op 0 (release #a) acts at frame 6, on or after the navigate at frame 6"
    early[0]["press_ms"] = 50
    refute_includes errors(nav_board(first_ops: early)), "last input"
    gliding = [ { "t_ms" => 0, "op" => "scroll", "target" => "html", "dy" => 200, "ms" => 900 },
                { "t_ms" => 100, "op" => "tap", "target" => "#next", "press_ms" => 100, "navigate" => true } ]
    assert_includes errors(nav_board(first_ops: gliding)), "op 0 (glide_step html) acts at frame 6"
    gliding[1]["t_ms"] = 800
    refute_includes errors(nav_board(first_ops: gliding)), "last input"
  end

  # E1: the last character lands on the release frame of the navigate.
  def test_input_on_the_navigate_frame_is_rejected
    ops = [ { "t_ms" => 1000, "op" => "type", "target" => "#q", "text" => "abcd", "cps" => 30 },
            { "t_ms" => 1000, "op" => "tap", "target" => "#next", "press_ms" => 100, "navigate" => true } ]
    assert_includes errors(nav_board(first_ops: ops)), "op 0 (type_char #q) acts at frame 33, on or after the navigate at frame 33"
    %w[click key move].each do |kind|
      late = { "t_ms" => 1100, "op" => kind, "target" => "#x", "keys" => "a", "duration_ms" => 0 }
      assert_includes errors(nav_board(first_ops: [ late, ops[1] ])), "last input", kind
    end
  end

  # E2 and E3 on a whole board.
  def test_scroll_inside_a_glide_and_a_late_release_are_rejected
    ops = [ { "t_ms" => 0, "op" => "scroll", "target" => "#feed", "dy" => 300, "ms" => 900 },
            { "t_ms" => 400, "op" => "scroll", "target" => "#feed", "dy" => 50 } ]
    assert_includes errors(board([ live("one", 1, "interactions" => ops) ])), "scrolls on #feed overlap"
    late = [ { "t_ms" => 2100, "op" => "tap", "target" => "#a", "press_ms" => 200 } ]
    assert_includes errors(board([ live("one", 1, "interactions" => late) ])), "op 0 (tap #a) releases at frame 69, past the scene's last frame 59"
  end

  # Decision 7: the next scene leads with, and films only, the tapping device.
  def test_navigate_needs_the_same_device_next
    b = nav_board(second: { "device" => "desktop" })
    assert_includes errors(b), "needs the next scene \"detail\" to lead with phone, not desktop"
    b = nav_board
    b["scenes"][1].delete("device")
    b["scenes"][1]["devices"] = %w[phone desktop]
    b["scenes"][1]["layout"] = "side_by_side"
    b["phone"] = { "w" => 390, "h" => 844, "dpr" => 2 }
    assert_includes errors(b), "films only the tapping device (phone), not desktop"
    assert_empty WalkthroughStoryboard.validate(nav_board)
  end

  def test_chained_navigate_and_a_transition_longer_than_its_scene_are_rejected
    b = nav_board(second: { "interactions" => [ { "t_ms" => 0, "op" => "tap", "target" => "#more", "navigate" => true } ] })
    b["scenes"] << live("more", 3, "session_from_scene" => "detail")
    assert_includes errors(b), "the scene after a navigate tap cannot navigate again"
    short = nav_board(second: { "timing" => { "min_ms" => 300, "pad_ms" => 0, "transition" => { "type" => "push", "ms" => 1500 } } })
    assert_includes errors(short), "the transition into this scene overlaps 45 frames, longer than the scene's 9"
  end

  # CODEX-2: a shared list gives the phone the navigate tap too, and on a
  # cut its release lands one frame past the trimmed scene.
  def test_shared_navigate_on_two_devices_is_rejected
    b = nav_board
    feed = b["scenes"][0]
    feed.delete("device")
    feed["devices"] = %w[desktop phone]
    feed["layout"] = "side_by_side"
    feed["interactions"] = [ { "t_ms" => 1000, "op" => "tap", "target" => "#next", "navigate" => true } ]
    b["scenes"][1]["device"] = "desktop"
    b["phone"] = { "w" => 390, "h" => 844, "dpr" => 2 }
    assert_includes errors(b), "phone: op 0 (tap #next) releases at frame 34, past the scene's last frame 33"
    feed["interactions"] = { "desktop" => [ { "t_ms" => 1000, "op" => "tap", "target" => "#next", "navigate" => true } ],
                             "phone" => [ { "t_ms" => 300, "op" => "tap", "target" => "#a" } ] }
    refute_includes errors(b), "trimmed to the navigate tap"
  end

  # Decision 10: the tapping scene ends at the tap plus the overlap, and its
  # voice line must end by the tap.
  def test_tapping_scene_is_trimmed_to_the_tap_and_narration_must_fit
    b = nav_board
    feed = b["scenes"][0]
    assert_equal 34, PrototypeCapture.frame_count(WalkthroughLive.duration_ms(b, feed), 30), "cut at frame 34, no overlap"
    b["transition"] = { "type" => "push", "ms" => 300 }
    assert_equal 34 + 9, PrototypeCapture.frame_count(WalkthroughLive.duration_ms(b, feed), 30), "plus a 300 ms push"
    timeline = WalkthroughStoryboard.timeline(b)["scenes"]
    assert_equal 34, timeline[1]["start_frame"], "the next scene starts on the tap's release frame"
    feed["narration"]["measured_ms"] = 1200
    assert_includes errors(b), "narration no longer fits: the scene is trimmed to its navigate tap at 1133 ms"
    feed["narration"]["measured_ms"] = 1100
    refute_includes errors(b), "narration no longer fits"
    (0..300).each do |n|
      ms = WalkthroughTimeline.frames_ms(n, 30)
      assert_equal n, PrototypeCapture.frame_count(ms, 30), n.to_s
      assert_equal n, PrototypeCapture.frame_count(WalkthroughTimeline.frames_ms(n, 24), 24), "24 fps #{n}"
    end
  end

  # -- easing ------------------------------------------------------------

  def test_css_easings_are_the_real_cubic_bezier_curves
    assert_in_delta 0.5, PrototypeCapture.ease("ease-in-out", 0.5), 1e-9
    # Reference values of cubic-bezier(0.42, 0, 0.58, 1), symmetric about 0.5.
    assert_in_delta 0.129, PrototypeCapture.ease("ease-in-out", 0.25), 0.002
    assert_in_delta 1 - PrototypeCapture.ease("ease-in-out", 0.25), PrototypeCapture.ease("ease-in-out", 0.75), 1e-9
    assert_in_delta 0.0, PrototypeCapture.ease("ease-in", 0.0), 1e-12
    assert_in_delta 1.0, PrototypeCapture.ease("ease-out", 1.0), 1e-12
    assert_operator PrototypeCapture.ease("ease-out", 0.25), :>, 0.25
    assert_operator PrototypeCapture.ease("ease-in", 0.25), :<, 0.25
    # ease (0.25, 0.1, 0.25, 1) at x 0.5 is about 0.8024.
    assert_in_delta 0.8024, PrototypeCapture.ease("ease", 0.5), 0.001
  end

  def test_glide_frames_step_scroll_offsets_on_the_curve
    plan = PrototypeCapture.schedule([ { "t_ms" => 100, "op" => "scroll", "target" => "html", "dy" => 220, "ms" => 900 } ], 40)
    glides = plan.each_index.select { |i| plan[i]["glide"] }
    assert_equal (3..29).to_a, glides, "27 frames of a 900 ms glide at 30 fps from frame 3"
    dys = glides.map { |i| plan[i]["glide"][0]["dy"] }
    assert_equal 220.0, dys.last
    assert plan[3]["glide"][0]["first"]
    refute plan[4]["glide"][0]["first"]
    assert_nil plan[3]["scroll"], "a glide never jumps"
    steps = dys.each_cons(2).map { |a, b| b - a }
    assert steps.all?(&:positive?), "monotonic"
    assert_operator steps[13], :>, steps[0] * 3, "eased: fast in the middle, slow at the ends"
    want = (1..27).map { |k| (220 * PrototypeCapture.cubic_bezier(0.42, 0, 0.58, 1, k / 27.0)).round(2) }
    assert_equal want, dys
    lin = PrototypeCapture.schedule([ { "t_ms" => 0, "op" => "scroll", "target" => "html", "dy" => 90, "ms" => 100, "ease" => "linear" } ], 5)
    assert_equal [ 30.0, 60.0, 90.0 ], lin.first(3).map { |e| e["glide"][0]["dy"] }
  end

  # -- taps --------------------------------------------------------------

  def test_tap_presses_then_releases_into_a_real_click
    plan = PrototypeCapture.schedule([ { "t_ms" => 300, "op" => "tap", "target" => "#buy" } ], 30)
    assert_equal [ "#buy" ], plan[9]["press"]
    assert_equal 9 + 4, plan.index { |e| e["tap"] }, "default 120 ms press is 4 frames at 30 fps"
    assert_equal([ { "target" => "#buy", "navigate" => false } ], plan[13]["tap"])
    long = PrototypeCapture.schedule([ { "t_ms" => 0, "op" => "tap", "target" => "#x", "press_ms" => 5000, "navigate" => true } ], 10)
    assert(long.none? { |e| e["tap"] }, "a release past the scene's end never lands (validation rejects it)")
    assert_includes PrototypeUxLint.lint_frames(plan, 30), 13
  end

  def test_overlapping_glides_on_one_target_are_rejected
    ops = [ { "t_ms" => 0, "op" => "scroll", "target" => "#feed", "dy" => 300, "ms" => 900 },
            { "t_ms" => 100, "op" => "scroll", "target" => "#feed", "dy" => 100, "ms" => 100 } ]
    assert_includes errors(board([ live("one", 1, "interactions" => ops) ])), "scrolls on #feed overlap"
    ops[1]["t_ms"] = 900
    refute_includes errors(board([ live("one", 1, "interactions" => ops) ])), "overlap"
    ops[1]["t_ms"] = 100
    ops[1]["target"] = "#side"
    refute_includes errors(board([ live("one", 1, "interactions" => ops) ])), "overlap"
  end

  def test_glides_on_two_devices_never_overlap
    glide = { "t_ms" => 0, "op" => "scroll", "target" => "html", "dy" => 300, "ms" => 900 }
    scene = live("one", 1, "interactions" => { "desktop" => [ glide ], "phone" => [ glide ] }).except("device")
    assert_empty WalkthroughStoryboard.timeline_errors(scene, board([ scene ]))
  end

  def test_overlapping_glides_on_two_targets_both_run
    plan = PrototypeCapture.schedule([ { "t_ms" => 0, "op" => "scroll", "target" => "#feed", "dy" => 300, "ms" => 900 },
                                       { "t_ms" => 100, "op" => "scroll", "target" => "#side", "dy" => 50, "ms" => 900 } ], 40)
    assert_equal 300.0, plan[26]["glide"].find { |g| g["target"] == "#feed" }["dy"]
    assert_equal %w[#feed #side], plan[10]["glide"].map { |g| g["target"] }
  end

  def test_ripple_carries_across_a_navigate_cut
    rect = WalkthroughDevice::Rect.new(name: "phone", scale: 1.0, x: 0, y: 0, w: 390, h: 693, bezel: 0)
    still = Array.new(12) { { "x" => 50, "y" => 60, "down" => false } }
    assert_equal WalkthroughDevice.hidden_path(12), WalkthroughDevice.ripple_path(rect, still, 10)
    carried = [ still.first.merge("carry" => 4) ] + still.drop(1)
    path = WalkthroughDevice.ripple_path(rect, carried, 10)
    shown = path.each_index.select { |i| path[i]["x"] == 45 }
    assert_equal (0..4).to_a, shown, "the ripple finishes its 9 frames: 4 before the cut, 5 after"
  end

  def test_presses_starting_on_one_frame_both_show
    plan = PrototypeCapture.schedule([ { "t_ms" => 0, "op" => "tap", "target" => "#a" }, { "t_ms" => 10, "op" => "tap", "target" => "#b" } ], 10)
    assert_equal %w[#a #b], plan[0]["press"]
  end

  def test_typing_must_finish_before_a_navigate_tap
    ops = [ { "t_ms" => 0, "op" => "type", "target" => "#q", "text" => "abcdefghij", "cps" => 5 },
            { "t_ms" => 100, "op" => "tap", "target" => "#next", "press_ms" => 100, "navigate" => true } ]
    assert_includes errors(nav_board(first_ops: ops)), "op 0 (type_char #q) acts at frame 6"
    # The old ms check let the last character share the release frame.
    ops[1]["t_ms"] = 1700
    assert_includes errors(nav_board(first_ops: ops)), "op 0 (type_char #q) acts at frame 54, on or after the navigate at frame 54"
    ops[1]["t_ms"] = 1800
    refute_includes errors(nav_board(first_ops: ops)), "last input"
  end

  def test_navigate_cut_uses_the_resolved_transition
    b = nav_board.merge("transition" => { "type" => "slide-left", "ms" => 400 })
    assert_equal({ "type" => "slide-left", "ms" => 400, "ease" => "ease-in-out" }, WalkthroughTransition.resolve(b, b["scenes"][1], 1))
    b["scenes"][1]["timing"]["transition"] = { "type" => "push", "ms" => 300, "ease" => "ease-out" }
    assert_equal "push", WalkthroughTransition.resolve(b, b["scenes"][1], 1)["type"]
    b["scenes"][1]["timing"]["transition"] = { "type" => "zoom" }
    assert_includes errors(b), "must be one of"
  end

  def test_taps_releasing_on_one_frame_both_land
    plan = PrototypeCapture.schedule([ { "t_ms" => 0, "op" => "tap", "target" => "#a", "press_ms" => 200 },
                                       { "t_ms" => 100, "op" => "tap", "target" => "#b", "press_ms" => 100 } ], 20)
    assert_equal %w[#a #b], plan[6]["tap"].map { |t| t["target"] }
  end

  def test_navigate_tap_must_come_from_the_session_device
    b = nav_board
    b["scenes"][0].delete("device")
    b["scenes"][0]["devices"] = %w[desktop phone]
    b["scenes"][0]["layout"] = "side_by_side"
    b["scenes"][0]["interactions"] = { "desktop" => [], "phone" => [ { "t_ms" => 0, "op" => "tap", "target" => "#n", "navigate" => true } ] }
    b["phone"] = { "w" => 390, "h" => 844, "dpr" => 2 }
    assert_includes errors(b), "a navigate tap must be in the desktop interactions"
    b["scenes"][0]["interactions"] = { "desktop" => [ { "t_ms" => 0, "op" => "tap", "target" => "#n", "navigate" => true } ], "phone" => [] }
    refute_includes errors(b), "navigate tap must be in"
  end

  def test_press_state_is_injected_only_for_taps
    js = PrototypeCapture.function_module(html: "<p>x</p>", events: [], range: 0...1, viewport: nil, prng_seed: 1, state: {})
    assert_includes js, 'case "press":'
    assert_includes js, "__cf-pressed"
    assert_includes PrototypeCapture::PRESS_CSS, "scale: 0.96 !important"
    live_js = WalkthroughLive.run_device_js(board([ live("a", 1) ]), live("a", 1))
    assert_includes live_js, 'case "press":'
    assert_includes live_js, "page.touchscreen.tap(to.x, to.y)"
  end

  # -- tap-to-navigate -----------------------------------------------------

  # -- the navigate run ------------------------------------------------------

  def run_job(b)
    feed, detail = b["scenes"]
    cut = WalkthroughLive.navigate_cut(b, feed)
    [ WalkthroughLive.run_job(b, feed, detail, WalkthroughDevice.specs(b, feed).first, WalkthroughLive::Secrets.new([]), cut, shots: true), cut ]
  end

  def test_navigate_run_is_one_plan_split_at_the_cut
    b = nav_board(second: { "interactions" => [ { "t_ms" => 300, "op" => "tap", "target" => "#b" } ] })
    job, cut = run_job(b)
    assert_equal({ "device" => "phone", "cut_frame" => 34, "press_frame" => 30, "overlap" => 0, "frames" => 34 }, cut)
    kinds = job["events"].each_with_index.reject { |e, _| e.empty? }.to_h { |e, i| [ i, e.map { |x| x["kind"] } ] }
    assert_equal %w[press], kinds[30]
    assert_equal %w[release navigate], kinds[34], "the tap's release is the cut frame, the next scene's frame 0"
    assert_equal %w[press], kinds[34 + 9], "the next scene's events follow on the run's frames"
    assert_equal %w[release navigate], kinds[34], "the next scene's frame-0 input waits for the painted page"
    assert_equal [], job["entryEvents"]
    assert_equal 34 + 60, job["events"].size
    assert_equal "https://app.localhost/detail", job["expectUrl"]
    assert_nil job["html"], "the page is never reloaded: one goto, for the tapping scene"
    js = WalkthroughLive.run_device_js(b, b["scenes"][0])
    assert_includes js, "tap-navigate never reached the next scene's url"
    refute_includes js, "session.tap", "nothing hands a tap through the exported session"
  end

  def test_navigate_run_splits_into_two_scenes
    run = { "name" => "phone", "ticks" => (0...50).to_a, "cursor" => (0...50).map { |i| { "x" => i, "y" => 7, "down" => i == 30 } },
            "lint" => [ { "frame" => 2 }, { "frame" => 40 } ], "devices" => [], "overlays" => { "a" => 3, "b" => 41 },
            "links" => %w[early late], "linkFrames" => [ 1, 36 ], "session" => { "url" => "u" } }
    cut = { "device" => "phone", "cut_frame" => 34, "press_frame" => 30, "overlap" => 9, "frames" => 43 }
    head, tail = WalkthroughLive::NavigateRun.split(run, cut)
    assert_equal (0...34).to_a + ([ 33 ] * 9), head["ticks"], "the tapping scene holds its last frame before the tap through the overlap"
    assert_equal 43, head["cursor"].size
    assert_equal [ { "frame" => 2 } ], head["lint"]
    assert_equal({ "a" => 3 }, head["overlays"])
    assert_equal %w[early], head["links"]
    assert_equal (34...50).to_a, tail["ticks"]
    assert_equal({ "x" => 34, "y" => 7, "down" => false, "carry" => 4 }, tail["cursor"].first, "the ripple has shown 4 frames at the cut")
    assert_equal [ { "frame" => 6 } ], tail["lint"]
    assert_equal({ "b" => 7 }, tail["overlays"])
    assert_equal %w[late], tail["links"]
    assert_equal({ "phone" => { "x" => 34, "y" => 7, "ripple_age_at_cut" => 4 } }, WalkthroughLive::NavigateRun.handoff(run, cut))
  end

  def test_navigate_run_shares_one_key
    keys = lambda do |b|
      memo = {}
      b["scenes"].map { |s| WalkthroughLive.prepare(b, s, "/r", memo)[:key] }
    end
    base = keys.call(nav_board)
    later = nav_board(second: { "interactions" => [ { "t_ms" => 300, "op" => "tap", "target" => "#b" } ] })
    changed = keys.call(later)
    refute_equal base[0], changed[0], "the tapping scene recaptures when the next scene changes"
    refute_equal base[1], changed[1]
    moved = nav_board(first_ops: [ { "t_ms" => 1100, "op" => "tap", "target" => "#next", "navigate" => true } ])
    refute_equal base[1], keys.call(moved)[1], "the next scene recaptures when the tapping scene changes"
  end

  def test_render_captures_a_navigate_pair_as_one_run
    Dir.mktmpdir do |root|
      b = nav_board
      b["scenes"] << live("after", 3, "session_from_scene" => "detail")
      calls = []
      capture = lambda do |**kw|
        calls << [ kw[:scene]["id"], kw[:next_scene]&.dig("id"), kw[:out_dir] ? :shots : :replay ]
        { "from" => kw[:next_scene] ? kw[:next_scene]["id"] : kw[:scene]["id"] }
      end
      run = WalkthroughRender::Run.new(root, board: b, out: StringIO.new, providers: { live_capture: capture })
      run.send(:capture_live, :session)
      assert_equal [ [ "feed", "detail", :shots ], [ "after", nil, :shots ] ], calls, "detail is never captured on its own"
      calls.clear
      run.send(:start_session, :session, b["scenes"][2], {})
      assert_equal [ [ "feed", "detail", :replay ] ], calls, "a later scene's session replays the whole run"
    end
  end

  def test_bridge_holds_cursor_and_ripple_still_through_a_push
    push = { "type" => "push", "ms" => 300, "ease" => "ease-in-out" }
    point = ->(f, x) { { "frame" => f, "x" => x, "y" => 50 } }
    plan = { fps: 30, width: 1080, height: 1920,
             scenes: [ { id: "feed", frames: 43, start_frame: 0, transition: WalkthroughTransition::CUT,
                         cursor: (1..43).map { |f| point.call(f, 10) }, taps: nil },
                       { id: "detail", frames: 60, start_frame: 34, transition: push, bridge: true,
                         cursor: (1..60).map { |f| point.call(f, 10) }, taps: (1..60).map { |f| f <= 5 ? point.call(f, 33) : point.call(f, -500) } } ] }
    assert_equal 9, WalkthroughFfmpeg.bridge_frames(plan, 1)
    hidden = WalkthroughFfmpeg.track(plan, 1, :taps).first(9).map { |p| p["x"] }
    assert_equal [ -1000 ] * 9, hidden, "the scene's own layer, which the push moves, draws nothing in the overlap"
    graph = WalkthroughFfmpeg.video_graph(plan).join(";")
    assert_includes graph, "split=3[c0][c1][cb1]", "the bridge has its own cursor sprite"
    assert_match(/\[j1\]\[cb1\]overlay=x='if\(lt\(n,34\),-1000,if\(lt\(n,43\),10,-1000\)\)'/, graph, "drawn on the blended stream, absolute frames 34..42")
    assert_match(/\[cursorb1\]\[rb1\]overlay=x='if\(lt\(n,34\),-1000,if\(lt\(n,39\),33,if\(lt\(n,43\),-500,-1000\)\)\)'/, graph, "the ripple finishes at the tap point")
    plan[:scenes][1].delete(:bridge)
    refute_includes WalkthroughFfmpeg.video_graph(plan).join(";"), "cb1", "only a navigate run bridges"
  end

  def test_new_keys_change_the_frames_key
    base = nav_board(first_ops: [ { "t_ms" => 0, "op" => "scroll", "target" => "html", "dy" => 220 } ])
    keys = [ {}, { "ms" => 900 }, { "ms" => 900, "ease" => "ease" } ].map do |extra|
      b = Marshal.load(Marshal.dump(base))
      b["scenes"][0]["interactions"][0].merge!(extra)
      WalkthroughLive.frames_key(b, b["scenes"][0])
    end
    assert_equal 3, keys.uniq.size
  end

  # -- existing boards ---------------------------------------------------

  def test_existing_boards_plan_exactly_as_before
    Dir[File.join(FIXTURES, "*", "storyboard.json")].each do |path|
      b = JSON.parse(File.read(path))
      WalkthroughStoryboard.scenes(b).each do |scene|
        plan = PrototypeCapture.schedule(WalkthroughLive.all_interactions(scene), 400)
        assert_empty plan.flat_map(&:keys).uniq - LEGACY_PLAN_KEYS, "#{path} #{scene['id']}"
      end
    end
    assert_equal 4, PrototypeCapture::CAPTURE_VERSION
    assert_equal 4, WalkthroughLive::CAPTURE_VERSION
  end
end
