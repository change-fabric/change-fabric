# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../scripts/walkthrough_render"

# Scroll placement (block, offset_px) and loud missing targets: a scroll,
# move, hover or wait that finds nothing is reported with its scene, op,
# t_ms and selector, and fails under strict targets.
class WalkthroughScrollTargetTest < Minitest::Test
  def errs(op) = WalkthroughStoryboard.interaction_errors([ { "t_ms" => 0 }.merge(op) ]).join("\n")

  def test_block_and_offset_validate
    assert_empty errs("op" => "scroll", "target" => "#a", "block" => "start", "offset_px" => 72)
    PrototypeCapture::SCROLL_BLOCKS.each { |b| assert_empty errs("op" => "scroll", "target" => "#a", "block" => b) }
    assert_includes errs("op" => "scroll", "target" => "#a", "block" => "top"), "scroll block must be one of start, center, end, nearest"
    assert_includes errs("op" => "scroll", "target" => "#a", "offset_px" => 1.5), "scroll offset_px must be an integer"
    assert_includes errs("op" => "scroll", "target" => "#a", "dy" => 10, "block" => "start"), "applies only to an into-view scroll"
    assert_includes errs("op" => "hover", "target" => "#a", "block" => "start"), "block applies only to a scroll op"
    assert_includes errs("op" => "tap", "target" => "#a", "offset_px" => 4), "offset_px applies only to a scroll op"
  end

  def test_default_block_is_center
    assert_equal "center", PrototypeCapture::DEFAULT_SCROLL_BLOCK
    assert_includes PrototypeCapture::DISPATCH_JS, '"center"'
  end

  def test_events_carry_op_t_ms_and_placement
    ops = [ { "t_ms" => 0, "op" => "hover", "target" => "#a" },
            { "t_ms" => 400, "op" => "scroll", "target" => "[aria-label=Search]", "block" => "start", "offset_px" => 80 } ]
    t = WalkthroughTimeline.build(ops, fps: 30, frames: 30)
    scroll = t.events_by_frame[12].first
    assert_equal({ "kind" => "scroll", "target" => "[aria-label=Search]", "op" => 1, "t_ms" => 400, "block" => "start", "offset_px" => 80 }, scroll)
    assert_equal 0, t.events_by_frame[0].first["op"]
  end

  def test_misses_warn_by_default
    io = StringIO.new
    misses = [ { "kind" => "hover", "target" => "#gone", "op" => 2, "t_ms" => 1200 },
               { "kind" => "move_step", "target" => "#late", "op" => 3, "t_ms" => 1500 },
               { "kind" => "wait", "target" => "main", "ms" => 10_000 } ]
    PrototypeCapture.report_misses!(misses, "scene s1", strict: false, io: io)
    out = io.string
    assert_includes out, "warning: scene s1: hover op 2 at t_ms 1200 matched nothing: #gone"
    assert_includes out, "move op 3 at t_ms 1500 matched nothing: #late"
    assert_includes out, "scene s1: wait.selector timed out after 10000ms: main"
  end

  def test_misses_fail_under_strict
    io = StringIO.new
    err = assert_raises(PrototypeCapture::TargetMissError) do
      PrototypeCapture.report_misses!([ { "kind" => "hover", "target" => "#gone", "op" => 0, "t_ms" => 0 } ], "scene s1", strict: true, io: io)
    end
    assert_includes err.message, "#gone"
    assert_includes io.string, "warning:"
    assert PrototypeCapture.strict_targets?({ "CF_WALKTHROUGH_STRICT" => "1" })
    refute PrototypeCapture.strict_targets?({})
  end

  def test_no_misses_is_silent
    io = StringIO.new
    PrototypeCapture.report_misses!([], "scene s1", strict: true, io: io)
    assert_empty io.string
  end

  def test_ambiguous_selector_warns_with_the_element_acted_on
    io = StringIO.new
    miss = { "kind" => "click", "target" => "details > summary", "op" => 1, "t_ms" => 600, "count" => 3, "label" => '<summary> "Billing"' }
    PrototypeCapture.report_misses!([ miss ], "scene s2", strict: false, io: io)
    assert_includes io.string, 'warning: scene s2: click op 1 at t_ms 600 selector matches 3 elements, acted on index 0 <summary> "Billing": details > summary'
    assert_raises(PrototypeCapture::TargetMissError) { PrototypeCapture.report_misses!([ miss ], "scene s2", strict: true, io: StringIO.new) }
    assert_equal 4, PrototypeCapture::DISPATCH_JS.scan("await census(ev)").size, "move/hover (reach), click, dblclick and press"
  end

  def test_wait_op_with_selector_validates_and_builds_an_event
    assert_empty errs("op" => "wait", "selector" => "#panel", "state" => "visible", "timeout_ms" => 2000)
    assert_empty errs("op" => "wait", "duration_ms" => 500)
    assert_includes errs("op" => "wait", "selector" => ""), "wait selector must be a non-empty string"
    assert_includes errs("op" => "wait", "selector" => "#p", "state" => "attached"), "wait state must be visible"
    assert_includes errs("op" => "wait", "selector" => "#p", "timeout_ms" => 0), "wait timeout_ms must be an integer in 1..30000"
    assert_includes errs("op" => "wait", "timeout_ms" => 100), "wait timeout_ms needs selector"
    ops = [ { "t_ms" => 0, "op" => "click", "target" => "summary" },
            { "t_ms" => 300, "op" => "wait", "selector" => "#inside" },
            { "t_ms" => 300, "op" => "scroll", "target" => "#inside" } ]
    frame = WalkthroughTimeline.build(ops, fps: 30, frames: 30).events_by_frame[9]
    assert_equal %w[wait_for scroll], frame.map { |e| e["kind"] }, "the wait runs before a same-frame scroll"
    assert_equal({ "kind" => "wait_for", "target" => "#inside", "op" => 1, "t_ms" => 300, "state" => "visible", "timeout_ms" => 3000 }, frame.first)
    io = StringIO.new
    PrototypeCapture.report_misses!([ frame.first ], "scene s3", strict: false, io: io)
    assert_includes io.string, "scene s3: wait op 1 at t_ms 300 never saw its selector visible within 3000ms: #inside"
  end

  def test_live_capture_polls_and_bounds_wait
    scene = { "id" => "s", "screen" => { "url" => "https://app.localhost/" }, "wait" => { "selector" => "main" } }
    js = WalkthroughLive.run_device_js({ "viewport" => { "w" => 1280, "h" => 720 } }, scene)
    assert_includes js, "lazyMs: #{WalkthroughLive::LAZY_TARGET_MS}"
    assert_includes js, "timeout: #{WalkthroughLive::WAIT_SELECTOR_MS}"
    assert_includes js, 'kind: "wait"'
    assert_includes PrototypeCapture::DISPATCH_JS, "scroll target not found after"
  end
end
