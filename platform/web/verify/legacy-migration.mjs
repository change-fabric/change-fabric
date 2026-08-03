#!/usr/bin/env node
/**
 * Phase 7 evidence: the artifact a migrated team published, as a person
 * actually sees it in the deployed staging web app.
 *
 * Deliberately NOT part of `verify/run.mjs`. That script signs up a throwaway
 * address at the SES simulator every run, which is the right thing for proving
 * the sign-up and onboarding flow and the wrong thing here: this has to sign in
 * as the REAL maintainer of the REAL migrated team, because the whole point is
 * that `change-fabric/core` carries `changefabric-core`'s history and lists the
 * run that was published to it.
 *
 * Same browser as everything else in this repo: the digest-pinned browserless
 * Chromium container, over CDP. No host browser, no second automation library.
 *
 *   CF_PLATFORM_PASSWORD=... AWS_PROFILE=personal node verify/legacy-migration.mjs
 *
 * Screenshots land in platform/web/.verification/ (gitignored). They are
 * evidence for the run's own report, not an artifact of the build.
 */
import { execFile, spawn } from "node:child_process";
import { mkdir } from "node:fs/promises";
import { createServer } from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { chromium } from "playwright-core";

const run = promisify(execFile);

const BROWSERLESS_IMAGE =
  "ghcr.io/browserless/chromium:v2.38.1@sha256:78afaada9f7b049783bfed624e6b5e9a2d3438fc04bb46801ed777e82ae1501f";

const APP_URL = process.env.APP_URL ?? "https://app.staging.changefabric.org";
const REGION = "us-east-1";
const CREDENTIAL_PARAMETER = "/cf-platform/staging/basic-auth-credential";

const EMAIL = process.env.CF_PLATFORM_EMAIL ?? "patrick@pstaylor.net";
const PASSWORD = process.env.CF_PLATFORM_PASSWORD ?? "";
const TEAM_SLUG = process.env.CF_TEAM_SLUG ?? "core";

const here = path.dirname(fileURLToPath(import.meta.url));
const shots = path.join(here, "..", ".verification");
const stamp = Date.now();

function record(step, detail) {
  console.log(`[ok] ${step}: ${detail}`);
}

async function freePort() {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

async function readCredential() {
  const { stdout } = await run("aws", [
    "ssm", "get-parameter",
    "--region", REGION,
    "--name", CREDENTIAL_PARAMETER,
    "--with-decryption",
    "--query", "Parameter.Value",
    "--output", "text",
  ]);
  return stdout.trim();
}

async function startBrowserless() {
  const port = await freePort();
  const token = `phase7-${stamp}`;
  const name = `cf-web-phase7-${stamp}`;

  const child = spawn(
    "docker",
    [
      "run", "--rm", "--name", name,
      "-p", `127.0.0.1:${port}:3000`,
      "-e", `TOKEN=${token}`,
      "-e", "TIMEOUT=300000",
      "-e", "CONCURRENT=5",
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

async function main() {
  if (PASSWORD === "") {
    throw new Error("set CF_PLATFORM_PASSWORD to the maintainer's platform password");
  }
  await mkdir(shots, { recursive: true });

  const credential = await readCredential();
  const [username, password] = credential.split(/:(.*)/s);
  const container = await startBrowserless();
  record("browserless", `ready on 127.0.0.1:${container.port}`);

  const browser = await chromium.connectOverCDP(
    `ws://127.0.0.1:${container.port}?token=${container.token}`,
  );

  try {
    // The staging-wide Basic Auth fence sits in front of the app itself, so the
    // context carries it for every request the page makes.
    const context = await browser.newContext({
      httpCredentials: { username, password },
      viewport: { width: 1440, height: 900 },
      ignoreHTTPSErrors: false,
    });
    const page = await context.newPage();

    page.on("console", (message) => {
      if (message.type() === "error") {
        console.log(`[console] ${message.text()}`);
      }
    });
    page.on("requestfailed", (request) => {
      console.log(`[netfail] ${request.method()} ${request.url()} ${request.failure()?.errorText}`);
    });
    page.on("response", (response) => {
      if (response.url().includes("/api/auth/") || response.status() >= 400) {
        console.log(`[net] ${response.status()} ${response.request().method()} ${response.url()}`);
      }
    });

    await page.goto(`${APP_URL}/login`, { waitUntil: "networkidle" });
    await page.fill('input[type="email"]', EMAIL);
    await page.fill('input[type="password"]', PASSWORD);
    await page.screenshot({ path: path.join(shots, `phase7-1-login-${stamp}.png`) });
    await page.click('button[type="submit"]');

    // Waiting on the Email field to GO is the only reliable signal here. This is
    // a single-page app: a successful sign-in re-renders in place rather than
    // navigating, so there is no load event to wait for, and `networkidle` can
    // fall through while the sign-in request is still in flight. The submit
    // button is the wrong thing to wait on because its label becomes "Logging
    // in" while the request is pending, which no "Log in" text match survives.
    await page
      .locator('input[type="email"]')
      .waitFor({ state: "detached", timeout: 60_000 });
    await page.waitForLoadState("networkidle");
    record("signed in", EMAIL);

    await page.screenshot({
      path: path.join(shots, `phase7-2-dashboard-${stamp}.png`),
      fullPage: true,
    });

    // The team index, then the migrated team, then its artifacts.
    await page.goto(`${APP_URL}/teams`, { waitUntil: "networkidle" });
    await page.screenshot({
      path: path.join(shots, `phase7-3-teams-${stamp}.png`),
      fullPage: true,
    });
    record("teams page", await page.title());

    // The team table renders one "Open" per row, so the row is selected by its
    // slug and the link is taken from inside it. Matching on the slug alone
    // would also match the slug cell's own text, which is not a link.
    const teamRow = page.locator("tr", { hasText: TEAM_SLUG }).first();
    const openLink = teamRow.locator('a:has-text("Open"), button:has-text("Open")').first();
    if (await openLink.count()) {
      await openLink.click();
      await page.waitForLoadState("networkidle");
      await page.waitForTimeout(1500);
    }
    await page.screenshot({
      path: path.join(shots, `phase7-4-team-${stamp}.png`),
      fullPage: true,
    });

    const artifactsLink = page
      .locator('a:has-text("Findings"), button:has-text("Findings")')
      .first();
    if (await artifactsLink.count()) {
      await artifactsLink.click();
      await page.waitForLoadState("networkidle");
    }
    // Wait for the listing to have resolved to something other than its
    // loading state before the shot is taken.
    await page.waitForTimeout(2000);
    await page.screenshot({
      path: path.join(shots, `phase7-5-artifacts-${stamp}.png`),
      fullPage: true,
    });
    record("artifacts page", page.url());

    const text = await page.locator("body").innerText();
    console.log("\n--- what the artifacts page renders ---");
    console.log(text.slice(0, 1200));
    console.log("---------------------------------------\n");
    record("screenshots", shots);
  } finally {
    await browser.close().catch(() => {});
    await stopBrowserless(container);
  }
}

main().catch((error) => {
  console.error(`[fail] ${error.message}`);
  process.exitCode = 1;
});
