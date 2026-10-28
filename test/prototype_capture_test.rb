# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "json"
require "tmpdir"
require_relative "../scripts/prototype_capture"

class PrototypeCaptureTest < Minitest::Test
  def write(dir, name, body)
    path = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    path
  end

  def test_unsupported_content_raises_naming_element
    {
      "<video src='a.mp4'></video>" => "<video>",
      "<canvas></canvas>" => "<canvas>",
      "<iframe src='x.html'></iframe>" => "<iframe>",
      "<lottie-player></lottie-player>" => "Lottie",
      "<img src='https://cdn.example.com/a.png'>" => "remote src",
      "<link rel='stylesheet' href='//fonts.example.com/a.css'>" => "remote href"
    }.each do |html, needle|
      err = assert_raises(PrototypeCapture::UnsupportedContentError) { PrototypeCapture.check_supported!(html) }
      assert_includes err.message, needle
    end
    assert PrototypeCapture.check_supported!("<a href='#top'>x</a><img src='data:image/png;base64,AA'>")
  end

  def test_inline_screen_embeds_local_assets
    Dir.mktmpdir do |dir|
      write(dir, "tokens.css", ":root { --bg: #fff; } @font-face { src: url(fonts/a.woff2); }")
      write(dir, "fonts/a.woff2", "FONT")
      write(dir, "mock-store.js", "window.CFStore = {};")
      write(dir, "assets/i.svg", "<svg/>")
      html = write(dir, "s.html", <<~HTML)
        <link rel="stylesheet" href="tokens.css"><script src="mock-store.js"></script><img src="assets/i.svg">
      HTML
      out = PrototypeCapture.inline_screen(html)
      assert_includes out, "<style>:root { --bg: #fff; }"
      assert_includes out, "url(\"data:font/woff2;base64,#{Base64.strict_encode64('FONT')}\")"
      assert_includes out, "<script>window.CFStore = {};</script>"
      assert_includes out, "src=\"data:image/svg+xml;base64,"
      write(dir, "bad.css", "a { background: url(https://x.example.com/a.png); }")
      bad = write(dir, "bad.html", "<link rel='stylesheet' href='bad.css'>")
      assert_raises(PrototypeCapture::UnsupportedContentError) { PrototypeCapture.inline_screen(bad) }
    end
  end

  def test_easing_and_frame_math
    assert_in_delta 0.5, PrototypeCapture.ease("easeInOutCubic", 0.5)
    assert_in_delta 1.0, PrototypeCapture.ease("easeInOutCubic", 1.0)
    assert_in_delta 0.0, PrototypeCapture.ease("linear", -1)
    assert_equal 30, PrototypeCapture.frame_count(1000)
    assert_equal 31, PrototypeCapture.frame_count(1001)
    assert_equal 0, PrototypeCapture.frame_at(33)
    assert_equal 1, PrototypeCapture.frame_at(34)
    assert_equal [ 0...90, 90...100 ], PrototypeCapture.batches(100)
  end

  def test_schedule_interpolates_move_to_frame_boundaries
    plan = PrototypeCapture.schedule([
      { "t_ms" => 0, "op" => "move", "target" => "#a", "duration_ms" => 100, "easing" => "linear" },
      { "t_ms" => 200, "op" => "click", "target" => "#a" },
      { "t_ms" => 300, "op" => "type", "target" => "#c", "text" => "abc", "cps" => 30 },
      { "t_ms" => 500, "op" => "wait", "duration_ms" => 100 }
    ], 20)
    moves = plan.filter_map { |f| f["move"] }
    assert_equal 3, moves.size
    assert_in_delta 1.0 / 3, moves[0]["p"]
    assert moves[0]["first"]
    assert_in_delta 1.0, moves[2]["p"]
    assert_equal "#a", plan[6]["click"]
    typed = plan.filter_map { |f| f["type"] }
    assert_equal "abc", typed.map { |t| t["text"] }.join
    assert typed.first["focus"]
    assert_raises(ArgumentError) { PrototypeCapture.schedule([ { "op" => "drag", "t_ms" => 0 } ], 1) }
  end

  def test_cursor_path_numbers_frames_from_one
    path = PrototypeCapture.cursor_path([ { "x" => 1.234, "y" => 2, "down" => false }, { "x" => 3, "y" => 4, "down" => true } ])
    assert_equal [ { "frame" => 1, "x" => 1.23, "y" => 2, "down" => false }, { "frame" => 2, "x" => 3, "y" => 4, "down" => true } ], path
  end

  def test_clock_script_overrides_every_global
    js = PrototypeCapture.clock_script(prng_seed: 42, state: { "invoices" => [] })
    [ "window.Date = FixedDate", "performance.now =", "window.requestAnimationFrame =", "window.setTimeout =",
      "window.setInterval =", "Math.random = rand", "randomUUID", "localStorage.clear()", "sessionStorage.clear()",
      "indexedDB", "window.__cfAdvance", "window.__CF_SEED__ = {\"invoices\":[]}", "__cfRealRaf" ].each do |needle|
      assert_includes js, needle
    end
    assert_operator js.index("__cfRealRaf"), :<, js.index("window.requestAnimationFrame = (fn)")
  end

  def test_function_module_uses_shared_primitives_and_real_input
    mod = PrototypeCapture.function_module(html: "<p>hi</p>", plan: [ { "frame" => 0 } ], range: 0...1,
                                           viewport: nil, prng_seed: 1, state: {})
    [ "newBrowserContext", "setRequestInterception", "createCDPSession",
      "Animation.setPlaybackRate", "getAnimations", "anim.pause()", "page.mouse.move", "page.keyboard.type",
      "Page.captureScreenshot", "CFStore.dump", "width: 1920" ].each { |needle| assert_includes mod, needle }
    refute_match(/puppeteer\.launch|chromium\.launch|playwright|screencast/i, mod)
  end

  def test_clock_is_injected_ahead_of_screen_scripts
    mod = PrototypeCapture.function_module(html: "<html><head><script>app()</script></head><body></body></html>",
                                           plan: [ { "frame" => 0 } ], range: 0...1, viewport: nil, prng_seed: 1, state: {})
    refute_match(/evaluateOnNewDocument\([^\n]*__cfAdvance/, mod)
    html = PrototypeCapture.with_clock("<html><head><script>app()</script></head></html>", "window.__cfAdvance = 1;")
    assert_operator html.index("__cfAdvance"), :<, html.index("app()")
    assert_equal "<script>x</script><p>hi</p>", PrototypeCapture.with_clock("<p>hi</p>", "x")
  end

  def test_check_result_rejects_network_and_indexeddb
    assert_raises(PrototypeCapture::UnsupportedContentError) do
      PrototypeCapture.check_result!({ "blockedRequests" => [ { "url" => "https://x.example.com" } ] }, "s")
    end
    assert_raises(PrototypeCapture::UnsupportedContentError) do
      PrototypeCapture.check_result!({ "pageErrors" => [ "indexedDB is not supported under the fixed clock" ] }, "s")
    end
  end

  def test_resolve_state_applies_patch_ops
    seed = { "invoices" => [ { "status" => "draft" } ] }
    state = PrototypeCapture.resolve_state(seed, patch: [
      { "op" => "set", "path" => "invoices.0.status", "value" => "paid" },
      { "op" => "push", "path" => "invoices", "value" => { "status" => "new" } },
      { "op" => "delete", "path" => "invoices.0" }
    ])
    assert_equal [ { "status" => "new" } ], state["invoices"]
    assert_equal "draft", seed["invoices"][0]["status"]
    assert_equal({ "a" => 1 }, PrototypeCapture.resolve_state(seed, from_end_state: { "a" => 1 }))
  end

  def test_frames_key_is_order_independent_and_pins_image
    a = PrototypeCapture.frames_key(html: "h", fps: 30)
    assert_equal a, PrototypeCapture.frames_key(fps: 30, html: "h")
    refute_equal a, PrototypeCapture.frames_key(html: "h", fps: 24)
    assert_equal ChangeDocker::BROWSERLESS_IMAGE.split("@").last, PrototypeCapture.browserless_digest
  end

  class FakeSession
    attr_reader :modules

    def initialize = @modules = []

    def run_function(code)
      @modules << code
      first = code[/const first = (\d+);/, 1].to_i
      last = code[/const last = (\d+);/, 1].to_i
      n = last - first + 1
      { "frames" => Array.new(n) { Base64.strict_encode64("png") }, "cursor" => Array.new(n) { { "x" => 0, "y" => 0, "down" => false } },
        "endState" => { "done" => true }, "blockedRequests" => [], "pageErrors" => [] }
    end
  end

  def test_capture_batches_and_writes_outputs
    Dir.mktmpdir do |dir|
      session = FakeSession.new
      PrototypeCapture.capture(session: session, html: "<p/>", interactions: [], duration_ms: 4000, out_dir: dir,
                               state: {}, prng_seed: 7)
      assert_equal 2, session.modules.size
      assert_equal 120, Dir.glob(File.join(dir, "*.png")).size
      assert File.exist?(File.join(dir, "000120.png"))
      assert_equal 120, JSON.parse(File.read(File.join(dir, "cursor.json"))).size
      assert_equal({ "done" => true }, JSON.parse(File.read(File.join(dir, "end-state.json"))))
    end
  end

  def test_scene_duration_is_derived
    assert_equal 3000, PrototypeCapture.scene_duration("timing" => { "min_ms" => 3000, "pad_ms" => 400 }, "narration" => { "measured_ms" => 1000 })
    assert_equal 5400, PrototypeCapture.scene_duration("timing" => { "min_ms" => 3000, "pad_ms" => 400 }, "narration" => { "measured_ms" => 5000 })
  end
end
