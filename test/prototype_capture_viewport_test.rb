# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "json"
require "tmpdir"
require_relative "../scripts/prototype_capture"
require_relative "../scripts/walkthrough_live"
require_relative "support/png_fixture"

# A capture must come out at the board's viewport. browserless sometimes
# lays a page out at its 800x600 default window instead, so the capture
# asserts the laid-out size and every frame's size, retries a mismatch on
# a fresh call, never caches a wrong-size capture, and rejects one already
# in the cache.
class PrototypeCaptureViewportTest < Minitest::Test
  VIEWPORT = { "w" => 64, "h" => 36, "dpr" => 1 }.freeze

  # Answers each batch with frames of the queued sizes in turn (the last
  # one repeats), or with a laid-out size mismatch for :mismatch.
  class SizedSession
    attr_reader :calls

    def initialize(*answers)
      @answers = answers
      @calls = 0
    end

    def alive? = true

    def run_function(code, launch_args: nil)
      _ = launch_args
      answer = @answers[[ @calls, @answers.size - 1 ].min]
      @calls += 1
      return { "viewportMismatch" => [ 800, 600 ], "frames" => [], "cursor" => [] } if answer == :mismatch

      n = code[/const last = (\d+);/, 1].to_i - code[/const first = (\d+);/, 1].to_i + 1
      frame = Base64.strict_encode64(PngFixture.png(*answer))
      { "frames" => Array.new(n, frame), "cursor" => Array.new(n) { { "x" => 0, "y" => 0, "down" => false } },
        "endState" => nil, "blockedRequests" => [], "pageErrors" => [] }
    end
  end

  def capture(session, dir)
    PrototypeCapture.capture(session: session, html: "<p/>", interactions: [], duration_ms: 100, out_dir: dir,
                             state: {}, prng_seed: 7, viewport: VIEWPORT)
  end

  def test_png_info_reads_the_ihdr_size
    assert_equal [ 64, 36 ], PngInfo.size(PngFixture.png(64, 36))
    assert_nil PngInfo.size("png")
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "a.png"), PngFixture.png(3, 5))
      assert_equal [ 3, 5 ], PngInfo.file_size(File.join(dir, "a.png"))
      assert_nil PngInfo.file_size(File.join(dir, "missing.png"))
    end
  end

  def test_the_capture_module_applies_and_asserts_the_viewport_on_the_page
    code = PrototypeCapture.function_module(html: "<p/>", events: [], range: 0...1, viewport: VIEWPORT, prng_seed: 1, state: {})
    assert_includes code, "async function ensureViewport(page, vp)"
    assert_includes code, '"Emulation.setDeviceMetricsOverride"'
    assert_includes code, "window.innerWidth, window.innerHeight"
    assert_includes code, 'ensureViewport(page, {"width":64,"height":36,"deviceScaleFactor":1,"mobile":false})'
    assert_includes code, "viewportMismatch: laidOut"
    assert_operator code.index("setContent"), :<, code.index("await ensureViewport(page"), "asserted after the page loads"
  end

  def test_a_desktop_live_page_asserts_its_viewport_too
    code = WalkthroughLive.page_setup_js(false) + WalkthroughLive.run_device_js({ "fps" => 30 }, { "id" => "s" })
    assert_includes code, "async function ensureViewport(page, vp)"
    assert_includes code, "if (!dev.mobile)"
    assert_includes code, "viewport mismatch: laid out at"
  end

  def test_a_laid_out_mismatch_is_retried_on_a_fresh_call
    Dir.mktmpdir do |dir|
      session = SizedSession.new(:mismatch, [ 64, 36 ])
      capture(session, dir)
      assert_equal 2, session.calls
      assert_equal [ 64, 36 ], PngInfo.file_size(File.join(dir, "000001.png"))
      assert File.file?(File.join(dir, "end-state.json"))
    end
  end

  def test_a_wrong_size_frame_is_retried_and_never_written
    Dir.mktmpdir do |dir|
      session = SizedSession.new([ 800, 600 ], [ 64, 36 ])
      capture(session, dir)
      assert_equal 2, session.calls
      Dir.glob(File.join(dir, "*.png")).each { |f| assert_equal [ 64, 36 ], PngInfo.file_size(f) }
    end
  end

  def test_a_persistent_mismatch_fails_without_caching_anything
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "end-state.json"), "null\n")
      session = SizedSession.new([ 800, 600 ])
      error = assert_raises(PrototypeCapture::ViewportMismatchError) { capture(session, dir) }
      assert_match(/800x600, not 64x36/, error.message)
      assert_equal 1 + PrototypeCapture::VIEWPORT_RETRIES, session.calls
      assert_empty Dir.glob(File.join(dir, "*.png"))
      refute File.file?(File.join(dir, "end-state.json")), "an older marker never vouches for a failed capture"
    end
    assert_raises(PrototypeCapture::ViewportMismatchError) do
      PrototypeCapture.check_result!({ "viewportMismatch" => [ 800, 600 ] }, "s")
    end
  end

  def test_frame_size_follows_the_dpr
    assert_equal [ 2560, 1440 ], PrototypeCapture.frame_size({ "w" => 1280, "h" => 720, "dpr" => 2 })
    assert_equal [ 1920, 1080 ], PrototypeCapture.frame_size(nil)
  end

  def test_the_cache_rejects_a_capture_of_the_wrong_size
    board = { "viewport" => { "w" => 64, "h" => 36, "dpr" => 1 }, "scenes" => [] }
    scene = { "id" => "logo" }
    Dir.mktmpdir do |dir|
      refute PrototypeCapture.cached?(board, scene, dir), "no marker, not cached"
      File.write(File.join(dir, "end-state.json"), "null\n")
      File.binwrite(File.join(dir, "000001.png"), PngFixture.png(800, 600))
      refute PrototypeCapture.cached?(board, scene, dir), "an 800x600 capture of a 64x36 board is stale"
      File.binwrite(File.join(dir, "000001.png"), PngFixture.png(64, 36))
      assert PrototypeCapture.cached?(board, scene, dir)
    end
  end

  def test_a_browser_framed_scene_is_checked_against_its_stage
    board = { "viewport" => { "w" => 64, "h" => 36, "dpr" => 1 }, "scenes" => [] }
    scene = { "id" => "web", "screen" => { "html" => "screens/web.html", "frame" => "browser" }, "camera" => { "zoom" => 1.5 } }
    assert WalkthroughBrowserFrame.browser?(scene)
    assert_equal [ 96, 54 ], PrototypeCapture.expected_frame_size(board, scene)
    assert_equal WalkthroughSharpness.stage_size(board, scene), PrototypeCapture.expected_frame_size(board, scene)
  end

  def test_capture_versions_are_bumped_so_old_captures_are_not_reused
    assert_operator PrototypeCapture::CAPTURE_VERSION, :>=, 3
    assert_operator WalkthroughLive::CAPTURE_VERSION, :>=, 3
  end
end
