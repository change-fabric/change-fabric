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

  def test_unmatched_remap_lists_only_pairs_the_screen_never_references
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "aaa.png"), "x")
      File.binwrite(File.join(dir, "bbb.png"), "y")
      File.write(File.join(dir, "s.html"), '<img src="aaa.png"><img src="stable.png">')
      File.binwrite(File.join(dir, "stable.png"), "z")
      remap = { "aaa" => "bbb", "ccc" => "ddd" }
      assert_equal [ "ccc" ], PrototypeCapture.unmatched_remap(File.join(dir, "s.html"), remap)
      assert_empty PrototypeCapture.unmatched_remap(File.join(dir, "s.html"), {})
    end
  end

  def test_unmatched_remap_never_requires_draft_assets_to_exist
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "bbb.png"), "y")
      File.binwrite(File.join(dir, "fff.png"), "y")
      File.write(File.join(dir, "s.css"), ".h{background:url('eee.png')}")
      File.write(File.join(dir, "s.html"),
        '<link rel="stylesheet" href="s.css"><img src="aaa.png"><script src="ggg.js"></script><a href="#x">x</a>')
      remap = { "aaa" => "bbb", "eee" => "fff", "ggg" => "hhh", "ccc" => "ddd" }
      assert_equal [ "ccc" ], PrototypeCapture.unmatched_remap(File.join(dir, "s.html"), remap)
    end
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

  def test_inline_screen_resolves_urls_in_every_css_source
    Dir.mktmpdir do |dir|
      write(dir, "art.png", "PNG")
      b64 = Base64.strict_encode64("PNG")
      {
        "linked" => [ "<link rel='stylesheet' href='l.css'>", "l.css" ],
        "style block" => [ "<style>.hero { background-image: url(art.png) }</style>", nil ],
        "double-quoted style attr" => [ '<div style="background: url(art.png)"></div>', nil ],
        "single-quoted style attr" => [ "<div style='background: url(\"art.png\")'></div>", nil ]
      }.each do |name, (markup, css)|
        write(dir, css, ".a { background: url('art.png') }") if css
        out = PrototypeCapture.inline_screen(write(dir, "s.html", markup))
        assert_includes out, "data:image/png;base64,#{b64}", name
        refute_match(/url\(\s*["']?art\.png/, out, name)
      end
      bad = write(dir, "bad.html", "<style>a { background: url(https://x.example.com/a.png) }</style>")
      assert_raises(PrototypeCapture::UnsupportedContentError) { PrototypeCapture.inline_screen(bad) }
    end
  end

  def test_inline_screen_preserves_stylesheet_media_conditions
    Dir.mktmpdir do |dir|
      write(dir, "d.css", "body{}")
      {
        %(<link rel="stylesheet" href="d.css" media="(prefers-color-scheme: dark)">) => %(<style media="(prefers-color-scheme: dark)">),
        %(<link media='print' rel='stylesheet' href='d.css'>) => %(<style media="print">),
        %(<link rel="stylesheet" href="d.css" media="screen and (min-width: 600px)">) => %(<style media="screen and (min-width: 600px)">),
        %(<link rel="stylesheet" href="d.css" media="all">) => "<style>",
        %(<link rel="stylesheet" href="d.css">) => "<style>"
      }.each do |link, expected|
        out = PrototypeCapture.inline_screen(write(dir, "s.html", link))
        assert_includes out, "#{expected}body{}</style>", link
      end
    end
  end

  def test_inline_screen_embeds_srcset_candidates
    Dir.mktmpdir do |dir|
      write(dir, "hero.png", "A")
      write(dir, "hero2x.png", "B")
      png = ->(b) { "data:image/png;base64,#{Base64.strict_encode64(b)}" }
      variants = {
        %(<picture><source srcset="hero.png"><img alt="Hero"></picture>) => %(srcset="#{png.('A')}"),
        %(<img srcset='hero.png 1x, hero2x.png 2x' alt="h">) => %(srcset='#{png.('A')} 1x, #{png.('B')} 2x'),
        %(<img srcset="hero.png 480w,hero2x.png 960w" alt="h">) => %(srcset="#{png.('A')} 480w, #{png.('B')} 960w"),
        %(<link rel="preload" as="image" imagesrcset="hero2x.png 2x">) => %(imagesrcset="#{png.('B')} 2x"),
        %(<img srcset="data:image/png;base64,QQ==, hero.png 2x" alt="h">) => %(srcset="data:image/png;base64,QQ==, #{png.('A')} 2x")
      }
      variants.each_with_index do |(markup, expected), i|
        assert_includes PrototypeCapture.inline_screen(write(dir, "v#{i}.html", markup)), expected
      end
      first = PrototypeCapture.inline_screen(File.join(dir, "v0.html"))
      write(dir, "hero.png", "C")
      refute_equal first, PrototypeCapture.inline_screen(File.join(dir, "v0.html"))
      remote = write(dir, "r.html", %(<img srcset="hero.png 1x, https://x.example.com/a.png 2x" alt="h">))
      assert_raises(PrototypeCapture::UnsupportedContentError) { PrototypeCapture.inline_screen(remote) }
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
  end

  def test_batch_size_shrinks_with_viewport_pixels
    assert_equal 90, PrototypeCapture.batch_size({ "w" => 1280, "h" => 720, "dpr" => 1 })
    assert_equal 40, PrototypeCapture.batch_size(nil)
    assert_equal 10, PrototypeCapture.batch_size({ "w" => 3840, "h" => 2160, "dpr" => 2 })
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

    def alive? = true

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
                               state: {}, prng_seed: 7, viewport: { "w" => 1280, "h" => 720, "dpr" => 1 })
      assert_equal 2, session.modules.size
      assert_equal 120, Dir.glob(File.join(dir, "*.png")).size
      assert File.exist?(File.join(dir, "000120.png"))
      assert_equal 120, JSON.parse(File.read(File.join(dir, "cursor.json"))).size
      assert_equal({ "done" => true }, JSON.parse(File.read(File.join(dir, "end-state.json"))))
    end
  end

  class FlakySession < FakeSession
    def initialize(drops)
      super()
      @drops = drops
    end

    def run_function(code)
      if @drops.positive?
        @drops -= 1
        raise EOFError, "end of file reached"
      end
      super
    end
  end

  def test_capture_retries_a_dropped_batch
    Dir.mktmpdir do |dir|
      PrototypeCapture.capture(session: FlakySession.new(2), html: "<p/>", interactions: [], duration_ms: 1000, out_dir: dir,
                               state: {}, prng_seed: 7)
      assert_equal 30, Dir.glob(File.join(dir, "*.png")).size
    end
    assert_raises(EOFError) { PrototypeCapture.run_with_retry(FlakySession.new(3), "const first = 0; const last = 0;") }
  end

  class GoneSession < FakeSession
    def initialize
      super
      @calls = 0
    end

    attr_reader :calls

    def run_function(_code)
      @calls += 1
      raise(@calls == 1 ? EOFError : Errno::ECONNREFUSED, "gone")
    end

    def alive? = false
  end

  def test_retry_after_a_lost_container_raises_a_clear_error
    session = GoneSession.new
    error = assert_raises(PrototypeCapture::BrowserlessGoneError) { PrototypeCapture.run_with_retry(session, "x") }
    assert_match(/container gone/, error.message)
    assert_equal 1, session.calls
  end

  def test_connection_refused_is_retried_when_the_container_is_alive
    session = Class.new(FlakySession) do
      def run_function(code)
        unless @refused
          @refused = true
          raise Errno::ECONNREFUSED
        end

        super
      end

      def alive? = true
    end.new(0)
    assert PrototypeCapture.run_with_retry(session, "const first = 0; const last = 0;")
  end

  def test_batch_size_caps_by_measured_bytes
    vp = { "w" => 1280, "h" => 720, "dpr" => 1 }
    assert_equal 90, PrototypeCapture.batch_size(vp, bytes_per_frame: 1_000_000)
    assert_equal 26, PrototypeCapture.batch_size(vp, bytes_per_frame: 5_000_000)
    assert_operator PrototypeCapture.batch_size(vp, bytes_per_frame: 5_000_000) * 5_000_000, :<=, 128 * 1024 * 1024
    assert_equal 1, PrototypeCapture.batch_size(vp, bytes_per_frame: 500_000_000)
  end

  def test_ensure_parents_captures_missing_ancestors_root_first
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "screens"))
      File.write(File.join(root, "screens", "mock-store.js"), "")
      %w[a b c].each { |id| File.write(File.join(root, "screens", "#{id}.html"), "<p>#{id}</p>") }
      scene = ->(id, from) { { "id" => id, "screen" => { "html" => "screens/#{id}.html" }, "store" => (from ? { "from_scene" => from } : {}) } }
      board = { "viewport" => { "width" => 10, "height" => 10 }, "scenes" => [ scene.("a", nil), scene.("b", "a"), scene.("c", "b") ] }
      captured = []
      fake = lambda { |label:, out_dir:, **|
        captured << label
        FileUtils.mkdir_p(out_dir)
        File.write(File.join(out_dir, "end-state.json"), "{}")
      }
      original = PrototypeCapture.method(:capture)
      PrototypeCapture.define_singleton_method(:capture, &fake)
      begin
        PrototypeCapture.ensure_parents(board, board["scenes"][0], root, {}, nil)
        assert_empty captured, "a root scene has no ancestors"
        PrototypeCapture.ensure_parents(board, board["scenes"][2], root, {}, nil)
        assert_equal %w[a b], captured
        PrototypeCapture.ensure_parents(board, board["scenes"][2], root, {}, nil)
        assert_equal %w[a b], captured, "cached ancestors are not recaptured"
        PrototypeCapture.prepare(board, board["scenes"][2], root, {})
      ensure
        PrototypeCapture.define_singleton_method(:capture, original)
      end
    end
  end

  def test_scene_duration_is_derived
    assert_equal 3000, PrototypeCapture.scene_duration("timing" => { "min_ms" => 3000, "pad_ms" => 400 }, "narration" => { "measured_ms" => 1000 })
    assert_equal 5400, PrototypeCapture.scene_duration("timing" => { "min_ms" => 3000, "pad_ms" => 400 }, "narration" => { "measured_ms" => 5000 })
  end

  def test_inline_screen_keeps_deferred_and_async_script_timing
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "s.js"), "go()")
      %w[defer async].each do |attr|
        File.write(File.join(dir, "x.html"), %(<script #{attr} src="s.js"></script>))
        out = PrototypeCapture.inline_screen(File.join(dir, "x.html"))
        assert_includes out, %(<script #{attr} src="data:text/javascript;base64,#{Base64.strict_encode64('go()')}"></script>)
      end
      File.write(File.join(dir, "x.html"), %(<script src="s.js"></script>))
      assert_includes PrototypeCapture.inline_screen(File.join(dir, "x.html")), "<script>go()</script>"
    end
  end

  def test_skip_reason_covers_every_scene_without_a_screen_html
    assert_match(/ai-broll/, PrototypeCapture.skip_reason("id" => "b", "kind" => "ai-broll", "broll" => {}))
    assert_match(/ai-broll/, PrototypeCapture.skip_reason("id" => "b", "kind" => "ai-broll", "screen" => { "url" => "https://x" }))
    assert_match(/live/, PrototypeCapture.skip_reason("id" => "l", "screen" => { "url" => "https://x" }))
    assert_nil PrototypeCapture.skip_reason("id" => "p", "screen" => { "html" => "screens/a.html" })
  end

  def test_skip_reason_skips_compose_and_message_scenes_without_a_screen_html
    assert_match(/compose/, PrototypeCapture.skip_reason("id" => "c", "kind" => "compose", "screen" => { "html" => "screens/c.html" }))
    assert_match(/screen\.html/, PrototypeCapture.skip_reason("id" => "m", "kind" => "message", "screen" => {}))
    assert_match(/screen\.html/, PrototypeCapture.skip_reason("id" => "m", "kind" => "message"))
  end
end
