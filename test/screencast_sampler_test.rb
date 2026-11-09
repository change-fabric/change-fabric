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

  def test_store_stays_bounded_under_many_unticked_frames
    out = run_node(<<~JS)
      const s = ScreencastSampler({ quality: 60, maxWidth: 1, maxHeight: 1 });
      await s.attach(c);
      let peak = 0;
      for (let i = 0; i < 5000; i++) { emit("f" + i); peak = Math.max(peak, s.stored()); if (i % 1000 === 999) s.tick(); }
      return { peak, stored: s.stored(), result: s.result() };
    JS
    assert_operator out["peak"], :<=, 6
    assert_equal 5, out["stored"]
    assert_equal({ "frames" => %w[f999 f1999 f2999 f3999 f4999], "ticks" => [ 0, 1, 2, 3, 4 ], "dropped" => 0 }, out["result"])
  end

  def test_caps_at_construction_stop_storing_and_count_drops
    out = run_node(<<~JS)
      const s = ScreencastSampler({ quality: 60, maxWidth: 1, maxHeight: 1, maxFrames: 2 });
      await s.attach(c);
      for (const f of ["a", "b", "c", "d"]) { emit(f); s.tick(); s.tick(); }
      const stored = s.stored();
      emit("e");
      return { stored, after: s.stored(), result: s.result() };
    JS
    assert_equal 2, out["stored"]
    assert_equal 2, out["after"]
    assert_equal({ "frames" => %w[a b], "ticks" => [ 0, 0, 1, 1 ], "dropped" => 4 }, out["result"])
  end

  def test_incremental_caps_match_end_of_walk_compaction
    out = run_node(<<~JS)
      #{OLD_SAMPLER_JS}
      let seedState = 7;
      const rnd = () => (seedState = (seedState * 1103515245 + 12345) % 2147483648) / 2147483648;
      const mk = async (o) => {
        let h = null;
        const s = ScreencastSampler(Object.assign({ quality: 1, maxWidth: 1, maxHeight: 1 }, o));
        await s.attach({ on(ev, fn) { h = fn; }, async send() {} });
        s.frame = (data) => h({ data, sessionId: 1 });
        return s;
      };
      const cases = [];
      for (let n = 0; n < 200; n++) {
        const caps = { maxFrames: 1 + Math.floor(rnd() * 12), maxBytes: rnd() < 0.5 ? 10 + Math.floor(rnd() * 60) : undefined };
        const fresh = await mk({ maxFrames: caps.maxFrames, maxBytes: caps.maxBytes });
        const legacy = OldSampler(), compat = await mk({});
        for (let i = 0; i < 80; i++) {
          const r = rnd();
          const data = "x".repeat(1 + Math.floor(rnd() * 9)) + i;
          for (const s of [fresh, legacy, compat]) {
            if (r < 0.45) s.frame(data);
            else if (r < 0.5) s.seed(data);
            else s.tick();
          }
        }
        cases.push([fresh.result(), legacy.result(caps), compat.result(caps)]);
      }
      return cases;
    JS
    out.each { |fresh, legacy, compat| assert_equal legacy, fresh; assert_equal legacy, compat }
    assert(out.any? { |_, legacy, _| legacy["dropped"].positive? })
  end

  def test_seed_is_kept_when_ticked_and_replaced_when_not
    out = run_node(<<~JS)
      const a = ScreencastSampler({ quality: 1, maxWidth: 1, maxHeight: 1 });
      a.seed("still"); a.tick(); await a.attach(c); a.tick(); emit("live"); a.tick();
      const b = ScreencastSampler({ quality: 1, maxWidth: 1, maxHeight: 1 });
      b.seed("still"); b.seed("again"); b.tick();
      return [a.result(), b.result()];
    JS
    assert_equal({ "frames" => %w[still live], "ticks" => [ 0, 0, 1 ], "dropped" => 0 }, out[0])
    assert_equal({ "frames" => %w[again], "ticks" => [ 0 ], "dropped" => 0 }, out[1])
  end

  # The pre-bounding sampler: keeps every frame, compacts and caps in result().
  OLD_SAMPLER_JS = <<~JS
    function OldSampler() {
      const store = [], ticks = [];
      let latest = -1;
      return {
        seed(d) { store.push(d); latest = store.length - 1; },
        frame(d) { store.push(d); latest = store.length - 1; },
        tick() { if (latest >= 0) ticks.push(latest); },
        result(caps) {
          const maxFrames = caps && caps.maxFrames, maxBytes = caps && caps.maxBytes;
          const frames = [], out = [], index = new Map();
          let bytes = 0, dropped = 0, cut = false;
          for (const t of ticks) {
            if (!cut && !index.has(t)) {
              const size = store[t].length;
              if ((maxFrames && frames.length + 1 > maxFrames) || (maxBytes && bytes + size > maxBytes)) cut = true;
              else { index.set(t, frames.length); frames.push(store[t]); bytes += size; }
            }
            if (cut) dropped++;
            else out.push(index.get(t));
          }
          return { frames, ticks: out, dropped };
        }
      };
    }
  JS

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
