# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/walkthrough_storyboard"
require_relative "../scripts/walkthrough_browser_frame"

# The browser frame: validation, geometry above the caption band, the
# address and title text slots, the filter, the cursor remap, and the
# frames_key material for live and environment scenes.
class WalkthroughBrowserFrameTest < Minitest::Test
  BF = WalkthroughBrowserFrame
  BOARD = { "viewport" => { "w" => 1920, "h" => 1080, "dpr" => 1 } }.freeze

  def live(screen = {}) = { "id" => "docs", "screen" => { "url" => "https://docs.example.test/northwind-agent" }.merge(screen) }

  def env(screen = {}) = { "id" => "docs", "kind" => "environment", "screen" => { "html" => "screens/docs.html" }.merge(screen) }

  def test_errors
    assert_empty BF.errors(live)
    assert_empty BF.errors(live("frame" => "browser", "title" => "Northwind Agent docs"))
    assert_empty BF.errors(env("frame" => "browser", "address" => "https://docs.example.test/install"))
    assert_includes BF.errors(live("frame" => "tablet")).join, "screen.frame must be one of browser"
    assert_includes BF.errors(live("title" => "x")).join, "need screen.frame"
    assert_includes BF.errors(env("frame" => "browser")).join, "needs screen.address"
    assert_includes BF.errors({ "screen" => { "html" => "a.html", "frame" => "browser" } }).join, "live or environment"
    assert_includes BF.errors(live("frame" => "browser", "address" => "a\nb")).join, "single-line"
    assert_includes BF.errors(live("frame" => "browser").merge("devices" => [ "phone" ])).join, "desktop only"
  end

  def test_storyboard_reports_frame_errors
    errs = WalkthroughStoryboard.scene_errors(live("frame" => "tablet").merge("order" => 1, "assumptions" => [ "a" ]), [], {}, Dir.pwd)
    assert(errs.any? { |e| e.include?("screen.frame must be") })
  end

  def test_text_defaults
    assert_equal "https://docs.example.test/northwind-agent", BF.address(live("frame" => "browser"))
    assert_equal "docs.example.test", BF.title(live("frame" => "browser"))
    assert_equal "Docs", BF.title(live("frame" => "browser", "title" => "Docs"))
  end

  def test_geometry_fits_above_caption_band_and_keeps_aspect
    lay = BF.layout(BOARD)
    c = lay.content
    assert_equal [ 1920, 1080 ], [ lay.canvas_w, lay.canvas_h ]
    assert_operator lay.window.y + lay.window.h, :<=, BF.band_top(1080)
    assert_in_delta 1920.0 / 1080, c.w.to_f / c.h, 0.01
    assert_equal 0, c.w % 2
    assert_equal 0, c.h % 2
    assert_equal lay.window.y + BF::BORDER + lay.bar.h + (lay.bar.y - lay.window.y - BF::BORDER), c.y
    assert_operator lay.field.x + lay.field.w, :<=, lay.window.x + lay.window.w
    assert_equal (1920 - lay.window.w) / 2, lay.window.x
    assert_empty WalkthroughDevice.frame_findings(lay)
  end

  def test_address_text_slot_is_clipped_to_field
    lay = BF.layout(BOARD)
    long = "https://docs.example.test/#{'a' * 190}"
    Dir.mktmpdir do |dir|
      title, address = BF.write_text(lay, live("frame" => "browser", "address" => long, "title" => "Northwind Agent"), dir)
      assert_equal "Northwind Agent", File.read(title)
      text = File.read(address)
      assert text.end_with?("...")
      assert_operator text.size * lay.font * BF::GLYPH, :<=, lay.field.w
    end
  end

  def test_filter_reads_text_from_files
    f = BF.filter(BF.layout(BOARD), title_file: "/work/t.txt", address_file: "/work/a.txt")
    assert f.start_with?("[0:v]scale=")
    assert_includes f, "textfile='/work/t.txt'"
    assert_includes f, "textfile='/work/a.txt'"
    assert_includes f, "expansion=none"
    assert f.end_with?("[out]")
  end

  def test_cursor_maps_into_content
    lay = BF.layout(BOARD)
    pt = BF.map_cursor(lay, [ { "frame" => 1, "x" => 0, "y" => 0, "down" => true } ]).first
    assert_equal [ lay.content.x.to_f, lay.content.y.to_f, true ], [ pt["x"], pt["y"], pt["down"] ]
  end

  def test_live_frames_key_includes_frame
    plain = WalkthroughLive.frames_key(BOARD, live)
    framed = WalkthroughLive.frames_key(BOARD, live("frame" => "browser"))
    retitled = WalkthroughLive.frames_key(BOARD, live("frame" => "browser", "title" => "Other"))
    assert_equal 3, [ plain, framed, retitled ].uniq.size
  end

  def test_environment_material
    assert_nil BF.material(env)
    m = BF.material(env("frame" => "browser", "address" => "https://docs.example.test/"))
    assert_equal [ "browser", BF::VERSION ], [ m[:frame], m[:version] ]
  end

  def test_frame_dir_composites_and_remaps
    Dir.mktmpdir do |work|
      dir = File.join(work, ".cache", "frames", "k")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "000001.png"), "raw")
      File.write(File.join(dir, "end-state.json"), "{}")
      File.write(File.join(dir, "cursor.json"), JSON.generate([ { "frame" => 1, "x" => 0, "y" => 0, "down" => false } ]))
      seen = nil
      docker = lambda do |argv|
        seen = argv
        File.write(File.join(dir, "framed", "000001.png"), "framed")
        [ "", Struct.new(:success?).new(true) ]
      end
      BF.frame_dir!(BOARD, env("frame" => "browser", "address" => "https://docs.example.test/"), dir, work: work, docker: docker)
      assert_includes seen.join(" "), "/work/.cache/frames/k/%06d.png"
      assert_equal "framed", File.read(File.join(dir, "000001.png"))
      refute File.exist?(File.join(dir, "framed"))
      assert_equal BF.layout(BOARD).content.x, JSON.parse(File.read(File.join(dir, "cursor.json"))).first["x"]
    end
  end

  def test_frame_dir_failure_drops_capture_marker
    Dir.mktmpdir do |work|
      File.write(File.join(work, "end-state.json"), "{}")
      docker = ->(_argv) { [ "boom", Struct.new(:success?).new(false) ] }
      assert_raises(BF::FrameError) { BF.frame_dir!(BOARD, env("frame" => "browser", "address" => "x"), work, work: work, docker: docker) }
      refute File.exist?(File.join(work, "end-state.json"))
    end
  end
end
