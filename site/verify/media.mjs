#!/usr/bin/env node
/**
 * Proves the click-to-load media slot keeps its promises: no media bytes
 * before a click, nothing playing on its own, captions on by default, a
 * keyboard path through it, and a follow-along transcript that runs only
 * while playing and never under reduced motion.
 *
 * Entirely local, on the conventions of verify/spec-release.mjs: it serves a
 * build from this process (mirroring CloudFront's 404 fallback) and drives the
 * digest-pinned browserless Chromium container over CDP. Nothing here touches
 * AWS or deploys anything.
 *
 * Unless --dist is given it makes its own fixture build first
 * (VITE_MEDIA_FIXTURE=1, into dist-verify/), which adds the /verify/media
 * route and the fixture slots; /media/* is answered from the committed
 * synthetic bytes in verify/fixtures/media/. It also checks that the plain
 * production build in dist/ carries none of that.
 *
 *   cd site && npm run build && npm run verify:media [-- --route / --route /x]
 *   node verify/media.mjs --record-baseline --dist <pre-PR dist> --route /
 *
 * Screenshots land in site/.verification/media/ (gitignored).
 */
import { execFile, spawn } from "node:child_process";
import { createReadStream } from "node:fs";
import { mkdir, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { createServer as createHttpServer } from "node:http";
import { createServer as createTcpServer } from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { chromium } from "playwright-core";

const run = promisify(execFile);

// Pinned to the same digest as scripts/change_docker.rb.
const BROWSERLESS_IMAGE =
  "ghcr.io/browserless/chromium:v2.38.1@sha256:78afaada9f7b049783bfed624e6b5e9a2d3438fc04bb46801ed777e82ae1501f";
const HOST_ALIAS = process.env.CF_HOST_ALIAS ?? "host.docker.internal";

const here = path.dirname(fileURLToPath(import.meta.url));
const site = path.join(here, "..");
const fixtures = path.join(here, "fixtures", "media");
const baselineFile = path.join(here, "media-baseline.json");
const shots = path.join(site, ".verification", "media");
const stamp = Date.now();

const FIXTURE_ROUTE = "/verify/media";
const BUDGET_BYTES = 120 * 1024;
const MEDIA_BYTES = /\/media\/.*\.(mp4|mp3)(\?|$)/;

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".md": "text/markdown; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".webp": "image/webp",
  ".mp4": "video/mp4",
  ".mp3": "audio/mpeg",
  ".vtt": "text/vtt; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".webmanifest": "application/manifest+json",
};

function parseArgs(argv) {
  const args = { routes: [], dist: null, recordBaseline: false };
  const value = (i) => {
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) throw new Error(`${argv[i]} needs a value`);
    return next;
  };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--route") args.routes.push(value(i++));
    else if (argv[i] === "--dist") args.dist = path.resolve(value(i++));
    else if (argv[i] === "--record-baseline") args.recordBaseline = true;
    else throw new Error(`unknown argument ${argv[i]}`);
  }
  if (args.routes.length === 0) args.routes.push(args.recordBaseline ? "/" : FIXTURE_ROUTE);
  return args;
}

function record(step, detail) {
  console.log(`[ok] ${step}: ${detail}`);
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function freePort() {
  return new Promise((resolve, reject) => {
    const server = createTcpServer();
    server.on("error", reject);
    server.listen(0, "0.0.0.0", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

// Media elements fetch with Range requests, so /media/* answers them the way
// S3 behind CloudFront does.
function sendFile(request, response, file, size) {
  const type = MIME[path.extname(file)] ?? "application/octet-stream";
  const range = /^bytes=(\d*)-(\d*)$/.exec(request.headers.range ?? "");
  if (range) {
    const start = range[1] === "" ? Math.max(0, size - Number(range[2])) : Number(range[1]);
    const end = range[1] !== "" && range[2] !== "" ? Math.min(Number(range[2]), size - 1) : size - 1;
    response.writeHead(206, {
      "content-type": type,
      "content-range": `bytes ${start}-${end}/${size}`,
      "content-length": end - start + 1,
      "accept-ranges": "bytes",
      "cache-control": "no-store",
    });
    createReadStream(file, { start, end }).pipe(response);
    return;
  }
  response.writeHead(200, {
    "content-type": type,
    "content-length": size,
    "accept-ranges": "bytes",
    "cache-control": "no-store",
  });
  createReadStream(file).pipe(response);
}

async function serve(dist) {
  const port = await freePort();
  const server = createHttpServer(async (request, response) => {
    const requested = decodeURIComponent(new URL(request.url, "http://x").pathname);
    const safe = path.normalize(requested).replace(/^(\.\.[/\\])+/, "");
    if (requested.startsWith("/media/")) {
      const file = path.join(fixtures, path.basename(safe));
      const found = await stat(file).catch(() => null);
      if (found === null || !found.isFile()) {
        response.writeHead(404).end();
        return;
      }
      sendFile(request, response, file, found.size);
      return;
    }
    let file = path.join(dist, safe);
    const found = await stat(file).catch(() => null);
    if (found === null || found.isDirectory()) file = path.join(dist, "index.html");
    sendFile(request, response, file, (await stat(file)).size);
  });
  await new Promise((resolve) => server.listen(port, "0.0.0.0", resolve));
  return { server, port };
}

async function startBrowserless() {
  const port = await freePort();
  const token = `media-${stamp}`;
  const name = `cf-site-media-${stamp}`;
  const child = spawn(
    "docker",
    [
      "run", "--rm", "--name", name,
      "-p", `127.0.0.1:${port}:3000`,
      "-e", `TOKEN=${token}`,
      "-e", "TIMEOUT=300000",
      "-e", "CONCURRENT=5",
      "--add-host", `${HOST_ALIAS}:host-gateway`,
      BROWSERLESS_IMAGE,
    ],
    { stdio: "ignore" },
  );
  child.unref();
  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/version?token=${token}`);
      if (response.ok) return { port, token, name };
    } catch {
      // Not up yet. A readiness probe, never a fixed sleep.
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error("browserless did not become ready within 120s");
}

async function stopBrowserless(container) {
  await run("docker", ["rm", "-f", container.name]).catch(() => {});
}

async function fixtureBuild() {
  const env = { ...process.env, VITE_MEDIA_FIXTURE: "1" };
  await run("npm", ["run", "build", "--", "--outDir", "dist-verify"], { cwd: site, env, maxBuffer: 1 << 26 });
  // Put src/generated/media.json back to the production slots.
  const clean = { ...process.env };
  delete clean.VITE_MEDIA_FIXTURE;
  await run("node", ["scripts/embed-media.mjs"], { cwd: site, env: clean });
  return path.join(site, "dist-verify");
}

// The production build must carry no trace of the fixture route or slots.
async function checkProductionClean() {
  const dist = path.join(site, "dist");
  const assets = await readdir(path.join(dist, "assets")).catch(() => null);
  assert(assets !== null, "dist/ is missing: run `npm run build` first");
  for (const name of assets.filter((file) => file.endsWith(".js"))) {
    const body = await readFile(path.join(dist, "assets", name), "utf8");
    assert(!body.includes("fixture-video"), `dist/assets/${name} carries the media fixture slots`);
    assert(!body.includes("Media slot fixture"), `dist/assets/${name} carries the media fixture page`);
  }
  const media = await stat(path.join(dist, "media")).catch(() => null);
  assert(media === null, "dist/media exists; media bytes never ship in the build");
  record("production build", `${assets.length} assets, no fixture route, slots, or media/`);
}

// Loads a route with a fresh context and sums transferred bytes before any
// interaction, noting any media byte request.
async function load(browser, base, route, options = {}) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, ...options });
  const page = await context.newPage();
  page.on("pageerror", (error) => console.log(`[pageerror] ${error.message}`));
  const state = { bytes: 0, media: [], pending: [] };
  page.on("request", (request) => {
    if (MEDIA_BYTES.test(request.url())) state.media.push(request.url());
  });
  page.on("requestfinished", (request) => {
    state.pending.push(
      request.sizes().then((sizes) => {
        state.bytes += sizes.responseBodySize + sizes.responseHeadersSize;
      }).catch(() => {}),
    );
  });
  const response = await page.goto(`${base}${route}`, { waitUntil: "networkidle" });
  assert(response?.status() === 200, `${route} answered ${response?.status()}`);
  await Promise.all(state.pending);
  return { context, page, state, preBytes: state.bytes, preMedia: [...state.media] };
}

async function assertAllPaused(page, when) {
  const playing = await page.$$eval("video, audio", (els) => els.filter((el) => !el.paused).length);
  assert(playing === 0, `${playing} media element(s) playing ${when}`);
}

async function checkRoute(browser, base, route, baseline) {
  const slug = route.replace(/[^a-z0-9]+/gi, "-").replace(/^-|-$/g, "") || "home";
  const { context, page, state, preBytes, preMedia } = await load(browser, base, route);
  try {
    const h1 = await page.locator("h1").first().boundingBox();
    assert(h1 !== null && h1.y >= 0 && h1.y + h1.height <= 844, `${route}: h1 is not within the 390x844 viewport`);
    for (const box of await Promise.all((await page.locator(".hero-actions a").all()).map((l) => l.boundingBox()))) {
      assert(box !== null && box.y + box.height <= 844, `${route}: a hero button is below the 390x844 fold`);
    }
    record(route, "h1 and hero buttons within 390x844");

    assert(preMedia.length === 0, `${route}: media bytes requested before any click: ${preMedia.join(", ")}`);
    record(route, `zero mp4/mp3 requests before click, ${preBytes} bytes transferred`);

    if (route === "/") {
      if (baseline === null) {
        console.log("[skip] / byte budget: no verify/media-baseline.json recorded yet");
      } else {
        const delta = preBytes - baseline.bytes;
        assert(delta <= BUDGET_BYTES, `/ grew ${delta} bytes before interaction, over the ${BUDGET_BYTES} budget`);
        record(route, `pre-interaction delta ${delta} bytes (budget ${BUDGET_BYTES})`);
      }
    }

    await assertAllPaused(page, "after load");
    await page.waitForTimeout(5000);
    await assertAllPaused(page, "after 5 s idle");
    await page.screenshot({ path: path.join(shots, `${slug}-before.png`), fullPage: true });
    record(route, "no media element playing after load or after 5 s idle");

    const buttons = page.locator(".media-slot-play");
    const count = await buttons.count();
    for (let index = 0; index < count; index += 1) {
      await checkSlotKeyboard(page, route, index);
    }
    if (count > 0) await page.screenshot({ path: path.join(shots, `${slug}-after.png`), fullPage: true });
    record(route, `${count} slot(s) checked`);
    assert(state.media.length >= Math.min(count, 1), `${route}: playing fetched no media bytes`);
  } finally {
    await context.close();
  }
}

// Tab reaches the play button; Enter swaps in the player with captions on
// and focus on it; further Tabs reach the Transcript summary.
async function checkSlotKeyboard(page, route, index) {
  const label = await page.locator(".media-slot-play").first().textContent();
  await page.evaluate(() => {
    document.activeElement?.blur();
    window.getSelection()?.removeAllRanges();
  });
  let reached = false;
  for (let tab = 0; tab < 60 && !reached; tab += 1) {
    await page.keyboard.press("Tab");
    reached = await page.evaluate(
      (text) => document.activeElement?.classList.contains("media-slot-play") && document.activeElement.textContent === text,
      label,
    );
  }
  assert(reached, `${route}: Tab never reached "${label}"`);
  await page.keyboard.press("Enter");
  const figure = page.locator("figure.media-slot").nth(index);
  await figure.locator("video, audio").waitFor();
  assert(await figure.locator("track[kind=captions][default]").count() === 1, `${route}: no default captions track`);
  const focusedMedia = await page.evaluate(() => ["VIDEO", "AUDIO"].includes(document.activeElement?.tagName ?? ""));
  assert(focusedMedia, `${route}: focus did not move to the player after "${label}"`);
  let summary = false;
  for (let tab = 0; tab < 20 && !summary; tab += 1) {
    await page.keyboard.press("Tab");
    summary = await figure.evaluate((el) => el.querySelector("summary") === document.activeElement);
  }
  assert(summary, `${route}: Tab from the player never reached its Transcript summary`);
  await figure.evaluate((el) => el.querySelector("video, audio")?.pause());
  // The browserless image is open-source Chromium, which has no H.264/AAC
  // decoder, so the fixture mp4 cannot play there. The slot must then fall
  // back to its note rather than fail silently; that path is what runs here.
  if (await figure.locator("video").count()) {
    await page.waitForTimeout(500);
    const note = await figure.locator(".media-slot-note").count();
    const played = await figure.evaluate((el) => (el.querySelector("video")?.currentTime ?? 0) > 0);
    assert(note === 1 || played, `${route}: video neither played nor showed its unavailable note`);
    console.log(`[note] ${route}: video ${played ? "played" : "showed \"Video unavailable in this build\" (no H.264 in this Chromium)"}`);
  }
  record(route, `"${label}": Tab, Enter, focus on player, captions default, Tab to Transcript`);
}

// Plays the fixture audio and watches the transcript for aria-current.
async function highlightSeen(browser, base, reducedMotion) {
  const { context, page } = await load(browser, base, FIXTURE_ROUTE, { reducedMotion });
  try {
    const figure = page.locator("figure.media-slot-audio");
    await figure.locator("summary").click();
    await figure.locator(".media-slot-play").click();
    await figure.locator("audio").waitFor();
    let seen = false;
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline && !seen) {
      seen = (await figure.locator("[aria-current]").count()) > 0;
      if (!seen) await page.waitForTimeout(50);
    }
    const playing = await figure.evaluate((el) => {
      const audio = el.querySelector("audio");
      return audio !== null && audio.currentTime > 0;
    });
    assert(playing, "the fixture audio never started playing after its click");
    return seen;
  } finally {
    await context.close();
  }
}

async function readBaseline() {
  const raw = await readFile(baselineFile, "utf8").catch(() => null);
  return raw === null ? null : JSON.parse(raw);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  await rm(shots, { recursive: true, force: true });
  await mkdir(shots, { recursive: true });

  if (!args.recordBaseline && args.dist === null) await checkProductionClean();
  const dist = args.dist ?? (await fixtureBuild());
  if (args.dist === null) record("fixture build", "VITE_MEDIA_FIXTURE=1 -> dist-verify/");

  const app = await serve(dist);
  const base = `http://${HOST_ALIAS}:${app.port}`;
  record("static server", `serving ${path.relative(site, dist) || dist} on port ${app.port}`);
  const container = await startBrowserless();
  record("browserless", `ready on 127.0.0.1:${container.port}`);
  const browser = await chromium.connectOverCDP(`ws://127.0.0.1:${container.port}?token=${container.token}`);

  try {
    if (args.recordBaseline) {
      const { context, preBytes } = await load(browser, base, "/");
      await context.close();
      await writeFile(baselineFile, `${JSON.stringify({ route: "/", bytes: preBytes }, null, 2)}\n`);
      record("baseline", `/ transferred ${preBytes} bytes before interaction -> ${path.relative(site, baselineFile)}`);
      return;
    }

    const baseline = await readBaseline();
    for (const route of args.routes) await checkRoute(browser, base, route, baseline);

    if (args.dist === null) {
      assert(!(await highlightSeen(browser, base, "reduce")), "a word got aria-current under reduced motion");
      record("reduced motion", "no word highlighted during playback");
      assert(await highlightSeen(browser, base, "no-preference"), "no word got aria-current during playback");
      record("follow-along", "a word span got aria-current during playback");
    }
  } finally {
    await browser.close().catch(() => {});
    await stopBrowserless(container);
    app.server.close();
  }

  console.log("\nall media verification steps passed");
  console.log(`screenshots: ${shots}`);
}

main().catch((error) => {
  console.error(`\nverification FAILED: ${error.message}`);
  process.exitCode = 1;
});
