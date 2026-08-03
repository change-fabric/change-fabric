#!/usr/bin/env node
/**
 * Drives the real deployed staging app in a real browser, then checks the rows
 * it claims to have created actually exist in Postgres.
 *
 * The browser is the digest-pinned browserless Chromium container this repo
 * already standardises on (scripts/change_docker.rb), driven with Playwright
 * over CDP, which is the same arrangement cf:qa uses. No host browser is
 * launched and no second automation library is introduced.
 *
 * Every run signs up a fresh address at the SES mailbox simulator, so re-running
 * never collides with a previous run and never needs a human inbox.
 *
 * Screenshots land in platform/web/.verification/ (gitignored). They are
 * evidence for the run's own report, not an artifact of the build.
 *
 *   AWS_PROFILE=personal node verify/run.mjs
 */
import { execFile, spawn } from "node:child_process";
import { mkdir, rm } from "node:fs/promises";
import { createServer } from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { chromium } from "playwright-core";

const run = promisify(execFile);

// Pinned to the same digest as scripts/change_docker.rb, so the browser this
// verification sees is the browser every other lane in the repo sees.
const BROWSERLESS_IMAGE =
  "ghcr.io/browserless/chromium:v2.38.1@sha256:78afaada9f7b049783bfed624e6b5e9a2d3438fc04bb46801ed777e82ae1501f";

const APP_URL = process.env.APP_URL ?? "https://app.staging.changefabric.org";
const MIGRATE_FUNCTION = "cf-platform-migrate";
const REGION = "us-east-1";
const CREDENTIAL_PARAMETER = "/cf-platform/staging/basic-auth-credential";

const here = path.dirname(fileURLToPath(import.meta.url));
// One directory per script. They used to share `.verification/`, which was fine
// while each was run on its own and destroys the previous script's evidence the
// moment `verify:all` runs them back to back.
const shots = path.join(here, "..", ".verification", "signup");

const stamp = Date.now();
const account = {
  name: "Verification Runner",
  email: `success+cfweb${stamp}@simulator.amazonses.com`,
  password: `verify-${stamp}-staging`,
};
const organization = {
  name: `Verification Org ${stamp}`,
  slug: `verify-org-${stamp}`,
};

const steps = [];

/** Set once a page exists, so a failure can report what the page was showing. */
let diagnose = async () => null;

function record(step, detail) {
  steps.push({ step, detail });
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
  const token = `verify-${stamp}`;
  const name = `cf-web-verify-${stamp}`;

  // --rm, an ephemeral name, and a published loopback port only: the container
  // exists for this run and nothing else can reach it.
  const child = spawn(
    "docker",
    [
      "run", "--rm", "--name", name,
      "-p", `127.0.0.1:${port}:3000`,
      "-e", `TOKEN=${token}`,
      // browserless closes a session after 30s by default, which is shorter
      // than a real sign-up plus onboarding round trip. Five minutes is well
      // past the whole run and still an upper bound rather than no bound.
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

async function queryRows(sql, params) {
  const payloadFile = path.join(shots, `query-${Date.now()}.json`);
  const outFile = path.join(shots, `query-out-${Date.now()}.json`);
  const { writeFile, readFile, rm: unlink } = await import("node:fs/promises");
  await writeFile(payloadFile, JSON.stringify({ action: "query", sql, params }));
  try {
    await run("aws", [
      "lambda", "invoke",
      "--region", REGION,
      "--function-name", MIGRATE_FUNCTION,
      "--cli-binary-format", "raw-in-base64-out",
      "--payload", `fileb://${payloadFile}`,
      outFile,
    ]);
    const body = JSON.parse(await readFile(outFile, "utf8"));
    if (body.ok !== true) {
      throw new Error(`query failed: ${JSON.stringify(body)}`);
    }
    return body.detail.rows;
  } finally {
    await unlink(payloadFile).catch(() => {});
    await unlink(outFile).catch(() => {});
  }
}

async function main() {
  await rm(shots, { recursive: true, force: true });
  await mkdir(shots, { recursive: true });

  const credential = await readCredential();
  const [username, ...rest] = credential.split(":");
  const authorization =
    "Basic " + Buffer.from(`${username}:${rest.join(":")}`).toString("base64");

  const container = await startBrowserless();
  const browser = await chromium.connectOverCDP(
    `ws://127.0.0.1:${container.port}?token=${container.token}`,
  );

  try {
    const context = browser.contexts()[0] ?? (await browser.newContext());
    // The staging Basic Auth gate. Set as an explicit header rather than relying
    // on the browser's own challenge handling, so a 401 is a real failure of the
    // gate rather than an artifact of how the harness answers a prompt.
    await context.setExtraHTTPHeaders({ Authorization: authorization });
    const page = await context.newPage();
    await page.setViewportSize({ width: 1280, height: 900 });

    // A failure here is nearly always something the page already said out loud.
    // Collecting it means the report names the cause rather than the selector
    // that happened to time out first.
    const consoleLines = [];
    page.on("console", (message) =>
      consoleLines.push(`${message.type()}: ${message.text()}`),
    );
    page.on("pageerror", (error) => consoleLines.push(`pageerror: ${error.message}`));
    diagnose = async () => {
      await page
        .screenshot({ path: path.join(shots, "99-failure.png"), fullPage: true })
        .catch(() => {});
      const notice = await page
        .textContent('[data-testid="error-notice"]')
        .catch(() => null);
      return {
        url: page.url(),
        inlineError: notice,
        console: consoleLines.slice(-20),
      };
    };

    // --- 1. Past the Basic Auth gate ------------------------------------
    const response = await page.goto(APP_URL, { waitUntil: "networkidle" });
    if (response === null || response.status() !== 200) {
      throw new Error(`app returned ${response?.status()} rather than 200`);
    }
    await page.waitForSelector("#login-email");
    await page.screenshot({ path: path.join(shots, "01-login.png") });
    record(
      "basic auth gate",
      `${APP_URL} answered 200 and rendered the log-in form (title "${await page.title()}")`,
    );

    // --- 2. Sign up -----------------------------------------------------
    await page.click('button:has-text("Create one")');
    await page.waitForSelector("#signup-email");
    await page.fill("#signup-name", account.name);
    await page.fill("#signup-email", account.email);
    await page.fill("#signup-password", account.password);
    await page.screenshot({ path: path.join(shots, "02-signup-filled.png") });
    await page.click('button[type="submit"]');

    await page.waitForSelector("text=Check your email", { timeout: 30_000 });
    const notice = await page.textContent(".notice-info");
    await page.screenshot({ path: path.join(shots, "03-verify-notice.png") });
    record("sign-up", `created ${account.email}; notice read "${notice.trim()}"`);

    // --- 3. Onboarding --------------------------------------------------
    await page.click('button:has-text("Set up your organization")');
    await page.waitForSelector("#org-name");
    await page.fill("#org-name", organization.name);
    await page.fill("#org-slug", organization.slug);
    await page.screenshot({ path: path.join(shots, "04-onboarding-filled.png") });
    await page.click('button[type="submit"]');

    // --- 4. Dashboard ---------------------------------------------------
    await page.waitForSelector('[data-testid="dashboard-heading"]', {
      timeout: 30_000,
    });
    const heading = (
      await page.textContent('[data-testid="dashboard-heading"]')
    ).trim();
    const slugShown = (
      await page.textContent('[data-testid="active-org-slug"]')
    ).trim();
    const orgBar = (
      await page.textContent('[data-testid="active-org-name"]')
    ).trim();
    await page.screenshot({
      path: path.join(shots, "05-dashboard.png"),
      fullPage: true,
    });

    if (heading !== organization.name) {
      throw new Error(
        `dashboard heading was "${heading}", expected "${organization.name}"`,
      );
    }
    if (slugShown !== organization.slug) {
      throw new Error(
        `dashboard slug was "${slugShown}", expected "${organization.slug}"`,
      );
    }
    record(
      "onboarding and dashboard",
      `heading "${heading}", slug "${slugShown}", org bar "${orgBar}"`,
    );

    // --- 5. Members -----------------------------------------------------
    await page.click('button:has-text("Members")');
    await page.waitForSelector('[data-testid="members-table"]');
    const rows = await page.$$eval('[data-testid="members-table"] tbody tr', (trs) =>
      trs.map((tr) =>
        Array.from(tr.querySelectorAll("td")).map((td) => td.textContent.trim()),
      ),
    );
    await page.screenshot({
      path: path.join(shots, "06-members.png"),
      fullPage: true,
    });
    record("members list", `${rows.length} row(s): ${JSON.stringify(rows)}`);

    // --- 6. Single-org accounts get no switcher -------------------------
    const switcherCount = await page.locator("select#org-switcher").count();
    if (switcherCount !== 0) {
      throw new Error("a single-organization account rendered a switcher");
    }
    record(
      "org switcher",
      "single-org account shows the org name as text, no dead-end select",
    );

    // --- 7. Log out, then log back in -----------------------------------
    await page.click('button:has-text("Log out")');
    await page.waitForSelector("#login-email");
    await page.fill("#login-email", account.email);
    await page.fill("#login-password", account.password);
    await page.click('button[type="submit"]');
    await page.waitForSelector('[data-testid="dashboard-heading"]', {
      timeout: 30_000,
    });
    const afterLogin = (
      await page.textContent('[data-testid="dashboard-heading"]')
    ).trim();
    await page.screenshot({ path: path.join(shots, "07-relogin.png") });
    if (afterLogin !== organization.name) {
      throw new Error(`log-in landed on "${afterLogin}"`);
    }
    record("log in", `signed back in and landed on "${afterLogin}"`);

    // --- 8. A rejected credential produces visible error text ------------
    await page.click('button:has-text("Log out")');
    await page.waitForSelector("#login-email");
    await page.fill("#login-email", account.email);
    await page.fill("#login-password", "definitely-not-the-password");
    await page.click('button[type="submit"]');
    const wrongPassword = (
      await page.textContent('[data-testid="error-notice"]', { timeout: 30_000 })
    ).trim();
    await page.screenshot({ path: path.join(shots, "08-bad-credentials.png") });
    record("wrong password", `rendered inline: "${wrongPassword}"`);

    // --- 9. A duplicate email produces visible error text ----------------
    await page.click('button:has-text("Create one")');
    await page.waitForSelector("#signup-email");
    await page.fill("#signup-name", account.name);
    await page.fill("#signup-email", account.email);
    await page.fill("#signup-password", account.password);
    await page.click('button[type="submit"]');
    const duplicate = (
      await page.textContent('[data-testid="error-notice"]', { timeout: 30_000 })
    ).trim();
    await page.screenshot({ path: path.join(shots, "09-duplicate-email.png") });
    record("duplicate email", `rendered inline: "${duplicate}"`);
  } catch (error) {
    const pageState = await diagnose().catch(() => null);
    if (pageState !== null) {
      console.error(`page state at failure: ${JSON.stringify(pageState, null, 2)}`);
    }
    throw error;
  } finally {
    await browser.close().catch(() => {});
    await stopBrowserless(container);
  }

  // --- 10. The rows, in Postgres, not in the UI --------------------------
  const dbRows = await queryRows(
    `select u.email,
            u.name  as user_name,
            o.name  as org_name,
            o.slug  as org_slug,
            m.role  as member_role
       from "user" u
       join member m on m.user_id = u.id
       join organization o on o.id = m.organization_id
      where u.email = $1`,
    [account.email],
  );
  if (dbRows.length !== 1) {
    throw new Error(
      `expected exactly one user/member/organization row, got ${dbRows.length}`,
    );
  }
  const row = dbRows[0];
  if (row.org_slug !== organization.slug || row.member_role !== "owner") {
    throw new Error(`row did not match what the UI showed: ${JSON.stringify(row)}`);
  }
  record("postgres row check", JSON.stringify(row));

  console.log("\nall verification steps passed");
  console.log(`screenshots: ${shots}`);
}

main().catch((error) => {
  console.error(`\nverification FAILED: ${error.message}`);
  process.exitCode = 1;
});
