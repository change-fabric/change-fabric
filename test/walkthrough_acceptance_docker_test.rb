# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "../scripts/change_docker"
require_relative "../scripts/prototype_capture"
require_relative "../scripts/walkthrough_cache"
require_relative "../scripts/walkthrough_clipcheck"
require_relative "../scripts/walkthrough_ffmpeg"
require_relative "../scripts/walkthrough_loudness"
require_relative "../scripts/walkthrough_storyboard"

# The acceptance board end to end in the pinned images, free: word anchors
# resolve from fixture alignments and the click lands on its word's frame in
# a real capture; the baked faces are the ones the page renders with; no text
# crosses the safe area or falls under the label size; and a narrated mix
# leveled by the two passes passes the master loudness gate.
class WalkthroughAcceptanceDockerTest < Minitest::Test
  ACCEPTANCE = File.join(__dir__, "fixtures", "walkthrough", "acceptance")
  STAGE = File.read(File.join(ACCEPTANCE, "screens", "stage.html"))

  def setup
    skip "docker not available" unless ChangeDocker.available?
    @dir = Dir.mktmpdir
    @board = WalkthroughStoryboard.load(File.join(ACCEPTANCE, "board.json"))
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def resolve!
    WalkthroughStoryboard.scenes(@board).each do |scene|
      dest = WalkthroughCache.path(@dir, :audio, WalkthroughStoryboard.audio_key(@board, scene), "alignment.json")
      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.cp(File.join(ACCEPTANCE, "alignments", "#{scene['id']}.json"), dest)
    end
    assert_equal [], WalkthroughStoryboard.resolve_anchors(@board, @dir)
  end

  # The installed-face probe: a family is real when text set in it measures
  # differently from the same text in a generic fallback.
  FONT_PROBE = <<~JS
    export default async function ({ page }) {
      await page.setViewport({ width: 1920, height: 1080 });
      await page.setContent(#{JSON.generate(STAGE)}, { waitUntil: "load" });
      const data = await page.evaluate(async () => {
        await document.fonts.ready;
        const ctx = document.createElement("canvas").getContext("2d");
        const width = (font) => { ctx.font = font; return ctx.measureText("Every change starts as a plan 0123").width; };
        return {
          inter: width('40px "Inter", monospace') !== width("40px monospace"),
          serif: width('96px "Source Serif 4", monospace') !== width("96px monospace"),
          h1: getComputedStyle(document.querySelector("#statement")).fontFamily,
          button: getComputedStyle(document.querySelector("#ship")).fontFamily
        };
      });
      return { data, type: "application/json" };
    }
  JS

  def test_landing_frames_faces_clipping_and_type_size
    resolve!
    scene = @board["scenes"].find { |s| s["id"] == "plan" }
    fps = WalkthroughStoryboard.fps(@board)
    click = scene["interactions"].find { |op| op["op"] == "click" }
    out = File.join(@dir, "plan")
    ChangeDocker.with_browserless(network: nil) do |session|
      fonts = session.run_function(FONT_PROBE)
      assert fonts["inter"], "Inter is installed in #{ChangeDocker::BROWSERLESS_IMAGE}"
      assert fonts["serif"], "Source Serif 4 is installed in #{ChangeDocker::BROWSERLESS_IMAGE}"
      assert_match(/\A"?Source Serif 4"?,/, fonts["h1"])
      assert_match(/\A"?Inter"?,/, fonts["button"])

      PrototypeCapture.capture(session: session, html: STAGE, interactions: scene["interactions"], duration_ms: click["t_ms"] + 300,
                               out_dir: out, state: {}, prng_seed: 7, viewport: @board["viewport"], fps: fps, label: "plan")
    end

    cursor = JSON.parse(File.read(File.join(out, "cursor.json")))
    pressed = cursor.find { |c| c["down"] }
    assert pressed, "the click is captured"
    assert_in_delta PrototypeCapture.frame_at(click["t_ms"], fps) + 1, pressed["frame"], 1, "the click lands on the frame of its word"

    result = WalkthroughClipcheck.check_dir(out)
    refute_nil result, "the stage reports its boxes"
    assert_empty result[:refusals]
    ship = JSON.parse(File.read(File.join(out, WalkthroughClipcheck::BOXES)))["frames"].last["boxes"].find { |b| b["id"] == "ship" }
    assert_operator pressed["x"], :>=, ship["x"]
    assert_operator pressed["x"], :<=, ship["x"] + ship["w"]
  end

  def ffmpeg!(args)
    argv = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, args: args, mounts: { @dir => "/work" }, workdir: "/work")
    out, status = Open3.capture2e("timeout", "300", *argv)
    assert status.success?, out.lines.last(10).join
    out
  end

  def test_narrated_master_passes_the_loudness_gate
    FileUtils.mkdir_p(File.join(@dir, "f0"))
    ffmpeg!([ "-hide_banner", "-v", "error", "-y", "-f", "lavfi", "-i", "color=c=gray:s=64x36:r=30", "-frames:v", "150",
              "-start_number", "1", "f0/%06d.png" ])
    ffmpeg!([ "-hide_banner", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=f=220:r=48000:d=5", "-af", "volume=0.05", "-ac", "1", "n0.wav" ])
    FileUtils.cp(File.join(__dir__, "..", "scripts", "vendor", "walkthrough", "cursor.png"), @dir)
    scene = { id: "plan", frames_dir: "/work/f0", frames: 150, start_frame: 0, transition: { "type" => "cut", "ms" => 0 },
              cursor: [], hero_still: false, audio: "/work/n0.wav", offset_ms: 0 }
    plan = { fps: 30, width: 64, height: 36, total_ms: 5000, cursor_png: "/work/cursor.png", srt: "/work/c.srt",
             output: "/work/master.mp4", music: nil, duck_spans: [], scenes: [ scene ], caption_track: false }
    ffmpeg!(WalkthroughFfmpeg.pass2(plan, WalkthroughFfmpeg.parse_loudnorm(ffmpeg!(WalkthroughFfmpeg.pass1(plan)))))
    result = WalkthroughLoudness.check(File.join(@dir, "master.mp4"), @board, docker: ->(argv) { Open3.capture2e("timeout", "120", *argv) })
    assert result.pass?, result.reason
  end
end
