export default async function ({ page }) {
  const baseUrl = "https://app.example.org";
  const routeEntries = [{"path":"/","auth":false,"figmaViewport":null,"waitFor":{"loadState":"domcontentloaded","selector":"body","urlContains":null,"urlMatches":null,"timeoutMs":30000},"states":[]},{"path":"/about","auth":false,"figmaViewport":null,"waitFor":{"loadState":"domcontentloaded","selector":"body","urlContains":null,"urlMatches":null,"timeoutMs":30000},"states":[]}];
  const viewports = [{"name":"mobile","width":390,"height":844},{"name":"tablet","width":768,"height":1024},{"name":"desktop","width":1440,"height":900}];
  const auth = null;
  const figmaRefs = {};
  const basicAuth = null;
  const capture = {"screenshots":false,"video":false,"fps":0};
  const isolateCells = true;
  const locale = "fr-FR";
  const deviceScaleFactor = 1;
  const diffThreshold = 32;
  const diffStabilityCss = "*, *::before, *::after {\n  animation-delay: -1ms !important;\n  animation-duration: 1ms !important;\n  animation-iteration-count: 1 !important;\n  transition-duration: 1ms !important;\n  transition-delay: -1ms !important;\n  caret-color: transparent !important;\n  -webkit-font-smoothing: antialiased !important;\n}\n";

  // Applies one readiness contract after a navigation: the load state was
// already passed to page.goto, so what is left is the selector and the
// optional url predicate. A miss throws, and the caller grades it as the
// navigation failure it is.
async function awaitReadiness(page, waitFor) {
  if (waitFor.selector) {
    await page.waitForSelector(waitFor.selector, { timeout: waitFor.timeoutMs });
  }
  if (waitFor.urlContains) {
    await page.waitForFunction(
      (needle) => window.location.href.indexOf(needle) !== -1,
      { timeout: waitFor.timeoutMs },
      waitFor.urlContains
    );
  }
  if (waitFor.urlMatches) {
    await page.waitForFunction(
      (pattern) => new RegExp(pattern).test(window.location.href),
      { timeout: waitFor.timeoutMs },
      waitFor.urlMatches
    );
  }
}

  function ScreencastSampler(opts) {
  const frames = [], ticks = [];
  const maxFrames = opts.maxFrames, maxBytes = opts.maxBytes;
  let pending = null, latest = -1, bytes = 0, dropped = 0, cut = false, client = null, handler = null;
  const offer = (data) => { if (!cut) { pending = data; latest = -1; } };
  return {
    seed(data) { offer(data); },
    async attach(c) {
      client = c;
      handler = (f) => {
        c.send("Page.screencastFrameAck", { sessionId: f.sessionId }).catch(() => {});
        offer(f.data);
      };
      c.on("Page.screencastFrame", handler);
      await c.send("Page.startScreencast", { format: "jpeg", quality: opts.quality, maxWidth: opts.maxWidth, maxHeight: opts.maxHeight, everyNthFrame: 1 });
    },
    tick() {
      if (cut) { dropped++; return; }
      if (pending !== null) {
        const size = pending.length;
        if ((maxFrames && frames.length + 1 > maxFrames) || (maxBytes && bytes + size > maxBytes)) {
          cut = true; pending = null; dropped++; return;
        }
        frames.push(pending); bytes += size; latest = frames.length - 1; pending = null;
      }
      if (latest >= 0) ticks.push(latest);
    },
    async detach() {
      if (!client) return;
      const c = client, h = handler;
      client = null; handler = null;
      if (typeof c.off === "function") c.off("Page.screencastFrame", h);
      await c.send("Page.stopScreencast");
    },
    stored() { return frames.length + (pending === null ? 0 : 1); },
    result(caps) {
      const capFrames = caps && caps.maxFrames, capBytes = caps && caps.maxBytes;
      if (!capFrames && !capBytes) return { frames: frames.slice(), ticks: ticks.slice(), dropped };
      const kept = [], out = [];
      let used = 0, extra = 0, stop = false;
      for (const t of ticks) {
        if (!stop && t === kept.length) {
          const size = frames[t].length;
          if ((capFrames && kept.length + 1 > capFrames) || (capBytes && used + size > capBytes)) stop = true;
          else { kept.push(frames[t]); used += size; }
        }
        if (stop) extra++;
        else out.push(t);
      }
      return { frames: kept, ticks: out, dropped: dropped + extra };
    }
  };
}

function startRecording(vp) {
  if (!capture.video) return null;
  const sampler = ScreencastSampler({ quality: 60, maxWidth: vp.width, maxHeight: vp.height, maxFrames: 300, maxBytes: 25165824 });
  const state = { sampler: sampler, client: null, error: null, timer: null };
  state.timer = setInterval(() => sampler.tick(), 1000 / Math.max(1, capture.fps));
  return state;
}

async function attachCell(state, cellPage) {
  if (!state) return;
  try {
    const client = await cellPage.createCDPSession();
    state.client = client;
    await state.sampler.attach(client);
  } catch (err) {
    state.error = String(err);
  }
}

async function detachCell(state) {
  if (!state || !state.client) return;
  const client = state.client;
  state.client = null;
  try { await state.sampler.detach(); } catch (err) { void err; }
  try { await client.detach(); } catch (err) { void err; }
}

async function finishRecording(state, vp) {
  if (!capture.video) return null;
  if (!state) return { viewport: vp.name, error: "recording was not started" };
  await detachCell(state);
  clearInterval(state.timer);
  state.sampler.tick();
  const sampled = state.sampler.result();
  if (!sampled.frames.length) return { viewport: vp.name, error: state.error || "no screencast frames captured" };
  return { viewport: vp.name, frames: sampled.frames, ticks: sampled.ticks, dropped: sampled.dropped };
}

  const STATE_BUDGET_MS = 40000;
const STATE_RELOAD_MS = 20000;
const STATE_LIMIT_MS = 30000;
const FUNCTION_LIMIT_MS = 115000;
const STATE_RESERVE_MS = 15000;
const CELL_RESERVE_MS = 4000;
const MIN_STEP_MS = 250;
const INNER_MARGIN_MS = 200;

// One absolute deadline per route: the route budget, but never later than
// the browserless function timeout less a reserve for this cell's cleanup
// and for every cell still to run after it.
// `cellCostMs` is what a cell costs without its states (the slowest seen
// so far, or this cell's own time before its states), floored at
// CELL_RESERVE_MS, so slow-loading routes reserve what they really need.
function routeDeadline(scanStarted, cellsLeft, cellCostMs) {
  const reserve = STATE_RESERVE_MS + cellsLeft * Math.max(CELL_RESERVE_MS, cellCostMs);
  return Math.min(Date.now() + STATE_BUDGET_MS, scanStarted + FUNCTION_LIMIT_MS - reserve);
}

// The time an await may take: its own limit, or what is left before the
// deadline if that is less. Nothing left fails the state instead of
// starting a wait that could outlive the route. Too little left to do the
// step is the same failure, not a misleading "took over 1ms".
function capMs(limitMs, deadline, what) {
  const left = deadline - Date.now();
  if (left < MIN_STEP_MS) throw new Error("state budget used up before " + what);
  return Math.min(limitMs, left);
}

// The limit handed to a call that has its own timeout (waitForSelector,
// goto), a little under the outer cap so the call's own timeout error wins
// and only a call that ignores its timeout is reported as hung.
function innerMs(limitMs, deadline) {
  return Math.max(1, Math.min(limitMs, deadline - Date.now()) - INNER_MARGIN_MS);
}

// Runs `start()` only once the cap is known, so a spent budget never
// dispatches work (a click, a read) whose late failure nobody handles.
// A timeout marks the error `hung`: the work behind it may still be running.
function bounded(start, limitMs, deadline, what) {
  const ms = capMs(limitMs, deadline, what);
  let timer;
  const expiry = new Promise((_, reject) => {
    timer = setTimeout(() => { const err = new Error(what + " took over " + ms + "ms"); err.hung = true; reject(err); }, ms);
  });
  return Promise.race([Promise.resolve().then(start), expiry]).finally(() => clearTimeout(timer));
}

// A zero-size box (display none) reads as absent: it has no layout to hold still.
// The page width is read with the rects, so a state with nothing to watch
// still waits for its layout to stop moving before the width is graded.
async function readRects(statePage, selectors) {
  return statePage.evaluate((list) => ({
    pageWidth: document.documentElement.scrollWidth,
    rects: list.map((selector) => {
      const el = document.querySelector(selector);
      if (!el) return null;
      const r = el.getBoundingClientRect();
      if (r.width === 0 && r.height === 0) return null;
      return { x: r.x + window.scrollX, y: r.y + window.scrollY, width: r.width, height: r.height };
    })
  }), selectors);
}

async function readRectsBy(statePage, selectors, deadline) {
  return JSON.stringify(await bounded(() => readRects(statePage, selectors), STATE_LIMIT_MS, deadline, "rect read"));
}

// Fonts ready, two frames painted, then the rects polled until two reads
// in a row agree, so a transition is not sampled mid-flight. At least one
// pair of reads is compared even when the limit is short.
async function settledRects(statePage, selectors, limitMs, deadline) {
  await bounded(() => statePage.evaluate(async () => {
    if (document.fonts && document.fonts.ready) await document.fonts.ready;
    await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
  }), limitMs, deadline, "fonts and paint");
  const until = Math.min(Date.now() + limitMs, deadline);
  let last = await readRectsBy(statePage, selectors, deadline);
  for (;;) {
    await new Promise((done) => setTimeout(done, 50));
    const next = await readRectsBy(statePage, selectors, deadline);
    if (next === last) return JSON.parse(last).rects;
    last = next;
    if (Date.now() >= until) throw new Error("layout did not settle in " + limitMs + "ms");
  }
}

async function runOneState(statePage, st, reload, routeEnd) {
  const result = { name: st.name };
  const deadline = Math.min(routeEnd, Date.now() + STATE_LIMIT_MS);
  const waitFor = (selector, what) => bounded(
    () => statePage.waitForSelector(selector, { visible: true, timeout: innerMs(st.timeoutMs, deadline) }),
    st.timeoutMs, deadline, what);
  try {
    await bounded(() => reload(innerMs(STATE_RELOAD_MS, deadline)), STATE_RELOAD_MS, deadline, "reload");
    if (st.click) {
      await waitFor(st.click, "click target");
      // Click scrolls the target into view; do it first so a fixed or sticky
      // watched element is not measured before the scroll and after it.
      await bounded(() => statePage.evaluate((selector) => {
        const target = document.querySelector(selector);
        if (target) target.scrollIntoView({ block: "center", inline: "center" });
      }, st.click), st.timeoutMs, deadline, "scroll into view");
    }
    const before = await settledRects(statePage, st.watch, st.timeoutMs, deadline);
    if (st.click) await bounded(() => statePage.click(st.click), st.timeoutMs, deadline, "click");
    if (st.ready) await waitFor(st.ready, "ready element");
    result.after = await settledRects(statePage, st.watch, st.timeoutMs, deadline);
    result.before = before;
    result.scrollWidth = await bounded(() => statePage.evaluate(() => document.documentElement.scrollWidth), st.timeoutMs, deadline, "width read");
  } catch (err) {
    result.error = String(err);
    result.hung = err && err.hung === true;
  }
  return result;
}

async function runStates(statePage, states, reload, routeEnd) {
  // A beforeunload prompt is accepted so the next reload can leave the
  // page; every other dialog is dismissed.
  const onDialog = (dialog) => {
    const settle = dialog.type() === "beforeunload" ? dialog.accept() : dialog.dismiss();
    Promise.resolve(settle).catch(() => {});
  };
  statePage.on("dialog", onDialog);
  const results = [];
  let hung = false;
  try {
    for (const st of states) {
      if (Date.now() >= routeEnd) {
        results.push({ name: st.name, error: "state budget was used up" });
        continue;
      }
      // A timed-out step may still be running in the page (a click, a
      // navigation). The next state would reload on top of it, so the
      // rest of the route stops here instead.
      if (hung) {
        results.push({ name: st.name, error: "skipped: an earlier state hung and may still be running" });
        continue;
      }
      const result = await runOneState(statePage, st, reload, routeEnd);
      hung = result.hung === true;
      delete result.hung;
      results.push(result);
    }
  } finally {
    try { statePage.off("dialog", onDialog); } catch (err) { void err; }
  }
  return results;
}


  // A cell's own browser context, or the one shared session when
  // continuity was opted into. Puppeteer renamed this call
  // (createIncognitoBrowserContext -> createBrowserContext); both names
  // are probed so the lane is not pinned to one puppeteer major beyond
  // the browserless image pin itself.
  async function newBrowserContext(browser) {
  if (typeof browser.createBrowserContext === "function") return browser.createBrowserContext();
  if (typeof browser.createIncognitoBrowserContext === "function") return browser.createIncognitoBrowserContext();
  return null;
}

  // Everything that makes a page's rendering reproducible is applied
  // here, once, at the moment the page is created: the pinned locale
  // (both the request header and what the page's own JS reads back) and
  // any basic-auth credentials. A cell never inherits these from a
  // sibling; it is given them.
  async function openSession() {
    const browser = page.browser();
    const context = await newBrowserContext(browser);
    const cellPage = context ? await context.newPage() : await browser.newPage();
    const headers = { "Accept-Language": locale };
    if (basicAuth) {
      await cellPage.authenticate({ username: basicAuth.username, password: basicAuth.password });
      // page.authenticate() only fires on a WWW-Authenticate challenge,
      // which some gates never send (an ALB fixed-response 401 has no
      // mechanism to set arbitrary response headers). Sending the header
      // unconditionally works regardless of whether the target's 401
      // carries a real challenge.
      // btoa, not Buffer: this module runs inside browserless's function
      // sandbox, a browser-like context with no Node globals.
      headers.Authorization = "Basic " + btoa(`${basicAuth.username}:${basicAuth.password}`);
    }
    await cellPage.setExtraHTTPHeaders(headers);
    await cellPage.evaluateOnNewDocument((lang) => {
  Object.defineProperty(navigator, "language", { get: () => lang });
  Object.defineProperty(navigator, "languages", { get: () => [lang] });
}, locale);
    return { context, page: cellPage, authOk: null, authError: null, authDiagnostics: null, lastAuthResponse: null };
  }

  async function closeSession(session) {
    if (!session) return;
    try { await session.page.close(); } catch (err) { void err; }
    try { if (session.context) await session.context.close(); } catch (err) { void err; }
  }

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


  // Captures a real diagnosis of an auth failure - the url actually
  // landed on, the last main-frame response status, the page title,
  // and a body-text snippet - so a reader sees why the login failed
  // instead of a bare Puppeteer timeout message. Every read is
  // wrapped so a diagnostics failure (a closed page, a weird DOM)
  // never masks the real auth error it is describing.
  async function captureAuthDiagnostics(session) {
    const diag = {};
    try { diag.url = session.page.url(); } catch (err) { diag.url = null; }
    try { diag.status = session.lastAuthResponse ? session.lastAuthResponse.status() : null; } catch (err) { diag.status = null; }
    try { diag.title = await session.page.title(); } catch (err) { diag.title = null; }
    try {
      diag.bodyText = await session.page.evaluate(() => (document.body ? document.body.innerText : "").slice(0, 500));
    } catch (err) {
      diag.bodyText = null;
    }
    try { diag.screenshot = await session.page.screenshot({ encoding: "base64" }); } catch (err) { diag.screenshot = null; }
    return diag;
  }

  // Runs every configured step in order, in this session's own page, so
  // a multi-step login (submit an email, then submit a code from a
  // second form) carries its cookies from one step into the next. The
  // result is memoized on the session, so an isolated cell logs in once
  // and a continuity run logs in once for the whole matrix.
  async function ensureAuth(session) {
    if (!auth || session.authOk !== null) return session.authOk;
    try {
      for (const step of auth.steps) await runAuthStep(session, step);
      session.authOk = true;
    } catch (err) {
      session.authOk = false;
      session.authError = String(err);
      session.authDiagnostics = await captureAuthDiagnostics(session);
    }
    return session.authOk;
  }

  async function diffAgainstReference(cellPage, shotBase64, refBase64, threshold, mime) {
  return cellPage.evaluate(async (a, b, cutoff, type) => {
    function loadImage(base64) {
      return new Promise((resolve, reject) => {
        const img = new Image();
        img.onload = () => resolve(img);
        img.onerror = reject;
        img.src = "data:" + (type || "image/png") + ";base64," + base64;
      });
    }
    function toImageData(img) {
      const canvas = document.createElement("canvas");
      canvas.width = img.width;
      canvas.height = img.height;
      const ctx = canvas.getContext("2d", { alpha: false, willReadFrequently: true });
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(img, 0, 0);
      return { imageData: ctx.getImageData(0, 0, canvas.width, canvas.height), width: canvas.width, height: canvas.height };
    }
    const shotImg = await loadImage(a);
    const refImg = await loadImage(b);
    const shot = toImageData(shotImg);
    const ref = toImageData(refImg);
    const width = Math.min(shot.width, ref.width);
    const height = Math.min(shot.height, ref.height);
    let diffCount = 0;
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        const si = (y * shot.width + x) * 4;
        const ri = (y * ref.width + x) * 4;
        const dr = shot.imageData.data[si] - ref.imageData.data[ri];
        const dg = shot.imageData.data[si + 1] - ref.imageData.data[ri + 1];
        const db = shot.imageData.data[si + 2] - ref.imageData.data[ri + 2];
        if (Math.sqrt(dr * dr + dg * dg + db * db) > cutoff) diffCount += 1;
      }
    }
    const totalPixels = width * height;
    return {
      diffPercent: totalPixels ? (diffCount / totalPixels) * 100 : 100,
      comparedWidth: width,
      comparedHeight: height,
      shotWidth: shot.width,
      shotHeight: shot.height,
      refWidth: ref.width,
      refHeight: ref.height,
    };
  }, shotBase64, refBase64, threshold, mime);
}


  const out = [];
  const scanStarted = Date.now();
  const totalCells = viewports.length * routeEntries.length;
  let cellsDone = 0;
  let baseCellMs = 0;
  const videos = [];
  // Non-null only when continuity was opted into: one session carried
  // across the whole matrix, exactly as the lane behaved before cells
  // were isolated.
  let sharedSession = null;
  for (const vp of viewports) {
    const recorder = await startRecording(vp);
    for (const entry of routeEntries) {
      const cell = { viewport: vp.name, width: vp.width, height: vp.height, route: entry.path, routeIndex: routeEntries.indexOf(entry) };
      const waitFor = entry.waitFor;
      let session = null;
      let consoleErrors = 0;
      const onError = (msg) => { if (msg.type() === "error") consoleErrors += 1; };
      // F6 step 1: lightweight Date.now() deltas around this cell's
      // three real costs, purely additive instrumentation so a future
      // decision to raise FUNCTION_TIMEOUT_MS or split the scan per
      // viewport can be made from real numbers instead of a guess.
      const cellStart = Date.now();
      let statesStart = 0;
      let statesMs = 0;
      try {
        if (isolateCells) {
          session = await openSession();
        } else {
          if (!sharedSession) sharedSession = await openSession();
          session = sharedSession;
        }
        await session.page.setViewport({ width: vp.width, height: vp.height, deviceScaleFactor: deviceScaleFactor });
        await attachCell(recorder, session.page);

        if (entry.auth) {
          const ok = await ensureAuth(session);
          if (!ok) {
            // Still navigated below and graded on its real response
            // (F3): an auth-required route no longer collapses into an
            // identical generic finding for every route without ever
            // being visited.
            cell.authBlocked = true;
            cell.authError = session.authError;
            cell.authDiagnostics = session.authDiagnostics;
          }
        }

        // Registered after any login and before this cell's own
        // navigation, so the count covers exactly the route being
        // graded: not the login page's errors, and not a neighbouring
        // cell's. It used to be attached to the shared page around a
        // window that had already navigated, and read before the cell's
        // remaining awaits had run.
        session.page.on("console", onError);
        const navStart = Date.now();
        const resp = await session.page.goto(baseUrl + entry.path, { waitUntil: waitFor.loadState, timeout: waitFor.timeoutMs });
        cell.httpStatus = resp ? resp.status() : null;
        await awaitReadiness(session.page, waitFor);
        cell.navMs = Date.now() - navStart;
        cell.finalUrl = session.page.url();
        const evalStart = Date.now();
        const scrollWidth = await session.page.evaluate(() => document.documentElement.scrollWidth);
        cell.evalMs = Date.now() - evalStart;
        cell.scrollWidth = scrollWidth;
        cell.overflow = scrollWidth > vp.width + 1;

        // Suppressed for an auth-failed cell (F3): the screenshot is
        // of the wrong (unauthenticated) page, so a pixel diff
        // against the gated route's Figma reference would be
        // meaningless noise, not a real design-alignment signal.
        const refBase64 = !cell.authBlocked && entry.figmaViewport === vp.name ? figmaRefs[entry.path] : null;
        if (refBase64) {
          await session.page.addStyleTag({ content: diffStabilityCss });
          const shotBase64 = await session.page.screenshot({ encoding: "base64" });
          cell.figmaDiff = await diffAgainstReference(session.page, shotBase64, refBase64, diffThreshold, "image/png");
        }
        if (capture.screenshots) {
          const shotStart = Date.now();
          cell.shot = await session.page.screenshot({ encoding: "base64", type: "jpeg", quality: 72, fullPage: true });
          cell.shotMs = Date.now() - shotStart;
        }
        // Read last, after every await this cell makes, so the count
        // covers the whole cell rather than whatever had arrived by the
        // time the old code happened to read it.
        cell.consoleErrors = consoleErrors;
        // After every other read, so a state's clicks cannot change what
        // the cell above was graded on. A failure stays inside the state.
        if (entry.states.length && !cell.authBlocked) {
          const reload = async (capMs) => {
            const bounded = Object.assign({}, waitFor, { timeoutMs: Math.min(waitFor.timeoutMs, capMs) });
            // Through about:blank, so a hash-only route is a fresh document load, never a same-document hash change.
            await session.page.goto("about:blank", { timeout: bounded.timeoutMs });
            await session.page.goto(baseUrl + entry.path, { waitUntil: waitFor.loadState, timeout: bounded.timeoutMs });
            await awaitReadiness(session.page, bounded);
          };
          statesStart = Date.now();
          cell.states = await runStates(session.page, entry.states, reload, routeDeadline(scanStarted, totalCells - cellsDone - 1, Math.max(baseCellMs, Date.now() - cellStart)));
          statesMs = Date.now() - statesStart;
        }
      } catch (err) {
        cell.error = String(err);
        cell.consoleErrors = consoleErrors;
      } finally {
        await detachCell(recorder);
        if (session) {
          try { session.page.off("console", onError); } catch (err) { void err; }
          if (isolateCells) await closeSession(session);
        }
      }
      cell.totalMs = Date.now() - cellStart;
      if (!cell.error) baseCellMs = Math.max(baseCellMs, cell.totalMs - statesMs);
      cellsDone += 1;
      out.push(cell);
    }
    const video = await finishRecording(recorder, vp);
    if (video) videos.push(video);
  }
  await closeSession(sharedSession);
  return { data: { cells: out, videos: videos }, type: "application/json" };
}
