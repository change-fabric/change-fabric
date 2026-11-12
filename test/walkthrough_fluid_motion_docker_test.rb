# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "digest"
require "fileutils"
require "json"
require "open3"
require_relative "../scripts/walkthrough_render"

# Real captures in the pinned browserless image. A prototype page records
# its own scroll offset and the tap target's computed look on every frame,
# so the glide is checked against the curve and the press against its
# CSS, not only by frames differing. A phone page glides, taps a link that
# navigates, and the next scene continues the same page in one run: its
# scroll position survives the cut and the cursor never jumps.
# Set CF_FLUID_SAMPLE_DIR to keep the phone frames as JPEGs for a look.
class WalkthroughFluidMotionDockerTest < Minitest::Test
  FEED = <<~HTML
    <!doctype html><html><head><meta name="viewport" content="width=device-width">
    <style>body{margin:0;font:18px sans-serif} .row{height:90px;border-bottom:1px solid #ccc;padding:12px}
    .row:nth-child(odd){background:#eef} #next{display:block;margin:24px;padding:16px;background:#246;color:#fff;text-align:center}
    #detail{display:none} #detail:target{display:block;position:fixed;inset:0;background:#fc6;padding:40px;font-size:32px}</style></head>
    <body>#{(1..9).map { |i| "<div class='row'>Row #{i}</div>" }.join}
    <a id="next" href="#detail">Open detail</a><div id="detail">Detail page</div><p id="status"></p>
    <script>window.addEventListener("hashchange", () => { document.getElementById("status").textContent = "scrolled " + window.scrollY; });</script>
    </body></html>
  HTML
  # Each virtual-clock tick records the list's offset and the button's look
  # as the previous frame's input left them; CFStore.dump hands the log
  # back as the capture's end state.
  PROTO = <<~HTML
    <!doctype html><html><body style="margin:0;font:20px sans-serif">
    <div id="list" style="height:300px;overflow:auto">#{(1..30).map { |i| "<p style='margin:0;height:40px'>Item #{i}</p>" }.join}</div>
    <div style="position:relative;height:120px"><button id="buy" style="position:absolute;left:50%;top:20px;transform:translateX(-50%);padding:20px 40px;font-size:24px"
      onclick="this.dataset.clicked = String(Date.now())">Buy</button></div>
    <script>
      const log = [];
      const tick = () => {
        const b = document.getElementById("buy"), r = b.getBoundingClientRect(), cs = getComputedStyle(b);
        log.push({ t: Date.now(), top: document.getElementById("list").scrollTop, scale: cs.scale, opacity: cs.opacity,
                   clicked: b.dataset.clicked || null, cx: r.left + r.width / 2, cy: r.top + r.height / 2 });
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
      window.CFStore = { dump: () => log };
    </script>
    </body></html>
  HTML

  PHONE = { "name" => "phone", "w" => 390, "h" => 693, "dpr" => 2, "mobile" => true,
            "ua" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148" }.freeze

  def setup
    skip "docker not available" unless ChangeDocker.available?
  end

  def test_prototype_glide_follows_the_curve_and_the_press_shows_before_the_click
    Dir.mktmpdir do |dir|
      ChangeDocker.with_browserless(network: nil) do |session|
        PrototypeCapture.capture(session: session, html: PROTO, out_dir: dir, state: {}, prng_seed: 7, duration_ms: 1000,
                                 viewport: { "w" => 400, "h" => 460, "dpr" => 1 },
                                 interactions: [ { "t_ms" => 0, "op" => "scroll", "target" => "#list", "dy" => 300, "ms" => 500 },
                                                 { "t_ms" => 600, "op" => "tap", "target" => "#buy", "press_ms" => 200 } ])
      end
      after = after_frames(JSON.parse(File.read(File.join(dir, "end-state.json"))))
      # A 500 ms glide is 15 frames (0..14); after frame k the offset is
      # 300 * ease((k + 1) / 15) as scheduled (to 0.01 px), within the half
      # pixel a dpr 1 page snaps a scroll offset by, the last exact.
      tops = (0..14).map { |k| after[k]["top"] }
      want = (0..14).map { |k| (300 * PrototypeCapture.ease("ease-in-out", (k + 1) / 15.0)).round(2) }
      tops.zip(want).each_with_index { |(got, exp), k| assert_in_delta exp, got, 0.5, "frame #{k}" }
      assert_equal 300, tops.last
      assert tops.each_cons(2).all? { |a, b| b > a }, "monotonic: #{tops.inspect}"
      # The press lands on frame 18 and releases on frame 24 (200 ms).
      before = after[17]
      pressed = after[18]
      assert_equal "0.96", pressed["scale"]
      assert_in_delta 0.82, pressed["opacity"].to_f, 1e-6
      assert_nil after[23]["clicked"], "the click has not fired while the finger is down"
      refute_nil after[24]["clicked"], "the release lands the real click"
      assert_equal "none", after[24]["scale"], "the release lifts the pressed look"
      assert_in_delta before["cx"], pressed["cx"], 0.01, "a translateX(-50%) target keeps its centre while pressed"
      assert_in_delta before["cy"], pressed["cy"], 0.01
    end
  end

  def test_phone_navigate_run_continues_the_same_page
    board = { "fps" => 30, "viewport" => { "w" => 1080, "h" => 1920 }, "scenes" => [
      { "id" => "feed", "order" => 1, "device" => "phone-fullbleed", "screen" => { "url" => "about:blank" },
        "interactions" => [ { "t_ms" => 0, "op" => "scroll", "target" => "html", "dy" => 440, "ms" => 900 },
                            { "t_ms" => 1000, "op" => "tap", "target" => "#next", "navigate" => true } ] },
      { "id" => "detail", "order" => 2, "device" => "phone-fullbleed", "screen" => { "url" => "about:blank#detail" },
        "session_from_scene" => "feed", "timing" => { "min_ms" => 600 } }
    ] }
    feed, detail = board["scenes"]
    cut = WalkthroughLive.navigate_cut(board, feed)
    job = WalkthroughLive.run_job(board, feed, detail, PHONE, WalkthroughLive::Secrets.new([]), cut, shots: true).merge("html" => FEED)
    run = film(board, feed, job)
    keep(run, "run")
    assert_equal "scrolled 440", run.dig("composed", "status"), "the destination is the same page, its scroll position kept"
    at = cut["cut_frame"]
    assert_equal run["cursor"][at - 1].values_at("x", "y"), run["cursor"][at].values_at("x", "y"), "the cursor never jumps at the cut"
    head, tail = WalkthroughLive::NavigateRun.split(run, cut)
    assert_equal at, head["ticks"].size
    assert_equal 4, tail["cursor"].first["carry"], "the ripple carries its 4 frames into the next scene"
    assert_operator run["frames"].size, :>, 20, "the glide streams many distinct frames, not a jump"
    bad = job.merge("expectUrl" => "about:blank#elsewhere")
    error = assert_raises(StandardError) { film(board, feed, bad) }
    assert_match(/tap-navigate never reached the next scene's url about:blank#elsewhere/, error.message)
  end

  # A full page load: the destination is a new document. The first incoming
  # frame must show it painted, not the old page or a blank one mid-load.
  def test_navigate_run_first_incoming_frame_shows_the_painted_destination
    dest = "<!doctype html><html><body style='margin:0;background:#c03'><h1 style='font:64px sans-serif;color:#fff'>Detail</h1></body></html>"
    # A blob URL is a real top-level document load (Chromium refuses a
    # top-level data: navigation), so the URL is only known in the page.
    href = "https://app.localhost/detail"
    feed = "<!doctype html><html><body style='margin:0;background:#fff'><a id='next' " \
           "style='display:block;margin:200px 40px;padding:40px;background:#246;color:#fff'>Go</a>" \
           "<script>document.getElementById('next').href = URL.createObjectURL(new Blob([#{JSON.generate(dest)}], { type: 'text/html' }));</script></body></html>"
    board = { "fps" => 30, "viewport" => { "w" => 1080, "h" => 1920 }, "transition" => { "type" => "push", "ms" => 300 }, "scenes" => [
      { "id" => "feed", "order" => 1, "device" => "phone-fullbleed", "screen" => { "url" => "about:blank" },
        "interactions" => [ { "t_ms" => 300, "op" => "tap", "target" => "#next", "navigate" => true } ] },
      { "id" => "detail", "order" => 2, "device" => "phone-fullbleed", "screen" => { "url" => href },
        "session_from_scene" => "feed", "timing" => { "min_ms" => 600 } }
    ] }
    cut = WalkthroughLive.navigate_cut(board, board["scenes"][0])
    job = WalkthroughLive.run_job(board, board["scenes"][0], board["scenes"][1], PHONE, WalkthroughLive::Secrets.new([]), cut, shots: true)
                        .merge("html" => feed, "expectUrl" => nil)
    run = film(board, board["scenes"][0], job)
    _, tail = WalkthroughLive::NavigateRun.split(run, cut)
    assert_equal job["events"].size - cut["cut_frame"], tail["ticks"].size, "the wait adds no frames"
    keep(tail, "incoming")
    first = Base64.decode64(run["frames"][tail["ticks"].first])
    assert_operator red_share(first), :>, 0.5, "the first incoming frame shows the painted destination"
  end

  private

  # The share of pixels that are the destination's red, via the pinned ffmpeg.
  def red_share(jpg)
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "f.jpg"), jpg)
      argv = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, mounts: { dir => "/w" },
                                      args: [ "-v", "error", "-i", "/w/f.jpg", "-vf", "scale=20:20", "-f", "rawvideo", "-pix_fmt", "rgb24", "/w/f.rgb" ])
      Open3.capture2e(*argv)
      px = File.binread(File.join(dir, "f.rgb")).bytes.each_slice(3).to_a
      px.count { |r, g, b| r > 150 && g < 80 && b < 100 }.fdiv(px.size)
    end
  end

  # The page's state after each frame's input, by frame index. Frame k's
  # input runs once the clock reaches (k + 1) frames, so a record strictly
  # between (k + 1) and (k + 2) frames shows it; a record landing exactly on
  # a frame boundary could fall either side and is skipped.
  def after_frames(log)
    step = 1000.0 / 30
    log.filter_map do |e|
      f = (e["t"] - PrototypeCapture::START_MS) / step
      [ f.floor - 1, e ] unless (f - f.round).abs < 1e-6
    end.group_by(&:first).transform_values { |list| list.last.last }
  end

  def film(board, scene, job)
    code = WalkthroughLive.capture_module(board, scene, jobs: [ job ], session: nil)
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
