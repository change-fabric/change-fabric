#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'change_flow_selector'

# Compiles a declarative list of browser steps into one browserless /function
# payload. Pure Ruby, deterministic, and it never calls an LLM: the same steps
# at the same commit compile to the same JS, so a browser check is a fact that
# can be repeated rather than a script re-derived from scratch on every run.
#
# This is an extraction, not an invention. The browserless lane already carried
# a declarative multi-step flow compiled to JS: `browserless.auth.steps[]`, with
# a field's value coming from an env var or from a `code_source` polled live
# inside the container. That compiler and its JS runtime moved here verbatim
# (`compile_auth`, `auth_runtime_js`), so the lane's login behaves exactly as
# it did, and the general vocabulary below grew around it.
#
# Two entry points, deliberately distinct:
#
# - `ChangeFlowCompiler.compile_auth(steps, base_url:)` is the login flow the
#   browserless lane has always emitted, in the shape its runtime has always
#   consumed. Its output is a compatibility contract, not a design.
# - `ChangeFlowCompiler.new(steps, base_url:)` is the general vocabulary:
#   actions `goto`, `click`, `fill`, `select`, `press`, `wait_for`,
#   `screenshot`, `capture`; assertions `expect_visible`, `expect_hidden`,
#   `expect_text`, `expect_url`, `expect_status`, `expect_count`,
#   `expect_equal`, `expect_relation` (suite_version 8); and `eval` as an escape hatch for raw JS. Any selector
#   may use the text/nth forms ChangeFlowSelector parses.
#
# `eval` is supported and marked. A compiled `eval` step carries `raw: true`
# and a label naming it as raw JS, so a report can show a reader exactly where
# the declarative contract was abandoned instead of presenting hand-written JS
# as though it were a checked assertion.
#
# Secrets: a `fill` whose value comes from `env` reads that value on the host
# and it reaches the container, because that is the only place it can be typed
# into a form. It must never travel anywhere else. `#redacted` is the only
# shape that may be written to a report, a log, or a payload dump; `#compile`
# and `#function_module` carry real credentials and are for the container
# alone. A `code_source` value is never read on the host at all: only its url
# is compiled, and the runtime polls it from inside the container.
class ChangeFlowCompiler
  Error = Class.new(StandardError)

  REDACTED = '[redacted]'
  DEFAULT_TIMEOUT_MS = 15_000
  DEFAULT_CODE_SOURCE_TIMEOUT_MS = 20_000
  DEFAULT_CODE_SOURCE_POLL_INTERVAL_MS = 1_000
  DEFAULT_WAIT_UNTIL = 'domcontentloaded'

  ACTIONS = %w[goto click fill select press wait_for screenshot capture].freeze
  ASSERTIONS = %w[expect_visible expect_hidden expect_text expect_url expect_status expect_count
                  expect_equal expect_stable expect_visual expect_relation].freeze
  # State waits poll the current page until a condition holds. Event waits
  # observe something that happens, so the runtime arms their listener before
  # the step that triggers it (the step before, unless `after: none`).
  STATE_WAITS = %w[wait_for_url wait_for_text wait_until_hidden].freeze
  EVENT_WAITS = %w[wait_for_response wait_for_network_idle].freeze
  ESCAPE_HATCH = 'eval'
  VERBS = (ACTIONS + STATE_WAITS + EVENT_WAITS + ASSERTIONS + [ ESCAPE_HATCH ]).freeze
  # Bounds for wait_for_network_idle's quiet window, in ms.
  NETWORK_IDLE_RANGE = (100..10_000)
  DEFAULT_NETWORK_IDLE_MS = 500

  # Every compiled step carries a `verb` in this camelCase runtime spelling, so
  # the JS runtime switches on one token while the flow file keeps snake_case.
  RUNTIME_VERBS = VERBS.to_h { |verb| [ verb, verb.gsub(/_(.)/) { Regexp.last_match(1).upcase } ] }.freeze

  # Step-level keys that are options rather than the verb itself.
  OPTION_KEYS = %w[timeout_ms budget_ms budget_from label].freeze

  # (suite_version 5) Numeric reads of geometry and scroll position.
  # `rect.*` is the element's getBoundingClientRect(); `scroll_y` is
  # window.scrollY, or the element's scrollTop when a selector is given.
  MEASURED_KINDS = %w[rect.x rect.y rect.width rect.height rect.bottom scroll_y].freeze

  # What expect_stable can judge: the kinds the first-paint recorder samples.
  STABLE_KINDS = %w[rect.x rect.y rect.width rect.height rect.bottom].freeze

  # What capture and expect_equal read from a selector. (suite_version 8)
  # `list` is the trimmed text of every element matching the selector, in
  # document order; only capture reads it, and only `subset` compares it.
  READ_KINDS = (%w[text number count list] + MEASURED_KINDS).freeze

  # (suite_version 8) The relations expect_relation can judge, the reads each
  # takes, and the bound on settle's re-read rounds.
  RELATIONS = { 'equal' => %w[a b], 'le' => %w[a b], 'subset' => %w[a b], 'sum' => %w[total parts] }.freeze
  MAX_REREAD = 3
  TAG_NAME = /\A[A-Za-z0-9_-]+\z/
  VAR_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

  # --- the JS runtime ---------------------------------------------------------

  # Polls a code_source url until its body matches. Shared by the auth flow and
  # the general vocabulary, because an OTP is an OTP whichever one asked for it.
  CODE_SOURCE_JS = <<~JS
    // Polls a code_source url (an HTTP endpoint reachable on the run
    // network, e.g. a Mailpit/MailHog dev inbox API) with Node's own
    // fetch until its body matches, so an out-of-band OTP is read live
    // rather than ever landing in CHANGE.md or the host environment.
    async function resolveCodeSource(codeSource) {
      const deadline = Date.now() + codeSource.timeoutMs;
      let lastErr = null;
      while (Date.now() < deadline) {
        try {
          const res = await fetch(codeSource.url);
          const text = await res.text();
          if (codeSource.pattern) {
            const match = text.match(new RegExp(codeSource.pattern));
            if (match) return match[1] || match[0];
          } else if (text.trim()) {
            return text.trim();
          }
        } catch (err) {
          lastErr = err;
        }
        await new Promise((resolve) => setTimeout(resolve, codeSource.pollIntervalMs));
      }
      throw new Error(
        `code_source did not yield a value within ${codeSource.timeoutMs}ms: ${codeSource.url}` +
          (lastErr ? ` (last error: ${lastErr})` : "")
      );
    }
  JS

  # The auth flow's runtime, moved here from the browserless lane unchanged. It
  # takes the lane's `session` (its own page plus the last main-frame response)
  # rather than a bare page, because the lane's auth diagnostics read that
  # response when a login fails.
  AUTH_JS = <<~JS
    async function fillField(session, field, timeoutMs) {
      await session.page.waitForSelector(field.selector, { timeout: timeoutMs });
      const value = field.codeSource ? await resolveCodeSource(field.codeSource) : field.value;
      await session.page.type(field.selector, value);
    }

    async function runAuthStep(session, step) {
      if (step.url) {
        session.lastAuthResponse = await session.page.goto(step.url, { waitUntil: "domcontentloaded", timeout: step.timeoutMs });
      }
      for (const field of step.fields) await fillField(session, field, step.timeoutMs);
      if (step.submitSelector) {
        const [navResponse] = await Promise.all([
          session.page.waitForNavigation({ waitUntil: "domcontentloaded", timeout: step.timeoutMs }).catch(() => null),
          session.page.click(step.submitSelector),
        ]);
        if (navResponse) session.lastAuthResponse = navResponse;
      }
      if (step.waitForSelector) await session.page.waitForSelector(step.waitForSelector, { timeout: step.timeoutMs });
    }
  JS

  # The general vocabulary's runtime. One switch, one record per step, and the
  # walk stops at the first failing step: everything after a failed assertion
  # runs against a page that is no longer in the state the flow described, so
  # continuing would report noise as evidence.
  FLOW_JS = <<~JS
    function cfFail(message) { throw new Error(message); }

    // Resolves a compiled text/nth locator (see ChangeFlowSelector) inside
    // the page. Self-contained, because Puppeteer serializes it into the page.
    // mode is one of "attached", "visible", "hidden", "count".
    const cfLocate = (loc, mode) => {
      const norm = (s) => String(s || "").replace(/\\s+/g, " ").trim();
      const textOf = (el) => norm(el.innerText || el.textContent);
      const content = (el) => !el.closest("head, title, script, style, noscript, template");
      let els = Array.from(document.querySelectorAll(loc.css || "*"));
      if (!loc.css) els = els.filter(content);
      if (loc.textIs !== null) els = els.filter((el) => textOf(el) === loc.textIs);
      if (loc.hasText !== null) els = els.filter((el) => textOf(el).indexOf(loc.hasText) !== -1);
      if (!loc.css) els = els.filter((el) => !els.some((other) => other !== el && el.contains(other)));
      const picked = loc.nth === null ? els[0] : els[loc.nth < 0 ? els.length + loc.nth : loc.nth];
      if (mode === "count") return loc.nth === null ? els.length : (picked ? 1 : 0);
      if (mode === "list") return (loc.nth === null ? els : (picked ? [ picked ] : [])).map(textOf);
      const visible = (el) => {
        const style = getComputedStyle(el);
        const rect = el.getBoundingClientRect();
        return style.visibility !== "hidden" && style.display !== "none" && rect.width > 0 && rect.height > 0;
      };
      if (mode === "hidden") return !picked || !visible(picked);
      if (!picked) return null;
      if (mode === "visible" && !visible(picked)) return null;
      return picked;
    };

    // After a step's wait timed out on a selector that matches nothing,
    // gathers raw facts about the elements that are there, for the host to
    // score (ChangeSelectorSuggestions). Suggest-only: the step still fails.
    // Walks the page and open shadow roots; an iframe is counted, never
    // entered. Never reads a field's value, and skips password inputs.
    // The candidates ride on the record as a non-enumerable property, so a
    // checkpoint that serializes the record (afterStep, evidence files) never
    // writes raw page text. cfExpose makes them visible once, at the return
    // to the host, which redacts them before anything is stored.
    function cfExpose(steps) {
      const out = steps.map((record) => (Object.getOwnPropertyDescriptor(record, "candidates") ? Object.assign({}, record, { candidates: record.candidates }) : record));
      out.vars = steps.vars;
      return out;
    }
    const CF_CANDIDATE_LIMIT = 60;
    const CF_CANDIDATE_SCAN = 3000;
    async function cfCandidates(page, step) {
      try {
        if ((await cfCount(page, step)) > 0) return null;
        return await page.evaluate((limit, scanMax) => {
          const clip = (s) => String(s || "").replace(/\\s+/g, " ").trim().slice(0, 80);
          // Exact attribute values: a selector built from a clipped value would match nothing.
          const attr = (el, name) => { const v = el.getAttribute(name); return v && v.length <= 200 ? v : null; };
          // Text is sent whole or not at all: a clipped copy could cut a secret in half past the host's masking.
          const whole = (s) => { const t = String(s || "").replace(/\\s+/g, " ").trim(); return t && t.length <= 200 ? t : null; };
          const interesting = "a,button,input,select,textarea,summary,label,h1,h2,h3,h4,h5,h6,[role],[data-testid],[id]";
          const implicit = { a: "link", button: "button", select: "combobox", textarea: "textbox", summary: "button", h1: "heading", h2: "heading", h3: "heading", h4: "heading", h5: "heading", h6: "heading" };
          const found = { items: [], frames: 0, scanned: 0, truncated: false };
          const walk = (root, scope) => {
            for (const el of root.querySelectorAll("*")) {
              if (found.scanned >= scanMax) { found.truncated = true; return; }
              found.scanned += 1;
              if (el.tagName === "IFRAME" || el.tagName === "FRAME") found.frames += 1;
              if (el.shadowRoot) walk(el.shadowRoot, "shadow");
              if (!el.matches(interesting)) continue;
              const type = (el.getAttribute("type") || "").toLowerCase();
              if (el.tagName === "INPUT" && (type === "password" || type === "hidden")) continue;
              if (found.items.length >= limit) { found.truncated = true; return; }
              const id = attr(el, "id");
              const testid = attr(el, "data-testid");
              found.items.push({
                tag: el.tagName.toLowerCase(), scope,
                id: id, testid: testid,
                role: clip(el.getAttribute("role") || implicit[el.tagName.toLowerCase()] || (el.tagName === "INPUT" ? "textbox" : "")) || null,
                label: attr(el, "aria-label"),
                text: whole(el.innerText || el.textContent),
                idCount: id ? root.querySelectorAll("[id=" + JSON.stringify(id) + "]").length : 0,
                testidCount: testid ? root.querySelectorAll("[data-testid=" + JSON.stringify(testid) + "]").length : 0,
              });
            }
          };
          walk(document, "page");
          return found;
        }, CF_CANDIDATE_LIMIT, CF_CANDIDATE_SCAN);
      } catch (err) {
        void err;
        return null;
      }
    }

    // Waits for a step's target: through Puppeteer's own selector engine for
    // a plain selector, through cfLocate for a text/nth one. Returns the
    // element handle, or null for mode "hidden".
    async function cfWait(page, step, timeoutMs, mode = "attached") {
      if (!step.locator) {
        const options = { timeout: timeoutMs };
        if (mode === "visible") options.visible = true;
        if (mode === "hidden") options.hidden = true;
        return page.waitForSelector(step.selector, options);
      }
      const handle = await page.waitForFunction(cfLocate, { timeout: timeoutMs }, step.locator, mode);
      return mode === "hidden" ? null : handle.asElement();
    }

    async function cfCount(page, step) {
      if (step.locator) return page.evaluate(cfLocate, step.locator, "count");
      return page.$$eval(step.selector, (els) => els.length);
    }

    async function cfText(page, step, timeoutMs) {
      const el = await cfWait(page, step, timeoutMs);
      return el.evaluate((node) => (node.innerText || node.textContent || "").trim());
    }

    // Reads a value for capture and expect_equal: the element's text, the
    // first number in that text, or the count of matching elements.
    async function cfRead(page, step, timeoutMs) {
      if (step.kind === "count") return cfCount(page, step);
      if (step.kind === "list") {
        if (step.locator) return page.evaluate(cfLocate, step.locator, "list");
        return page.$$eval(step.selector, (els) => els.map((el) => String(el.innerText || el.textContent || "").replace(/\\s+/g, " ").trim()));
      }
      if (step.kind === "scroll_y") {
        if (!step.selector) return page.evaluate(() => window.scrollY);
        return (await cfWait(page, step, timeoutMs)).evaluate((node) => node.scrollTop);
      }
      if (step.kind.indexOf("rect.") === 0) {
        const rectKey = step.kind.slice(5);
        return (await cfWait(page, step, timeoutMs)).evaluate((node, key) => node.getBoundingClientRect()[key], rectKey);
      }
      const text = await cfText(page, step, timeoutMs);
      if (step.kind === "text") return text;
      const match = text.replace(/,/g, "").match(/-?\\d+(\\.\\d+)?/);
      if (!match) cfFail(`expected a number in the text of ${step.selector}, found ${JSON.stringify(text)}`);
      return Number(match[0]);
    }

    function cfVar(state, name) {
      if (!Object.prototype.hasOwnProperty.call(state.vars, name)) cfFail(`variable ${name} was never captured`);
      return state.vars[name];
    }

    // A step-level viewport applies to this capture only; the flow's own
    // viewport is restored after it.
    async function cfScreenshot(page, step) {
      const previous = step.viewport ? page.viewport() : null;
      if (step.viewport) await page.setViewport(step.viewport);
      try {
        return { screenshot: await page.screenshot({ encoding: "base64", fullPage: step.fullPage === true }), name: step.name };
      } finally {
        if (previous) await page.setViewport(previous);
      }
    }

    // expect_visual: the page or one element as a PNG, for the host to diff
    // (ChangeVisualBaseline). Animations and the caret are off and masked
    // elements hidden during the capture, then restored.
    async function cfVisual(page, step, timeout) {
      const previous = step.viewport ? page.viewport() : null;
      if (step.viewport) await page.setViewport(step.viewport);
      let prepared = false;
      try {
        const handle = step.selector ? await cfWait(page, step, timeout, "visible") : null;
        const size = page.viewport();
        if (!size) cfFail("expect_visual needs a viewport; the case set none");
        prepared = true;
        const masked = await page.evaluate(async (masks) => {
          const style = document.createElement("style");
          style.setAttribute("data-cf-visual", "1");
          style.textContent = "*,*::before,*::after{animation:none!important;transition:none!important;caret-color:transparent!important;scroll-behavior:auto!important}";
          document.head.appendChild(style);
          window.__cfVisualHidden = [];
          let count = 0;
          for (const selector of masks) {
            const nodes = document.querySelectorAll(selector);
            if (nodes.length === 0) throw new Error("expect_visual mask " + JSON.stringify(selector) + " matched no element");
            for (const node of nodes) {
              window.__cfVisualHidden.push([node, node.style.getPropertyValue("visibility"), node.style.getPropertyPriority("visibility")]);
              node.style.setProperty("visibility", "hidden", "important");
              count += 1;
            }
          }
          if (document.fonts && document.fonts.ready) await document.fonts.ready;
          await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
          return count;
        }, step.mask);
        const options = { encoding: "base64" };
        const image = handle ? await handle.screenshot(options) : await page.screenshot(options);
        return { screenshot: image, name: step.name, visual: { name: step.name, width: size.width, height: size.height, masked: masked } };
      } finally {
        if (prepared) {
          try {
            await page.evaluate(() => {
              for (const [node, value, priority] of (window.__cfVisualHidden || []).reverse()) {
                if (value) node.style.setProperty("visibility", value, priority); else node.style.removeProperty("visibility");
              }
              window.__cfVisualHidden = [];
              for (const style of document.querySelectorAll("style[data-cf-visual]")) style.remove();
            });
          } catch (err) { void err; }
        }
        if (previous) await page.setViewport(previous);
      }
    }

    // A url matcher compiled on the host: a glob became a regex there. A
    // pattern starting with "/" is matched against path plus query only.
    function cfUrlMatches(url, match) {
      let target = url;
      if (match.pathOnly) {
        try { const parsed = new URL(url); target = parsed.pathname + parsed.search; } catch (err) { void err; }
      }
      if (!match.regex) {
        try { match.regex = new RegExp(match.pattern); } catch (err) { cfFail(`not a valid JavaScript regex: /${match.pattern}/ (${err.message})`); }
      }
      return match.regex.test(target);
    }

    async function cfPoll(check, timeoutMs, label) {
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        if (await check()) return;
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      cfFail(`${label}: not true within ${timeoutMs}ms`);
    }

    async function cfTextNow(page, step) {
      try {
        if (!step.selector) return await page.evaluate(() => (document.body ? document.body.innerText || "" : ""));
        if (step.locator) {
          const el = (await page.evaluateHandle(cfLocate, step.locator, "attached")).asElement();
          return el ? await el.evaluate((node) => node.innerText || node.textContent || "") : "";
        }
        const el = await page.$(step.selector);
        return el ? await el.evaluate((node) => node.innerText || node.textContent || "") : "";
      } catch (err) {
        return "";
      }
    }

    function cfIsEventWait(step) { return !!step && (step.verb === "waitForResponse" || step.verb === "waitForNetworkIdle"); }

    // An event wait's listener. Listening starts here, so a response that
    // arrives while the triggering step is still running is not missed; the
    // timeout and the idle window start at start(), after the trigger. Every
    // listener is removed on a match, on the timeout, and on dispose().
    function cfArm(page, step) {
      let resolveFn;
      let rejectFn;
      const done = new Promise((resolve, reject) => { resolveFn = resolve; rejectFn = reject; });
      done.catch(() => {});
      const listeners = [];
      let settled = false;
      let started = false;
      const inflight = new Set();
      let timer = null;
      let idleTimer = null;
      const on = (event, fn) => { page.on(event, fn); listeners.push([event, fn]); };
      const dispose = () => {
        settled = true;
        clearTimeout(timer);
        clearTimeout(idleTimer);
        for (const [event, fn] of listeners) page.off(event, fn);
        listeners.length = 0;
      };
      const finish = (value) => { if (settled) return; dispose(); resolveFn(value); };
      const fail = (err) => { if (settled) return; dispose(); rejectFn(err); };
      const settle = () => {
        if (!started || settled) return;
        clearTimeout(idleTimer);
        if (inflight.size === 0) idleTimer = setTimeout(() => finish({ idleMs: step.idleMs }), step.idleMs);
      };
      if (step.verb === "waitForResponse") {
        on("response", (response) => {
          let matched = false;
          try { matched = cfUrlMatches(response.url(), step.match); } catch (err) { fail(err); return; }
          if (!matched) return;
          if (step.status !== null && response.status() !== step.status) return;
          finish({ found: response.url(), status: response.status() });
        });
      } else {
        // Only requests that started after arming count, by identity: one
        // already in flight finishing must not cancel out a new one.
        const ended = (request) => { inflight.delete(request); settle(); };
        on("request", (request) => { inflight.add(request); settle(); });
        on("requestfinished", ended);
        on("requestfailed", ended);
      }
      return {
        index: step.index,
        done: done,
        dispose: dispose,
        start() {
          if (settled || started) return;
          started = true;
          timer = setTimeout(() => {
            if (settled) return;
            dispose();
            rejectFn(new Error(`${step.label}: nothing matched within ${step.timeoutMs}ms`));
          }, step.timeoutMs);
          if (step.verb === "waitForNetworkIdle") settle();
        },
      };
    }

    async function cfAwaitEvent(page, step, state) {
      const armed = state.armed && state.armed.index === step.index ? state.armed : cfArm(page, step);
      state.armed = null;
      try {
        armed.start();
        return await armed.done;
      } finally {
        armed.dispose();
      }
    }

    // Installed before the first navigation (a new-document script, which is
    // Chrome's Page.addScriptToEvaluateOnNewDocument), so layout is recorded
    // from the start rather than guessed at later. It buffers layout-shift
    // entries with the tracked selectors each one touched, and records each
    // tracked selector's rect on the first animation frame it exists.
    const cfMeasureInit = (selectors) => {
      const layout = { shifts: [], first: {}, samples: {} };
      window.__cfLayout = layout;
      const rectOf = (node) => {
        const r = node.getBoundingClientRect();
        return { x: r.x, y: r.y, width: r.width, height: r.height, bottom: r.bottom };
      };
      const find = (selector) => { try { return document.querySelector(selector); } catch (err) { return null; } };
      try {
        new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) {
            const touched = [];
            for (const source of entry.sources || []) {
              for (const selector of selectors) {
                const el = find(selector);
                if (el && source.node && (el === source.node || el.contains(source.node) || source.node.contains(el)) && touched.indexOf(selector) === -1) touched.push(selector);
              }
            }
            layout.shifts.push({ value: entry.value, at: entry.startTime, input: entry.hadRecentInput, selectors: touched });
          }
        }).observe({ type: "layout-shift", buffered: true });
      } catch (err) { void err; }
      const pending = new Set();
      const snap = () => {
        for (const selector of selectors) {
          if (layout.first[selector] || pending.has(selector) || !find(selector)) continue;
          pending.add(selector);
          requestAnimationFrame(() => {
            const el = find(selector);
            if (el && !layout.first[selector]) layout.first[selector] = rectOf(el);
          });
        }
      };
      try { new MutationObserver(snap).observe(document, { childList: true, subtree: true }); } catch (err) { void err; }
      snap();
      // Every animation frame, a tracked rect that changed is sampled, so a
      // figure that moves during load and then comes back is still seen.
      const tick = () => {
        for (const selector of selectors) {
          const el = find(selector);
          if (!el) continue;
          const rect = rectOf(el);
          const list = layout.samples[selector] || (layout.samples[selector] = []);
          const last = list[list.length - 1];
          const same = last && last.x === rect.x && last.y === rect.y && last.width === rect.width && last.height === rect.height;
          if (!same && list.length < 5000) list.push(rect);
        }
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    };

    // Installs the recorder once per page; the testcases lane calls this before
    // a seeded landing navigation, and cfRunFlow calls it again harmlessly.
    async function cfInstallMeasure(page, steps) {
      if (page.__cfMeasureInstalled || !steps.some((step) => step.verb === "expectStable")) return;
      page.__cfMeasureInstalled = true;
      const selectors = steps.filter((step) => step.verb === "expectStable" && step.selector && !step.locator).map((step) => step.selector);
      await page.evaluateOnNewDocument(cfMeasureInit, Array.from(new Set(selectors)));
    }

    // Network idle that counts requests already in flight (tracked from the
    // start of the walk, not from now) and fails when idle is never reached.
    async function cfWaitIdle(state, idleMs, timeoutMs, label) {
      const deadline = Date.now() + timeoutMs;
      const began = Date.now();
      while (Date.now() < deadline) {
        const quietFor = Date.now() - Math.max(state.lastActivity, began);
        if (state.inflight.size === 0 && quietFor >= idleMs) return;
        await new Promise((resolve) => setTimeout(resolve, 25));
      }
      cfFail(`${label}: the network was not idle for ${idleMs}ms within ${timeoutMs}ms`);
    }

    // Waits for fonts and network idle, then judges the whole window from
    // first paint to now, not first against last: the largest deviation of any
    // sampled value from the first recorded one must stay within tolerancePx
    // (a header that moves 20 px during load and returns fails), and the layout
    // shift attributed to the element (entries whose sources touched it, minus
    // those right after input) must stay within maxCls.
    async function cfExpectStable(page, step, state, timeoutMs) {
      // Fonts get the step's own deadline: a stalled font request fails the
      // step by name instead of running the whole browserless call out.
      const fontsReady = page.evaluate(() => (document.fonts ? document.fonts.ready.then(() => true) : true)).catch(() => true);
      let fontTimer = null;
      const fontDeadline = new Promise((resolve) => { fontTimer = setTimeout(() => resolve("timeout"), timeoutMs); });
      const fontOutcome = await Promise.race([ fontsReady, fontDeadline ]);
      clearTimeout(fontTimer);
      if (fontOutcome === "timeout") cfFail(`${step.label}: document.fonts.ready was not settled within ${timeoutMs}ms`);
      await cfWaitIdle(state, 500, timeoutMs, step.label);
      const last = await cfRead(page, step, timeoutMs);
      await cfRecordRead(page, state, step.var, { selector: step.selector, kind: step.kind }, last);
      const layout = await page.evaluate(() => window.__cfLayout || null).catch(() => null);
      const key = step.kind.indexOf("rect.") === 0 ? step.kind.slice(5) : null;
      const sampled = layout && step.selector && key ? (layout.samples[step.selector] || []).map((rect) => rect[key]) : [];
      const recorded = layout && step.selector && key && layout.first[step.selector] ? layout.first[step.selector][key] : sampled[0];
      // No recording is no evidence: never substitute the final value.
      if (recorded === undefined) cfFail(`no first-paint recording for ${step.selector}: the element did not exist in a page instrumented before navigation, so stability cannot be judged`);
      const first = recorded;
      const values = [ first ].concat(sampled, [ last ]);
      const worst = values.reduce((far, value) => (Math.abs(value - first) > Math.abs(far - first) ? value : far), first);
      const deviation = Math.abs(worst - first);
      const shifts = layout && step.selector ? layout.shifts.filter((entry) => entry.selectors.indexOf(step.selector) !== -1) : [];
      const cls = shifts.filter((entry) => !entry.input).reduce((sum, entry) => sum + entry.value, 0);
      const where = step.selector || "the window";
      if (deviation > step.tolerancePx) cfFail(`${step.kind} of ${where} moved from ${first} to ${worst} (deviation ${deviation}, tolerance ${step.tolerancePx}px)`);
      if (cls > step.maxCls) cfFail(`layout shift ${cls.toFixed(4)} attributed to ${where} exceeds max_cls ${step.maxCls}`);
      return { found: last, first: first, deviation: deviation, cls: cls, samples: sampled.length, recorded: recorded !== undefined, shifts: shifts };
    }

    // The text of each freshness selector now, so a later re-read can wait
    // for it to change. Best effort: a page without the element yields null.
    async function cfFreshness(page, state) {
      const selectors = state.freshnessSelectors || [];
      if (selectors.length === 0) return null;
      const out = {};
      for (const selector of selectors) {
        try {
          const el = await page.$(selector);
          out[selector] = el ? await el.evaluate((node) => (node.innerText || node.textContent || "").trim()) : null;
        } catch (err) { out[selector] = null; }
      }
      return out;
    }

    // Records a read with its provenance: where it was read (the page url at
    // read time), how, and when. Relations and the report both read this.
    async function cfRecordRead(page, state, name, step, value) {
      const readAtMs = Date.now();
      const read = { var: name, value: value, url: page.url(), selector: step.selector || null, locator: step.locator || null,
                     kind: step.kind, readAt: new Date(readAtMs).toISOString(), readAtMs: readAtMs, source: "page",
                     freshness: await cfFreshness(page, state) };
      state.vars[name] = value;
      state.reads[name] = read;
      return read;
    }

    function cfPublicRead(read) {
      return { var: read.var, value: read.value, url: read.url, selector: read.selector, kind: read.kind, readAt: read.readAt,
               source: read.source, freshness: read.freshness || null };
    }

    function cfNumber(value, name) {
      if (Array.isArray(value)) cfFail(`${name} is a list; this relation compares numbers`);
      const number = typeof value === "number" ? value : Number(String(value).replace(/,/g, "").trim());
      if (!Number.isFinite(number)) cfFail(`${name} = ${JSON.stringify(value)} is not a number; capture it with kind: number`);
      return number;
    }

    function cfOperand(state, operand) {
      if (operand.literal !== undefined) return { name: String(operand.literal), value: operand.literal, literal: true };
      return { name: operand.var, value: cfVar(state, operand.var) };
    }

    function cfRelationOperands(step) {
      const reads = step.reads;
      return reads.parts ? [ reads.total ].concat(reads.parts) : [ reads.a, reads.b ];
    }

    // The captured variables a relation names, in the order they were read.
    function cfRelationNames(step, state) {
      const names = Array.from(new Set(cfRelationOperands(step).filter((operand) => operand.var).map((operand) => operand.var)));
      return names.sort((left, right) => ((state.reads[left] || {}).readAtMs || 0) - ((state.reads[right] || {}).readAtMs || 0));
    }

    // Judges the relation against the current values: { ok, message }.
    function cfJudge(step, state) {
      const tolerance = step.tolerance || 0;
      const show = (item) => (item.literal ? String(item.value) : `${item.name} = ${JSON.stringify(item.value)}`);
      if (step.relation === "subset") {
        const a = cfOperand(state, step.reads.a);
        const b = cfOperand(state, step.reads.b);
        if (!Array.isArray(a.value) || !Array.isArray(b.value)) cfFail(`subset needs list reads, found ${show(a)} and ${show(b)}`);
        if (a.value.length === 0) return { ok: false, message: `expected ${a.name} to list items to find in ${b.name}, but it is empty (a selector that matches nothing proves nothing)` };
        const trimmed = b.value.map((item) => String(item).trim());
        const missing = a.value.map((item) => String(item).trim()).filter((item) => trimmed.indexOf(item) === -1);
        return { ok: missing.length === 0, message: `expected every item of ${a.name} to appear in ${b.name}; missing ${JSON.stringify(missing)} (${a.name} = ${JSON.stringify(a.value)}, ${b.name} = ${JSON.stringify(b.value)})` };
      }
      if (step.relation === "sum") {
        const total = cfOperand(state, step.reads.total);
        const parts = step.reads.parts.map((part) => cfOperand(state, part));
        const sum = parts.reduce((acc, part) => acc + cfNumber(part.value, part.name), 0);
        const gap = Math.abs(cfNumber(total.value, total.name) - sum);
        return { ok: gap <= tolerance, message: `expected ${show(total)} to equal the sum ${sum} of ${parts.map(show).join(", ")} within ${tolerance} (off by ${gap})` };
      }
      const a = cfOperand(state, step.reads.a);
      const b = cfOperand(state, step.reads.b);
      const left = cfNumber(a.value, a.name);
      const right = cfNumber(b.value, b.name);
      if (step.relation === "le") return { ok: left <= right + tolerance, message: `expected ${show(a)} <= ${show(b)} within ${tolerance}` };
      const gap = Math.abs(left - right);
      return { ok: gap <= tolerance, message: `expected ${show(a)} to equal ${show(b)} within ${tolerance} (off by ${gap})` };
    }

    // Re-reads one named read the way it was first read: a page read goes back
    // to its url, waits up to 2 s for the freshness text to change, and reads
    // its selector with its kind.
    async function cfRereadOne(page, state, step, name, timeoutMs) {
      const read = state.reads[name];
      if (page.url() !== read.url) await page.goto(read.url, { waitUntil: "domcontentloaded", timeout: timeoutMs });
      const selector = step.settle && step.settle.freshnessSelector;
      if (selector) {
        const before = read.freshness ? read.freshness[selector] : undefined;
        const deadline = Date.now() + 2000;
        while (Date.now() < deadline) {
          const now = (await cfFreshness(page, { freshnessSelectors: [ selector ] }))[selector];
          if (now !== before && now !== undefined) break;
          await new Promise((resolve) => setTimeout(resolve, 100));
        }
      }
      const spec = { selector: read.selector, locator: read.locator, kind: read.kind };
      const value = await cfRead(page, spec, timeoutMs);
      await cfRecordRead(page, state, name, spec, value);
    }

    // Re-reads every named read in the order it was first read.
    async function cfReread(page, state, step, names, timeoutMs) {
      const order = [];
      const add = (name) => {
        const read = state.reads[name];
        if (!read || order.indexOf(name) !== -1) return;
        order.push(name);
      };
      names.forEach(add);
      for (const name of order) await cfRereadOne(page, state, step, name, timeoutMs);
    }

    async function cfExpectRelation(page, step, state, timeoutMs) {
      const names = cfRelationNames(step, state);
      const first = cfJudge(step, state);
      const firstReads = names.map((name) => cfPublicRead(state.reads[name]));
      if (first.ok) return { relation: step.relation, status: "pass", drift: false, reads: firstReads };
      const failure = (message) => {
        const err = new Error(message);
        err.detail = { relation: step.relation, status: "fail", drift: false, reads: names.map((name) => cfPublicRead(state.reads[name])), firstReads: firstReads };
        return err;
      };
      if (!step.settle) throw failure(first.message);
      let last = first;
      const home = page.url();
      for (let round = 0; round < step.settle.reread && !last.ok; round += 1) {
        await cfReread(page, state, step, names, timeoutMs);
        last = cfJudge(step, state);
      }
      // A re-read navigates to where each figure was read; the steps after
      // this one expect the page they were on.
      if (page.url() !== home) await page.goto(home, { waitUntil: "domcontentloaded", timeout: timeoutMs }).catch(() => null);
      if (!last.ok) throw failure(`${first.message}; after re-read: ${last.message}`);
      return { relation: step.relation, status: "warn", drift: true, reads: names.map((name) => cfPublicRead(state.reads[name])),
               firstReads: firstReads, firstMessage: first.message };
    }

    async function cfRunStep(page, step, state) {
      const timeout = step.timeoutMs;
      switch (step.verb) {
        case "goto":
          state.lastResponse = await page.goto(step.url, { waitUntil: step.waitUntil, timeout: timeout });
          return null;
        case "click":
          await (await cfWait(page, step, timeout)).click();
          return null;
        case "fill": {
          const el = await cfWait(page, step, timeout);
          const value = step.codeSource ? await resolveCodeSource(step.codeSource) : step.value;
          await el.type(value);
          return null;
        }
        case "select":
          await (await cfWait(page, step, timeout)).select(step.value);
          return null;
        case "press":
          if (step.selector) await (await cfWait(page, step, timeout)).focus();
          await page.keyboard.press(step.key);
          return null;
        case "waitFor":
          if (step.selector) await cfWait(page, step, timeout);
          else if (step.urlContains) {
            await page.waitForFunction((needle) => window.location.href.indexOf(needle) !== -1, { timeout: timeout }, step.urlContains);
          } else {
            const response = await page.waitForNavigation({ waitUntil: step.state, timeout: timeout });
            if (response) state.lastResponse = response;
          }
          return null;
        case "waitForUrl":
          await cfPoll(async () => cfUrlMatches(page.url(), step.match), timeout, step.label);
          return { found: page.url() };
        case "waitForText":
          await cfPoll(async () => (await cfTextNow(page, step)).indexOf(step.text) !== -1, timeout, step.label);
          return null;
        case "waitUntilHidden":
          await cfWait(page, step, timeout, "hidden");
          return null;
        case "waitForResponse":
        case "waitForNetworkIdle":
          return cfAwaitEvent(page, step, state);
        case "screenshot":
          return cfScreenshot(page, step);
        case "capture": {
          const value = await cfRead(page, step, timeout);
          const read = await cfRecordRead(page, state, step.as, step, value);
          return { captured: step.as, found: value, kind: step.kind, readAt: read.readAt, url: read.url, selector: read.selector,
                   freshness: read.freshness };
        }
        case "expectRelation":
          return cfExpectRelation(page, step, state, timeout);
        case "expectVisible":
          await cfWait(page, step, timeout, "visible");
          return null;
        case "expectHidden":
          await cfWait(page, step, timeout, "hidden");
          return null;
        case "expectText": {
          const text = await cfText(page, step, timeout);
          if (step.equals !== null && text !== step.equals) cfFail(`expected text ${JSON.stringify(step.equals)}, found ${JSON.stringify(text)}`);
          if (step.contains !== null && text.indexOf(step.contains) === -1) cfFail(`expected text containing ${JSON.stringify(step.contains)}, found ${JSON.stringify(text)}`);
          return { found: text };
        }
        case "expectUrl": {
          const url = page.url();
          if (step.equals !== null && url !== step.equals) cfFail(`expected url ${JSON.stringify(step.equals)}, found ${JSON.stringify(url)}`);
          if (step.contains !== null && url.indexOf(step.contains) === -1) cfFail(`expected url containing ${JSON.stringify(step.contains)}, found ${JSON.stringify(url)}`);
          return { found: url };
        }
        case "expectStatus": {
          if (!state.lastResponse) cfFail("expect_status has no navigation response to read; the flow never performed a goto");
          const status = state.lastResponse.status();
          if (status !== step.equals) cfFail(`expected status ${step.equals}, found ${status}`);
          return { found: status };
        }
        case "expectCount": {
          const count = await cfCount(page, step);
          if (count !== step.equals) cfFail(`expected ${step.equals} element(s) matching ${step.selector}, found ${count}`);
          return { found: count };
        }
        case "expectEqual": {
          const expected = cfVar(state, step.var);
          const actual = step.equalsVar !== null ? cfVar(state, step.equalsVar) : await cfRead(page, step, timeout);
          const source = step.equalsVar !== null ? step.equalsVar : step.selector;
          if (step.tolerance !== undefined) {
            const gap = Math.abs(Number(actual) - Number(expected));
            if (!(gap <= step.tolerance)) cfFail(`expected ${source} = ${JSON.stringify(actual)} to be within ${step.tolerance} of ${step.var} = ${JSON.stringify(expected)}`);
            return { found: actual, expected: expected };
          }
          if (String(actual) !== String(expected)) cfFail(`expected ${source} = ${JSON.stringify(actual)} to equal ${step.var} = ${JSON.stringify(expected)}`);
          return { found: actual, expected: expected };
        }
        case "expectStable":
          return cfExpectStable(page, step, state, timeout);
        case "expectVisual":
          return cfVisual(page, step, timeout);
        case "eval":
          return { value: await page.evaluate("(async () => {" + step.script + "})()") };
        default:
          return cfFail("unknown flow verb: " + step.verb);
      }
    }

    // `options` lets a caller resume a flow part way (startAt, with the
    // captured vars it had) and stop it after a step (afterStep returns
    // true), which is how the testcases lane resumes a case after a re-login.
    async function cfRunFlow(page, steps, options = {}) {
      const state = { lastResponse: null, vars: Object.assign({}, options.vars || {}), reads: Object.assign({}, options.reads || {}),
                      armed: null,
                      freshnessSelectors: Array.from(new Set(steps.filter((step) => step.settle && step.settle.freshnessSelector).map((step) => step.settle.freshnessSelector))) };
      const results = [];
      const pending = steps.filter((step) => step.index >= (options.startAt || 0));
      await cfInstallMeasure(page, steps);
      const watching = steps.some((step) => step.verb === "expectStable");
      const inflight = new Set();
      // Every request event stamps lastActivity, so a request that starts and
      // finishes between two polls still breaks the quiet window.
      const touch = () => { state.lastActivity = Date.now(); };
      const track = { request: (request) => { touch(); inflight.add(request); }, requestfinished: (request) => { touch(); inflight.delete(request); }, requestfailed: (request) => { touch(); inflight.delete(request); } };
      if (watching) for (const [event, fn] of Object.entries(track)) page.on(event, fn);
      state.inflight = inflight;
      state.lastActivity = 0;
      // Every step records when it started (ms from the walk's start) and how
      // long it ran; a step's `budgetMs` is judged on the span from the start
      // of its `budgetFrom` step (or its own start) to its own end.
      const walkStart = Date.now();
      const startedAtByTag = new Map();
      for (let position = 0; position < pending.length; position += 1) {
        const step = pending[position];
        const next = pending[position + 1];
        // Arm the next step's event wait before this step runs, so the event
        // this step causes is observed even when it lands immediately.
        if (cfIsEventWait(next) && next.after === "previous" && !cfIsEventWait(step)) state.armed = cfArm(page, next);
        const record = { index: step.index, verb: step.verb, label: step.label, raw: step.raw === true, ok: true, error: null };
        const startedAt = Date.now();
        record.startedAtMs = startedAt - walkStart;
        if (step.tag) { record.tag = step.tag; startedAtByTag.set(step.tag, startedAt); }
        try {
          const detail = await cfRunStep(page, step, state);
          if (detail) Object.assign(record, detail);
        } catch (err) {
          record.ok = false;
          record.error = String(err);
          const waited = (err && err.name === "TimeoutError") || /Waiting (for selector|failed)/.test(String(err && err.message));
          if (waited && step.selector) { record.selector = step.selector; Object.defineProperty(record, "candidates", { value: await cfCandidates(page, step), enumerable: false }); }
          if (err && err.detail) Object.assign(record, err.detail);
        }
        const endedAt = Date.now();
        record.durationMs = endedAt - startedAt;
        if (record.ok && step.budgetMs !== undefined) {
          const known = step.budgetFrom === undefined || startedAtByTag.has(step.budgetFrom);
          const from = step.budgetFrom !== undefined && known ? startedAtByTag.get(step.budgetFrom) : startedAt;
          const span = endedAt - from;
          record.spanMs = span;
          if (!known) {
            // A resumed walk starts after the labelled step, so the origin is
            // gone; measuring only this step would pass a span it never saw.
            record.ok = false;
            record.error = `step ${step.index + 1} budget_from ${step.budgetFrom} started before this walk resumed, so its span cannot be measured`;
          } else if (span > step.budgetMs) {
            record.ok = false;
            record.error = `span ${step.budgetFrom !== undefined ? step.budgetFrom : "step " + (step.index + 1)}..${step.tag || "step " + (step.index + 1)} took ${span}ms, budget ${step.budgetMs}ms`;
          }
        }
        results.push(record);
        const stop = (options.afterStep && (await options.afterStep(step, record))) || !record.ok;
        if (stop) break;
      }
      if (state.armed) state.armed.dispose();
      if (watching) for (const [event, fn] of Object.entries(track)) page.off(event, fn);
      results.vars = state.vars;
      results.reads = state.reads;
      return results;
    }
  JS

  # --- the auth flow (extracted verbatim from ChangeLaneBrowserless) ----------

  class << self
    def auth_runtime_js = [ CODE_SOURCE_JS, AUTH_JS ].join("\n")

    def flow_runtime_js = [ CODE_SOURCE_JS, FLOW_JS ].join("\n")

    # Both runtimes in one module, for a lane that logs in and then walks a
    # declarative flow in the same page (the testcases lane). Emitting
    # `auth_runtime_js` and `flow_runtime_js` side by side would declare
    # `resolveCodeSource` twice, which an ES module rejects outright, so the
    # shared helper is emitted once here instead.
    def auth_and_flow_runtime_js = [ CODE_SOURCE_JS, AUTH_JS, FLOW_JS ].join("\n")

    # A login url in the config may be absolute or site-relative; the lane has
    # always resolved a relative one against the target's base url.
    def absolute_url(url, base_url)
      return url.to_s if url.to_s =~ %r{\Ahttps?://}

      path = url.to_s
      "#{base_url}#{path.start_with?('/') ? path : "/#{path}"}"
    end

    # The browserless lane's `auth:` block, already normalized by its own
    # AuthConfig into `{ url:, fields:, submit_selector:, wait_for_selector:,
    # timeout_ms: }` steps, compiled into the payload its runtime consumes.
    # Exactly the shape the lane emitted before this file existed.
    def compile_auth(steps, base_url:)
      return nil unless steps

      { steps: steps.map { |step| compile_auth_step(step, base_url) } }
    end

    def compile_auth_step(step, base_url)
      {
        url: step[:url] && !step[:url].empty? ? absolute_url(step[:url], base_url) : nil,
        fields: step[:fields].map { |field| compile_auth_field(field) },
        submitSelector: step[:submit_selector],
        waitForSelector: step[:wait_for_selector],
        timeoutMs: step[:timeout_ms]
      }
    end

    def compile_auth_field(field)
      return { selector: field[:selector], codeSource: compile_code_source(field[:code_source]) } if field[:code_source]

      { selector: field[:selector], value: field[:value].to_s }
    end

    def compile_code_source(code_source)
      {
        url: code_source[:url],
        pattern: code_source[:pattern],
        timeoutMs: code_source[:timeout_ms],
        pollIntervalMs: code_source[:poll_interval_ms]
      }
    end
  end

  # --- the general vocabulary -------------------------------------------------

  attr_reader :base_url, :timeout_ms

  # `viewport` ({ width:, height: }) sizes the page before the first step;
  # without it the page keeps Puppeteer's default.
  # `before` is the compiled steps that run ahead of these in the same page
  # (a case's preconditions): the variables they capture are in scope here,
  # as they are at run time.
  def initialize(steps, base_url: nil, timeout_ms: DEFAULT_TIMEOUT_MS, viewport: nil, env: ENV, before: [])
    @raw_steps = Array(steps)
    @base_url = base_url.to_s
    @timeout_ms = Integer(timeout_ms)
    @viewport = viewport && compile_viewport(viewport, 'flow')
    @env = env
    @tags = {}
    @var_kinds = {}
    @inherited = []
    before.each { |step| track_var(@inherited, step) }
  end

  # The compiled steps, credentials included. Hand this to the container and
  # nowhere else.
  def compile
    @compile ||= begin
      captured = @inherited.dup
      @raw_steps.each_with_index.map do |raw, index|
        step = compile_step(raw, index, captured.dup)
        track_var(captured, step)
        step
      end
    end
  end

  # The only shape that may be written to a report, a log, or a dump: every
  # value that came from an env var is replaced by a fixed marker, so a
  # password cannot ride a compiled-payload dump into an artifact.
  def redacted = compile.map { |step| step[:secret] ? step.merge(value: REDACTED) : step }

  # A pretty JSON dump of the redacted steps, for a report or a review.
  def dump = JSON.pretty_generate(redacted)

  def labels = compile.map { |step| step[:label] }

  def eval_steps = compile.select { |step| step[:raw] }

  def uses_eval? = eval_steps.any?

  # One browserless /function module running the whole flow and returning a
  # per-step result record. Carries real credentials: never log it.
  def function_module
    <<~JS
      #{self.class.flow_runtime_js}
      export default async ({ page }) => {
        const steps = #{JSON.generate(compile)};
        const viewport = #{JSON.generate(@viewport)};
        if (viewport) await page.setViewport(viewport);
        const results = await cfRunFlow(page, steps);
        return { data: { steps: results }, type: "application/json" };
      };
    JS
  end

  private

  # The variables a step leaves behind for later steps, and the kind each was
  # read as (a relation checks that a `list` only meets `subset`).
  def track_var(captured, step)
    case step[:verb]
    when 'capture' then name = step[:as]
    when 'expectStable' then name = step[:var]
    else return
    end
    captured << name
    @var_kinds[name] = step[:kind]
  end

  # `captured` names the variables earlier steps captured, so expect_equal can
  # refuse one that nothing set.
  def compile_step(raw, index, captured)
    verb, value, timeout, options = split_step(raw, index)
    compiled = with_locator(send(:"compile_#{verb}", value, captured))
    compiled = compiled.merge(verb: RUNTIME_VERBS.fetch(verb), index: index, timeoutMs: Integer(timeout || @timeout_ms))
    compiled = compiled.merge(tag: tag_for(options['label'], index)) if options['label']
    options['budget_ms'] ? compiled.merge(budget_options(options, index)) : budget_from_alone(options, compiled, index)
  end

  # (suite_version 5) A step's own name, which `budget_from` points at. A name
  # is a word, and may be used once in a case.
  def tag_for(raw, index)
    name = raw.to_s
    raise Error, "step #{index + 1} label must be a word (letters, digits, underscore, dash), got #{raw.inspect}" unless name.match?(TAG_NAME)
    raise Error, "step #{index + 1} reuses the label #{name}" if @tags.key?(name)

    @tags[name] = index
    name
  end

  # (suite_version 5) A budget is a verdict, not a timeout: the step still
  # passes or fails on its own, and then fails for the span from `budget_from`'s
  # start (or its own start) to its own end exceeding `budget_ms`.
  def budget_options(options, index)
    budget = options['budget_ms']
    budget = Integer(budget.to_s, exception: false) unless budget.is_a?(Integer)
    raise Error, "step #{index + 1} budget_ms must be a positive integer, got #{options['budget_ms'].inspect}" unless budget&.positive?

    from = options['budget_from']
    return { budgetMs: budget } if from.nil?

    unless @tags.key?(from.to_s) && @tags[from.to_s] < index
      raise Error, "step #{index + 1} budget_from #{from} is not the label of an earlier step"
    end

    { budgetMs: budget, budgetFrom: from.to_s }
  end

  def budget_from_alone(options, compiled, index)
    raise Error, "step #{index + 1} budget_from needs a budget_ms" if options['budget_from']

    compiled
  end

  # A text/nth selector carries a locator the runtime resolves in the page; a
  # plain one carries none, so its compiled step is unchanged.
  def with_locator(compiled)
    return compiled unless compiled[:selector]

    locator = ChangeFlowSelector.locator(compiled[:selector])
    locator ? compiled.merge(locator: locator) : compiled
  rescue ChangeFlowSelector::Error => e
    raise Error, e.message
  end

  # A step is a mapping carrying exactly one verb key, plus optional
  # step-level options. Two verbs in one mapping is an authoring mistake with
  # no defensible ordering, so it is refused rather than silently resolved.
  def split_step(raw, index)
    raise Error, "step #{index + 1} must be a mapping, got #{raw.class}" unless raw.is_a?(Hash)

    keyed = raw.to_h { |key, value| [ key.to_s, value ] }
    verbs = keyed.keys & VERBS
    unknown = keyed.keys - VERBS - OPTION_KEYS
    raise Error, "step #{index + 1} has unknown key(s): #{unknown.sort.join(', ')}" if unknown.any?
    raise Error, "step #{index + 1} names no known verb (expected one of: #{VERBS.join(', ')})" if verbs.empty?
    raise Error, "step #{index + 1} names more than one verb: #{verbs.sort.join(', ')}" if verbs.size > 1

    value = keyed.fetch(verbs.first)
    options = %w[budget_ms budget_from label].to_h { |key| [ key, keyed[key] || inner_option(value, key) ] }.compact
    [ verbs.first, value, keyed['timeout_ms'] || inner_option(value, 'timeout_ms'), options ]
  end

  # A step-level `timeout_ms` wins over one inside the verb's own mapping
  # (`wait_for: { selector:, timeout_ms: }`); the flow default comes last.
  def inner_option(value, key)
    return nil unless value.is_a?(Hash)

    value[key] || value[key.to_sym]
  end

  # --- actions ---------------------------------------------------------------

  def compile_goto(value, _captured)
    spec = spec_for(value, 'url')
    url = self.class.absolute_url(require_string(spec, 'url', 'goto'), @base_url)
    { url: url, waitUntil: (spec['wait_until'] || DEFAULT_WAIT_UNTIL).to_s, label: "goto #{url}" }
  end

  def compile_click(value, _captured)
    selector = selector_for(value, 'click')
    { selector: selector, label: "click #{selector}" }
  end

  # The one step that can carry a secret. Exactly one value source: an env var
  # read on the host, a literal already visible in the flow file, or a
  # code_source resolved inside the container.
  def compile_fill(value, _captured)
    spec = spec_for(value, 'selector')
    selector = require_string(spec, 'selector', 'fill')
    sources = spec.slice('env', 'value', 'code_source').keys
    raise Error, "fill #{selector} needs one of env, value, or code_source" if sources.empty?
    raise Error, "fill #{selector} names more than one value source: #{sources.sort.join(', ')}" if sources.size > 1

    fill_source(selector, spec)
  end

  def fill_source(selector, spec)
    if spec['code_source']
      source = flow_code_source(spec['code_source'], selector)
      return { selector: selector, codeSource: source, label: "fill #{selector} from code_source #{source[:url]}" }
    end
    if spec.key?('env')
      name = spec['env'].to_s
      return { selector: selector, value: @env[name].to_s, secret: true, label: "fill #{selector} from env #{name}" }
    end

    { selector: selector, value: spec['value'].to_s, label: "fill #{selector} with #{spec['value'].to_s.inspect}" }
  end

  def flow_code_source(raw, selector)
    raise Error, "fill #{selector} code_source must be a mapping" unless raw.is_a?(Hash)

    spec = raw.to_h { |key, value| [ key.to_s, value ] }
    raise Error, "fill #{selector} code_source.url is not set" if spec['url'].to_s.empty?

    {
      url: spec['url'].to_s,
      pattern: spec['pattern']&.to_s,
      timeoutMs: Integer(spec['timeout_ms'] || DEFAULT_CODE_SOURCE_TIMEOUT_MS),
      pollIntervalMs: Integer(spec['poll_interval_ms'] || DEFAULT_CODE_SOURCE_POLL_INTERVAL_MS)
    }
  end

  def compile_select(value, _captured)
    spec = spec_for(value, 'selector')
    selector = require_string(spec, 'selector', 'select')
    raise Error, "select #{selector} needs a value" unless spec.key?('value')

    option = spec['value'].to_s
    { selector: selector, value: option, label: "select #{option.inspect} in #{selector}" }
  end

  def compile_press(value, _captured)
    spec = spec_for(value, 'key')
    key = require_string(spec, 'key', 'press')
    selector = spec['selector']&.to_s
    { key: key, selector: selector, label: selector ? "press #{key} in #{selector}" : "press #{key}" }
  end

  # The readiness contract in step form: wait for a selector, for the url to
  # contain a fragment, or for a navigation to reach a load state. The wait is
  # the contract; the timeout is only the failure mode.
  def compile_wait_for(value, _captured)
    spec = spec_for(value, 'selector')
    conditions = spec.slice('selector', 'url_contains', 'state').keys
    raise Error, 'wait_for needs one of selector, url_contains, or state' if conditions.empty?
    raise Error, "wait_for names more than one condition: #{conditions.sort.join(', ')}" if conditions.size > 1

    { selector: spec['selector']&.to_s, urlContains: spec['url_contains']&.to_s, state: spec['state']&.to_s,
      label: "wait_for #{conditions.first} #{spec.fetch(conditions.first)}" }
  end

  # `full_page: true` captures the whole scrollable page; `viewport:` resizes
  # for this capture only.
  # --- waits ------------------------------------------------------------------

  def compile_wait_for_url(value, _captured)
    spec = spec_for(value, 'glob')
    match = url_match(spec, 'glob', 'regex', 'wait_for_url')
    { match: match, label: "wait_for_url #{match[:description]}" }
  end

  def compile_wait_for_text(value, _captured)
    spec = spec_for(value, 'text')
    text = require_string(spec, 'text', 'wait_for_text')
    selector = spec['selector']&.to_s
    { text: text, selector: selector, label: "wait_for_text #{text.inspect}#{" in #{selector}" if selector}" }
  end

  def compile_wait_until_hidden(value, _captured)
    selector = selector_for(value, 'wait_until_hidden')
    { selector: selector, label: "wait_until_hidden #{selector}" }
  end

  def compile_wait_for_response(value, _captured)
    spec = spec_for(value, 'url')
    match = url_match(spec, 'url', 'url_regex', 'wait_for_response')
    status = spec['status']
    raise Error, "wait_for_response status must be an HTTP status code, got #{status.inspect}" unless status.nil? || (status.is_a?(Integer) && (100..599).cover?(status))

    { match: match, status: status, after: event_after(spec, 'wait_for_response'),
      label: "wait_for_response #{match[:description]}#{" status #{status}" if status}" }
  end

  def compile_wait_for_network_idle(value, _captured)
    spec = value == true ? {} : spec_for(value, 'idle_ms')
    idle = spec.fetch('idle_ms', DEFAULT_NETWORK_IDLE_MS)
    unless idle.is_a?(Integer) && NETWORK_IDLE_RANGE.cover?(idle)
      raise Error, "wait_for_network_idle idle_ms must be an integer from #{NETWORK_IDLE_RANGE.min} to #{NETWORK_IDLE_RANGE.max}, got #{idle.inspect}"
    end

    { idleMs: idle, after: event_after(spec, 'wait_for_network_idle'), label: "wait_for_network_idle #{idle}ms" }
  end

  # `previous` (the default) arms the listener before the step before this
  # one; `none` arms it when this step starts.
  def event_after(spec, verb)
    after = (spec['after'] || 'previous').to_s
    return after if %w[previous none].include?(after)

    raise Error, "#{verb} after must be previous or none, got #{after.inspect}"
  end

  # A glob (`*` within a path segment, `**` across them, `?` one character)
  # or a regex, compiled to one regex source the runtime tests. A pattern
  # starting with "/" matches the path and query rather than the full url.
  def url_match(spec, glob_key, regex_key, verb)
    keys = spec.slice(glob_key, regex_key).keys
    raise Error, "#{verb} needs #{glob_key} or #{regex_key}" if keys.empty?
    raise Error, "#{verb} names both #{glob_key} and #{regex_key}" if keys.size > 1

    raw = require_string(spec, keys.first, verb)
    # A regex is compiled by the browser runtime, in JavaScript's dialect, so
    # it is checked there; an invalid one fails its step by name.
    if keys.first == regex_key
      return { pattern: raw, pathOnly: false, description: "matching /#{raw}/" }
    end

    { pattern: glob_regex(raw), pathOnly: raw.start_with?('/'), description: raw.inspect }
  end

  def glob_regex(glob)
    body = glob.split(/(\*\*|\*|\?)/).map do |part|
      case part
      when '**' then '.*'
      when '*' then '[^/]*'
      when '?' then '.'
      else Regexp.escape(part)
      end
    end.join
    "^#{body}$"
  end

  def compile_screenshot(value, _captured)
    spec = spec_for(value, 'name')
    name = (spec['name'] || 'screenshot').to_s
    full_page = spec['full_page'] == true
    viewport = spec['viewport'] && compile_viewport(spec['viewport'], "screenshot #{name}")
    label = [ "screenshot #{name}", full_page ? 'full page' : nil,
              viewport ? "at #{viewport[:width]}x#{viewport[:height]}" : nil ].compact.join(' ')
    { name: name, fullPage: full_page, viewport: viewport, label: label }
  end

  # Reads a value into a named variable a later expect_equal compares against,
  # so a count on one page can be checked against a list on another.
  def compile_capture(value, _captured)
    spec = spec_for(value, 'selector')
    kind = read_kind(spec, 'capture')
    selector = read_selector(spec, 'capture', kind)
    name = var_name(spec['as'] || spec['var'], 'capture', 'as')
    { selector: selector, as: name, kind: kind, label: "capture #{kind} of #{selector || 'the window'} as #{name}" }
  end

  # The recorder resolves selectors with document.querySelector in the page, so
  # a text or nth locator, or a `::-p-` selector, has no first-paint history.
  # Refused here rather than passed with nothing measured.
  def recordable_selector!(selector, who = 'expect_stable')
    return unless ChangeFlowSelector.locator(selector) || selector.include?('::-p-')

    raise Error, "#{who} needs a plain CSS selector (it is resolved in the page; #{selector.inspect} is not one)"
  end

  # `scroll_y` alone reads the window; every other kind reads an element.
  def read_selector(spec, verb, kind)
    return require_string(spec, 'selector', verb) unless kind == 'scroll_y'

    spec['selector'].to_s.empty? ? nil : spec['selector'].to_s
  end

  # (suite_version 5) A figure must not move between first paint and the point
  # the page settles (fonts ready, network idle): no sampled value may deviate
  # from the first by more than `tolerance_px`, and the layout shift attributed
  # to the element may not exceed `max_cls` (default 0). The last value is kept
  # in `var`.
  def compile_expect_stable(value, _captured)
    spec = spec_for(value, 'var')
    name = var_name(spec['var'], 'expect_stable', 'var')
    kind = (spec['kind'] || 'rect.y').to_s
    raise Error, "expect_stable kind must be one of #{STABLE_KINDS.join(', ')}, got #{kind}" unless STABLE_KINDS.include?(kind)

    tolerance = spec.fetch('tolerance_px', 0)
    raise Error, "expect_stable tolerance_px must be a number of 0 or more, got #{tolerance.inspect}" unless tolerance.is_a?(Numeric) && tolerance >= 0

    wait = (spec['wait'] || 'fonts').to_s
    raise Error, "expect_stable wait must be fonts, got #{wait}" unless wait == 'fonts'

    max_cls = spec.fetch('max_cls', 0)
    raise Error, "expect_stable max_cls must be a number of 0 or more, got #{max_cls.inspect}" unless max_cls.is_a?(Numeric) && max_cls >= 0

    selector = read_selector(spec, 'expect_stable', kind)
    recordable_selector!(selector)
    { var: name, selector: selector, kind: kind, tolerancePx: tolerance, maxCls: max_cls,
      label: "expect_stable #{kind} of #{selector || 'the window'} within #{tolerance}px" }
  end

  VISUAL_NAME = /\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/
  VISUAL_KEYS = %w[name selector viewport max_diff_ratio mask].freeze
  DEFAULT_MAX_DIFF_RATIO = 0.001

  # (suite_version 7) The page or one element must match the committed baseline
  # within `max_diff_ratio` (0 to 1; 0 is exact). The diff is the host's; `mask`
  # lists plain CSS selectors hidden before the capture.
  def compile_expect_visual(value, _captured)
    spec = spec_for(value, 'name')
    unknown = spec.keys - VISUAL_KEYS
    raise Error, "expect_visual does not know #{unknown.join(', ')} (expected: #{VISUAL_KEYS.join(', ')})" unless unknown.empty?

    name = spec['name'].to_s
    raise Error, "expect_visual name must be a word (letters, digits, underscore, dash), got #{spec['name'].inspect}" unless name.match?(VISUAL_NAME)

    ratio = spec.fetch('max_diff_ratio', DEFAULT_MAX_DIFF_RATIO)
    unless ratio.is_a?(Numeric) && ratio.to_f.finite? && ratio.between?(0, 1)
      raise Error, "expect_visual max_diff_ratio is a fraction from 0 to 1 (0 is exact), got #{ratio.inspect}"
    end

    selector = spec['selector'].nil? ? nil : require_string(spec, 'selector', 'expect_visual')
    viewport = spec['viewport'] && compile_viewport(spec['viewport'], "expect_visual #{name}")
    { name: name, selector: selector, maxDiffRatio: ratio, mask: visual_masks(spec['mask']), viewport: viewport,
      label: "expect_visual #{name} of #{selector || 'the page'}" }
  end

  def visual_masks(raw)
    return [] if raw.nil?
    raise Error, 'expect_visual mask must be a list of CSS selectors' unless raw.is_a?(Array) && raw.all? { |item| item.is_a?(String) && !item.strip.empty? }

    raw.each { |mask| recordable_selector!(mask, 'expect_visual mask') }
    raw
  end

  # --- assertions -------------------------------------------------------------

  def compile_expect_visible(value, _captured) = expect_selector(value, 'expect_visible')

  def compile_expect_hidden(value, _captured) = expect_selector(value, 'expect_hidden')

  def expect_selector(value, verb)
    selector = selector_for(value, verb)
    { selector: selector, label: "#{verb} #{selector}" }
  end

  def compile_expect_text(value, _captured)
    spec = spec_for(value, 'selector')
    selector = require_string(spec, 'selector', 'expect_text')
    match = match_for(spec, 'expect_text')
    { selector: selector, equals: match[:equals], contains: match[:contains],
      label: "expect_text #{selector} #{match[:description]}" }
  end

  def compile_expect_url(value, _captured)
    match = match_for(spec_for(value, 'contains'), 'expect_url')
    { equals: match[:equals], contains: match[:contains], label: "expect_url #{match[:description]}" }
  end

  # Reads the status of the last navigation this flow performed, so a route
  # that answers 500 with a rendered body is still a failure.
  def compile_expect_status(value, _captured)
    spec = spec_for(value, 'equals')
    raise Error, 'expect_status needs an expected status code' unless spec.key?('equals')

    status = Integer(spec['equals'])
    { equals: status, label: "expect_status #{status}" }
  end

  def compile_expect_count(value, _captured)
    spec = spec_for(value, 'selector')
    selector = require_string(spec, 'selector', 'expect_count')
    raise Error, "expect_count #{selector} needs an expected count" unless spec.key?('equals')

    count = Integer(spec['equals'])
    { selector: selector, equals: count, label: "expect_count #{selector} equals #{count}" }
  end

  # Compares a captured variable with a live read of a selector, or with a
  # second captured variable. Both sides compare as strings, so a captured
  # number matches a count.
  def compile_expect_equal(value, captured)
    spec = spec_for(value, 'var')
    name = captured_var(spec['var'], 'var', captured)
    refuse_list('expect_equal', name)
    sources = spec.slice('selector', 'equals_var').keys
    window_scroll = spec['kind'].to_s == 'scroll_y' && sources.empty?
    raise Error, 'expect_equal needs one of selector or equals_var' if sources.empty? && !window_scroll
    raise Error, 'expect_equal names both selector and equals_var' if sources.size > 1

    tolerance = equal_tolerance(spec)
    if spec.key?('equals_var')
      other = captured_var(spec['equals_var'], 'equals_var', captured)
      refuse_list('expect_equal', other)
      return with_tolerance({ var: name, equalsVar: other, selector: nil, kind: nil, label: "expect_equal #{other} equals #{name}" }, tolerance)
    end

    kind = read_kind(spec, 'expect_equal')
    raise Error, 'expect_equal cannot compare a list; use expect_relation with relation subset' if kind == 'list'

    selector = read_selector(spec, 'expect_equal', kind)
    with_tolerance({ var: name, equalsVar: nil, selector: selector, kind: kind,
                     label: "expect_equal #{kind} of #{selector || 'the window'} equals #{name}" }, tolerance)
  end

  def refuse_list(verb, name)
    return unless @var_kinds[name] == 'list'

    raise Error, "#{verb} cannot use #{name}, a list read; only expect_relation with relation subset compares lists"
  end

  # (suite_version 8) A relation between named reads, judged at run time:
  # `equal` (|a - b| <= tolerance), `le` (a <= b + tolerance), `sum` (total
  # equals the sum of parts within tolerance) and `subset` (every item of list
  # a appears in list b). An operand is a captured variable name or a numeric
  # literal. `settle` re-reads the named reads once on a mismatch, so a
  # mismatch that heals is a drift warning and one that persists is a failure.
  def compile_expect_relation(value, captured)
    spec = spec_for(value, 'relation')
    relation = spec['relation'].to_s
    raise Error, "expect_relation relation must be one of #{RELATIONS.keys.join(', ')}, got #{relation.inspect}" unless RELATIONS.key?(relation)

    reads = relation_reads(spec['reads'], relation, captured)
    tolerance = spec.fetch('tolerance', 0)
    raise Error, "expect_relation tolerance must be a number of 0 or more, got #{tolerance.inspect}" unless tolerance.is_a?(Numeric) && tolerance >= 0

    settle = relation_settle(spec['settle'])
    names = relation_operands(reads).filter_map { |operand| operand[:var] }.uniq
    { relation: relation, reads: reads, tolerance: tolerance, settle: settle,
      label: "expect_relation #{relation} of #{names.join(', ').then { |list| list.empty? ? 'literals' : list }}" }
  end

  def relation_reads(raw, relation, captured)
    keys = RELATIONS.fetch(relation)
    raise Error, "expect_relation #{relation} needs reads: #{keys.join(' and ')}" unless raw.is_a?(Hash)

    given = raw.to_h { |key, operand| [ key.to_s, operand ] }
    raise Error, "expect_relation #{relation} reads must be exactly #{keys.join(' and ')}, got #{given.keys.sort.join(', ')}" unless given.keys.sort == keys.sort

    reads = if relation == 'sum'
      parts = given['parts']
      raise Error, 'expect_relation sum parts must be a list of one or more reads' unless parts.is_a?(Array) && !parts.empty?

      { total: operand_for(given['total'], captured), parts: parts.map { |part| operand_for(part, captured) } }
    else
      { a: operand_for(given['a'], captured), b: operand_for(given['b'], captured) }
    end
    check_operand_kinds(relation, reads)
    reads
  end

  # A numeric literal, or the name of a variable an earlier step captured.
  def operand_for(raw, captured)
    return { literal: raw } if raw.is_a?(Numeric)

    name = raw.to_s
    raise Error, "expect_relation read #{raw.inspect} must be a captured variable name or a number" unless raw.is_a?(String) && name.match?(VAR_NAME)
    raise Error, "expect_relation read #{name} is not captured by an earlier step" unless captured.include?(name)

    { var: name }
  end

  def relation_operands(reads) = reads.values.flatten

  # A list var belongs to `subset` and nowhere else, and `subset` takes
  # nothing but list vars.
  def check_operand_kinds(relation, reads)
    relation_operands(reads).each do |operand|
      kind = operand[:var] ? @var_kinds[operand[:var]] : nil
      if relation == 'subset'
        next if kind == 'list'

        raise Error, "expect_relation subset needs list reads (capture with kind: list), got #{operand[:var] || operand[:literal].inspect}"
      elsif kind == 'list'
        raise Error, "expect_relation #{relation} cannot use #{operand[:var]}, a list read; only subset compares lists"
      end
    end
  end

  def relation_settle(raw)
    return nil if raw.nil?
    raise Error, 'expect_relation settle must be a mapping (reread, freshness_selector)' unless raw.is_a?(Hash)

    spec = raw.to_h { |key, inner| [ key.to_s, inner ] }
    unknown = spec.keys - %w[reread freshness_selector]
    raise Error, "expect_relation settle has unknown key(s): #{unknown.sort.join(', ')}" if unknown.any?

    reread = spec.fetch('reread', 1)
    raise Error, "expect_relation settle reread must be an integer from 1 to #{MAX_REREAD}, got #{reread.inspect}" unless reread.is_a?(Integer) && reread.between?(1, MAX_REREAD)

    freshness = spec['freshness_selector']
    raise Error, 'expect_relation settle freshness_selector must be a selector string' unless freshness.nil? || (freshness.is_a?(String) && !freshness.empty?)

    { reread: reread, freshnessSelector: freshness }
  end

  # (suite_version 5) `tolerance` makes the compare numeric, within that
  # distance. Absent, the compare is the v4 string compare and the compiled
  # step carries no extra key.
  def equal_tolerance(spec)
    return nil unless spec.key?('tolerance')

    tolerance = spec['tolerance']
    raise Error, "expect_equal tolerance must be a number of 0 or more, got #{tolerance.inspect}" unless tolerance.is_a?(Numeric) && tolerance >= 0

    tolerance
  end

  def with_tolerance(step, tolerance) = tolerance.nil? ? step : step.merge(tolerance: tolerance)

  def captured_var(raw, key, captured)
    name = var_name(raw, 'expect_equal', key)
    raise Error, "expect_equal #{key} #{name} is not captured by an earlier step" unless captured.include?(name)

    name
  end

  def var_name(raw, verb, key)
    name = raw.to_s
    raise Error, "#{verb} needs #{key}: a variable name (letters, digits, underscore)" unless name.match?(VAR_NAME)

    name
  end

  def read_kind(spec, verb)
    kind = (spec['kind'] || 'text').to_s
    raise Error, "#{verb} kind must be one of #{READ_KINDS.join(', ')}, got #{kind}" unless READ_KINDS.include?(kind)

    kind
  end

  def compile_viewport(raw, where)
    raise Error, "#{where} viewport must be a mapping of width and height" unless raw.is_a?(Hash)

    spec = raw.to_h { |key, inner| [ key.to_s, inner ] }
    width = Integer(spec['width'], exception: false)
    height = Integer(spec['height'], exception: false)
    raise Error, "#{where} viewport needs positive integer width and height" unless width&.positive? && height&.positive?

    { width: width, height: height }
  end

  # --- the escape hatch --------------------------------------------------------

  # Raw JS, run as-is in the page. Marked `raw: true` and labeled as raw JS so
  # every reader of a report can see that this step is not a checked assertion
  # but hand-written code the declarative vocabulary did not cover.
  def compile_eval(value, _captured)
    script = require_string(spec_for(value, 'script'), 'script', 'eval')
    { script: script, raw: true, label: "eval raw JS (declarative contract bypassed): #{script}" }
  end

  # --- shared parsing -----------------------------------------------------------

  # Every verb takes either a scalar shorthand (`click: "#go"`) or a full
  # mapping (`click: { selector: "#go" }`); the shorthand fills the verb's
  # primary key.
  def spec_for(value, primary_key)
    return { primary_key => value } unless value.is_a?(Hash)

    value.to_h { |key, inner| [ key.to_s, inner ] }
  end

  def selector_for(value, verb) = require_string(spec_for(value, 'selector'), 'selector', verb)

  def require_string(spec, key, verb)
    found = spec[key].to_s
    raise Error, "#{verb} needs a #{key}" if found.empty?

    found
  end

  def match_for(spec, verb)
    modes = spec.slice('equals', 'contains').keys
    raise Error, "#{verb} needs equals or contains" if modes.empty?
    raise Error, "#{verb} names both equals and contains" if modes.size > 1

    mode = modes.first
    expected = spec.fetch(mode).to_s
    { equals: mode == 'equals' ? expected : nil, contains: mode == 'contains' ? expected : nil,
      description: "#{mode} #{expected.inspect}" }
  end
end
