# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../scripts/walkthrough_storyboard"
require_relative "../scripts/walkthrough_inset"

# The magnified inset: validation, the bounding-box mapping through the
# browser frame and full-bleed layouts, the placement above the caption
# band, the FFmpeg filter chain, the frames_key, and one containerised
# composite that checks the inset appears, fades, and leaves the frame.
class WalkthroughInsetTest < Minitest::Test
  WI = WalkthroughInset
  BOARD = { "viewport" => { "w" => 1920, "h" => 1080, "dpr" => 1 }, "fps" => 30 }.freeze
  INSET = { "selector" => ".badge", "at_ms" => 1000, "duration_ms" => 2000 }.freeze

  def live(inset = INSET, screen = {})
    { "id" => "report", "order" => 1, "assumptions" => [ "a" ], "screen" => { "url" => "https://app.example.test/report" }.merge(screen), "inset" => inset }
  end

  def test_accepts_minimal_and_full_shapes
    assert_empty WI.errors(live, live: true)
    assert_empty WI.errors(live(INSET.merge("scale" => 3, "position" => "bottom-left"), "frame" => "browser"), live: true)
    assert_empty WI.errors({ "id" => "x" }, live: false)
  end

  def test_rejects_bad_shapes
    {
      "must be an object" => live([ 1 ]),
      "selector must be" => live(INSET.merge("selector" => " ")),
      "at_ms must be" => live(INSET.merge("at_ms" => -1)),
      "duration_ms must be" => live(INSET.merge("duration_ms" => 100)),
      "scale must be" => live(INSET.merge("scale" => 9)),
      "position must be" => live(INSET.merge("position" => "center")),
      "unknown keys: zoom" => live(INSET.merge("zoom" => 2)),
      "camera.zoom are exclusive" => live.merge("camera" => { "zoom" => 1.5 }),
      "drop devices" => live.merge("devices" => %w[desktop phone])
    }.each { |msg, scene| assert_includes WI.errors(scene, live: true).join, msg, msg }
    assert_includes WI.errors(live, live: false).join, "needs a live scene"
  end

  def test_storyboard_validator_reports_inset_errors
    errs = WalkthroughStoryboard.scene_errors(live(INSET.merge("position" => "middle")), [], {}, Dir.pwd)
    assert(errs.any? { |e| e.include?("inset.position") })
    proto = { "id" => "p", "order" => 1, "assumptions" => [ "a" ], "screen" => { "html" => "screens/p.html" }, "inset" => INSET }
    assert(WalkthroughStoryboard.scene_errors(proto, [], {}, Dir.pwd).any? { |e| e.include?("needs a live scene") })
  end

  def test_full_bleed_maps_identity_and_sits_top_right_above_band
    lay = WalkthroughDevice.layout(BOARD, live)
    plan = WI.plan(live, lay, { "x" => 100, "y" => 200, "w" => 60, "h" => 14 }, viewport_w: 1920, fps: 30, frames: 120)
    assert_equal [ 94, 194, 72, 26 ], [ plan.crop_x, plan.crop_y, plan.crop_w, plan.crop_h ]
    assert_equal [ 144, 52 ], [ plan.w, plan.h ]
    margin = 42
    assert_equal 1920 - margin - plan.w - (2 * WI::BORDER), plan.x
    assert_equal margin, plan.y
    assert_equal [ 30, 89, 6 ], [ plan.start, plan.stop, plan.fade ]
  end

  def test_browser_frame_maps_through_content_rect
    scene = live(INSET.merge("position" => "bottom-left"), "frame" => "browser")
    lay = WalkthroughBrowserFrame.layout(BOARD)
    c = lay.content
    plan = WI.plan(scene, lay, { "x" => 960, "y" => 540, "w" => 40, "h" => 10 }, viewport_w: 1920, fps: 30, frames: 120)
    k = c.w / 1920.0
    assert_in_delta c.x + ((960 - WI::PAD_CSS) * k), plan.crop_x, 2
    assert_in_delta c.y + ((540 - WI::PAD_CSS) * k), plan.crop_y, 2
    band = 1080 * (1 - PrototypeUxLint::CAPTION_BAND)
    assert_operator plan.y + plan.h + (2 * WI::BORDER), :<=, band, "inset ends above the caption band"
    assert_equal 42, plan.x
    assert WalkthroughDevice.frame_findings(WalkthroughDevice.layout(BOARD, live)).empty?
  end

  def test_scale_is_capped_to_the_safe_area_and_window_to_the_scene
    huge = { "x" => 0, "y" => 0, "w" => 1900, "h" => 300 }
    plan = WI.plan(live(INSET.merge("scale" => 4)), WalkthroughDevice.layout(BOARD, live), huge, viewport_w: 1920, fps: 30, frames: 50)
    assert_operator plan.x, :>=, 42
    assert_operator plan.scale, :<, 4
    assert_equal 49, plan.stop
  end

  def test_filter_chain
    plan = WI::Plan.new(crop_x: 10, crop_y: 20, crop_w: 40, crop_h: 12, x: 100, y: 42, w: 80, h: 24, scale: 2.0, start: 30, stop: 89, fade: 6)
    out = WI.append("[0:v]scale=1920:1080[d0];[d0]null[out]", plan)
    assert_includes out, "[d0]null[cfbase];[cfbase]split=2[cfbg][cfsrc]"
    assert_includes out, "crop=40:12:10:20,scale=80:24:flags=lanczos,pad=86:30:3:3"
    assert_includes out, "fade=t=in:s=30:n=6:alpha=1,fade=t=out:s=84:n=6:alpha=1"
    assert out.end_with?("overlay=x=100:y=42:enable='between(n,30,89)'[out]")
    assert_equal "a[out]", WI.append("a[out]", nil)
    assert_raises(ArgumentError) { WI.append("a[x]", plan) }
  end

  def test_frames_key_includes_inset
    plain = live.except("inset")
    key = WalkthroughLive.frames_key(BOARD, plain)
    refute_equal key, WalkthroughLive.frames_key(BOARD, live)
    refute_equal WalkthroughLive.frames_key(BOARD, live), WalkthroughLive.frames_key(BOARD, live(INSET.merge("scale" => 3)))
  end

  # Ten flat gray frames with a red square; the inset shows a magnified red
  # region at the corner only inside its window. Runs the pinned FFmpeg.
  def test_composite_in_container
    skip "docker not available" unless ChangeDocker.available?

    Dir.mktmpdir do |dir|
      gen = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, mounts: { dir => "/w" }, workdir: "/w",
                                     args: [ "-hide_banner", "-y", "-f", "lavfi", "-i", "color=c=gray:s=320x180:r=10", "-frames:v", "10",
                                             "-vf", "drawbox=x=20:y=20:w=10:h=10:color=red:t=fill", "-start_number", "1", "in%06d.png" ])
      out, st = Open3.capture2e(*gen)
      assert st.success?, out
      plan = WI::Plan.new(crop_x: 18, crop_y: 18, crop_w: 14, crop_h: 14, x: 200, y: 10, w: 56, h: 56, scale: 4.0, start: 3, stop: 7, fade: 1)
      filter = WI.append("[0:v]null[out]", plan)
      run = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, mounts: { dir => "/w" }, workdir: "/w",
                                     args: [ "-hide_banner", "-y", "-start_number", "1", "-i", "in%06d.png", "-filter_complex", filter,
                                             "-map", "[out]", "-pix_fmt", "rgb24", "-f", "rawvideo", "out.rgb" ])
      out, st = Open3.capture2e(*run)
      assert st.success?, out
      raw = File.binread(File.join(dir, "out.rgb"))
      frame = 320 * 180 * 3
      assert_equal 10 * frame, raw.bytesize
      px = ->(f, x, y) { raw.byteslice((f * frame) + (((y * 320) + x) * 3), 3).bytes }
      red = ->(rgb) { rgb[0] > 200 && rgb[1] < 60 && rgb[2] < 60 }
      center = [ 200 + 3 + 28, 10 + 3 + 28 ]
      refute red.(px.(0, *center)), "no inset before at_ms"
      assert red.(px.(5, *center)), "magnified red inside the window"
      refute red.(px.(9, *center)), "no inset after the window"
      assert red.(px.(5, 25, 25)), "the source frame itself is untouched"
    end
  end
end
