#!/usr/bin/env node
/**
 * The whole platform, once, as one person.
 *
 * Every phase of this stack verified itself in isolation, and each of those runs
 * bootstrapped its own fixtures: phase 4 made an organization to prove teams
 * work, phase 5 made another to prove artifact access works, phase 6 made a
 * third to prove a real cf:change sweep publishes. Nothing had ever carried ONE
 * identity from the sign-up form all the way to reading a published findings run
 * in a browser. The seams between the phases are exactly where a stack assembled
 * that way goes wrong, so this run is deliberately one continuous session: one
 * account, one organization, one team, one API key, one artifact.
 *
 * Same harness as verify/run.mjs, verify/teams.mjs and verify/artifacts.mjs, and
 * deliberately so: the digest-pinned browserless Chromium container this repo
 * standardises on (scripts/change_docker.rb), driven with Playwright over CDP,
 * torn down on every exit path. No host browser and no second automation
 * library.
 *
 * Step 6 is the part that is not a browser at all. It writes a throwaway repo in
 * a temp directory with its own CHANGE.md pointing at the organization and team
 * the earlier steps just created, stands the audit target up as a container, and
 * runs the real scripts/change_run.rb against it. What publishes the artifact is
 * change_artifact_publish.rb, unmodified, authenticating with the key step 5
 * minted through the real UI. Nothing about the publish path is simulated here.
 *
 * Fresh identifiers every run (a timestamp in the address, the org slug, the
 * team slug and the scratch repo), so this is repeatable with no cleanup and
 * never collides with a previous run.
 *
 *   AWS_PROFILE=personal node verify/e2e-smoke.mjs
 */
import { execFile, spawn } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { chromium } from "playwright-core";

const run = promisify(execFile);

// Pinned to the same digest as scripts/change_docker.rb, so the browser this
// verification sees is the browser every other lane in the repo sees.
const BROWSERLESS_IMAGE =
  "ghcr.io/browserless/chromium:v2.38.1@sha256:78afaada9f7b049783bfed624e6b5e9a2d3438fc04bb46801ed777e82ae1501f";

// The audit target step 6 sweeps. Digest-pinned for the same reason every other
// image in this repo is, and a container rather than a host process because the
// docker doctrine applies to a fixture exactly as it applies to a real service.
const SITE_IMAGE =
  "nginx:1.29-alpine@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de";

const APP_URL = process.env.APP_URL ?? "https://app.staging.changefabric.org";
const ARTIFACTS_URL =
  process.env.ARTIFACTS_URL ?? "https://artifacts.staging.changefabric.org";
const API_URL = process.env.API_URL ?? "https://api.staging.changefabric.org";
const MIGRATE_FUNCTION = "cf-platform-migrate";
const REGION = "us-east-1";
const CREDENTIAL_PARAMETER = "/cf-platform/staging/basic-auth-credential";

const here = path.dirname(fileURLToPath(import.meta.url));
const shots = path.join(here, "..", ".verification");
const repoRoot = path.resolve(here, "..", "..", "..");

const stamp = Date.now();
// Lower-case addresses on purpose: Better Auth normalises an address before
// storing it, and every WHERE clause below compares against exactly what the
// server stored.
const owner = {
  name: "Smoke Owner",
  email: `success+e2esmoke${stamp}a@simulator.amazonses.com`,
  password: `verify-a-${stamp}-staging`,
};
const contributor = {
  name: "Smoke Contributor",
  email: `success+e2esmoke${stamp}b@simulator.amazonses.com`,
  password: `verify-b-${stamp}-staging`,
};
const organization = {
  name: `E2E Smoke ${stamp}`,
  slug: `e2e-smoke-${stamp}`,
};
const team = { name: "Core Platform", slug: "core" };

const steps = [];
let shotIndex = 0;

function record(step, detail) {
  steps.push({ step, detail });
  console.log(`[ok] ${step}: ${detail}`);
}

function expect(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

/** Numbered in call order, so the filenames read as the run's own sequence. */
async function shoot(page, label) {
  shotIndex += 1;
  const name = `${String(shotIndex).padStart(2, "0")}-${label}.png`;
  await page.screenshot({ path: path.join(shots, name), fullPage: true });
  return name;
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
  const name = `cf-e2e-verify-${stamp}`;

  // --rm, an ephemeral name, and a published loopback port only: the container
  // exists for this run and nothing else can reach it.
  const child = spawn(
    "docker",
    [
      "run", "--rm", "--name", name,
      "-p", `127.0.0.1:${port}:3000`,
      "-e", `TOKEN=${token}`,
      // This session outlives a real cf:change sweep, which is minutes rather
      // than seconds. Thirty minutes is well past the whole run and still an
      // upper bound rather than no bound.
      "-e", "TIMEOUT=1800000",
      "-e", "CONCURRENT=5",
      BROWSERLESS_IMAGE,
    ],
    { stdio: "ignore" },
  );
  child.unref();

  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(
        `http://127.0.0.1:${port}/json/version?token=${token}`,
      );
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

/**
 * A read-only query against the live staging database, through the maintenance
 * function, because nothing outside the VPC can reach the instance directly.
 */
async function queryRows(sql, params = []) {
  const payloadFile = path.join(shots, `.query-${Date.now()}.json`);
  const outFile = path.join(shots, `.query-out-${Date.now()}.json`);
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
    await rm(payloadFile, { force: true });
    await rm(outFile, { force: true });
  }
}

/**
 * curl, returning the status, the headers and the body, so a 401 or a 302 is
 * data rather than a throw.
 */
async function curl(url, options = {}) {
  const headerFile = path.join(shots, `.headers-${Date.now()}-${Math.random()}`);
  const args = [
    "-s", "-o", "-", "-w", "\n%{http_code}",
    "-D", headerFile,
    "-X", options.method ?? "GET",
  ];
  if (options.credential !== undefined) {
    args.push("-u", options.credential);
  }
  for (const [name, value] of Object.entries(options.headers ?? {})) {
    args.push("-H", `${name}: ${value}`);
  }
  if (options.body !== undefined) {
    args.push("--data-binary", options.body);
  }
  args.push(url);

  try {
    const { stdout } = await run("curl", args, { maxBuffer: 32 * 1024 * 1024 });
    const split = stdout.lastIndexOf("\n");
    const rawHeaders = await readFile(headerFile, "utf8").catch(() => "");
    const headers = {};
    for (const line of rawHeaders.split(/\r?\n/)) {
      const colon = line.indexOf(":");
      if (colon > 0) {
        headers[line.slice(0, colon).trim().toLowerCase()] = line
          .slice(colon + 1)
          .trim();
      }
    }
    return {
      status: Number(stdout.slice(split + 1).trim()),
      body: stdout.slice(0, split),
      headers,
      rawHeaders,
    };
  } finally {
    await rm(headerFile, { force: true });
  }
}

/** A person's own browser: their own context, their own cookies. */
async function openPerson(browser, authorization) {
  const context = await browser.newContext();
  // The staging Basic Auth gate, on every host this context touches. Set as an
  // explicit header rather than relying on the browser's own challenge
  // handling, so a 401 is a real failure of the gate rather than an artifact of
  // how the harness answers a prompt.
  await context.setExtraHTTPHeaders({ Authorization: authorization });
  const page = await context.newPage();
  await page.setViewportSize({ width: 1280, height: 1000 });

  const consoleLines = [];
  page.on("console", (message) =>
    consoleLines.push(`${message.type()}: ${message.text()}`),
  );
  page.on("pageerror", (error) =>
    consoleLines.push(`pageerror: ${error.message}`),
  );

  // "Failed to load resource: 403" in the console names no URL, which makes a
  // refusal that the app swallows impossible to attribute. The response itself
  // does name one, so the refusals are collected here with their method and
  // path and reported by the failure handler.
  const refusals = [];
  page.on("response", (response) => {
    if (response.status() >= 400) {
      refusals.push(
        `${response.request().method()} ${response.url()} -> ${response.status()}`,
      );
    }
  });

  return { context, page, consoleLines, refusals };
}

async function signUp(person, account) {
  await person.page.goto(APP_URL, { waitUntil: "networkidle" });
  await person.page.waitForSelector("#login-email");
  await person.page.click('button:has-text("Create one")');
  await person.page.waitForSelector("#signup-email");
  await person.page.fill("#signup-name", account.name);
  await person.page.fill("#signup-email", account.email);
  await person.page.fill("#signup-password", account.password);
  await person.page.click('button[type="submit"]');
  await person.page.waitForSelector("text=Check your email", { timeout: 60_000 });
}

// --- step 6: a real cf:change sweep -----------------------------------------

/**
 * An accessible fixture page. Deliberately clean rather than deliberately
 * broken: what is being proved here is that a real sweep publishes a real
 * bundle, and a page with planted violations would only make the verdict noisy.
 */
function fixturePage(title, heading) {
  return [
    "<!doctype html>",
    '<html lang="en">',
    "<head>",
    '<meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    `<title>${title}</title>`,
    "<style>",
    "body { background: #ffffff; color: #111111; font-family: system-ui, sans-serif;",
    "       margin: 0 auto; max-width: 40rem; padding: 2rem; }",
    "a { color: #0b4f9e; }",
    "</style>",
    "</head>",
    "<body>",
    `<h1>${heading}</h1>`,
    "<p>A fixture page for the change-fabric end to end smoke run.</p>",
    '<p><a href="/">Home</a> <a href="/about.html">About</a></p>',
    "</body>",
    "</html>",
    "",
  ].join("\n");
}

/**
 * The throwaway repo the sweep runs in.
 *
 * A separate git repository rather than a config path inside this one, because
 * ChangeArtifactsConfig resolves the publishing block from the git repo root's
 * own CHANGE.md. Pointing --config at a file elsewhere would leave the artifact
 * step reading this repo's real CHANGE.md and publishing to the real team, which
 * is exactly what a smoke run must not do.
 */
async function writeScratchRepo(rawKey) {
  const dir = await mkdtemp(path.join(tmpdir(), `cf-e2e-smoke-${stamp}-`));
  const network = `cf-e2e-smoke-net-${stamp}`;
  const site = `cf-e2e-smoke-site-${stamp}`;
  const port = await freePort();

  await mkdir(path.join(dir, "public"), { recursive: true });
  await writeFile(
    path.join(dir, "public", "index.html"),
    fixturePage("Smoke fixture", "Smoke fixture"),
  );
  await writeFile(
    path.join(dir, "public", "about.html"),
    fixturePage("About the smoke fixture", "About"),
  );

  const up = [
    `docker network create ${network} >/dev/null 2>&1 || true`,
    [
      `docker run -d --rm --name ${site} --network ${network}`,
      `-p 127.0.0.1:${port}:80`,
      `-v ${path.join(dir, "public")}:/usr/share/nginx/html:ro`,
      `${SITE_IMAGE} >/dev/null`,
    ].join(" "),
  ].join("; ");
  const down = [
    `docker rm -f ${site} >/dev/null 2>&1 || true`,
    `docker network rm ${network} >/dev/null 2>&1 || true`,
  ].join("; ");

  const changeMd = [
    "---",
    "contributors_team:",
    `  team_id: e2e-smoke-${stamp}`,
    "  contributors: []",
    `  organization: ${organization.slug}`,
    `  team: ${team.slug}`,
    "  platform:",
    `    api_url: ${API_URL}`,
    "    api_key_env: CF_TEAM_API_KEY",
    "    basic_auth:",
    "      username_env: CF_PLATFORM_BASIC_AUTH_USER",
    "      password_env: CF_PLATFORM_BASIC_AUTH_PASSWORD",
    "",
    "change_config:",
    "  project: e2e-smoke",
    "  boot:",
    `    up: ${JSON.stringify(up)}`,
    `    down: ${JSON.stringify(down)}`,
    `    network: ${network}`,
    `    target_url: http://${site}`,
    "    health:",
    `      url: http://127.0.0.1:${port}/`,
    "      expect_status: 200",
    "      timeout_seconds: 90",
    "  lanes:",
    "    k6:",
    "      enabled: false",
    "    zap:",
    "      enabled: false",
    "    a11y:",
    "      enabled: true",
    '      routes: ["/", "/about.html"]',
    "      threshold: serious",
    "    browserless:",
    "      enabled: true",
    "      routes:",
    '        - "/"',
    '        - "/about.html"',
    "      viewports:",
    "        - { name: mobile, width: 390, height: 844 }",
    "        - { name: desktop, width: 1440, height: 900 }",
    "---",
    "",
    "# Scratch repo for the change-fabric end to end smoke run",
    "",
    "Generated by platform/web/verify/e2e-smoke.mjs. Never committed anywhere.",
    "",
  ].join("\n");
  await writeFile(path.join(dir, "CHANGE.md"), changeMd);

  // Its own git repo, with its own remote, so repo_root and repo_id both
  // resolve here and neither can reach the checkout this script lives in.
  const git = (...args) => run("git", ["-C", dir, ...args]);
  await git("init", "-q", "-b", "main");
  await git("config", "user.name", "E2E Smoke");
  await git("config", "user.email", "smoke@example.test");
  await git(
    "remote", "add", "origin",
    `https://example.test/change-fabric/e2e-smoke-${stamp}`,
  );
  await git("add", "-A");
  await git(
    "-c", "commit.gpgsign=false",
    "commit", "-q", "-m", "Scratch fixture for the end to end smoke run",
  );

  return { dir, network, site, port, rawKey };
}

/**
 * Runs the real orchestrator and returns everything it said.
 *
 * Streamed rather than buffered at the end, so a sweep that stalls shows where.
 * The team API key and the staging Basic Auth credential arrive as the exact
 * environment variables the scratch CHANGE.md names, which is the same way a
 * contributor's own machine or a CI job supplies them.
 */
function runSweep(scratch, credential) {
  const [username, ...rest] = credential.split(":");
  const child = spawn(
    "ruby",
    [path.join(repoRoot, "scripts", "change_run.rb"), "all"],
    {
      cwd: scratch.dir,
      env: {
        ...process.env,
        CF_TEAM_API_KEY: scratch.rawKey,
        CF_PLATFORM_BASIC_AUTH_USER: username,
        CF_PLATFORM_BASIC_AUTH_PASSWORD: rest.join(":"),
      },
    },
  );

  let output = "";
  const collect = (chunk) => {
    const text = chunk.toString();
    output += text;
    process.stdout.write(text);
  };
  child.stdout.on("data", collect);
  child.stderr.on("data", collect);

  return new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, output }));
  });
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

  let a;
  let b;
  let scratch = null;
  const captured = {};

  try {
    a = await openPerson(browser, authorization);
    b = await openPerson(browser, authorization);

    // --- 1. Sign up, through the real form -------------------------------
    const gate = await a.page.goto(APP_URL, { waitUntil: "networkidle" });
    expect(
      gate !== null && gate.status() === 200,
      `the app answered ${gate?.status()} behind the Basic Auth gate`,
    );
    await a.page.waitForSelector("#login-email");
    await shoot(a.page, "login");
    await a.page.click('button:has-text("Create one")');
    await a.page.waitForSelector("#signup-email");
    await a.page.fill("#signup-name", owner.name);
    await a.page.fill("#signup-email", owner.email);
    await a.page.fill("#signup-password", owner.password);
    await shoot(a.page, "signup-filled");
    await a.page.click('button[type="submit"]');
    await a.page.waitForSelector("text=Check your email", { timeout: 60_000 });
    await shoot(a.page, "signup-verify-notice");
    record(
      "1. signed up through the real UI",
      `${owner.email} created an account and landed on the verify notice`,
    );

    // --- 2. Onboard an organization --------------------------------------
    await a.page.click('button:has-text("Set up your organization")');
    await a.page.waitForSelector("#org-name");
    await a.page.fill("#org-name", organization.name);
    await a.page.fill("#org-slug", organization.slug);
    await shoot(a.page, "onboarding-filled");
    await a.page.click('button[type="submit"]');
    await a.page.waitForSelector('[data-testid="dashboard-heading"]', {
      timeout: 60_000,
    });
    const heading = (
      await a.page.textContent('[data-testid="dashboard-heading"]')
    ).trim();
    const roleShown = (
      await a.page.textContent('[data-testid="active-role"]')
    ).trim();
    await shoot(a.page, "dashboard");
    expect(
      heading === organization.name,
      `the dashboard read "${heading}", expected "${organization.name}"`,
    );
    expect(roleShown === "owner", `the owner's role rendered as "${roleShown}"`);
    record(
      "2. onboarded an organization through the real UI",
      `"${organization.name}" (${organization.slug}), role rendered as "${roleShown}"`,
    );

    // --- 3. A contributor team, and the owner on it ------------------------
    await a.page.click('button:has-text("Teams")');
    await a.page.waitForSelector('[data-testid="create-team"]');
    await a.page.fill("#team-name", team.name);
    await a.page.fill("#team-slug", team.slug);
    await a.page.click('[data-testid="create-team"]');
    await a.page.waitForSelector(`[data-testid="team-row-${team.slug}"]`, {
      timeout: 60_000,
    });
    await shoot(a.page, "teams-list");

    const teamRows = await queryRows(
      `select t.id, t.name, t.slug
         from team t
         join organization o on o.id = t.organization_id
        where o.slug = $1`,
      [organization.slug],
    );
    expect(
      teamRows.length === 1,
      `expected exactly one team row in Postgres, got ${teamRows.length}`,
    );
    captured.teamId = teamRows[0].id;

    // Creating a team does not put the creator on it: team membership is
    // explicit by design (routes/artifacts.ts says so in as many words, and the
    // authorize route asks for a team_member row rather than an organization
    // role). The owner is going to read this team's findings in step 7, so the
    // owner joins the team here, through the same picker the product offers.
    await a.page.goto(`${APP_URL}/teams/${captured.teamId}`, {
      waitUntil: "networkidle",
    });
    await a.page.waitForSelector('[data-testid="member-picker"]', {
      timeout: 60_000,
    });
    await a.page.selectOption('[data-testid="member-picker"]', {
      label: owner.name,
    });
    await a.page.click('[data-testid="add-team-member"]');
    await a.page.waitForSelector(`[data-testid="team-member-${owner.email}"]`, {
      timeout: 60_000,
    });
    await shoot(a.page, "team-detail-owner-joined");
    record(
      "3. created a contributor team through the real UI",
      `team "${team.name}" (${team.slug}) is ${captured.teamId} in Postgres, and ${owner.email} joined it through the member picker`,
    );

    // --- 4. A second account, invited onto that team -----------------------
    await signUp(b, contributor);
    await shoot(b.page, "contributor-signed-up");

    await a.page.click('button:has-text("Members")');
    await a.page.waitForSelector('[data-testid="open-invite"]');
    await a.page.click('[data-testid="open-invite"]');
    await a.page.waitForSelector("#invite-email");
    await a.page.fill("#invite-email", contributor.email);
    await a.page.selectOption("#invite-team", { label: team.name });
    await shoot(a.page, "invite-form");
    await a.page.click('[data-testid="send-invite"]');
    await a.page.waitForSelector('[data-testid="invite-sent"]', {
      timeout: 60_000,
    });
    await shoot(a.page, "invite-sent");

    const invitations = await queryRows(
      `select i.id, i.email, i.role, i.status, i.team_id
         from invitation i
         join organization o on o.id = i.organization_id
        where o.slug = $1`,
      [organization.slug],
    );
    expect(
      invitations.length === 1,
      `expected exactly one invitation row, got ${invitations.length}`,
    );
    const invitation = invitations[0];
    expect(
      invitation.team_id === captured.teamId,
      `the invitation named team ${invitation.team_id}, expected ${captured.teamId}`,
    );

    // The address the invitation mail carries. Read from the row rather than
    // from a mailbox because the mail goes to the SES simulator, which accepts
    // it and never delivers it anywhere a test can read.
    await b.page.goto(`${APP_URL}/accept-invite?invitation=${invitation.id}`, {
      waitUntil: "networkidle",
    });
    await b.page.waitForSelector('[data-testid="accept-invite"]', {
      timeout: 60_000,
    });
    await shoot(b.page, "accept-invite-page");
    await b.page.click('[data-testid="accept-invite"]');
    await b.page.waitForSelector('[data-testid="invite-accepted"]', {
      timeout: 60_000,
    });
    await shoot(b.page, "invite-accepted");

    const contributorTeams = await queryRows(
      `select t.slug
         from team_member tm
         join team t on t.id = tm.team_id
         join "user" u on u.id = tm.user_id
        where u.email = $1`,
      [contributor.email],
    );
    expect(
      contributorTeams.length === 1 && contributorTeams[0].slug === team.slug,
      `the accepted invitation did not put ${contributor.email} on "${team.slug}": ${JSON.stringify(contributorTeams)}`,
    );
    record(
      "4. invited and accepted a second account, scoped to the team",
      `invitation ${invitation.id} for ${invitation.email} (role ${invitation.role}) named team "${team.slug}", and accepting it wrote the team_member row`,
    );

    // --- 5. A team API key, minted through the real UI ---------------------
    await a.page.goto(`${APP_URL}/teams/${captured.teamId}`, {
      waitUntil: "networkidle",
    });
    await a.page.waitForSelector('[data-testid="create-key"]', {
      timeout: 60_000,
    });
    await a.page.fill("#key-name", "e2e-smoke");
    await a.page.click('[data-testid="create-key"]');
    await a.page.waitForSelector('[data-testid="revealed-key-value"]', {
      timeout: 60_000,
    });
    captured.rawKey = (
      await a.page.textContent('[data-testid="revealed-key-value"]')
    ).trim();
    // Screenshot taken only AFTER the banner is dismissed, so no image in
    // .verification/ ever carries the key itself.
    await a.page.click('[data-testid="dismiss-key"]');
    await a.page.waitForSelector('[data-testid="keys-table"]');
    await shoot(a.page, "team-key-minted");

    const keyRows = await queryRows(
      `select id, name, key_prefix, last_used_at, revoked_at
         from team_api_key
        where team_id = $1`,
      [captured.teamId],
    );
    expect(keyRows.length === 1, `expected one key row, got ${keyRows.length}`);
    captured.key = keyRows[0];
    expect(
      captured.rawKey.startsWith(captured.key.key_prefix) &&
        captured.key.key_prefix.length < captured.rawKey.length,
      "the stored prefix is not a proper prefix of the key that was shown",
    );
    expect(
      captured.key.last_used_at === null,
      "a freshly minted key already had a last_used_at",
    );
    record(
      "5. minted a team API key through the real UI",
      `key "${captured.key.name}" stored as a ${captured.key.key_prefix.length}-character prefix of a ${captured.rawKey.length}-character key, last_used_at null`,
    );

    // --- 6. A real cf:change sweep, publishing a real artifact -------------
    scratch = await writeScratchRepo(captured.rawKey);
    console.log(`\n[e2e] sweeping ${scratch.dir}\n`);
    const sweep = await runSweep(scratch, credential);
    expect(
      sweep.code === 0,
      `the sweep exited ${sweep.code}; the lanes did not all pass`,
    );

    const viewerLine = sweep.output.match(
      /\[change] artifact: (https:\/\/\S+)/,
    );
    expect(
      viewerLine !== null,
      `the sweep published no artifact URL. Output tail:\n${sweep.output.slice(-4000)}`,
    );
    captured.viewerUrl = viewerLine[1].trim();
    const uploadedLine = sweep.output.match(
      /\[change] artifact: uploaded (\d+) file\(s\)/,
    );
    expect(
      uploadedLine !== null && Number(uploadedLine[1]) > 0,
      "the sweep reported no uploaded files",
    );
    captured.uploaded = Number(uploadedLine[1]);

    const artifactRows = await queryRows(
      `select a.id, a.short_id, a.status, a.key_prefix, a.project, a.branch,
              a.head_sha, a.repo_id, a.byte_size, a.published_at,
              a.completion_note, a.contributor_user_id, a.contributor_label
         from artifact a
         join organization o on o.id = a.organization_id
        where o.slug = $1`,
      [organization.slug],
    );
    expect(
      artifactRows.length === 1,
      `expected exactly one artifact row, got ${artifactRows.length}`,
    );
    captured.artifact = artifactRows[0];
    expect(
      captured.artifact.key_prefix ===
        `${organization.slug}/${team.slug}/${captured.artifact.short_id}/`,
      `key_prefix is ${captured.artifact.key_prefix}`,
    );
    expect(
      captured.artifact.published_at !== null,
      "the artifact row was never completed",
    );
    expect(
      captured.artifact.completion_note === null,
      `the service recorded a completion note: ${captured.artifact.completion_note}`,
    );
    expect(
      captured.viewerUrl.startsWith(
        `${ARTIFACTS_URL}/v/${captured.artifact.key_prefix}`,
      ),
      `the published URL ${captured.viewerUrl} does not match the row's prefix`,
    );
    record(
      "6. a real cf:change sweep published a real artifact",
      `the sweep passed and uploaded ${captured.uploaded} file(s); artifact ${captured.artifact.short_id} (${captured.artifact.status}, ${captured.artifact.byte_size} bytes, project "${captured.artifact.project}", branch "${captured.artifact.branch}", repo "${captured.artifact.repo_id}") is at key_prefix ${captured.artifact.key_prefix} with no completion note`,
    );

    // --- 7. Reading the run back, as the account that started this run -----
    //
    // The gating sequence first, with curl, because a browser cannot show that a
    // request WITHOUT credentials is refused: the context carries the Basic Auth
    // header on every navigation by construction.
    const anonymous = await curl(captured.viewerUrl);
    expect(
      anonymous.status === 401,
      `the viewer URL with no Basic Auth answered ${anonymous.status}, expected 401`,
    );
    const cookieless = await curl(captured.viewerUrl, { credential });
    expect(
      cookieless.status === 302,
      `the viewer URL with Basic Auth and no cookies answered ${cookieless.status}, expected 302`,
    );
    const location = cookieless.headers.location ?? "";
    expect(
      location.startsWith(`${APP_URL}/artifacts/authorize?`) &&
        location.includes(`team=${team.slug}`) &&
        location.includes(encodeURIComponent(captured.viewerUrl)),
      `the 302 pointed at ${location}`,
    );

    // The team's own findings page, reached the way a person reaches it, so the
    // link followed below is the one the product rendered rather than one this
    // script happened to hold.
    await a.page.goto(`${APP_URL}/teams/${captured.teamId}/artifacts`, {
      waitUntil: "networkidle",
      timeout: 60_000,
    });
    await a.page.waitForSelector('[data-testid="artifacts-table"]', {
      timeout: 60_000,
    });
    const openLink = await a.page.getAttribute(
      `[data-testid="open-artifact-${captured.artifact.short_id}"]`,
      "href",
    );
    await shoot(a.page, "team-findings-listing");
    expect(
      openLink === captured.viewerUrl,
      `the listing linked at ${openLink}, expected ${captured.viewerUrl}`,
    );

    const opened = await a.page.goto(captured.viewerUrl, {
      waitUntil: "networkidle",
      timeout: 90_000,
    });
    // `attached`, not the default `visible`: the manifest the page carries is a
    // script tag, which is never visible and never will be.
    await a.page.waitForSelector("#manifest", {
      state: "attached",
      timeout: 60_000,
    });
    const published = JSON.parse(
      await a.page.textContent("#manifest"),
    );
    await shoot(a.page, "artifact-rendered");
    expect(
      opened !== null && opened.status() === 200,
      `the final navigation answered ${opened?.status()}`,
    );
    expect(
      a.page.url().startsWith(ARTIFACTS_URL),
      `the browser ended up at ${a.page.url()}`,
    );
    expect(
      published.run.project === "e2e-smoke",
      `the rendered manifest names project "${published.run.project}"`,
    );
    expect(
      published.status === captured.artifact.status,
      `the rendered manifest says "${published.status}" and the row says "${captured.artifact.status}"`,
    );

    const jar = await a.context.cookies(ARTIFACTS_URL);
    const cloudfront = jar.filter((cookie) =>
      cookie.name.startsWith("CloudFront-"),
    );
    expect(
      cloudfront.length === 3,
      `expected three CloudFront cookies, got ${JSON.stringify(cloudfront.map((c) => c.name))}`,
    );
    record(
      "7. the same account read the run back through the real gate",
      `401 with no Basic Auth, 302 to ${location.slice(0, 80)} with no cookies, then the listing's own Open link rendered the run at ${a.page.url()} with status ${opened.status()} and three CloudFront cookies; the page's embedded manifest reports lanes ${JSON.stringify(published.lane_status)}`,
    );
    // Every refusal either browser saw, reported rather than asserted on. Some
    // are the point of the run (the 403 CloudFront answers an object request
    // that has no cookie yet, on the way to the authorize screen), so a blanket
    // "no 4xx anywhere" assertion would be wrong. Printing them is what makes a
    // new one visible to whoever reads the run.
    captured.refusals = {
      owner: [...new Set(a.refusals)],
      contributor: [...new Set(b.refusals)],
    };
  } catch (error) {
    for (const [label, person] of [["owner", a], ["contributor", b]]) {
      if (person === undefined) {
        continue;
      }
      await person.page
        .screenshot({
          path: path.join(shots, `99-failure-${label}.png`),
          fullPage: true,
        })
        .catch(() => {});
      console.error(
        `${label} at failure: ${person.page.url()}` +
          `\n  console: ${JSON.stringify(person.consoleLines.slice(-15))}` +
          `\n  refused: ${JSON.stringify(person.refusals.slice(-15), null, 2)}`,
      );
    }
    throw error;
  } finally {
    await browser.close().catch(() => {});
    await stopBrowserless(container);
    if (scratch !== null) {
      await run("docker", ["rm", "-f", scratch.site]).catch(() => {});
      await run("docker", ["network", "rm", scratch.network]).catch(() => {});
      await rm(scratch.dir, { recursive: true, force: true }).catch(() => {});
    }
  }

  // --- 8. The whole chain, in one query ------------------------------------
  //
  // One row, or the join failed somewhere. This is the claim the run exists to
  // make: the account that signed up in step 1 owns the organization created in
  // step 2, which holds the team created in step 3, which the account invited in
  // step 4 belongs to, which the key minted in step 5 is scoped to, which the
  // sweep in step 6 published under.
  const chain = await queryRows(
    `select u.email          as owner_email,
            m.role           as owner_role,
            o.slug           as org_slug,
            t.slug           as team_slug,
            invited.email    as contributor_email,
            k.name           as key_name,
            k.last_used_at   as key_last_used_at,
            a.short_id       as artifact_short_id,
            a.key_prefix     as artifact_key_prefix,
            a.published_at   as artifact_published_at
       from "user" u
       join member m        on m.user_id = u.id
       join organization o  on o.id = m.organization_id
       join team t          on t.organization_id = o.id
       join team_member tm  on tm.team_id = t.id
       join "user" invited  on invited.id = tm.user_id
       join team_api_key k  on k.team_id = t.id
       join artifact a      on a.team_id = t.id
      where u.email = $1
        and invited.email = $2`,
    [owner.email, contributor.email],
  );
  expect(
    chain.length === 1,
    `the row chain is not one continuous line: ${JSON.stringify(chain)}`,
  );
  const row = chain[0];
  expect(row.owner_role === "owner", `the owner's member role is ${row.owner_role}`);
  expect(
    row.org_slug === organization.slug && row.team_slug === team.slug,
    `the chain names ${row.org_slug}/${row.team_slug}`,
  );
  expect(
    row.artifact_key_prefix === `${row.org_slug}/${row.team_slug}/${row.artifact_short_id}/`,
    `the artifact prefix ${row.artifact_key_prefix} is not under this team`,
  );
  expect(
    row.key_last_used_at !== null,
    "the key the sweep published with was never stamped as used",
  );
  expect(
    row.artifact_published_at !== null,
    "the artifact in the chain was never published",
  );
  record("8. the whole chain is one row in Postgres", JSON.stringify(row));

  console.log(`\nall ${steps.length} verification steps passed`);
  console.log(`organization: ${organization.name} (${organization.slug})`);
  console.log(`team:         ${team.name} (${team.slug})`);
  console.log(`artifact:     ${captured.artifact.short_id} at ${captured.viewerUrl}`);
  console.log(`screenshots:  ${shots}`);
  console.log(`\nrefusals either browser saw:`);
  console.log(JSON.stringify(captured.refusals, null, 2));
}

main().catch((error) => {
  console.error(`\nverification FAILED: ${error.message}`);
  process.exitCode = 1;
});
