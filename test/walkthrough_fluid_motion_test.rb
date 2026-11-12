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
    dys = glides.map { |i| plan[i]["glide"]["dy"] }
    assert_equal 220.0, dys.last
    assert plan[3]["glide"]["first"]
    refute plan[4]["glide"]["first"]
    assert_nil plan[3]["scroll"], "a glide never jumps"
    steps = dys.each_cons(2).map { |a, b| b - a }
    assert steps.all?(&:positive?), "monotonic"
    assert_operator steps[13], :>, steps[0] * 3, "eased: fast in the middle, slow at the ends"
    want = (1..27).map { |k| (220 * PrototypeCapture.cubic_bezier(0.42, 0, 0.58, 1, k / 27.0)).round(2) }
    assert_equal want, dys
    lin = PrototypeCapture.schedule([ { "t_ms" => 0, "op" => "scroll", "target" => "html", "dy" => 90, "ms" => 100, "ease" => "linear" } ], 5)
    assert_equal [ 30.0, 60.0, 90.0 ], lin.first(3).map { |e| e["glide"]["dy"] }
  end

  # -- taps --------------------------------------------------------------

  def test_tap_presses_then_releases_into_a_real_click
    plan = PrototypeCapture.schedule([ { "t_ms" => 300, "op" => "tap", "target" => "#buy" } ], 30)
    assert_equal "#buy", plan[9]["press"]
    assert_equal 9 + 4, plan.index { |e| e["tap"] }, "default 120 ms press is 4 frames at 30 fps"
    assert_equal({ "target" => "#buy", "navigate" => false }, plan[13]["tap"])
    long = PrototypeCapture.schedule([ { "t_ms" => 0, "op" => "tap", "target" => "#x", "press_ms" => 5000, "navigate" => true } ], 10)
    assert_equal({ "target" => "#x", "navigate" => true }, long.last["tap"], "a press longer than the scene releases on its last frame")
    assert_includes PrototypeUxLint.lint_frames(plan, 30), 13
  end

  def test_press_state_is_injected_only_for_taps
    js = PrototypeCapture.function_module(html: "<p>x</p>", plan: [], range: 0...1, viewport: nil, prng_seed: 1, state: {})
    assert_includes js, "if (step.press)"
    assert_includes js, "__cf-pressed"
    assert_includes PrototypeCapture::PRESS_CSS, "scale(0.96)"
    live_js = WalkthroughLive.run_device_js(board([ live("a", 1) ]), live("a", 1))
    assert_includes live_js, "if (step.press)"
    assert_includes live_js, "page.touchscreen.tap(pos.x, pos.y)"
  end

  # -- tap-to-navigate -----------------------------------------------------

  def test_navigate_tap_hands_its_point_to_the_next_scene
    b = nav_board
    js = WalkthroughLive.run_device_js(b, b["scenes"][1])
    assert_includes js, "if (step.tap.navigate) tapped = { x: pos.x, y: pos.y };"
    assert_includes js, "if (tapped) out.tap = tapped;"
    assert_includes js, "let pos = entered ? { x: entered.x, y: entered.y }"
    assert_includes js, "tap-navigate landed on"
    plan = WalkthroughLive.job(b, b["scenes"][0], WalkthroughDevice.specs(b, b["scenes"][0]).first,
                               WalkthroughLive::Secrets.new([]), compose: nil, shots: true)["plan"]
    assert_equal({ "target" => "#next", "navigate" => true }, plan[34]["tap"])
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
        lists = scene["interactions"].is_a?(Hash) ? scene["interactions"].values : [ scene["interactions"] ]
        lists.each do |ops|
          plan = PrototypeCapture.schedule(Array(ops), 400)
          extra = plan.flat_map(&:keys).uniq - LEGACY_PLAN_KEYS
          assert_empty extra, "#{path} #{scene['id']}"
        end
      end
    end
    assert_equal 3, PrototypeCapture::CAPTURE_VERSION
    assert_equal 3, WalkthroughLive::CAPTURE_VERSION
  end
end
