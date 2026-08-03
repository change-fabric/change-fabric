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
 *   AWS_PROFILE=personal node verify/legacy-migration.mjs
 *
 * The maintainer's password comes from CF_PLATFORM_PASSWORD, or from this
 * machine's Keychain when that is unset. See readPassword below.
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
const TEAM_SLUG = process.env.CF_TEAM_SLUG ?? "core";

// The Keychain service this repo already keeps platform credentials under.
// scripts/change_artifacts_config.rb reads team API keys from
// `change-fabric-platform`; the account password lives beside it under
// `change-fabric-platform-account`, keyed by the address it signs in as.
const KEYCHAIN_SERVICE = "change-fabric-platform-account";

const here = path.dirname(fileURLToPath(import.meta.url));
// One directory per script, so `verify:all` ends with all four runs' evidence
// rather than only the last one's.
const shots = path.join(here, "..", ".verification", "legacy-migration");
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

/**
 * The maintainer's platform password: the environment first, then this machine's
 * Keychain.
 *
 * Fail-soft in every direction, the same way change_artifacts_config.rb reads a
 * team key: no Keychain, no entry, or a `security` that is not on this platform
 * all mean "not here", and main() then says so by name. The fallback exists so
 * `npm run verify:all` is one command rather than one command plus a secret the
 * runner had to go and find.
 */
async function readPassword() {
  const fromEnv = process.env.CF_PLATFORM_PASSWORD ?? "";
  if (fromEnv !== "") {
    return fromEnv;
  }
  try {
    const { stdout } = await run("security", [
      "find-generic-password",
      "-s", KEYCHAIN_SERVICE,
      "-a", EMAIL,
      "-w",
    ]);
    return stdout.trim();
  } catch {
    return "";
  }
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
  const PASSWORD = await readPassword();
  if (PASSWORD === "") {
    throw new Error(
      "no platform password: set CF_PLATFORM_PASSWORD, or store it in the " +
        `Keychain under service "${KEYCHAIN_SERVICE}" account "${EMAIL}"`,
    );
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

    // The rows and the controls carry their own test ids, so each step waits on
    // the one thing it is about. The previous pass used text matching guarded by
    // `if (await link.count())`, which meant a missing team, a missing findings
    // control, or an empty listing all read as a pass: the script took its
    // screenshots of whatever was on screen and exited 0. Every claim in the
    // header is now a claim the run actually fails on.
    await page.waitForSelector('[data-testid="teams-table"]', { timeout: 30_000 });
    await page.waitForSelector(`[data-testid="team-row-${TEAM_SLUG}"]`, {
      timeout: 30_000,
    });
    record("migrated team is listed", `team row "${TEAM_SLUG}" is on /teams`);

    await page.click(`[data-testid="open-team-${TEAM_SLUG}"]`);
    await page.waitForSelector('[data-testid="team-heading"]', { timeout: 30_000 });
    const shownSlug = (await page.textContent('[data-testid="team-slug"]')).trim();
    if (shownSlug !== TEAM_SLUG) {
      throw new Error(`team page showed slug "${shownSlug}", expected "${TEAM_SLUG}"`);
    }
    await page.screenshot({
      path: path.join(shots, `phase7-4-team-${stamp}.png`),
      fullPage: true,
    });
    record(
      "team page",
      `"${(await page.textContent('[data-testid="team-heading"]')).trim()}" (${shownSlug})`,
    );

    await page.click('[data-testid="open-artifacts"]');
    await page.waitForSelector('[data-testid="artifacts-heading"]', {
      timeout: 30_000,
    });
    // The listing resolves to a table or to the empty notice. Waiting for either
    // replaces the fixed sleep that used to stand in for both.
    await page.waitForSelector(
      '[data-testid="artifacts-table"], [data-testid="artifacts-empty"]',
      { timeout: 30_000 },
    );
    await page.screenshot({
      path: path.join(shots, `phase7-5-artifacts-${stamp}.png`),
      fullPage: true,
    });
    record("artifacts page", page.url());

    // The whole point of the phase: the migrated team carries published history.
    // An empty listing here is the failure this script exists to catch.
    const rows = await page.$$eval(
      '[data-testid="artifacts-table"] tbody tr',
      (trs) =>
        trs.map((tr) =>
          Array.from(tr.querySelectorAll("td")).map((td) => td.textContent.trim()),
        ),
    );
    if (rows.length === 0) {
      throw new Error(
        `team "${TEAM_SLUG}" listed no published runs; the migrated history is not there`,
      );
    }
    record(
      "published runs",
      `${rows.length} run(s) listed, most recent ${JSON.stringify(rows[0])}`,
    );

    const text = await page.locator("body").innerText();
    console.log("\n--- what the artifacts page renders ---");
    console.log(text.slice(0, 1200));
    console.log("---------------------------------------\n");
    record("screenshots", shots);
  } finally {
    await browser.close().catch(() => {});
    await stopBrowserless(container);
  }

  console.log("\nall verification steps passed");
  console.log(`screenshots: ${shots}`);
}

main().catch((error) => {
  console.error(`[fail] ${error.message}`);
  process.exitCode = 1;
});
