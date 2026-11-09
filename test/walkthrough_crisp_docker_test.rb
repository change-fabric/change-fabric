# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "../scripts/walkthrough_render"

# Real capture and assembly of a synthetic walkthrough in the pinned
# browserless and FFmpeg images. A camera-zoomed scene of fine text is
# captured at its derived dpr and, as the baseline, at dpr 1 (what every
# capture was before: headless Chromium ignored the emulated dpr), then each
# is assembled and its text compared with an ideal render. Also checks that
# the browser never paints its own cursor into a frame and that a crossfade
# shows one composited cursor, not two.
class WalkthroughCrispDockerTest < Minitest::Test
  FPS = 30
  ZOOM = 1.5
  PAD = 3
  # A text crop in canvas px, inside the zoomed view of the column.
  CROP = [ 480, 240, 100, 300 ].freeze
  TEXT = "Quarterly ledger reconciled 0123456789, invoices matched and approved. " * 40
  PAGE = <<~HTML
    <!doctype html><html><head><meta charset="utf-8"><style>
    body { margin: 0; background: #fff; color: #333; font: 13px/1.4 sans-serif; }
    .col { position: absolute; left: 40px; top: 60px; width: 900px; }
    #pointer { position: absolute; left: 1300px; top: 100px; width: 500px; height: 400px; background: #fff; cursor: pointer; }
    </style></head><body><div class="col"><p>#{TEXT}</p></div><div id="pointer"></div></body></html>
  HTML
  MEASURED = { "input_i" => "-30", "input_tp" => "-30", "input_lra" => "1", "input_thresh" => "-40", "target_offset" => "0" }.freeze

  def setup
    skip "docker not available" unless ChangeDocker.available?
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def scene = { "id" => "zoom", "order" => 1, "timing" => { "min_ms" => 200 }, "camera" => { "zoom" => ZOOM },
                "interactions" => [ { "t_ms" => 0, "op" => "move", "target" => "#pointer", "duration_ms" => 60 } ] }

  def ffmpeg(*args, entrypoint: nil)
    argv = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, args: args, entrypoint: entrypoint,
                                    mounts: { @dir => "/work" }, workdir: "/work")
    out, status = Open3.capture2e(*argv)
    assert status.success?, out.lines.last(10).join
    out
  end

  def gray(file, filter)
    argv = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, mounts: { @dir => "/work" }, workdir: "/work",
                                    args: [ "-v", "error", "-i", "/work/#{file}", "-vf", "#{filter},format=gray", "-f", "rawvideo", "-" ])
    out, = Open3.capture2(*argv, binmode: true)
    out.bytes
  end

  def capture(session, board, name)
    dir = File.join(@dir, name)
    PrototypeCapture.capture(session: session, html: PAGE, interactions: scene["interactions"], duration_ms: 200, out_dir: dir,
                             state: {}, prng_seed: 1, viewport: PrototypeCapture.scene_viewport(board, scene), fps: FPS, label: name)
    dir
  end

  def reference(session)
    code = <<~JS
      export default async function ({ page }) {
        await page.setViewport({ width: 1920, height: 1080, deviceScaleFactor: 3 });
        await page.setContent(#{JSON.generate(PAGE)}, { waitUntil: "load" });
        return { data: { png: await page.screenshot({ encoding: "base64" }) }, type: "application/json" };
      }
    JS
    png = session.run_function(code, launch_args: BrowserlessJs.capture_launch_args(3))["png"]
    File.binwrite(File.join(@dir, "ref.png"), Base64.decode64(png))
  end

  def plan(scenes, out)
    { fps: FPS, width: 1920, height: 1080, total_ms: scenes.sum { |s| s[:frames] } * 1000 / FPS, cursor_png: "/work/cursor.png",
      srt: "/work/c.srt", output: "/work/#{out}", music: nil, duck_spans: [], scenes: scenes }
  end

  def assemble(plan)
    WalkthroughFfmpeg.sendcmd_files(plan).each { |path, body| File.write(path.sub("/work", @dir), body) }
    ffmpeg(*WalkthroughFfmpeg.pass2(plan, MEASURED))
  end

  def zoom_scene(name)
    { id: name, frames_dir: "/work/#{name}", frames: 6, start_frame: 0, transition: { "type" => "cut", "ms" => 0 },
      cursor: [], hero_still: false, camera: { "zoom" => ZOOM }, stage: [ 2880, 1620 ], audio: nil, offset_ms: 0 }
  end

  # Best PSNR of the mp4's last frame text crop against the ideal render,
  # over small alignment shifts.
  def psnr_vs_ideal(mp4)
    w, h, x, y = CROP
    ffmpeg("-y", "-sseof", "-0.05", "-i", "/work/#{mp4}", "-frames:v", "1", "/work/#{mp4}.png")
    got = gray("#{mp4}.png", "crop=#{w}:#{h}:#{x}:#{y}")
    bw = w + (2 * PAD)
    ref = gray("ref.png", "scale=2880:1620:flags=area,crop=#{bw}:#{h + (2 * PAD)}:#{480 + x - PAD}:#{270 + y - PAD}")
    (-PAD..PAD).to_a.product((-PAD..PAD).to_a).map do |dx, dy|
      mse = 0
      got.each_with_index { |v, k| mse += (v - ref[(((k / w) + PAD + dy) * bw) + (k % w) + PAD + dx])**2 }
      10 * Math.log10(255.0**2 / (mse.to_f / got.size).clamp(1e-9, nil))
    end.max
  end

  def test_crisp_capture_and_one_cursor
    FileUtils.cp(WalkthroughRender::CURSOR_PNG, File.join(@dir, "cursor.png"))
    File.write(File.join(@dir, "c.srt"), "1\n00:00:00,000 --> 00:00:00,100\n.\n")
    derived = baseline = nil
    ChangeDocker.with_browserless(network: nil) do |session|
      derived = capture(session, {}, "derived")
      baseline = capture(session, { "viewport" => { "dpr" => 1 } }, "baseline")
      reference(session)
    end
    assert_equal [ 3840, 2160 ], png_size(File.join(derived, "000001.png")), "dpr 2 really lands in the frame"
    assert_equal [ 1920, 1080 ], png_size(File.join(baseline, "000001.png"))
    native_cursor_absent!(derived)

    assemble(plan([ zoom_scene("derived") ], "derived.mp4"))
    assemble(plan([ zoom_scene("baseline") ], "baseline.mp4"))
    sharp = psnr_vs_ideal("derived.mp4")
    soft = psnr_vs_ideal("baseline.mp4")
    assert_operator sharp, :>, soft + 1.0, format("derived %.2f dB vs baseline %.2f dB against the ideal render", sharp, soft)

    one_cursor_through_a_fade!
  end

  def png_size(path) = File.binread(path, 24)[16, 8].unpack("NN")

  # The pointer rests over a `cursor: pointer` region of plain white: any
  # dark pixel there would be a cursor the browser painted itself.
  def native_cursor_absent!(dir)
    last = JSON.parse(File.read(File.join(dir, "cursor.json"))).last
    x = (last["x"] * 2).round - 40
    y = (last["y"] * 2).round - 40
    px = gray("#{File.basename(dir)}/000006.png", "crop=120:120:#{x}:#{y}")
    assert_operator px.min, :>=, 250, "no native cursor painted at #{last['x']},#{last['y']}"
  end

  # Two white scenes crossfade; each has its cursor at a different spot.
  # Mid-fade, only the incoming scene's cursor is drawn.
  def one_cursor_through_a_fade!
    %w[w1 w2].each do |d|
      FileUtils.mkdir_p(File.join(@dir, d))
      ffmpeg("-y", "-f", "lavfi", "-i", "color=c=white:s=1920x1080:r=#{FPS}", "-frames:v", "30", "-start_number", "1", "/work/#{d}/%06d.png")
    end
    track = ->(x, y) { (1..30).map { |f| { "frame" => f, "x" => x, "y" => y } } }
    scenes = [
      { id: "w1", frames_dir: "/work/w1", frames: 30, start_frame: 0, transition: { "type" => "cut", "ms" => 0 },
        cursor: track.call(300, 300), hero_still: false, audio: nil, offset_ms: 0 },
      { id: "w2", frames_dir: "/work/w2", frames: 30, start_frame: 20, transition: { "type" => "fade", "ms" => 333 },
        cursor: track.call(1400, 700), hero_still: false, audio: nil, offset_ms: 667 }
    ]
    p = plan(scenes, "fade.mp4").merge(total_ms: 50 * 1000 / FPS)
    assemble(p)
    ffmpeg("-y", "-i", "/work/fade.mp4", "-vf", "select=eq(n\\,25)", "-frames:v", "1", "/work/fade.png")
    outgoing = gray("fade.png", "crop=40:50:295:295")
    incoming = gray("fade.png", "crop=40:50:1395:695")
    assert_operator outgoing.min, :>=, 240, "the outgoing scene's cursor is parked during the fade"
    assert_operator incoming.min, :<, 200, "the incoming scene's cursor is drawn"
  end
end
