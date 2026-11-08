# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../scripts/browserless_js"
require_relative "../scripts/walkthrough_live"

# Drives BrowserlessJs::SCREENCAST_SAMPLER_JS under node with a fake CDP
# client, so compaction, tick remapping, and caps are checked on fixed inputs.
class ScreencastSamplerTest < Minitest::Test
  def test_exposes_the_sampler_api
    js = BrowserlessJs::SCREENCAST_SAMPLER_JS
    %w[seed( attach( tick( detach( result(].each { |m| assert_includes js, m }
  end

  def test_walkthrough_inlines_the_shared_sampler
    js = WalkthroughLive.run_device_js({ "fps" => 30 }, {})
    assert_includes js, BrowserlessJs::SCREENCAST_SAMPLER_JS
    assert_includes js, "quality: #{WalkthroughLive::JPEG_QUALITY}"
    assert_includes js, "sampler.result()"
  end

  def test_attach_acks_and_detach_stops
    out = run_node(<<~JS)
      const s = ScreencastSampler({ quality: 90, maxWidth: 10, maxHeight: 20 });
      await s.attach(c);
      emit("a", 7);
      s.tick();
      await s.detach();
      emit("b", 8);
      s.tick();
      return { sent: c.sent, result: s.result() };
    JS
    assert_equal [ "Page.startScreencast", "Page.screencastFrameAck", "Page.stopScreencast" ], out["sent"].map(&:first)
    assert_equal({ "format" => "jpeg", "quality" => 90, "maxWidth" => 10, "maxHeight" => 20, "everyNthFrame" => 1 }, out["sent"][0][1])
    assert_equal({ "frames" => [ "a" ], "ticks" => [ 0, 0 ], "dropped" => 0 }, out["result"])
  end

  def test_result_compacts_to_ticked_frames_and_remaps
    out = run_node(<<~JS)
      const s = ScreencastSampler({ quality: 90, maxWidth: 1, maxHeight: 1 });
      s.tick();
      s.seed("seed");
      s.tick();
      await s.attach(c);
      emit("x"); emit("y"); s.tick(); s.tick(); emit("z"); emit("w"); s.tick();
      return s.result();
    JS
    assert_equal({ "frames" => %w[seed y w], "ticks" => [ 0, 1, 1, 2 ], "dropped" => 0 }, out)
  end

  def test_frame_cap_drops_and_counts_later_ticks
    out = run_node(<<~JS)
      const s = ScreencastSampler({ quality: 60, maxWidth: 1, maxHeight: 1 });
      await s.attach(c);
      for (const f of ["a", "b", "c"]) { emit(f); s.tick(); s.tick(); }
      return s.result({ maxFrames: 2 });
    JS
    assert_equal({ "frames" => %w[a b], "ticks" => [ 0, 0, 1, 1 ], "dropped" => 2 }, out)
  end

  def test_byte_cap_cuts_before_the_frame_that_would_exceed_it
    out = run_node(<<~JS)
      const s = ScreencastSampler({ quality: 60, maxWidth: 1, maxHeight: 1 });
      await s.attach(c);
      for (const f of ["aaaa", "bbbb", "cc"]) { emit(f); s.tick(); }
      s.seed("aaaa"); s.tick();
      return s.result({ maxBytes: 9 });
    JS
    assert_equal({ "frames" => %w[aaaa bbbb], "ticks" => [ 0, 1 ], "dropped" => 2 }, out)
  end

  private

  def run_node(body)
    skip "node not available" unless system("node", "-e", "0", out: File::NULL, err: File::NULL)
    driver = <<~JS
      #{BrowserlessJs::SCREENCAST_SAMPLER_JS}
      const handlers = {};
      const c = {
        sent: [],
        on(ev, h) { handlers[ev] = h; },
        off(ev, h) { if (handlers[ev] === h) delete handlers[ev]; },
        async send(m, p) { this.sent.push([m, p]); }
      };
      const emit = (data, sessionId = 1) => { if (handlers["Page.screencastFrame"]) handlers["Page.screencastFrame"]({ data, sessionId }); };
      (async () => { #{body} })().then((r) => console.log(JSON.stringify(r)));
    JS
    out = IO.popen([ "timeout", "10", "node", "-e", driver ], &:read)
    assert $?.success?, "sampler driver failed: #{out}"
    JSON.parse(out)
  end
end
