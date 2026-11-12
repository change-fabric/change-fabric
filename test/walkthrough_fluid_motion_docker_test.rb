# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "digest"
require "fileutils"
require "json"
require_relative "../scripts/walkthrough_render"

# Real captures in the pinned browserless image. A prototype page glides
# through distinct frames and shows its pressed state before the real
# click; a phone page scrolls, taps a link that navigates, and the next
# scene starts on the navigated page with the cursor where the tap landed.
# Set CF_FLUID_SAMPLE_DIR to keep the phone frames as JPEGs for a look.
class WalkthroughFluidMotionDockerTest < Minitest::Test
  FEED = <<~HTML
    <!doctype html><html><head><meta name="viewport" content="width=device-width">
    <style>body{margin:0;font:18px sans-serif} .row{height:90px;border-bottom:1px solid #ccc;padding:12px}
    .row:nth-child(odd){background:#eef} #next{display:block;margin:24px;padding:16px;background:#246;color:#fff;text-align:center}
    #detail{display:none} #detail:target{display:block;position:fixed;inset:0;background:#fc6;padding:40px;font-size:32px}</style></head>
    <body>#{(1..9).map { |i| "<div class='row'>Row #{i}</div>" }.join}
    <a id="next" href="#detail">Open detail</a><div id="detail">Detail page</div></body></html>
  HTML
  # setContent cannot carry a hash, so the destination scene loads the
  # detail view as its own page, as a live goto of the URL would show it.
  DETAIL = "<!doctype html><html><head><meta name='viewport' content='width=device-width'></head><body style='margin:0;background:#fc6;padding:40px;font:32px sans-serif'>Detail page</body></html>"
  PROTO = <<~HTML
    <!doctype html><html><body style="margin:0;font:20px sans-serif">
    <div id="list" style="height:300px;overflow:auto">#{(1..30).map { |i| "<p style='margin:0;height:40px'>Item #{i}</p>" }.join}</div>
    <button id="buy" style="margin:20px;padding:20px 40px;font-size:24px" onclick="this.textContent='Bought'">Buy</button>
    </body></html>
  HTML

  def setup
    skip "docker not available" unless ChangeDocker.available?
  end

  def test_prototype_glide_and_press_frames
    Dir.mktmpdir do |dir|
      ChangeDocker.with_browserless(network: nil) do |session|
        PrototypeCapture.capture(session: session, html: PROTO, out_dir: dir, state: {}, prng_seed: 7, duration_ms: 1000,
                                 viewport: { "w" => 400, "h" => 420, "dpr" => 1 },
                                 interactions: [ { "t_ms" => 0, "op" => "scroll", "target" => "#list", "dy" => 300, "ms" => 500 },
                                                 { "t_ms" => 600, "op" => "tap", "target" => "#buy", "press_ms" => 200 } ])
      end
      sums = Dir[File.join(dir, "*.png")].sort.map { |f| Digest::SHA256.file(f).hexdigest }
      glide = sums[0, 15]
      assert_equal glide.size, glide.uniq.size, "every glide frame shows a new scroll offset"
      # Press lands on frame 18 and releases on frame 24 (plan indexes) (200 ms at 30 fps).
      assert_equal sums[18], sums[23], "the press holds steady"
      refute_equal sums[17], sums[18], "the pressed look shows"
      refute_equal sums[18], sums[24], "the release lifts it and the click lands"
      refute_equal sums[17], sums[24], "the page responded"
    end
  end

  def test_phone_glide_then_tap_navigate_carries_into_the_next_scene
    board = { "fps" => 30, "viewport" => { "w" => 1080, "h" => 1920 } }
    dev = { "name" => "phone", "w" => 390, "h" => 693, "dpr" => 2, "mobile" => true,
            "ua" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148" }
    scene = { "id" => "feed", "wait" => { "until" => "load" } }
    ops = [ { "t_ms" => 0, "op" => "scroll", "target" => "html", "dy" => 440, "ms" => 900 },
            { "t_ms" => 1000, "op" => "tap", "target" => "#next", "navigate" => true } ]
    first = film(board, scene, dev, FEED, "about:blank", PrototypeCapture.schedule(ops, 50), nil)
    keep(first, "feed")
    assert_equal "about:blank#detail", first["session"]["url"]
    tap = first["session"]["tap"]
    refute_nil tap
    second = film(board, scene, dev, DETAIL, "about:blank#detail", PrototypeCapture.schedule([], 10), first["session"])
    assert_equal [ tap["x"], tap["y"] ], second["cursor"].first.values_at("x", "y"), "the cursor starts where the tap landed"
    assert first["frames"].size > 20, "the glide streams many distinct frames, not a jump"
    keep(second, "detail")
  end

  private

  def film(board, scene, dev, html, url, plan, session)
    job = { "dev" => dev, "plan" => plan, "lint" => [], "band" => 0, "shots" => true, "group" => "phone", "url" => url, "html" => html }
    code = WalkthroughLive.capture_module(board, scene, jobs: [ job ], session: session)
    res = nil
    ChangeDocker.with_browserless(network: nil) do |bl|
      res = PrototypeCapture.run_with_retry(bl, code, retries: 0, launch_args: BrowserlessJs.capture_launch_args(2))
    end
    res["devices"].first
  end

  def keep(run, name)
    out = ENV["CF_FLUID_SAMPLE_DIR"] or return
    dir = File.join(out, name)
    FileUtils.mkdir_p(dir)
    run["ticks"].each_with_index do |frame, tick|
      jpg = Base64.decode64(run["frames"][frame])
      File.binwrite(File.join(dir, format("%03d.jpg", tick)), jpg)
    end
  end
end
