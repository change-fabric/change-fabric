# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "tmpdir"
require_relative "../scripts/prototype_capture"
require_relative "../scripts/walkthrough_fonts"

class WalkthroughFontsTest < Minitest::Test
  CSS_URL = "https://fonts.googleapis.com/css2?family=Inter:wght@400;700&display=swap"
  FONT_URL = "https://fonts.gstatic.com/s/inter/v13/inter-latin.woff2"
  SHEET = "@font-face { font-family: 'Inter'; src: url(#{FONT_URL}) format('woff2'); }"
  HTML = <<~HTML
    <html><head>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="#{CSS_URL}" rel="stylesheet">
    </head><body style="font-family: Inter">Hi</body></html>
  HTML

  def setup
    @root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@root, "screens"))
    @screen = File.join(@root, "screens", "a.html")
    File.write(@screen, HTML)
    @fetched = []
    @stub = lambda do |url|
      @fetched << url
      { CSS_URL => SHEET, FONT_URL => "WOFF2BYTES".b }.fetch(url) { raise WalkthroughFonts::FetchError, "font fetch failed: #{url} returned HTTP 404" }
    end
  end

  def teardown
    WalkthroughFonts.fetcher = nil
    FileUtils.rm_rf(@root)
  end

  def with_fetcher(fetch)
    WalkthroughFonts.fetcher = fetch
    yield
  ensure
    WalkthroughFonts.fetcher = nil
  end

  def inline = with_fetcher(@stub) { PrototypeCapture.inline_screen(@screen) }

  def test_stylesheet_and_font_files_are_rewritten_to_cached_local_bytes
    html = inline
    refute_includes html, "fonts.googleapis.com"
    refute_includes html, "fonts.gstatic.com"
    assert_includes html, "font-family: 'Inter'"
    assert_includes html, "url(\"data:font/woff2;base64,#{Base64.strict_encode64('WOFF2BYTES')}\")"
    assert_equal [ CSS_URL, FONT_URL ], @fetched
    cache = WalkthroughFonts.cache_dir(@root)
    assert File.file?(File.join(cache, Digest::SHA256.hexdigest("WOFF2BYTES")))
    assert File.file?(File.join(cache, Digest::SHA256.hexdigest(SHEET)))
  end

  def test_a_host_off_the_allowlist_is_refused
    File.write(@screen, "<link rel='stylesheet' href='https://fonts.example.com/a.css'>")
    err = assert_raises(PrototypeCapture::UnsupportedContentError) { inline }
    assert_includes err.message, "fonts.example.com"
    assert_empty @fetched
    err = assert_raises(WalkthroughFonts::HostError) { WalkthroughFonts.import_css("https://evil.example/a.css", @root, fetch: @stub) }
    assert_includes err.message, "only fonts from fonts.googleapis.com, fonts.gstatic.com"
  end

  def test_a_redirect_off_the_allowlist_names_the_refused_target
    err = assert_raises(WalkthroughFonts::HostError) { WalkthroughFonts.redirect_target(FONT_URL, "https://cdn.example.net/inter.woff2") }
    assert_includes err.message, "redirects to https://cdn.example.net/inter.woff2"
    assert_includes err.message, "cdn.example.net is not on the font allowlist"
    assert_includes err.message, FONT_URL
    assert_equal "https://fonts.gstatic.com/s/x.woff2", WalkthroughFonts.redirect_target(FONT_URL, "/s/x.woff2")
  end

  def test_html_escaped_query_is_fetched_as_the_browser_would
    File.write(@screen, "<link rel='stylesheet' href='https://fonts.googleapis.com/css2?family=Inter&amp;display=swap'>")
    stub = ->(url) { (@fetched << url) && url.end_with?(".woff2") ? "B".b : SHEET }
    with_fetcher(stub) { PrototypeCapture.inline_screen(@screen) }
    assert_equal "https://fonts.googleapis.com/css2?family=Inter&display=swap", @fetched.first
    @fetched.clear
    WalkthroughFonts.prefetch!(@screen, Dir.mktmpdir, fetch: stub)
    assert_equal "https://fonts.googleapis.com/css2?family=Inter&display=swap", @fetched.first
  end

  def test_prefetch_follows_nested_local_imports_and_stops_on_a_cycle
    File.write(File.join(@root, "screens", "a.css"), "@import url('b.css');")
    File.write(File.join(@root, "screens", "b.css"), "@import url('a.css'); @import url('#{CSS_URL}');")
    File.write(@screen, "<link rel='stylesheet' href='a.css'>")
    WalkthroughFonts.prefetch!(@screen, @root, fetch: @stub)
    assert_equal [ CSS_URL, FONT_URL ], @fetched
  end

  def test_second_render_hits_the_cache_with_no_network
    first = inline
    offline = ->(url) { raise "network touched for #{url}" }
    second = with_fetcher(offline) { PrototypeCapture.inline_screen(@screen) }
    assert_equal first, second
    assert_equal [ CSS_URL, FONT_URL ], @fetched
  end

  def test_font_bytes_change_the_inlined_page_and_so_the_frames_key
    first = inline
    FileUtils.rm_rf(WalkthroughFonts.cache_dir(@root))
    other = ->(url) { url == CSS_URL ? SHEET : "OTHERBYTES".b }
    refute_equal first, with_fetcher(other) { PrototypeCapture.inline_screen(@screen) }
  end

  def test_a_failed_fetch_names_the_url
    File.write(@screen, "<link rel='stylesheet' href='https://fonts.googleapis.com/css2?family=Nope'>")
    err = assert_raises(WalkthroughFonts::FetchError) { inline }
    assert_includes err.message, "https://fonts.googleapis.com/css2?family=Nope"
  end

  def test_prefetch_finds_links_imports_and_urls_in_linked_css
    File.write(File.join(@root, "screens", "t.css"), "@import url('#{CSS_URL}');")
    File.write(@screen, "<link rel='stylesheet' href='t.css'>")
    WalkthroughFonts.prefetch!(@screen, @root, fetch: @stub)
    assert_equal [ CSS_URL, FONT_URL ], @fetched
  end
end
