# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/walkthrough_storyboard"
require_relative "../scripts/walkthrough_ffmpeg"

class WalkthroughTransitionTest < Minitest::Test
  T = WalkthroughTransition

  def scene(id, order, transition = nil)
    timing = { "min_ms" => 1000, "pad_ms" => 0 }
    timing["transition"] = transition if transition
    { "id" => id, "order" => order, "timing" => timing, "narration" => { "text" => "x", "measured_ms" => 500 } }
  end

  def board(transitions, default: nil)
    b = { "fps" => 30, "scenes" => transitions.each_with_index.map { |t, i| scene("s#{i}", i + 1, t) } }
    b["transition"] = default if default
    b
  end

  # -- validation ------------------------------------------------------------

  def test_validates_types_ms_and_ease
    assert_empty T.errors(nil)
    assert_empty T.errors({ "type" => "cut", "ms" => 0 })
    assert_empty T.errors({ "type" => "fade", "ms" => 400 })
    %w[crossfade slide-left slide-up push].each do |type|
      assert_empty T.errors({ "type" => type })
      T::EASES.each { |ease| assert_empty T.errors({ "type" => type, "ms" => 350, "ease" => ease }) }
    end
    assert_match(/must be one of/, T.errors({ "type" => "wipe" }).first)
    assert_match(/ms must be an integer in 100..1500/, T.errors({ "type" => "push", "ms" => 50 }).first)
    assert_match(/ms must be an integer/, T.errors({ "type" => "push", "ms" => "350" }).first)
    assert_match(/ease "bounce" must be one of/, T.errors({ "type" => "push", "ease" => "bounce" }).first)
    assert_match(/fade transition ms must be in/, T.errors({ "type" => "fade", "ms" => 50 }).first)
    assert_match(/must be an object/, T.errors("push").first)
  end

  def test_storyboard_validates_scene_and_board_keys
    b = board([ nil, { "type" => "push", "ease" => "springy" } ], default: { "type" => "slide-up", "ms" => 9000 })
    errors = WalkthroughStoryboard.validate(b)
    assert(errors.any? { |e| e.include?('scene "s1": transition.ease "springy"') })
    assert(errors.any? { |e| e.start_with?("transition.ms must be an integer") })
  end

  # -- resolution and timeline -------------------------------------------------

  def test_scene_key_wins_over_board_default_and_defaults_fill
    b = board([ nil, nil, { "type" => "slide-left", "ms" => 500, "ease" => "linear" } ], default: { "type" => "push" })
    scenes = WalkthroughStoryboard.scenes(b)
    assert_equal T::CUT, T.resolve(b, scenes[0], 0)
    assert_equal({ "type" => "push", "ms" => 350, "ease" => "ease-in-out" }, T.resolve(b, scenes[1], 1))
    assert_equal({ "type" => "slide-left", "ms" => 500, "ease" => "linear" }, T.resolve(b, scenes[2], 2))
  end

  def test_legacy_boards_resolve_unchanged
    fade = { "type" => "fade", "ms" => 400 }
    b = board([ nil, fade ])
    assert_same fade, T.resolve(b, WalkthroughStoryboard.scenes(b)[1], 1)
  end

  def test_every_overlapping_type_overlaps_the_timeline_by_its_ms
    %w[fade crossfade slide-left slide-up push].each do |type|
      line = WalkthroughStoryboard.timeline(board([ nil, { "type" => type, "ms" => 400 } ]))
      first, second = line["scenes"]
      assert_equal first["frames"] - 12, second["start_frame"], type
    end
    cut = WalkthroughStoryboard.timeline(board([ nil, nil ]))["scenes"]
    assert_equal cut[0]["frames"], cut[1]["start_frame"]
    defaulted = WalkthroughStoryboard.timeline(board([ nil, nil ], default: { "type" => "push" }))["scenes"]
    assert_equal defaulted[0]["frames"] - PrototypeCapture.frame_at(350, 30), defaulted[1]["start_frame"]
  end

  # -- filter graph ------------------------------------------------------------

  def test_legacy_fade_is_the_original_xfade
    assert_equal "xfade=transition=fade:duration=0.500:offset=1.500",
                 T.xfade({ "type" => "fade", "ms" => 500 }, duration: "0.500", offset: "1.500")
  end

  def test_each_type_and_ease_builds_a_custom_xfade
    %w[fade crossfade slide-left slide-up push].each do |type|
      T::EASES.each do |ease|
        f = T.xfade({ "type" => type, "ms" => 350, "ease" => ease }, duration: "0.350", offset: "2.000")
        assert f.start_with?("xfade=transition=custom:duration=0.350:offset=2.000:expr='"), "#{type} #{ease}"
        assert_includes f, T.eased(ease)
        refute_match(/[:;\[\]]/, T.expression({ "type" => type, "ease" => ease }), "graph-safe #{type} #{ease}")
      end
    end
    assert_match(/\Aif\(lt\(X\+floor\(.*\*W\),W\),.*a0\(X\+floor/, T.expression({ "type" => "push" }))
    assert_match(/b0\(X-W\+floor/, T.expression({ "type" => "slide-left" }))
    assert_match(/\Aif\(gte\(Y,H-floor\(.*\*H\)\),.*b0\(X,Y-H\+floor/, T.expression({ "type" => "slide-up" }))
    assert T.expression({ "type" => "crossfade" }).start_with?("A*(1-")
  end

  # Evaluate an eased curve in Ruby at linear progress p (P = 1 - p).
  def curve(ease, p)
    expr = T.eased(ease).gsub("P", (1 - p).to_s).gsub(/pow\(([^,]+),3\)/, '((\1)**3)')
                        .gsub(/if\(lt\(([^,]+),0\.5\),([^,]+),(.+)\)\z/, '((\1)<0.5 ? (\2) : (\3))')
    Kernel.eval(expr)
  end

  def test_eases_are_real_curves
    assert_in_delta 0.25, curve("linear", 0.25), 1e-9
    assert_in_delta 0.015625, curve("ease-in", 0.25), 1e-9
    assert_in_delta 0.578125, curve("ease-out", 0.25), 1e-9
    assert_in_delta 0.0625, curve("ease-in-out", 0.25), 1e-9
    assert_in_delta 0.5, curve("ease-in-out", 0.5), 1e-9
    assert_in_delta 0.9375, curve("ease-in-out", 0.75), 1e-9
    T::EASES.each do |ease|
      assert_in_delta 0.0, curve(ease, 0.0), 1e-9
      assert_in_delta 1.0, curve(ease, 1.0), 1e-9
    end
  end

  def plan(transition)
    cur = ->(n) { (1..n).map { |f| { "frame" => f, "x" => 100, "y" => 100 } } }
    { fps: 30, width: 640, height: 360, total_ms: 3000, cursor_png: "/c.png", srt: "/s.srt", output: "/work/r/o.mp4",
      scenes: [
        { id: "a", frames_dir: "/a", frames: 50, start_frame: 0, transition: T::CUT, cursor: cur.(50), hero_still: false },
        { id: "b", frames_dir: "/b", frames: 50, start_frame: 40, transition: transition, cursor: cur.(50), hero_still: false }
      ] }
  end

  def test_overlap_parks_the_outgoing_cursor_and_uses_the_scene_transition
    push = { "type" => "push", "ms" => 350, "ease" => "ease-out" }
    p = plan(push)
    assert_equal 41, WalkthroughFfmpeg.fade_out_from(p, 0)
    hidden = WalkthroughFfmpeg.track(p, 0, :cursor).select { |pt| pt["x"] < 0 }.map { |pt| pt["frame"] }
    assert_equal (41..50).to_a, hidden
    assert_equal [ { offset: "1.333", duration: "0.333" } ], WalkthroughFfmpeg.transitions(p)
    graph = WalkthroughFfmpeg.video_graph(p)
    assert(graph.any? { |part| part.start_with?("[v0][v1]#{T.xfade(push, duration: '0.333', offset: '1.333')}[j1]") })
    assert_nil WalkthroughFfmpeg.fade_out_from(plan(T::CUT), 0)
  end
end
