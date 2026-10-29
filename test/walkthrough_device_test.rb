# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/walkthrough_storyboard"
require_relative "../scripts/walkthrough_device"
require_relative "../scripts/walkthrough_ffmpeg"

# Scene devices and layouts: validation, canvas geometry, cursor and tap
# mapping, the composite filter, and caption-safe frame checks.
class WalkthroughDeviceTest < Minitest::Test
  BOARD = { "viewport" => { "w" => 1920, "h" => 1080, "dpr" => 1 } }.freeze

  def scene(devices, layout = nil) = { "devices" => devices, "layout" => layout }.compact

  def test_scene_errors
    assert_empty WalkthroughDevice.scene_errors({})
    assert_empty WalkthroughDevice.scene_errors(scene([ "phone" ]))
    assert_empty WalkthroughDevice.scene_errors(scene(%w[desktop phone], "side_by_side"))
    assert_includes WalkthroughDevice.scene_errors({ "device" => "phone" }).join, "device is replaced by devices"
    assert_includes WalkthroughDevice.scene_errors(scene(%w[desktop phone])).join, "need layout side_by_side"
    assert_includes WalkthroughDevice.scene_errors(scene([ "phone" ], "side_by_side")).join, "side_by_side needs"
    assert_includes WalkthroughDevice.scene_errors(scene([ "tablet" ])).join, "devices must be"
    assert_includes WalkthroughDevice.scene_errors(scene([ "phone" ], "grid")).join, "layout must be"
  end

  def test_board_phone_errors
    assert_empty WalkthroughDevice.board_errors({ "phone" => { "w" => 412, "h" => 915, "dpr" => 2.625, "ua" => "Test UA" } })
    errs = WalkthroughDevice.board_errors({ "phone" => { "w" => 5, "dpr" => 9, "ua" => " ", "x" => 1 } })
    assert_equal 4, errs.size
  end

  def test_default_scene_is_full_bleed
    lay = WalkthroughDevice.layout(BOARD, {})
    rect = lay.rect("desktop")
    assert_equal [ 0, 0, 1920, 1080, 0 ], [ rect.x, rect.y, rect.w, rect.h, rect.bezel ]
    assert_empty WalkthroughDevice.frame_findings(lay)
    assert_equal "[0:v]scale=1920:1080:flags=lanczos,pad=1920:1080:0:0:color=0xE6E7EB[d0];[d0]null[out]", WalkthroughDevice.filter(lay)
  end

  def test_phone_is_centered_above_the_caption_band
    lay = WalkthroughDevice.layout(BOARD, scene([ "phone" ]))
    phone = lay.rect("phone")
    assert_in_delta 1920 / 2.0, phone.outer_x + (phone.outer_w / 2.0), 2
    assert_operator phone.bottom, :<=, WalkthroughDevice.band_top(1080)
    assert_in_delta 390.0 / 844, phone.w.to_f / phone.h, 0.01
    assert_empty WalkthroughDevice.frame_findings(lay)
  end

  def test_side_by_side_fits_both_frames
    lay = WalkthroughDevice.layout(BOARD.merge("phone" => { "w" => 412, "h" => 915 }), scene(%w[desktop phone], "side_by_side"))
    desk, phone = lay.rects
    assert_equal %w[desktop phone], lay.rects.map(&:name)
    assert_operator desk.outer_x + desk.outer_w, :<, phone.outer_x
    assert_operator phone.outer_x + phone.outer_w, :<=, 1920
    lay.rects.each { |r| assert_operator r.bottom, :<=, WalkthroughDevice.band_top(1080) }
    assert_in_delta 1920.0 / 1080, desk.w.to_f / desk.h, 0.01
    assert_includes WalkthroughDevice.filter(lay), "[d0][d1]overlay=x=#{phone.outer_x}:y=#{phone.outer_y}:shortest=1[o1];[o1]null[out]"
  end

  def test_frame_findings_flag_a_frame_in_the_band
    rect = WalkthroughDevice::Rect.new(name: "phone", scale: 1.0, x: 10, y: 900, w: 100, h: 160, bezel: 4)
    lay = WalkthroughDevice::Layout.new(rects: [ rect ], canvas_w: 1920, canvas_h: 1080)
    finding = WalkthroughDevice.frame_findings(lay).first
    assert_equal [ "caption-safe", "phone frame" ], finding.values_at("rule", "target")
  end

  def test_tap_and_arrow_mapping
    rect = WalkthroughDevice::Rect.new(name: "phone", scale: 0.5, x: 100, y: 40, w: 195, h: 422, bezel: 7)
    assert_equal [ 150.0, 90.0 ], rect.map(100, 100)
    positions = [ { "x" => 0, "y" => 0, "down" => false }, { "x" => 100, "y" => 100, "down" => true } ] +
                Array.new(WalkthroughDevice::RIPPLE_FRAMES + 1) { { "x" => 300, "y" => 300, "down" => false } }
    path = WalkthroughDevice.ripple_path(rect, positions)
    half = WalkthroughDevice::RIPPLE / 2.0
    assert_equal WalkthroughDevice::OFF_CANVAS, path[0]["x"]
    assert_equal({ "frame" => 2, "x" => 150 - half, "y" => 90 - half, "down" => true }, path[1])
    assert_equal [ 150 - half, false ], path[2].values_at("x", "down")
    assert_equal WalkthroughDevice::OFF_CANVAS, path[1 + WalkthroughDevice::RIPPLE_FRAMES]["x"]
    arrow = WalkthroughDevice.arrow_path(rect, [ { "x" => 10, "y" => 20, "down" => true } ])
    assert_equal [ { "frame" => 1, "x" => 105.0, "y" => 50.0, "down" => true } ], arrow
    assert WalkthroughDevice.hidden_path(3).all? { |p| p["x"] == WalkthroughDevice::OFF_CANVAS }
  end

  def test_specs_use_mobile_emulation_for_the_phone
    specs = WalkthroughDevice.specs(BOARD.merge("phone" => { "ua" => "Test UA" }), scene(%w[desktop phone], "side_by_side"))
    assert_equal [ false, true ], specs.map { |s| s["mobile"] }
    assert_equal [ 390, 844, 2, "Test UA" ], specs.last.values_at("w", "h", "dpr", "ua")
    assert_equal "phone side_by_side", WalkthroughDevice.group(scene(%w[desktop phone], "side_by_side"), "phone")
  end

  def test_ffmpeg_overlays_taps_without_a_new_input
    plan = { fps: 30, output: "/work/out.mp4", scenes: [
      { id: "a", cursor: [ { "frame" => 1, "x" => -200, "y" => -200 } ], taps: [ { "frame" => 1, "x" => 50, "y" => 60 } ], frames: 1, start_frame: 0 }
    ] }
    chain = WalkthroughFfmpeg.scene_chain(plan, plan[:scenes].first, 0).join(";")
    assert_includes chain, "[a0]"
    assert_includes chain, "color=c=white@0:s=44x44"
    assert_includes chain, "[a0][r0]overlay=x='50':y='60'"
    refute_includes WalkthroughFfmpeg.scene_chain(plan, plan[:scenes].first.merge(taps: nil), 0).join, "[r0]"
  end
end
