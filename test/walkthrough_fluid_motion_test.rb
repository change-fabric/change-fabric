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
    last = [ { "t_ms" => 0, "op" => "tap", "target" => "#next", "navigate" => true }, { "t_ms" => 100, "op" => "wait", "duration_ms" => 100 } ]
    assert_includes errors(nav_board(first_ops: last)), "must be the last interaction"
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
    early = [ { "t_ms" => 0, "op" => "tap", "target" => "#a", "press_ms" => 1000 },
              { "t_ms" => 100, "op" => "tap", "target" => "#next", "press_ms" => 100, "navigate" => true } ]
    assert_includes errors(nav_board(first_ops: early)), "must release after every other tap"
    early[0]["press_ms"] = 50
    refute_includes errors(nav_board(first_ops: early)), "must release after every other tap"
    gliding = [ { "t_ms" => 0, "op" => "scroll", "target" => "html", "dy" => 200, "ms" => 900 },
                { "t_ms" => 100, "op" => "tap", "target" => "#next", "press_ms" => 100, "navigate" => true } ]
    assert_includes errors(nav_board(first_ops: gliding)), "after every glide in its scene ends"
    gliding[1]["t_ms"] = 800
    refute_includes errors(nav_board(first_ops: gliding)), "after every glide"
    refute_includes errors(nav_board(first_ops: early)), "must release after every other tap"
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
    assert_equal "#buy", plan[9]["press"]
    assert_equal 9 + 4, plan.index { |e| e["tap"] }, "default 120 ms press is 4 frames at 30 fps"
    assert_equal([ { "target" => "#buy", "navigate" => false } ], plan[13]["tap"])
    long = PrototypeCapture.schedule([ { "t_ms" => 0, "op" => "tap", "target" => "#x", "press_ms" => 5000, "navigate" => true } ], 10)
    assert_equal([ { "target" => "#x", "navigate" => true } ], long.last["tap"], "a press longer than the scene releases on its last frame")
    assert_includes PrototypeUxLint.lint_frames(plan, 30), 13
  end

  def test_overlapping_glides_on_one_target_are_rejected
    ops = [ { "t_ms" => 0, "op" => "scroll", "target" => "#feed", "dy" => 300, "ms" => 900 },
            { "t_ms" => 100, "op" => "scroll", "target" => "#feed", "dy" => 100, "ms" => 100 } ]
    assert_includes errors(board([ live("one", 1, "interactions" => ops) ])), "glides on #feed overlap"
    ops[1]["t_ms"] = 900
    refute_includes errors(board([ live("one", 1, "interactions" => ops) ])), "overlap"
    ops[1]["t_ms"] = 100
    ops[1]["target"] = "#side"
    refute_includes errors(board([ live("one", 1, "interactions" => ops) ])), "overlap"
  end

  def test_glides_on_two_devices_never_overlap
    glide = { "t_ms" => 0, "op" => "scroll", "target" => "html", "dy" => 300, "ms" => 900 }
    scene = live("one", 1, "interactions" => { "desktop" => [ glide ], "phone" => [ glide ] }).except("device")
    assert_empty WalkthroughStoryboard.glide_overlap_errors(scene)
  end

  def test_overlapping_glides_on_two_targets_both_run
    plan = PrototypeCapture.schedule([ { "t_ms" => 0, "op" => "scroll", "target" => "#feed", "dy" => 300, "ms" => 900 },
                                       { "t_ms" => 100, "op" => "scroll", "target" => "#side", "dy" => 50, "ms" => 900 } ], 40)
    assert_equal 300.0, plan[26]["glide"].find { |g| g["target"] == "#feed" }["dy"]
    assert_equal %w[#feed #side], plan[10]["glide"].map { |g| g["target"] }
  end

  def test_navigate_waits_for_the_destination_before_exporting
    js = WalkthroughLive.run_device_js(nav_board, nav_board["scenes"][0])
    assert_includes js, "while (page.url() === tapped.from"
    assert_includes js, "out.tap = Object.assign({ x: tapped.x, y: tapped.y }"
  end

  def test_ripple_carries_across_a_navigate_cut
    rect = WalkthroughDevice::Rect.new(name: "phone", scale: 1.0, x: 0, y: 0, w: 390, h: 693, bezel: 0)
    still = Array.new(12) { { "x" => 50, "y" => 60, "down" => false } }
    assert_equal WalkthroughDevice.hidden_path(12), WalkthroughDevice.ripple_path(rect, still, 10)
    carried = [ still.first.merge("carry" => 4) ] + still.drop(1)
    path = WalkthroughDevice.ripple_path(rect, carried, 10)
    shown = path.each_index.select { |i| path[i]["x"] == 45 }
    assert_equal (0..4).to_a, shown, "the ripple finishes its 9 frames: 4 before the cut, 5 after"
    js = WalkthroughLive.run_device_js(nav_board, nav_board["scenes"][1])
    assert_includes js, "carry: entered.age"
  end

  def test_taps_releasing_on_one_frame_both_land
    plan = PrototypeCapture.schedule([ { "t_ms" => 0, "op" => "tap", "target" => "#a", "press_ms" => 200 },
                                       { "t_ms" => 100, "op" => "tap", "target" => "#b", "press_ms" => 100 } ], 20)
    assert_equal %w[#a #b], plan[6]["tap"].map { |t| t["target"] }
  end

  def test_navigate_url_check_canonicalizes
    js = WalkthroughLive.run_device_js(nav_board, nav_board["scenes"][1])
    assert_includes js, "canon(session.url) !== canon(job.url)"
    assert_includes js, "new URL(u).href"
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
    js = PrototypeCapture.function_module(html: "<p>x</p>", plan: [], range: 0...1, viewport: nil, prng_seed: 1, state: {})
    assert_includes js, "if (step.press)"
    assert_includes js, "__cf-pressed"
    assert_includes PrototypeCapture::PRESS_CSS, "scale: 0.96 !important"
    live_js = WalkthroughLive.run_device_js(board([ live("a", 1) ]), live("a", 1))
    assert_includes live_js, "if (step.press)"
    assert_includes live_js, "page.touchscreen.tap(pos.x, pos.y)"
  end

  # -- tap-to-navigate -----------------------------------------------------

  def test_navigate_tap_hands_its_point_to_the_next_scene
    b = nav_board
    js = WalkthroughLive.run_device_js(b, b["scenes"][1])
    assert_includes js, "if (tap.navigate) tapped = { x: pos.x, y: pos.y, from: page.url(),"
    assert_includes js, "if (tapped) out.tap = Object.assign("
    assert_includes js, "let pos = entered ? { x: entered.x, y: entered.y }"
    assert_includes js, "tap-navigate landed on"
    plan = WalkthroughLive.job(b, b["scenes"][0], WalkthroughDevice.specs(b, b["scenes"][0]).first,
                               WalkthroughLive::Secrets.new([]), compose: nil, shots: true)["plan"]
    assert_equal([ { "target" => "#next", "navigate" => true } ], plan[34]["tap"])
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
    assert_equal 3, PrototypeCapture::CAPTURE_VERSION
    assert_equal 3, WalkthroughLive::CAPTURE_VERSION
  end
end
