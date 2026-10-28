# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/browserless_js"
require_relative "../scripts/change_config"
require_relative "../scripts/change_lane_browserless"

# BrowserlessJs builds JS fragments for browserless /function modules. These
# tests check each fragment's shape; running them is a live docker concern.
class BrowserlessJsTest < Minitest::Test
  def balanced?(js)
    pairs = { ")" => "(", "]" => "[", "}" => "{" }
    js.each_char.with_object([]) do |c, stack|
      if pairs.value?(c) then stack.push(c)
      elsif pairs.key?(c) then return false unless stack.pop == pairs[c]
      end
    end.empty?
  end

  def test_fresh_context_probes_both_puppeteer_names
    js = BrowserlessJs.fresh_context_js
    assert_includes js, "async function newBrowserContext(browser)"
    assert_includes js, "browser.createBrowserContext()"
    assert_includes js, "browser.createIncognitoBrowserContext()"
    assert balanced?(js)
  end

  def test_locale_pins_header_and_navigator
    assert_equal '{ "Accept-Language": locale }', BrowserlessJs.locale_header_js
    js = BrowserlessJs.locale_js("lang0", page_var: "p")
    assert_includes js, "await p.evaluateOnNewDocument("
    assert_includes js, '"language"'
    assert_includes js, '"languages"'
    assert js.end_with?("}, lang0);")
    assert balanced?(js)
  end

  def test_cdp_session
    assert_equal "await cellPage.createCDPSession()", BrowserlessJs.cdp_session_js("cellPage")
  end

  def test_inline_html_aborts_http_and_records_failure
    js = BrowserlessJs.inline_html_js("<p>\"hi\"</p>")
    assert_includes js, "page.setRequestInterception(true)"
    assert_includes js, 'url.startsWith("data:")'
    assert_includes js, 'url.startsWith("about:")'
    assert_includes js, "req.abort("
    assert_includes js, "blockedRequests.push("
    assert_includes js, 'page.setContent("<p>\"hi\"</p>", { waitUntil: "load" })'
    assert balanced?(js)
  end

  def test_fixed_clock_overrides_every_global
    js = BrowserlessJs.fixed_clock_js(start_ms: 1_700_000_000_000, prng_seed: 42)
    [ "window.Date =", "performance.now =", "window.requestAnimationFrame =", "window.setTimeout =",
     "window.setInterval =", "Math.random =", '"randomUUID"', "localStorage.clear()",
     "sessionStorage.clear()", '"indexedDB"', "0x6D2B79F5", "window.__cfAdvance =" ].each do |needle|
      assert_includes js, needle
    end
    assert_includes js, "const startMs = 1700000000000;"
    assert_includes js, "let seed = 42 >>> 0;"
    assert balanced?(js)
  end

  def test_fixed_clock_rejects_non_integers
    assert_raises(ArgumentError) { BrowserlessJs.fixed_clock_js(start_ms: "soon", prng_seed: 1) }
  end

  def test_fixed_clock_self_rescheduling_callbacks_terminate
    require "json"
    skip "node not available" unless system("node", "-e", "0", out: File::NULL, err: File::NULL)
    clock = BrowserlessJs.fixed_clock_js(start_ms: 1_000, prng_seed: 1)
    driver = <<~JS
      globalThis.window = globalThis;
      globalThis.localStorage = { clear() {} };
      globalThis.sessionStorage = { clear() {} };
      #{clock}
      const counts = { raf: 0, timeout0: 0, timeoutUndef: 0, interval0: 0 };
      const raf = () => { counts.raf++; requestAnimationFrame(raf); };
      requestAnimationFrame(raf);
      const t0 = () => { counts.timeout0++; setTimeout(t0, 0); };
      setTimeout(t0, 0);
      const tu = () => { counts.timeoutUndef++; setTimeout(tu); };
      setTimeout(tu);
      setInterval(() => { counts.interval0++; }, 0);
      __cfAdvance(160);
      console.log(JSON.stringify(counts));
    JS
    out = IO.popen(["timeout", "10", "node", "-e", driver], &:read)
    assert $?.success?, "clock driver hung or failed: #{out}"
    counts = JSON.parse(out)
    assert_equal 10, counts["raf"]
    assert_equal 160, counts["timeout0"]
    assert_equal 160, counts["timeoutUndef"]
    assert_equal 160, counts["interval0"]
  end

  def test_screenshot
    assert_equal '(await c.send("Page.captureScreenshot", { format: "png" })).data', BrowserlessJs.screenshot_js("c")
  end

  Ctx = Struct.new(:network, :target_url) do
    def browserless = nil
    def log(_message) = nil
  end

  # Golden captured from scan_module before the shared-primitives refactor.
  def test_scan_module_matches_pre_refactor_golden
    config = ChangeConfig::LaneConfig.new("browserless", { "routes" => [ "/", "/about" ], "locale" => "fr-FR" }, "/repo")
    lane = ChangeLaneBrowserless.new(config, Ctx.new("net", "https://app.example.org"))
    actual = lane.send(:scan_module, lane.send(:route_entries), nil, {})
    golden = File.read(File.join(__dir__, "fixtures", "scan_module_golden.js"))
    normalize = ->(s) { s.gsub(/\s+/, "") }
    assert_equal normalize.call(golden), normalize.call(actual)
  end
end
