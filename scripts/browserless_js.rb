# frozen_string_literal: true

require 'json'

# Pure string builders for JS fragments that run inside a browserless
# /function module. cf:change, cf:qa, and cf:prototype share these so every
# browser touch sets up context, locale, CDP, and determinism the same way.
# Nothing here talks to a container: callers interpolate the fragments into a
# module and post it with ChangeDocker::Browserless#run_function.
module BrowserlessJs
  module_function

  # Defines newBrowserContext(browser). Puppeteer renamed the call
  # (createIncognitoBrowserContext -> createBrowserContext); both are probed.
  def fresh_context_js
    <<~JS.chomp
      async function newBrowserContext(browser) {
        if (typeof browser.createBrowserContext === "function") return browser.createBrowserContext();
        if (typeof browser.createIncognitoBrowserContext === "function") return browser.createIncognitoBrowserContext();
        return null;
      }
    JS
  end

  # The Accept-Language header object literal for setExtraHTTPHeaders.
  def locale_header_js(locale_expr = 'locale')
    %({ "Accept-Language": #{locale_expr} })
  end

  # Pins navigator.language and navigator.languages on every new document.
  def locale_js(locale_expr = 'locale', page_var: 'cellPage')
    <<~JS.chomp
      await #{page_var}.evaluateOnNewDocument((lang) => {
        Object.defineProperty(navigator, "language", { get: () => lang });
        Object.defineProperty(navigator, "languages", { get: () => [lang] });
      }, #{locale_expr});
    JS
  end

  # The same pin as plain document script source, for pages loaded with
  # setContent, where an evaluateOnNewDocument script never runs.
  def locale_script(locale)
    lang = JSON.generate(locale)
    "Object.defineProperty(navigator, \"language\", { get: () => #{lang} });" \
      "Object.defineProperty(navigator, \"languages\", { get: () => [#{lang}] });"
  end

  # An expression yielding a CDP session for the page.
  def cdp_session_js(page_var = 'page')
    "await #{page_var}.createCDPSession()"
  end

  # Loads static HTML with every non-data, non-about request aborted and
  # recorded into the array named by failures_var.
  def inline_html_js(html, page_var: 'page', failures_var: 'blockedRequests')
    <<~JS.chomp
      const #{failures_var} = [];
      await #{page_var}.setRequestInterception(true);
      #{page_var}.on("request", (req) => {
        const url = req.url();
        if (url.startsWith("data:") || url.startsWith("about:")) return req.continue();
        #{failures_var}.push({ url, reason: "blocked: external request in inline html" });
        return req.abort("blockedbyclient");
      });
      await #{page_var}.setContent(#{JSON.generate(html)}, { waitUntil: "load" });
    JS
  end

  # A document script (pass to evaluateOnNewDocument) that freezes time and
  # randomness: a controlled clock driving Date, performance.now, rAF,
  # setTimeout, and setInterval, advanced only by window.__cfAdvance(ms); a
  # seeded mulberry32 Math.random; crypto.randomUUID from that PRNG; cleared
  # storage; and an indexedDB that throws.
  def fixed_clock_js(start_ms:, prng_seed:)
    start = Integer(start_ms)
    seed = Integer(prng_seed) & 0xffffffff
    <<~JS.chomp
      (() => {
        const startMs = #{start};
        let nowMs = startMs;
        let seed = #{seed} >>> 0;
        const rand = () => {
          seed = (seed + 0x6D2B79F5) >>> 0;
          let t = seed;
          t = Math.imul(t ^ (t >>> 15), t | 1);
          t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
          return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
        };
        Math.random = rand;
        const hex = (n) => Array.from({ length: n }, () => Math.floor(rand() * 16).toString(16)).join("");
        if (window.crypto) {
          Object.defineProperty(window.crypto, "randomUUID", {
            configurable: true,
            value: () => `${hex(8)}-${hex(4)}-4${hex(3)}-${(8 + Math.floor(rand() * 4)).toString(16)}${hex(3)}-${hex(12)}`
          });
        }
        const RealDate = Date;
        class FixedDate extends RealDate {
          constructor(...args) { if (args.length === 0) super(nowMs); else super(...args); }
          static now() { return nowMs; }
        }
        window.Date = FixedDate;
        performance.now = () => nowMs - startMs;
        // Every callback fires strictly after the moment it was scheduled (rAF on
        // the next frame, timers at least 1ms out), so a self-rescheduling
        // callback cannot spin forever inside one __cfAdvance.
        const FRAME_MS = 16;
        let nextId = 1;
        const timers = new Map();
        const schedule = (fn, delay, args, repeat) => {
          const id = nextId++;
          const ms = Math.max(1, Number(delay) || 0);
          timers.set(id, { at: nowMs + ms, ms, fn, args, repeat, raf: false });
          return id;
        };
        window.setTimeout = (fn, delay, ...args) => schedule(fn, delay, args, false);
        window.setInterval = (fn, delay, ...args) => schedule(fn, delay, args, true);
        window.clearTimeout = window.clearInterval = (id) => { timers.delete(id); };
        window.requestAnimationFrame = (fn) => {
          const id = nextId++;
          timers.set(id, { at: nowMs + FRAME_MS, ms: FRAME_MS, fn, args: [], repeat: false, raf: true });
          return id;
        };
        window.cancelAnimationFrame = (id) => { timers.delete(id); };
        window.__cfAdvance = (ms) => {
          const target = nowMs + Math.max(0, Number(ms) || 0);
          for (;;) {
            let nextKey = null;
            let next = null;
            for (const [key, t] of timers) {
              if (t.at <= target && (!next || t.at < next.at)) { nextKey = key; next = t; }
            }
            if (!next) break;
            nowMs = Math.max(nowMs, next.at);
            if (next.repeat) next.at = nowMs + Math.max(1, next.ms); else timers.delete(nextKey);
            try {
              if (next.raf) next.fn(nowMs - startMs); else if (typeof next.fn === "function") next.fn(...next.args);
            } catch (err) { void err; }
          }
          nowMs = target;
          return nowMs;
        };
        try { localStorage.clear(); } catch (err) { void err; }
        try { sessionStorage.clear(); } catch (err) { void err; }
        Object.defineProperty(window, "indexedDB", {
          configurable: true,
          get: () => { throw new Error("indexedDB is not supported under the fixed clock"); }
        });
      })();
    JS
  end

  # An expression yielding a base64 PNG of the page via the CDP client.
  def screenshot_js(client_var = 'client')
    %{(await #{client_var}.send("Page.captureScreenshot", { format: "png" })).data}
  end
end
