#!/usr/bin/env node
/**
 * The phase 4 end-to-end run: contributor teams, invitations, membership across
 * two teams, and an API key minted, used, and revoked.
 *
 * Same harness as verify/run.mjs, and deliberately so: the digest-pinned
 * browserless Chromium container this repo standardises on
 * (scripts/change_docker.rb), driven with Playwright over CDP, torn down on
 * every exit path. No host browser, no second automation library.
 *
 * Two things make this run worth more than a UI test. First, every claim is
 * checked against Postgres through the cf-platform-migrate `query` action rather
 * than against what the screen said. Second, the authorization rule is exercised
 * the way an attacker would exercise it: with curl and a real member's session
 * cookie, not by observing that a button was hidden.
 *
 * Two browser contexts run side by side, one per person, so User A and User B
 * each hold their own cookie jar exactly as two people would.
 *
 *   AWS_PROFILE=personal node verify/teams.mjs
 */
import { execFile, spawn } from "node:child_process";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
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
// One directory per script, so `verify:all` ends with all four runs' evidence
// rather than only the last one's.
const shots = path.join(here, "..", ".verification", "teams");

const stamp = Date.now();
// Lower-case on purpose. Better Auth normalises an address before storing it, so
// an address with any upper case in it would not equal the one that comes back
// out, and every selector and every WHERE clause below compares against exactly
// what the server stored.
const userA = {
  name: "Team Owner",
  email: `success+cfteams-a-${stamp}@simulator.amazonses.com`,
  password: `verify-a-${stamp}-staging`,
};
const userB = {
  name: "Team Contributor",
  email: `success+cfteams-b-${stamp}@simulator.amazonses.com`,
  password: `verify-b-${stamp}-staging`,
};
const organization = {
  name: `Teams Verification ${stamp}`,
  slug: `teams-verify-${stamp}`,
};
const teams = [
  { name: "Core Platform", slug: "core" },
  { name: "Documentation", slug: "docs" },
];

const steps = [];
let shotIndex = 0;

function record(step, detail) {
  steps.push({ step, detail });
  console.log(`[ok] ${step}: ${detail}`);
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
  const name = `cf-teams-verify-${stamp}`;

  // --rm, an ephemeral name, and a published loopback port only: the container
  // exists for this run and nothing else can reach it.
  const child = spawn(
    "docker",
    [
      "run", "--rm", "--name", name,
      "-p", `127.0.0.1:${port}:3000`,
      "-e", `TOKEN=${token}`,
      // This run is longer than phase 3's: two contexts, an invitation round
      // trip, and a key lifecycle. Ten minutes is well past the whole run and
      // still an upper bound rather than no bound.
      "-e", "TIMEOUT=600000",
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

/** curl, returning the status and the body, so a 403 is data rather than a throw. */
async function curl(url, options = {}) {
  const args = [
    "-s", "-o", "-", "-w", "\n%{http_code}",
    "-X", options.method ?? "GET",
    "-u", options.credential,
  ];
  for (const [name, value] of Object.entries(options.headers ?? {})) {
    args.push("-H", `${name}: ${value}`);
  }
  if (options.body !== undefined) {
    args.push("-H", "Content-Type: application/json", "-d", options.body);
  }
  args.push(url);

  const { stdout } = await run("curl", args, { maxBuffer: 8 * 1024 * 1024 });
  const split = stdout.lastIndexOf("\n");
  return {
    status: Number(stdout.slice(split + 1).trim()),
    body: stdout.slice(0, split),
  };
}

/** A person's own browser: their own context, their own cookies. */
async function openPerson(browser, authorization) {
  const context = await browser.newContext();
  // The staging Basic Auth gate. Set as an explicit header rather than relying
  // on the browser's own challenge handling, so a 401 is a real failure of the
  // gate rather than an artifact of how the harness answers a prompt.
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

  return { context, page, consoleLines };
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

/** The session cookie, so curl can act as this person against the same API. */
async function sessionCookie(person) {
  const cookies = await person.context.cookies(APP_URL);
  const pairs = cookies.map((cookie) => `${cookie.name}=${cookie.value}`);
  if (pairs.length === 0) {
    throw new Error("no cookies on this context, so no session to borrow");
  }
  return pairs.join("; ");
}

async function main() {
  await rm(shots, { recursive: true, force: true });
  await mkdir(shots, { recursive: true });

  const credential = await readCredential();
  const [username, ...rest] = credential.split(":");
  const password = rest.join(":");
  const authorization =
    "Basic " + Buffer.from(`${username}:${password}`).toString("base64");

  const container = await startBrowserless();
  const browser = await chromium.connectOverCDP(
    `ws://127.0.0.1:${container.port}?token=${container.token}`,
  );

  let a;
  let b;
  const captured = {};

  try {
    a = await openPerson(browser, authorization);
    b = await openPerson(browser, authorization);

    // --- 1. User A: sign up and onboard an organization -------------------
    await signUp(a, userA);
    await a.page.click('button:has-text("Set up your organization")');
    await a.page.waitForSelector("#org-name");
    await a.page.fill("#org-name", organization.name);
    await a.page.fill("#org-slug", organization.slug);
    await a.page.click('button[type="submit"]');
    await a.page.waitForSelector('[data-testid="dashboard-heading"]', {
      timeout: 60_000,
    });
    const roleShown = (
      await a.page.textContent('[data-testid="active-role"]')
    ).trim();
    await shoot(a.page, "userA-dashboard");
    if (roleShown !== "owner") {
      throw new Error(`User A's role rendered as "${roleShown}", expected owner`);
    }
    record(
      "1. User A onboarded",
      `${userA.email} owns "${organization.name}" (${organization.slug}), role rendered as "${roleShown}"`,
    );

    // --- 2. User A: create two teams through the real UI -------------------
    await a.page.click('button:has-text("Teams")');
    await a.page.waitForSelector('[data-testid="create-team"]');
    for (const team of teams) {
      await a.page.fill("#team-name", team.name);
      await a.page.fill("#team-slug", team.slug);
      await a.page.click('[data-testid="create-team"]');
      await a.page.waitForSelector(`[data-testid="team-row-${team.slug}"]`, {
        timeout: 30_000,
      });
    }
    await shoot(a.page, "userA-two-teams");

    const teamRows = await queryRows(
      `select t.id, t.name, t.slug, t.archived_at
         from team t
         join organization o on o.id = t.organization_id
        where o.slug = $1
        order by t.created_at`,
      [organization.slug],
    );
    if (teamRows.length !== 2) {
      throw new Error(`expected 2 team rows in Postgres, got ${teamRows.length}`);
    }
    captured.teamCore = teamRows.find((row) => row.slug === "core");
    captured.teamDocs = teamRows.find((row) => row.slug === "docs");
    record(
      "2. two teams created through the UI",
      `Postgres has ${teamRows.map((row) => `${row.name} (${row.slug})`).join(", ")}`,
    );

    // --- 3. User B: a separate account, not in the organization ------------
    await signUp(b, userB);
    await shoot(b.page, "userB-signed-up");
    // A left join, so this returns one row whether or not a membership exists.
    // Asserting the row count first is what stops the membership check from
    // passing vacuously on an empty result, which is exactly what it would do if
    // the address did not match what was stored.
    const bBefore = await queryRows(
      `select u.id as user_id, m.id as member_id
         from "user" u
         left join member m on m.user_id = u.id
        where u.email = $1`,
      [userB.email],
    );
    if (bBefore.length !== 1) {
      throw new Error(
        `expected exactly one user row for User B, got ${bBefore.length}`,
      );
    }
    if (bBefore[0].member_id !== null) {
      throw new Error("User B already held a membership before being invited");
    }
    record(
      "3. User B signed up standalone",
      `${userB.email} exists with no member row of any kind`,
    );

    // --- 4. User A: invite User B, scoped to the first team -----------------
    await a.page.click('button:has-text("Members")');
    await a.page.waitForSelector('[data-testid="open-invite"]');
    await a.page.click('[data-testid="open-invite"]');
    await a.page.waitForSelector("#invite-email");
    await a.page.fill("#invite-email", userB.email);
    await a.page.selectOption("#invite-team", { label: teams[0].name });
    await shoot(a.page, "userA-invite-form");
    await a.page.click('[data-testid="send-invite"]');
    await a.page.waitForSelector('[data-testid="invite-sent"]', {
      timeout: 60_000,
    });
    await shoot(a.page, "userA-invite-sent");

    const invitations = await queryRows(
      `select i.id, i.email, i.role, i.status, i.team_id
         from invitation i
         join organization o on o.id = i.organization_id
        where o.slug = $1`,
      [organization.slug],
    );
    if (invitations.length !== 1) {
      throw new Error(
        `expected exactly one invitation row, got ${invitations.length}`,
      );
    }
    const invitation = invitations[0];
    if (invitation.team_id !== captured.teamCore.id) {
      throw new Error(
        `invitation named team ${invitation.team_id}, expected ${captured.teamCore.id}`,
      );
    }
    record(
      "4. User B invited, scoped to a team",
      `invitation for ${invitation.email} is ${invitation.status}, role ${invitation.role}, team "${teams[0].slug}"`,
    );

    // --- 5. User B: accept, through the link the mail carries ---------------
    await b.page.goto(`${APP_URL}/accept-invite?invitation=${invitation.id}`, {
      waitUntil: "networkidle",
    });
    await b.page.waitForSelector('[data-testid="accept-invite"]', {
      timeout: 60_000,
    });
    const invitedAddress = (
      await b.page.textContent('[data-testid="invitation-email"]')
    ).trim();
    await shoot(b.page, "userB-accept-page");
    await b.page.click('[data-testid="accept-invite"]');
    await b.page.waitForSelector('[data-testid="invite-accepted"]', {
      timeout: 60_000,
    });
    await shoot(b.page, "userB-accepted");
    record(
      "5. User B accepted through the real flow",
      `accept page showed the invitation was for ${invitedAddress}, and the accept succeeded`,
    );

    // --- 6. User A: add User B to the SECOND team too ----------------------
    await a.page.goto(`${APP_URL}/teams/${captured.teamDocs.id}`, {
      waitUntil: "networkidle",
    });
    await a.page.waitForSelector('[data-testid="member-picker"]', {
      timeout: 60_000,
    });
    await a.page.selectOption('[data-testid="member-picker"]', {
      label: userB.name,
    });
    await a.page.click('[data-testid="add-team-member"]');
    await a.page.waitForSelector(`[data-testid="team-member-${userB.email}"]`, {
      timeout: 30_000,
    });
    await shoot(a.page, "userA-second-team-membership");

    const memberships = await queryRows(
      `select t.slug
         from team_member tm
         join team t on t.id = tm.team_id
         join "user" u on u.id = tm.user_id
        where u.email = $1
        order by t.slug`,
      [userB.email],
    );
    const slugs = memberships.map((row) => row.slug);
    if (slugs.length !== 2) {
      throw new Error(
        `User B should be on two teams, Postgres says ${JSON.stringify(slugs)}`,
      );
    }
    record(
      "6. User B belongs to two teams",
      `team_member rows in Postgres: ${JSON.stringify(slugs)}`,
    );

    // --- 7. User A: mint a key, shown exactly once --------------------------
    await a.page.goto(`${APP_URL}/teams/${captured.teamCore.id}`, {
      waitUntil: "networkidle",
    });
    await a.page.waitForSelector('[data-testid="create-key"]', {
      timeout: 60_000,
    });
    await a.page.fill("#key-name", "verification-runner");
    await a.page.click('[data-testid="create-key"]');
    await a.page.waitForSelector('[data-testid="revealed-key-value"]', {
      timeout: 60_000,
    });
    const rawKey = (
      await a.page.textContent('[data-testid="revealed-key-value"]')
    ).trim();
    // Screenshot taken only AFTER the banner is dismissed, so no image in
    // .verification/ ever carries the key itself.
    await a.page.click('[data-testid="dismiss-key"]');
    await a.page.waitForSelector('[data-testid="keys-table"]');
    await shoot(a.page, "userA-keys-panel");

    const keyRows = await queryRows(
      `select k.id, k.name, k.key_prefix, k.last_used_at, k.revoked_at, t.slug
         from team_api_key k
         join team t on t.id = k.team_id
        where t.id = $1`,
      [captured.teamCore.id],
    );
    if (keyRows.length !== 1) {
      throw new Error(`expected one key row, got ${keyRows.length}`);
    }
    captured.key = keyRows[0];
    if (!rawKey.startsWith(captured.key.key_prefix)) {
      throw new Error("the stored prefix is not a prefix of the key that was shown");
    }
    if (captured.key.key_prefix.length >= rawKey.length) {
      throw new Error("the stored prefix is the whole key, which would publish it");
    }
    if (captured.key.last_used_at !== null) {
      throw new Error("a freshly minted key already had a last_used_at");
    }
    record(
      "7. key minted through the UI",
      `team "${captured.key.slug}" key "${captured.key.name}" stored with a ${captured.key.key_prefix.length}-character prefix of a ${rawKey.length}-character key, last_used_at null`,
    );

    // --- 8. The key resolves, and Postgres agrees it was used --------------
    const resolved = await curl(`${APP_URL}/v1/whoami-key`, {
      credential,
      headers: { "x-cf-key": rawKey },
    });
    if (resolved.status !== 200) {
      throw new Error(
        `whoami-key answered ${resolved.status}: ${resolved.body}`,
      );
    }
    const identity = JSON.parse(resolved.body);
    if (identity.teamId !== captured.teamCore.id) {
      throw new Error(
        `key resolved to team ${identity.teamId}, expected ${captured.teamCore.id}`,
      );
    }
    if (identity.keyName !== "verification-runner") {
      throw new Error(`key resolved to name "${identity.keyName}"`);
    }

    const afterUse = await queryRows(
      `select last_used_at from team_api_key where id = $1`,
      [captured.key.id],
    );
    if (afterUse[0].last_used_at === null) {
      throw new Error("last_used_at was still null after the key was used");
    }
    record(
      "8. key resolved and stamped",
      `whoami-key returned org ${identity.organizationId} / team "${captured.key.slug}" / key "${identity.keyName}"; Postgres last_used_at moved from null to ${afterUse[0].last_used_at}`,
    );

    // --- 9. Revoke through the UI, and the same call stops working ---------
    await a.page.reload({ waitUntil: "networkidle" });
    await a.page.waitForSelector(`[data-testid="revoke-key-${captured.key.id}"]`, {
      timeout: 60_000,
    });
    await a.page.click(`[data-testid="revoke-key-${captured.key.id}"]`);
    await a.page.waitForSelector(
      `[data-testid="key-status-${captured.key.id}"]:has-text("revoked")`,
      { timeout: 30_000 },
    );
    await shoot(a.page, "userA-key-revoked");

    const afterRevoke = await curl(`${APP_URL}/v1/whoami-key`, {
      credential,
      headers: { "x-cf-key": rawKey },
    });
    if (afterRevoke.status !== 401) {
      throw new Error(
        `a revoked key still answered ${afterRevoke.status}: ${afterRevoke.body}`,
      );
    }
    const revokedRow = await queryRows(
      `select revoked_at from team_api_key where id = $1`,
      [captured.key.id],
    );
    if (revokedRow[0].revoked_at === null) {
      throw new Error("revoked_at is still null after the UI reported a revoke");
    }
    record(
      "9. key revoked",
      `revoked_at set to ${revokedRow[0].revoked_at}; the same call now answers ${afterRevoke.status} ${afterRevoke.body.trim()}`,
    );

    // --- 10. The member-role 403, against the real API ---------------------
    // Not "the button was hidden". User B's own session cookie, lifted out of
    // their browser, pointed straight at the routes the UI does not offer them.
    const bCookie = await sessionCookie(b);
    const bCreateTeam = await curl(`${APP_URL}/v1/teams`, {
      credential,
      method: "POST",
      headers: { Cookie: bCookie },
      body: JSON.stringify({ name: "Shadow", slug: "shadow" }),
    });
    const bMintKey = await curl(
      `${APP_URL}/v1/teams/${captured.teamCore.id}/keys`,
      {
        credential,
        method: "POST",
        headers: { Cookie: bCookie },
        body: JSON.stringify({ name: "shadow-key" }),
      },
    );
    const bInvite = await curl(`${APP_URL}/v1/invitations`, {
      credential,
      method: "POST",
      headers: { Cookie: bCookie },
      body: JSON.stringify({ email: "nobody@example.test" }),
    });

    // A read still works, which is what proves the 403s were about the rule and
    // not about a session that simply failed to be sent.
    const bRead = await curl(`${APP_URL}/v1/teams`, {
      credential,
      headers: { Cookie: bCookie },
    });

    for (const [label, result] of [
      ["POST /v1/teams", bCreateTeam],
      ["POST /v1/teams/:id/keys", bMintKey],
      ["POST /v1/invitations", bInvite],
    ]) {
      if (result.status !== 403) {
        throw new Error(
          `${label} as a member answered ${result.status}, expected 403: ${result.body}`,
        );
      }
    }
    if (bRead.status !== 200) {
      throw new Error(
        `a member could not even read teams (${bRead.status}), so the 403s prove nothing`,
      );
    }
    const shadowTeams = await queryRows(
      `select t.id from team t join organization o on o.id = t.organization_id
        where o.slug = $1 and t.slug = 'shadow'`,
      [organization.slug],
    );
    if (shadowTeams.length !== 0) {
      throw new Error("the refused create-team call wrote a row anyway");
    }
    record(
      "10. member-role authorization holds against curl",
      `create-team ${bCreateTeam.status}, mint-key ${bMintKey.status}, invite ${bInvite.status}, all 403 with the same session that reads teams successfully (${bRead.status}); no row written`,
    );

    // --- 11. The member's own UI offers none of it -------------------------
    await b.page.goto(`${APP_URL}/teams`, { waitUntil: "networkidle" });
    await b.page.waitForSelector('[data-testid="teams-table"]', {
      timeout: 60_000,
    });
    const memberSeesCreate = await b.page.locator('[data-testid="create-team"]').count();
    await shoot(b.page, "userB-teams-readonly");
    await b.page.goto(`${APP_URL}/teams/${captured.teamCore.id}`, {
      waitUntil: "networkidle",
    });
    await b.page.waitForSelector('[data-testid="team-heading"]', {
      timeout: 60_000,
    });
    const memberSeesMint = await b.page.locator('[data-testid="create-key"]').count();
    await shoot(b.page, "userB-team-detail-readonly");
    if (memberSeesCreate !== 0 || memberSeesMint !== 0) {
      throw new Error(
        `a member was offered controls they cannot use (create-team ${memberSeesCreate}, create-key ${memberSeesMint})`,
      );
    }
    record(
      "11. the member's UI matches the rule",
      "neither the create-team control nor the mint-key control renders for a member",
    );
  } catch (error) {
    for (const [label, person] of [["userA", a], ["userB", b]]) {
      if (person === undefined) {
        continue;
      }
      await person.page
        .screenshot({ path: path.join(shots, `99-failure-${label}.png`), fullPage: true })
        .catch(() => {});
      console.error(
        `${label} at failure: ${person.page.url()}\n  console: ${JSON.stringify(person.consoleLines.slice(-15))}`,
      );
    }
    throw error;
  } finally {
    await browser.close().catch(() => {});
    await stopBrowserless(container);
  }

  // --- 12. The final state, in Postgres --------------------------------
  const orgMembers = await queryRows(
    `select u.email, m.role
       from member m
       join "user" u on u.id = m.user_id
       join organization o on o.id = m.organization_id
      where o.slug = $1
      order by m.created_at`,
    [organization.slug],
  );
  if (orgMembers.length !== 2) {
    throw new Error(
      `expected exactly two member rows, got ${JSON.stringify(orgMembers)}`,
    );
  }
  const byEmail = Object.fromEntries(
    orgMembers.map((row) => [row.email, row.role]),
  );
  if (byEmail[userA.email] !== "owner" || byEmail[userB.email] !== "member") {
    throw new Error(`roles were not owner/member: ${JSON.stringify(byEmail)}`);
  }

  const finalTeams = await queryRows(
    `select t.slug
       from team_member tm
       join team t on t.id = tm.team_id
       join "user" u on u.id = tm.user_id
      where u.email = $1
      order by t.slug`,
    [userB.email],
  );
  if (finalTeams.length !== 2) {
    throw new Error(
      `User B should hold exactly two team memberships, got ${JSON.stringify(finalTeams)}`,
    );
  }

  const finalKey = await queryRows(
    `select name, key_prefix, last_used_at, revoked_at from team_api_key where id = $1`,
    [captured.key.id],
  );
  if (finalKey[0].revoked_at === null || finalKey[0].last_used_at === null) {
    throw new Error(`the key row does not tell the story: ${JSON.stringify(finalKey[0])}`);
  }

  record(
    "12. final state confirmed in Postgres",
    `member rows ${JSON.stringify(byEmail)}; User B team_member slugs ${JSON.stringify(finalTeams.map((row) => row.slug))}; key "${finalKey[0].name}" used at ${finalKey[0].last_used_at} and revoked at ${finalKey[0].revoked_at}`,
  );

  console.log(`\nall ${steps.length} verification steps passed`);
  console.log(`organization: ${organization.name} (${organization.slug})`);
  console.log(`screenshots: ${shots}`);
}

main().catch((error) => {
  console.error(`\nverification FAILED: ${error.message}`);
  process.exitCode = 1;
});
