#!/usr/bin/env node
/**
 * Proves the spec release actually renders: the current version as current with
 * its release notes, and every archived version frozen at its own text.
 *
 * Entirely local. It serves the already-built dist/ from this process and
 * drives the digest-pinned browserless Chromium container over CDP, the same
 * browser every other lane and verification in this repo uses. Nothing here
 * touches AWS, the changefabric.org bucket, the CloudFront distribution, or
 * DNS; infra/deploy.sh is not invoked and is not reachable from here.
 *
 * The static server mirrors CloudFront's own 404 fallback (unknown path serves
 * index.html), because /spec/<version> is a client route and not a file.
 *
 *   cd site && npm run build && node verify/spec-release.mjs
 *
 * Screenshots land in site/.verification/ (gitignored). They are evidence for
 * the run's own report, not an artifact of the build.
 */
import { execFile, spawn } from "node:child_process";
import { createReadStream } from "node:fs";
import { mkdir, rm, stat } from "node:fs/promises";
import { createServer as createHttpServer } from "node:http";
import { createServer as createTcpServer } from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { chromium } from "playwright-core";

const run = promisify(execFile);

// Pinned to the same digest as scripts/change_docker.rb, so the browser this
// verification sees is the browser every other lane in the repo sees.
const BROWSERLESS_IMAGE =
  "ghcr.io/browserless/chromium:v2.38.1@sha256:78afaada9f7b049783bfed624e6b5e9a2d3438fc04bb46801ed777e82ae1501f";

// The container reaches this process's server through Docker Desktop's host
// alias. Overridable for a runtime that names the host differently.
const HOST_ALIAS = process.env.CF_HOST_ALIAS ?? "host.docker.internal";

const here = path.dirname(fileURLToPath(import.meta.url));
const dist = path.join(here, "..", "dist");
const shots = path.join(here, "..", ".verification");
const stamp = Date.now();

const CURRENT = process.env.CF_CURRENT_VERSION ?? "0.9.0";
const ARCHIVED = ["0.8.0", "0.6.0", "0.5.0", "0.4.0", "0.3.1", "0.3.0", "0.2.0", "0.1.0"];

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".md": "text/markdown; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".json": "application/json; charset=utf-8",
  ".webmanifest": "application/manifest+json",
};

function record(step, detail) {
  console.log(`[ok] ${step}: ${detail}`);
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

async function serveDist() {
  const port = await freePort();
  const server = createHttpServer(async (request, response) => {
    const requested = decodeURIComponent(new URL(request.url, "http://x").pathname);
    const candidate = path.join(dist, path.normalize(requested).replace(/^(\.\.[/\\])+/, ""));
    let file = candidate;
    // Anything that is not a real file is a client route, exactly as the
    // CloudFront 404 fallback treats it.
    const found = await stat(candidate).catch(() => null);
    if (found === null || found.isDirectory()) {
      file = path.join(dist, "index.html");
    }
    response.writeHead(200, {
      "content-type": MIME[path.extname(file)] ?? "application/octet-stream",
      "cache-control": "no-store",
    });
    createReadStream(file).pipe(response);
  });
  await new Promise((resolve) => server.listen(port, "0.0.0.0", resolve));
  return { server, port };
}

async function startBrowserless() {
  const port = await freePort();
  const token = `specrelease-${stamp}`;
  const name = `cf-site-specrelease-${stamp}`;

  // --rm, an ephemeral name, and a published loopback port only: the container
  // exists for this run and nothing else can reach it.
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
      if (response.ok) {
        return { port, token, name };
      }
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

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

async function main() {
  const built = await stat(path.join(dist, "index.html")).catch(() => null);
  assert(built !== null, "dist/index.html is missing: run `npm run build` first");

  await rm(shots, { recursive: true, force: true });
  await mkdir(shots, { recursive: true });

  const site = await serveDist();
  const base = `http://${HOST_ALIAS}:${site.port}`;
  record("static server", `serving dist/ on port ${site.port} as ${base}`);

  const container = await startBrowserless();
  record("browserless", `ready on 127.0.0.1:${container.port}`);

  const browser = await chromium.connectOverCDP(
    `ws://127.0.0.1:${container.port}?token=${container.token}`,
  );

  try {
    const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    const page = await context.newPage();
    page.on("pageerror", (error) => console.log(`[pageerror] ${error.message}`));

    // --- 1. The version index lists the current version as current ---------
    const indexResponse = await page.goto(`${base}/spec`, { waitUntil: "networkidle" });
    assert(indexResponse?.status() === 200, `/spec answered ${indexResponse?.status()}`);
    await page.waitForSelector(".versions-table");
    const rows = await page.$$eval(".versions-table tbody tr", (trs) =>
      trs.map((tr) => Array.from(tr.querySelectorAll("td")).map((td) => td.textContent.trim())),
    );
    await page.screenshot({ path: path.join(shots, "01-spec-index.png"), fullPage: true });

    const currentRows = rows.filter((row) => row[1] === "current");
    assert(currentRows.length === 1, `expected exactly one current row, got ${currentRows.length}`);
    assert(
      currentRows[0][0] === CURRENT,
      `index marks ${currentRows[0][0]} as current, expected ${CURRENT}`,
    );
    for (const version of ARCHIVED) {
      const row = rows.find((entry) => entry[0] === version);
      assert(row !== undefined, `/spec does not list ${version}`);
      assert(row[1] === "superseded", `${version} is listed as ${row[1]}, expected superseded`);
    }
    record("/spec index", `${rows.length} rows, current is ${currentRows[0][0]}`);

    // --- 2. The current version, with its release notes -------------------
    const currentResponse = await page.goto(`${base}/spec/${CURRENT}`, {
      waitUntil: "networkidle",
    });
    assert(currentResponse?.status() === 200, `/spec/${CURRENT} answered ${currentResponse?.status()}`);
    await page.waitForSelector(".spec-body");
    const notes = page.locator(`[data-testid="release-notes-${CURRENT}"]`);
    assert(await notes.count() === 1, `/spec/${CURRENT} rendered no release notes panel`);
    const notesHeading = (await notes.locator("h2").textContent()).trim();
    const notesTitles = await notes.locator(".release-note dt").allTextContents();
    const specVersionLine = await page.locator(".spec-body").innerText();
    await page.screenshot({ path: path.join(shots, `02-spec-${CURRENT}.png`), fullPage: true });
    // A second, viewport-only shot: the full-page one is tall enough that the
    // release notes are a sliver of it, and what matters is that they land
    // above the spec text rather than somewhere down the page.
    await page.screenshot({ path: path.join(shots, `02b-spec-${CURRENT}-notes.png`) });

    assert(
      notesHeading.includes(CURRENT),
      `release-notes heading read "${notesHeading}", expected it to name ${CURRENT}`,
    );
    assert(notesTitles.length > 0, "release-notes panel rendered no highlights");
    assert(
      specVersionLine.includes(`Schema version: ${CURRENT}`),
      `/spec/${CURRENT} body does not carry "Schema version: ${CURRENT}"`,
    );
    assert(
      specVersionLine.includes("contributors_team fields (0.6.0)"),
      "current spec body is missing the 0.6.0 contributors_team section",
    );
    const tag = (await page.locator(".spec-page-head .status-tag").textContent()).trim();
    assert(tag === "current", `/spec/${CURRENT} status tag read "${tag}"`);
    record(
      `/spec/${CURRENT}`,
      `status "${tag}", notes heading "${notesHeading}", ${notesTitles.length} highlights`,
    );

    // --- 3. Every archived version, frozen at its own text ----------------
    let shot = 3;
    for (const version of ARCHIVED) {
      const response = await page.goto(`${base}/spec/${version}`, { waitUntil: "networkidle" });
      assert(response?.status() === 200, `/spec/${version} answered ${response?.status()}`);
      await page.waitForSelector(".spec-body");
      const body = await page.locator(".spec-body").innerText();
      const status = (await page.locator(".spec-page-head .status-tag").textContent()).trim();
      const shownVersion = (await page.locator(".spec-page-head h1").innerText()).trim();
      await page.screenshot({
        path: path.join(shots, `${String(shot).padStart(2, "0")}-spec-${version}.png`),
        fullPage: true,
      });
      shot += 1;

      assert(status === "superseded", `/spec/${version} status tag read "${status}"`);
      assert(
        shownVersion.startsWith(`Version ${version}`),
        `/spec/${version} heading read "${shownVersion}"`,
      );
      assert(
        body.includes(`Schema version: ${version}`),
        `/spec/${version} body does not carry "Schema version: ${version}"`,
      );
      assert(
        !body.includes(`Schema version: ${CURRENT}`),
        `/spec/${version} is serving the CURRENT text, not its own frozen text`,
      );
      // The one section whose heading is version-stamped, so a page serving the
      // wrong archive entry is caught rather than only a page serving current.
      assert(
        !body.includes("contributors_team fields (0.6.0)"),
        `/spec/${version} contains the 0.6.0 contributors_team section`,
      );
      record(`/spec/${version}`, `"${shownVersion.replace(/\s+/g, " ")}", frozen at its own text`);
    }

    // --- 4. An unknown version is an honest 404 page, not the current spec -
    await page.goto(`${base}/spec/9.9.9`, { waitUntil: "networkidle" });
    const unknown = await page.locator("h1").textContent();
    await page.screenshot({ path: path.join(shots, "09-spec-unknown.png") });
    assert(
      unknown.trim() === "Unknown spec version",
      `/spec/9.9.9 rendered "${unknown}" rather than the unknown-version page`,
    );
    record("/spec/9.9.9", "renders the unknown-version page");
  } finally {
    await browser.close().catch(() => {});
    await stopBrowserless(container);
    site.server.close();
  }

  console.log("\nall verification steps passed");
  console.log(`screenshots: ${shots}`);
}

main().catch((error) => {
  console.error(`\nverification FAILED: ${error.message}`);
  process.exitCode = 1;
});
