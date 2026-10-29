export default async function ({ page }) {
  const baseUrl = "https://app.example.org";
  const routeEntries = [{"path":"/","auth":false,"figmaViewport":null,"waitFor":{"loadState":"domcontentloaded","selector":"body","urlContains":null,"urlMatches":null,"timeoutMs":30000}},{"path":"/about","auth":false,"figmaViewport":null,"waitFor":{"loadState":"domcontentloaded","selector":"body","urlContains":null,"urlMatches":null,"timeoutMs":30000}}];
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

  async function startRecording(vp) {
  if (!capture.video) return null;
  try {
    const recorderPage = await page.browser().newPage();
    await recorderPage.setViewport({ width: vp.width, height: vp.height });
    await recorderPage.setContent("<!doctype html><html><head><meta charset=\"utf-8\"><style>html,body{margin:0;background:#000}</style></head>\n<body><canvas id=\"cf-canvas\"></canvas><script>\n  let ctx = null, recorder = null, chunks = [], queue = Promise.resolve();\n  window.__cfStart = function (width, height, fps) {\n    const canvas = document.getElementById(\"cf-canvas\");\n    canvas.width = width;\n    canvas.height = height;\n    ctx = canvas.getContext(\"2d\");\n    ctx.fillStyle = \"#000\";\n    ctx.fillRect(0, 0, width, height);\n    const stream = canvas.captureStream(fps);\n    const preferred = \"video/webm;codecs=vp9\";\n    const mimeType = window.MediaRecorder && MediaRecorder.isTypeSupported(preferred) ? preferred : \"video/webm\";\n    recorder = new MediaRecorder(stream, { mimeType: mimeType });\n    chunks = [];\n    recorder.ondataavailable = function (event) { if (event.data && event.data.size) chunks.push(event.data); };\n    recorder.start(1000);\n    return true;\n  };\n  window.__cfPush = function (base64) {\n    queue = queue.then(function () {\n      return new Promise(function (resolve) {\n        const image = new Image();\n        image.onload = function () {\n          const canvas = ctx.canvas;\n          const scale = Math.min(canvas.width / image.width, canvas.height / image.height);\n          const width = image.width * scale;\n          const height = image.height * scale;\n          ctx.fillStyle = \"#000\";\n          ctx.fillRect(0, 0, canvas.width, canvas.height);\n          ctx.drawImage(image, (canvas.width - width) / 2, 0, width, height);\n          resolve();\n        };\n        image.onerror = function () { resolve(); };\n        image.src = \"data:image/jpeg;base64,\" + base64;\n      });\n    });\n    return queue;\n  };\n  window.__cfStop = function () {\n    if (!recorder) return Promise.resolve(null);\n    return queue.then(function () {\n      return new Promise(function (resolve) {\n        recorder.onstop = function () {\n          const blob = new Blob(chunks, { type: recorder.mimeType });\n          const reader = new FileReader();\n          reader.onloadend = function () { resolve(String(reader.result).split(\",\")[1] || null); };\n          reader.onerror = function () { resolve(null); };\n          reader.readAsDataURL(blob);\n        };\n        recorder.stop();\n      });\n    });\n  };\n</script></body></html>\n");
    await recorderPage.evaluate((w, h, fps) => window.__cfStart(w, h, fps), vp.width, vp.height, capture.fps);
    return { page: recorderPage, client: null, stopped: false, error: null };
  } catch (err) {
    return { page: null, client: null, stopped: true, error: String(err) };
  }
}

async function attachCell(state, cellPage, vp) {
  if (!state || !state.page || state.stopped) return;
  try {
    const client = await cellPage.createCDPSession();
    state.client = client;
    client.on("Page.screencastFrame", async (frame) => {
      if (state.stopped || !state.page) return;
      try {
        await state.page.evaluate((data) => window.__cfPush(data), frame.data);
      } catch (err) {
        state.error = String(err);
      }
      try {
        await client.send("Page.screencastFrameAck", { sessionId: frame.sessionId });
      } catch (err) {
        state.error = String(err);
      }
    });
    await client.send("Page.startScreencast", {
      format: "jpeg",
      quality: 60,
      maxWidth: vp.width,
      maxHeight: vp.height,
      everyNthFrame: 1,
    });
  } catch (err) {
    state.error = String(err);
  }
}

async function detachCell(state) {
  if (!state || !state.client) return;
  const client = state.client;
  state.client = null;
  try { await client.send("Page.stopScreencast"); } catch (err) { void err; }
  try { await client.detach(); } catch (err) { void err; }
}

async function stopRecording(state, vp) {
  if (!capture.video) return null;
  if (!state) return { viewport: vp.name, error: "recording was not started" };
  await detachCell(state);
  state.stopped = true;
  try {
    if (!state.page) return { viewport: vp.name, error: state.error || "no recorder page" };
    const webm = await state.page.evaluate(() => window.__cfStop());
    await state.page.close();
    if (!webm) return { viewport: vp.name, error: state.error || "recorder produced no data" };
    return { viewport: vp.name, webm: webm };
  } catch (err) {
    try { if (state.page) await state.page.close(); } catch (closeErr) { void closeErr; }
    return { viewport: vp.name, error: String(err) };
  }
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
  const videos = [];
  // Non-null only when continuity was opted into: one session carried
  // across the whole matrix, exactly as the lane behaved before cells
  // were isolated.
  let sharedSession = null;
  for (const vp of viewports) {
    const recorder = await startRecording(vp);
    for (const entry of routeEntries) {
      const cell = { viewport: vp.name, width: vp.width, height: vp.height, route: entry.path };
      const waitFor = entry.waitFor;
      let session = null;
      let consoleErrors = 0;
      const onError = (msg) => { if (msg.type() === "error") consoleErrors += 1; };
      // F6 step 1: lightweight Date.now() deltas around this cell's
      // three real costs, purely additive instrumentation so a future
      // decision to raise FUNCTION_TIMEOUT_MS or split the scan per
      // viewport can be made from real numbers instead of a guess.
      const cellStart = Date.now();
      try {
        if (isolateCells) {
          session = await openSession();
        } else {
          if (!sharedSession) sharedSession = await openSession();
          session = sharedSession;
        }
        await session.page.setViewport({ width: vp.width, height: vp.height, deviceScaleFactor: deviceScaleFactor });
        await attachCell(recorder, session.page, vp);

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
      out.push(cell);
    }
    const video = await stopRecording(recorder, vp);
    if (video) videos.push(video);
  }
  await closeSession(sharedSession);
  return { data: { cells: out, videos: videos }, type: "application/json" };
}
