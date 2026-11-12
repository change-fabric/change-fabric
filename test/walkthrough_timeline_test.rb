# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/prototype_capture"
require_relative "../scripts/walkthrough_timeline"

# The event timeline: ms become frames once, events on one frame run in a
# fixed seq order, and every timing conflict is found on frames.
class WalkthroughTimelineTest < Minitest::Test
  FPS = 30

  def build(ops, frames = 60) = WalkthroughTimeline.build(ops, fps: FPS, frames: frames)

  def test_same_frame_events_run_in_seq_order_then_authored_order
    ops = [ { "t_ms" => 0, "op" => "click", "target" => "#c" },
            { "t_ms" => 0, "op" => "hover", "target" => "#h" },
            { "t_ms" => 0, "op" => "scroll", "target" => "html", "dy" => 10 },
            { "t_ms" => 0, "op" => "type", "target" => "#t", "text" => "a" },
            { "t_ms" => 0, "op" => "move", "target" => "#m", "duration_ms" => 0 },
            { "t_ms" => 0, "op" => "tap", "target" => "#p", "press_ms" => 1 },
            { "t_ms" => 0, "op" => "tap", "target" => "#q", "press_ms" => 1, "navigate" => true } ]
    kinds = build(ops).events_by_frame[0].map { |e| e["kind"] }
    assert_equal %w[scroll move_step hover press press click type_char], kinds
    assert_equal %w[release release navigate], build(ops).events_by_frame[1].map { |e| e["kind"] }
  end

  def test_tap_presses_releases_and_navigates_on_frames
    t = build([ { "t_ms" => 300, "op" => "tap", "target" => "#buy", "navigate" => true } ])
    assert_equal [ "press" ], t.events_by_frame[9].map { |e| e["kind"] }
    assert_equal %w[release navigate], t.events_by_frame[13].map { |e| e["kind"] }, "120 ms is 4 frames at 30 fps"
    assert_equal 13, t.cut_frame
    assert_equal 9, t.navigate_press_frame
    assert_empty t.conflicts
  end

  # E1: typing "abcd" at 30 cps from 1000 ms lands "d" on frame 33, the
  # navigate tap at 1000 ms with press_ms 100 releases on frame 33 too.
  def test_input_on_the_navigate_frame_is_a_conflict
    ops = [ { "t_ms" => 1000, "op" => "type", "target" => "#q", "text" => "abcd", "cps" => 30 },
            { "t_ms" => 1000, "op" => "tap", "target" => "#next", "press_ms" => 100, "navigate" => true } ]
    msgs = build(ops).conflicts
    assert_equal 1, msgs.size, msgs.inspect
    assert_match(/op 0 \(type_char #q\) acts at frame 33, on or after the navigate at frame 33/, msgs.first)
    %w[click key move].each do |kind|
      op = { "t_ms" => 1100, "op" => kind, "target" => "#x", "keys" => "a", "duration_ms" => 0 }
      refute_empty build([ op, ops[1] ]).conflicts, kind
    end
    ops[0]["t_ms"] = 800
    assert_empty build(ops).conflicts
  end

  # E2: an instant scroll on a target that is mid-glide.
  def test_instant_scroll_inside_a_glide_is_a_conflict
    ops = [ { "t_ms" => 0, "op" => "scroll", "target" => "#feed", "dy" => 300, "ms" => 900 },
            { "t_ms" => 400, "op" => "scroll", "target" => "#feed", "dy" => 50 } ]
    assert_match(/scrolls on #feed overlap/, build(ops).conflicts.join)
    ops[1]["t_ms"] = 900
    assert_empty build(ops).conflicts, "frame 27 is after the glide's frames 0..26"
    ops[1]["target"] = "#side"
    ops[1]["t_ms"] = 400
    assert_empty build(ops).conflicts
  end

  def test_overlapping_presses_on_one_target_are_a_conflict
    ops = [ { "t_ms" => 0, "op" => "tap", "target" => "#a", "press_ms" => 300 },
            { "t_ms" => 200, "op" => "tap", "target" => "#a" } ]
    assert_match(/presses on #a overlap/, build(ops).conflicts.join)
    # Touching: the second press lands on the first one's release frame.
    touch = [ { "t_ms" => 0, "op" => "tap", "target" => "#a" }, { "t_ms" => 133, "op" => "tap", "target" => "#a" } ]
    assert_match(/presses on #a overlap/, build(touch).conflicts.join)
    touch[1]["t_ms"] = 167
    assert_empty build(touch).conflicts
  end

  # E3: a release past the last frame is rejected, never clamped.
  def test_release_past_the_last_frame_is_a_conflict
    t = build([ { "t_ms" => 0, "op" => "tap", "target" => "#x", "press_ms" => 1000, "navigate" => true } ], 10)
    assert_match(/releases at frame 30, past the scene's last frame 9/, t.conflicts.join)
    assert(WalkthroughTimeline.to_plan(t).none? { |e| e["tap"] }, "nothing lands past the end")
  end

  def test_glide_steps_follow_the_curve_and_end_exactly
    t = build([ { "t_ms" => 100, "op" => "scroll", "target" => "html", "dy" => 220, "ms" => 900 } ], 40)
    steps = t.events.select { |e| e.kind == "glide_step" }
    assert_equal (3..29).to_a, steps.map(&:frame)
    want = (1..27).map { |k| (220 * PrototypeCapture.cubic_bezier(0.42, 0, 0.58, 1, k / 27.0)).round(2) }
    assert_equal want, steps.map { |e| e.payload["dy"] }
    assert_equal 220.0, steps.last.payload["dy"]
    assert steps.first.payload["first"]
  end

  # The plan rendered from the timeline matches the scheduler origin/main
  # shipped, op for op, on random boards that use only the legacy ops.
  def test_legacy_plan_matches_the_old_scheduler
    rng = Random.new(392)
    200.times do |n|
      ops = Array.new(rng.rand(1..8)) { legacy_op(rng) }.sort_by { |op| op["t_ms"] }
      frames = rng.rand(1..60)
      got = WalkthroughTimeline.to_plan(WalkthroughTimeline.build(ops, fps: FPS, frames: frames))
      assert_equal old_schedule(ops, frames), got, "case #{n}: #{ops.inspect}"
    end
  end

  # Property: over random op lists, a timeline with no conflicts never has
  # an event on or after its navigate (other than the navigate tap's own),
  # never has two overlapping same-target intervals of one family, and
  # every release lands inside the scene; and a list that breaks one of
  # those always reports a conflict.
  def test_property_conflicts_are_exactly_the_broken_rules
    rng = Random.new(20_261_112)
    seen = { clean: 0, conflicted: 0 }
    500.times do |n|
      frames = rng.rand(10..90)
      ops = Array.new(rng.rand(1..7)) { any_op(rng) }
      ops << { "t_ms" => rng.rand(0..3000), "op" => "tap", "target" => "#go", "navigate" => true } if rng.rand < 0.6
      ops.sort_by! { |op| op["t_ms"] }
      t = WalkthroughTimeline.build(ops, fps: FPS, frames: frames)
      broken = broken_rules(ops, frames)
      if t.conflicts.empty?
        seen[:clean] += 1
        assert_empty broken, "case #{n}: #{ops.inspect}"
      else
        seen[:conflicted] += 1
        refute_empty broken, "case #{n} reported #{t.conflicts.inspect} for #{ops.inspect}"
      end
    end
    assert_operator seen[:clean], :>, 50
    assert_operator seen[:conflicted], :>, 50
  end

  def test_fluid_ops_are_detected
    refute WalkthroughTimeline.fluid?([ { "op" => "scroll", "target" => "html", "dy" => 3 } ])
    assert WalkthroughTimeline.fluid?([ { "op" => "scroll", "target" => "html", "dy" => 3, "ms" => 100 } ])
    assert WalkthroughTimeline.fluid?([ { "op" => "tap", "target" => "#a" } ])
  end

  private

  TARGETS = %w[#a #b html].freeze

  def legacy_op(rng)
    t = rng.rand(0..2500)
    target = TARGETS.sample(random: rng)
    case rng.rand(7)
    when 0 then { "t_ms" => t, "op" => "move", "target" => target, "duration_ms" => rng.rand(0..900), "easing" => [ nil, "easeInOutCubic" ].sample(random: rng) }.compact
    when 1 then { "t_ms" => t, "op" => %w[click dblclick hover].sample(random: rng), "target" => target }
    when 2 then { "t_ms" => t, "op" => "type", "target" => target, "text" => "abcdef"[0, rng.rand(1..6)], "cps" => rng.rand(5..40) }
    when 3 then { "t_ms" => t, "op" => "key", "keys" => %w[Enter a Control+C].sample(random: rng) }
    when 4 then { "t_ms" => t, "op" => "scroll", "target" => target, "dy" => rng.rand(-90..90) }
    when 5 then { "t_ms" => t, "op" => "scroll", "target" => target, "block" => "center" }
    else { "t_ms" => t, "op" => "wait", "duration_ms" => 100 }
    end
  end

  def any_op(rng)
    t = rng.rand(0..3000)
    target = TARGETS.sample(random: rng)
    case rng.rand(4)
    when 0 then { "t_ms" => t, "op" => "scroll", "target" => target, "dy" => rng.rand(1..300), "ms" => rng.rand(1..1200) }
    when 1 then { "t_ms" => t, "op" => "tap", "target" => target, "press_ms" => rng.rand(1..400) }
    else legacy_op(rng)
    end
  end

  # The rules, checked straight from the ops (an oracle independent of the
  # timeline's own events and intervals): every op's frames are recomputed
  # here from t_ms with frame_at and frame_count.
  def broken_rules(ops, frames)
    span = ->(ms) { [ PrototypeCapture.frame_count(ms.to_i, FPS), 1 ].max }
    at = ->(op) { PrototypeCapture.frame_at(op["t_ms"], FPS) }
    reach = lambda do |op|
      case op["op"]
      when "tap" then [ at.call(op), at.call(op) + span.call(op["press_ms"] || PrototypeCapture::PRESS_MS) ]
      when "scroll" then op["ms"] ? [ at.call(op), at.call(op) + span.call(op["ms"]) - 1 ] : [ at.call(op), at.call(op) ]
      when "move" then [ at.call(op), at.call(op) + span.call(op["duration_ms"]) - 1 ]
      when "type" then [ at.call(op), PrototypeCapture.frame_at(op["t_ms"] + ((op["text"].length - 1) * 1000.0 / op["cps"]), FPS) ]
      when "wait" then nil
      else [ at.call(op), at.call(op) ]
      end
    end
    out = []
    nav = ops.find { |op| op["navigate"] }
    if nav
      cut = reach.call(nav)[1]
      out << :after_navigate if ops.any? { |op| !op.equal?(nav) && (r = reach.call(op)) && r[1] >= cut && r[0] < frames }
    end
    family = { "tap" => :press, "scroll" => :scroll }
    ops.combination(2).each do |a, b|
      next unless family[a["op"]] && family[a["op"]] == family[b["op"]] && a["target"] == b["target"]

      ra = reach.call(a)
      rb = reach.call(b)
      out << :overlap if ra[0] <= rb[1] && rb[0] <= ra[1]
    end
    out << :late_release if ops.any? { |op| op["op"] == "tap" && reach.call(op)[1] >= frames }
    out
  end

  # origin/main's PrototypeCapture.schedule for the legacy ops, verbatim in
  # behaviour: the oracle the timeline's plan must match.
  def old_schedule(ops, frames, fps = FPS)
    plan = Array.new(frames) { |i| { "frame" => i } }
    ops.each do |op|
      start = PrototypeCapture.frame_at(op["t_ms"].to_i, fps)
      case op["op"]
      when "move"
        span = [ PrototypeCapture.frame_count(op["duration_ms"].to_i, fps), 1 ].max
        (1..span).each do |k|
          entry = plan[start + k - 1] or break
          entry["move"] = { "target" => op["target"], "p" => PrototypeCapture.ease(op["easing"], k.to_f / span), "first" => k == 1 }
        end
      when "click", "dblclick", "hover" then plan.dig(start)&.store(op["op"], op["target"])
      when "type"
        cps = (op["cps"] || 12).to_f
        op["text"].to_s.each_char.with_index do |char, k|
          entry = plan[PrototypeCapture.frame_at(op["t_ms"].to_i + (k * 1000.0 / cps), fps)] or break
          entry["type"] ||= { "target" => op["target"], "text" => +"", "focus" => k.zero? }
          entry["type"]["text"] << char
          entry["type"]["focus"] ||= k.zero?
        end
      when "key" then plan.dig(start)&.then { |e| (e["key"] ||= []) << { "keys" => PrototypeCapture.key_chord(op["keys"]), "target" => op["target"] }.compact }
      when "scroll" then plan.dig(start)&.store("scroll", { "target" => op["target"], "dx" => op["dx"], "dy" => op["dy"], "block" => op["block"] }.compact)
      end
    end
    plan
  end
end
