# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../scripts/browserless_js"

# Drives BrowserlessJs::FRAME_CLOCK_JS under node with a fake browser rAF, so
# the hold, the even steps, and the hand-back are checked on fixed inputs.
class FrameClockTest < Minitest::Test
  STEP = 1000.0 / 30

  def test_held_callbacks_run_only_on_a_step_in_even_frames
    out = run_node(<<~JS)
      const seen = [];
      const loop = (t) => { seen.push(t); window.requestAnimationFrame(loop); };
      window.requestAnimationFrame(loop);
      flush(1005);
      window.__cfFrameHold();
      flush(1012);
      const queuedWhileHeld = browser.length;
      for (let i = 0; i < 4; i++) window.__cfFrameStep(#{STEP});
      return { seen, queuedWhileHeld };
    JS
    assert_equal [ 1005, 1012 ], out["seen"].first(2), "real frames pass through until the hold takes the loop"
    assert_equal 0, out["queuedWhileHeld"], "a held loop never reaches the browser"
    steps = out["seen"].drop(1).each_cons(2).map { |a, b| (b - a).round(6) }
    assert_equal [ STEP.round(6) ] * 4, steps, "each step is exactly one frame after the last real time"
  end

  def test_release_hands_the_queue_back_and_time_never_goes_backward
    out = run_node(<<~JS)
      const seen = [];
      window.__cfFrameHold();
      window.requestAnimationFrame((t) => seen.push(["held", t]));
      const dropped = window.requestAnimationFrame((t) => seen.push(["cancelled", t]));
      window.cancelAnimationFrame(dropped);
      window.__cfFrameRelease();
      flush(2000);
      window.__cfFrameHold();
      window.requestAnimationFrame((t) => seen.push(["after", t]));
      window.__cfFrameStep(10);
      return seen;
    JS
    assert_equal [ [ "held", 2000 ], [ "after", 2010 ] ], out
  end

  def test_step_without_a_hold_runs_nothing
    out = run_node(<<~JS)
      let ran = false;
      window.requestAnimationFrame(() => { ran = true; });
      window.__cfFrameStep(#{STEP});
      return { ran, waiting: browser.length };
    JS
    assert_equal({ "ran" => false, "waiting" => 1 }, out)
  end

  def run_node(body)
    skip "node not available" unless system("node", "-e", "0", out: File::NULL, err: File::NULL)
    driver = <<~JS
      const browser = [];
      let browserId = 0;
      globalThis.window = {
        requestAnimationFrame(fn) { browser.push(fn); return ++browserId; },
        cancelAnimationFrame() {}
      };
      Object.defineProperty(globalThis, "performance", { value: { now: () => 1000 }, configurable: true });
      const flush = (t) => { for (const fn of browser.splice(0)) fn(t); };
      #{BrowserlessJs::FRAME_CLOCK_JS}
      (async () => { #{body} })().then((r) => console.log(JSON.stringify(r)));
    JS
    out = IO.popen([ "timeout", "10", "node", "-e", driver ], &:read)
    assert $?.success?, "frame clock driver failed: #{out}"
    JSON.parse(out)
  end
end
