# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../scripts/walkthrough_storyboard"
require_relative "../scripts/walkthrough_sharpness"
require_relative "../scripts/walkthrough_render"

# Capture sizing: every scene's stage, the dpr that fills its slot, and the
# guard that reports a capture stretched up into its slot.
class WalkthroughSharpnessTest < Minitest::Test
  S = WalkthroughSharpness
  BROWSER = { "url" => "http://app.example.test", "frame" => "browser" }.freeze
  ZOOMS = [ nil, 0.6, 1.0, 1.05, 1.3, 1.5, 1.8, 2.0, 2.5, 3.0 ].freeze

  def live(extra = {}) = { "id" => "s", "screen" => { "url" => "http://app.example.test" } }.merge(extra)

  def proto(extra = {}) = { "id" => "p", "screen" => { "html" => "screens/a.html" } }.merge(extra)

  def test_stage_is_the_canvas_times_a_magnifying_zoom
    assert_equal [ 1920, 1080 ], S.stage_size({}, proto)
    assert_equal [ 2880, 1620 ], S.stage_size({}, proto("camera" => { "zoom" => 1.5 }))
    assert_equal [ 1920, 1080 ], S.stage_size({}, proto("camera" => { "zoom" => 0.6 })), "a zoom out pads, it never magnifies"
    assert_equal [ 2150, 1208 ], S.stage_size({}, proto("hero_still" => true)), "the hero push-in ends at 1.12x"
    assert_equal [ 1920, 1080 ], S.stage_size({ "viewport" => { "w" => 1280, "h" => 720 } }, proto("camera" => { "zoom" => 1.5 }))
    assert_equal({ "w" => 2880, "h" => 1620, "dpr" => 1 }, S.stage_board({ "viewport" => { "w" => 1920, "h" => 1080, "dpr" => 1 } },
                                                                        proto("camera" => { "zoom" => 1.5 }))["viewport"])
  end

  # The derived dpr never stretches a capture past MAX_UPSCALE, for every
  # zoom, with and without a browser frame, and for every device layout.
  def test_derived_dpr_never_upscales_any_layout_or_zoom
    shapes = [ live, live("screen" => BROWSER), live("devices" => [ "phone" ]),
               live("devices" => %w[desktop phone], "layout" => "side_by_side"), proto, proto("hero_still" => true) ]
    shapes.product(ZOOMS).each do |scene, zoom|
      sc = zoom ? scene.merge("camera" => { "zoom" => zoom }) : scene
      rows = S.report({}, sc)
      refute_empty rows, sc.inspect
      rows.each { |r| assert_operator r["stretch"], :<=, S::MAX_UPSCALE, "#{sc.inspect}: #{S.describe(r)}" }
    end
  end

  def test_dpr_is_the_least_that_fills_the_slot
    assert_equal 1, S.desktop_dpr({}, proto)
    assert_equal 1, S.desktop_dpr({}, proto("camera" => { "zoom" => 1.05 })), "within the rounding slack"
    assert_equal 2, S.desktop_dpr({}, proto("camera" => { "zoom" => 1.5 }))
    assert_equal 2, S.desktop_dpr({}, proto("hero_still" => true))
    assert_equal 3, S.desktop_dpr({}, proto("camera" => { "zoom" => 3.0 }))
    assert_equal 1, S.desktop_dpr({}, live("screen" => BROWSER)), "the frame shrinks the page"
    assert_equal 1, S.desktop_dpr({ "viewport" => { "dpr" => 1 } }, proto("camera" => { "zoom" => 2.0 })), "an authored dpr wins"
    assert_equal 2, PrototypeCapture.scene_viewport({}, proto("camera" => { "zoom" => 1.5 }))["dpr"]
  end

  def test_guard_reports_a_pinned_dpr_that_stretches
    board = { "viewport" => { "w" => 1920, "h" => 1080, "dpr" => 1 },
              "scenes" => [ proto("order" => 1), proto("id" => "zoomed", "order" => 2, "camera" => { "zoom" => 1.5 }) ] }
    rows = S.upscaled(board)
    assert_equal [ "zoomed" ], rows.map { |r| r["scene"] }
    assert_equal({ "scene" => "zoomed", "device" => "desktop", "captured" => [ 1920, 1080 ], "slot" => [ 2880, 1620 ], "stretch" => 1.5 },
                 rows.first)
    assert_equal "zoomed (desktop): captured 1920x1080 drawn into 2880x1620, upscaled 1.50x", S.describe(rows.first)
    assert_empty S.upscaled(board.merge("viewport" => { "w" => 1920, "h" => 1080 })), "the derived dpr clears it"
  end

  def test_guard_skips_broll
    assert_empty S.report({}, { "id" => "b", "kind" => "ai-broll", "camera" => { "zoom" => 2.0 } })
  end

  # The phone spec's dpr is a floor: a zoomed phone slot raises it.
  def test_phone_dpr_rises_to_its_slot
    sc = live("order" => 1, "devices" => [ "phone" ], "camera" => { "zoom" => 2.5 })
    assert_equal 2, WalkthroughDevice.specs({}, live("devices" => [ "phone" ])).first["dpr"]
    assert_equal 3, WalkthroughDevice.specs({ "phone" => { "dpr" => 1 } }, sc).first["dpr"]
    assert_empty S.upscaled({ "phone" => { "dpr" => 1 }, "scenes" => [ sc ] })
  end

  def test_render_prints_the_guard
    out = StringIO.new
    board = { "viewport" => { "w" => 1920, "h" => 1080, "dpr" => 1 },
              "scenes" => [ proto("order" => 1, "camera" => { "zoom" => 1.5 }) ] }
    WalkthroughRender::Run.new(Dir.pwd, board: board, out: out).send(:sharpness!)
    assert_match(/warning: sharpness: 1 capture\(s\) upscaled/, out.string)
    assert_match(/p \(desktop\): captured 1920x1080 drawn into 2880x1620, upscaled 1.50x/, out.string)
    out = StringIO.new
    WalkthroughRender::Run.new(Dir.pwd, board: board.merge("viewport" => { "w" => 1920, "h" => 1080 }), out: out).send(:sharpness!)
    assert_match(/sharpness: every scene is captured at or above its slot size/, out.string)
  end
end
