#!/usr/bin/env node
/**
 * The phase 5 end-to-end run: publishing a findings artifact, and the two ways
 * of reading one back.
 *
 * Same harness as verify/run.mjs and verify/teams.mjs, and deliberately so: the
 * digest-pinned browserless Chromium container this repo standardises on
 * (scripts/change_docker.rb), driven with Playwright over CDP, torn down on
 * every exit path. No host browser, no second automation library.
 *
 * What makes this run worth more than a UI test is that almost none of it is a
 * UI test. The claims that matter here are about an edge nobody can see from
 * inside the app: that CloudFront refuses an unsigned request, that it accepts a
 * signed one, that a presigned URL really does move bytes, and that the bucket
 * behind all of it is unreachable on its own. Each of those is checked with curl
 * against the live host, and the rows are checked against Postgres through the
 * cf-platform-migrate `query` action rather than against what a screen said.
 *
 * The browser appears exactly once, for the one claim only a browser can make:
 * that a person following a link to a run they have never opened before ends up
 * looking at the run.
 *
 *   AWS_PROFILE=personal node verify/artifacts.mjs
 */
import { execFile, spawn } from "node:child_process";
import { createHash } from "node:crypto";
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
const ARTIFACTS_URL =
  process.env.ARTIFACTS_URL ?? "https://artifacts.staging.changefabric.org";
const ARTIFACTS_BUCKET =
  process.env.ARTIFACTS_BUCKET ?? "changefabric-artifacts-staging";
const MIGRATE_FUNCTION = "cf-platform-migrate";
const REGION = "us-east-1";
const CREDENTIAL_PARAMETER = "/cf-platform/staging/basic-auth-credential";

const here = path.dirname(fileURLToPath(import.meta.url));
const shots = path.join(here, "..", ".verification");

const stamp = Date.now();
const owner = {
  name: "Artifacts Owner",
  email: `success+cfart-a-${stamp}@simulator.amazonses.com`,
  password: `verify-a-${stamp}-staging`,
};
const outsider = {
  name: "Artifacts Outsider",
  email: `success+cfart-b-${stamp}@simulator.amazonses.com`,
  password: `verify-b-${stamp}-staging`,
};
const organization = {
  name: `Artifacts Verification ${stamp}`,
  slug: `art-verify-${stamp}`,
};
const team = { name: "Core Platform", slug: "core" };

/**
 * The bundle a run publishes. Small, but a real HTML page with a marker in it,
 * because step 4 asserts that the marker is what the browser ended up rendering
 * rather than that some page loaded.
 */
const MARKER = `findings-${stamp}`;
const fixtures = [
  {
    path: "index.html",
    contentType: "text/html",
    body: [
      "<!doctype html>",
      '<html lang="en">',
      "<head><meta charset=\"utf-8\"><title>Findings</title></head>",
      `<body><h1 id="marker">${MARKER}</h1><p>Fixture findings run.</p></body>`,
      "</html>",
      "",
    ].join("\n"),
  },
  {
    path: "manifest.json",
    contentType: "application/json",
    body: JSON.stringify({ run: MARKER, lanes: ["a11y", "zap"] }) + "\n",
  },
  {
    path: "reports/summary.md",
    contentType: "text/markdown",
    body: `# Summary\n\nRun ${MARKER}: 1 fail, 2 warn.\n`,
  },
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
  const name = `cf-artifacts-verify-${stamp}`;

  // --rm, an ephemeral name, and a published loopback port only: the container
  // exists for this run and nothing else can reach it.
  const child = spawn(
    "docker",
    [
      "run", "--rm", "--name", name,
      "-p", `127.0.0.1:${port}:3000`,
      "-e", `TOKEN=${token}`,
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

/**
 * curl, returning the status, the headers and the body, so a 401 or a 302 is
 * data rather than a throw.
 *
 * -o - with a status suffix rather than -i, because the body of a fixture is
 * asserted on and mixing headers into it would make that assertion fuzzy. The
 * headers come back separately via -D.
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

function sha256(text) {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

function expect(condition, message) {
  if (!condition) {
    throw new Error(message);
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

  let a;
  let b;
  const captured = {};

  try {
    a = await openPerson(browser, authorization);
    b = await openPerson(browser, authorization);

    // --- 0. Setup: an organization, a team, a key, and an outsider ----------
    //
    // Done through the real API with a real session rather than through the UI,
    // because phase 4 already verified that the UI does this correctly and
    // repeating it here would only make this run slower and its failures less
    // specific.
    await signUp(a, owner);
    const aCookie = await sessionCookie(a);

    const onboarded = await curl(`${APP_URL}/v1/onboarding`, {
      credential,
      method: "POST",
      headers: { Cookie: aCookie, "Content-Type": "application/json" },
      body: JSON.stringify({
        organizationName: organization.name,
        organizationSlug: organization.slug,
      }),
    });
    expect(onboarded.status === 201, `onboarding answered ${onboarded.status}: ${onboarded.body}`);

    const createdTeam = await curl(`${APP_URL}/v1/teams`, {
      credential,
      method: "POST",
      headers: { Cookie: aCookie, "Content-Type": "application/json" },
      body: JSON.stringify(team),
    });
    expect(createdTeam.status === 201, `create team answered ${createdTeam.status}: ${createdTeam.body}`);
    captured.teamId = JSON.parse(createdTeam.body).team.id;

    const ownerRows = await queryRows(`select id from "user" where email = $1`, [
      owner.email,
    ]);
    expect(ownerRows.length === 1, "expected exactly one user row for the owner");
    captured.ownerUserId = ownerRows[0].id;

    const joined = await curl(
      `${APP_URL}/v1/teams/${captured.teamId}/members`,
      {
        credential,
        method: "POST",
        headers: { Cookie: aCookie, "Content-Type": "application/json" },
        body: JSON.stringify({ userId: captured.ownerUserId }),
      },
    );
    expect(joined.status === 201, `add team member answered ${joined.status}: ${joined.body}`);

    const mintedKey = await curl(
      `${APP_URL}/v1/teams/${captured.teamId}/keys`,
      {
        credential,
        method: "POST",
        headers: { Cookie: aCookie, "Content-Type": "application/json" },
        body: JSON.stringify({ name: "artifacts-verification" }),
      },
    );
    expect(mintedKey.status === 201, `mint key answered ${mintedKey.status}: ${mintedKey.body}`);
    captured.rawKey = JSON.parse(mintedKey.body).key;

    // The outsider: a real member of the organization, through the real
    // invitation flow, deliberately NOT put on the team. That is the person
    // step 6 is about, and inviting them properly is what makes the 403 a
    // statement about team membership rather than about being a stranger.
    const invitation = await curl(`${APP_URL}/v1/invitations`, {
      credential,
      method: "POST",
      headers: { Cookie: aCookie, "Content-Type": "application/json" },
      body: JSON.stringify({ email: outsider.email }),
    });
    expect(invitation.status === 201, `invite answered ${invitation.status}: ${invitation.body}`);
    const invitationId = JSON.parse(invitation.body).invitation.id;

    await signUp(b, outsider);
    await b.page.goto(`${APP_URL}/accept-invite?invitation=${invitationId}`, {
      waitUntil: "networkidle",
    });
    await b.page.waitForSelector('[data-testid="accept-invite"]', {
      timeout: 60_000,
    });
    await b.page.click('[data-testid="accept-invite"]');
    await b.page.waitForSelector('[data-testid="invite-accepted"]', {
      timeout: 60_000,
    });
    const bCookie = await sessionCookie(b);

    record(
      "0. setup",
      `org "${organization.slug}", team "${team.slug}" (${captured.teamId}), owner on the team, ${outsider.email} in the org but NOT on the team`,
    );

    // --- 1. Publish a run through the machine path -------------------------
    const created = await curl(`${APP_URL}/v1/artifacts`, {
      credential,
      method: "POST",
      headers: {
        "x-cf-key": captured.rawKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        teamId: captured.teamId,
        status: "fail",
        failCount: 1,
        warnCount: 2,
        branch: "verify/artifacts",
        project: "platform",
        headSha: "0".repeat(40),
        files: fixtures.map((fixture) => ({
          path: fixture.path,
          contentType: fixture.contentType,
          bytes: Buffer.byteLength(fixture.body),
          sha256: sha256(fixture.body),
        })),
      }),
    });
    expect(created.status === 201, `create artifact answered ${created.status}: ${created.body}`);
    const artifact = JSON.parse(created.body);
    captured.artifactId = artifact.artifactId;
    captured.shortId = artifact.shortId;
    captured.viewerUrl = artifact.viewerUrl;

    // The presigned PUTs. No credentials of any kind on these calls: the URL is
    // the whole authority, which is the property being demonstrated.
    for (const upload of artifact.uploads) {
      const fixture = fixtures.find((row) => row.path === upload.path);
      expect(fixture !== undefined, `no fixture for uploaded path ${upload.path}`);
      const put = await curl(upload.url, {
        method: "PUT",
        headers: { "Content-Type": fixture.contentType },
        body: fixture.body,
      });
      expect(
        put.status === 200,
        `presigned PUT for ${upload.path} answered ${put.status}: ${put.body}`,
      );
    }

    const completed = await curl(
      `${APP_URL}/v1/artifacts/${captured.artifactId}/complete`,
      {
        credential,
        method: "POST",
        headers: { "x-cf-key": captured.rawKey },
      },
    );
    expect(completed.status === 200, `complete answered ${completed.status}: ${completed.body}`);
    const completion = JSON.parse(completed.body);
    expect(
      completion.note === null,
      `completion recorded a mismatch note: ${completion.note}`,
    );
    expect(
      completion.artifact.publishedAt !== null,
      "complete did not set published_at",
    );

    record(
      "1. published through the machine path",
      `artifact ${captured.shortId} created with a team API key, ${artifact.uploads.length} presigned PUTs all answered 200, complete reported ${completion.uploadedBytes} uploaded bytes and no mismatch note; viewer ${captured.viewerUrl}`,
    );

    // --- 2. The viewer URL with NO Basic Auth ------------------------------
    const anonymous = await curl(captured.viewerUrl);
    expect(
      anonymous.status === 401,
      `viewer URL without Basic Auth answered ${anonymous.status}, expected 401`,
    );
    expect(
      /basic realm/i.test(anonymous.headers["www-authenticate"] ?? ""),
      `401 carried no Basic challenge: ${JSON.stringify(anonymous.headers)}`,
    );
    record(
      "2. no Basic Auth is refused at the edge",
      `${captured.viewerUrl} answered 401 with ${anonymous.headers["www-authenticate"]}`,
    );

    // --- 3. Basic Auth but no cookies --------------------------------------
    const cookieless = await curl(captured.viewerUrl, { credential });
    expect(
      cookieless.status === 302,
      `viewer URL with Basic Auth and no cookies answered ${cookieless.status}, expected 302`,
    );
    const location = cookieless.headers.location ?? "";
    expect(
      location.startsWith(`${APP_URL}/artifacts/authorize?`),
      `302 pointed at ${location}`,
    );
    expect(
      location.includes(`team=${team.slug}`),
      `302 did not name the team: ${location}`,
    );
    expect(
      location.includes(encodeURIComponent(captured.viewerUrl)),
      `302 did not carry the original URL: ${location}`,
    );
    record(
      "3. Basic Auth without cookies is redirected, not refused",
      `answered 302 to ${location}`,
    );

    // Also worth stating once: the OBJECT path, which is the one that actually
    // holds bytes, is refused by CloudFront itself rather than by the function.
    const objectPath = `${ARTIFACTS_URL}/${captured.viewerUrl.slice(`${ARTIFACTS_URL}/v/`.length)}index.html`;
    captured.objectPath = objectPath;
    const unsignedObject = await curl(objectPath, { credential });
    expect(
      unsignedObject.status === 403,
      `object path without cookies answered ${unsignedObject.status}, expected CloudFront's 403`,
    );
    record(
      "3b. the object path itself is refused by CloudFront",
      `${objectPath} answered 403 with valid Basic Auth and no signed cookie`,
    );

    // --- 4pre. The team's own findings page in the app ---------------------
    //
    // Taken before the artifacts host is visited, so the "Open" link this page
    // renders is the same URL step 4 then follows. That is the actual journey a
    // person takes, rather than a URL the harness happened to hold.
    await a.page.goto(`${APP_URL}/teams/${captured.teamId}/artifacts`, {
      waitUntil: "networkidle",
      timeout: 60_000,
    });
    await a.page.waitForSelector('[data-testid="artifacts-table"]', {
      timeout: 60_000,
    });
    const openLink = await a.page.getAttribute(
      `[data-testid="open-artifact-${captured.shortId}"]`,
      "href",
    );
    const statusShown = (
      await a.page.textContent(`[data-testid="artifact-status-${captured.shortId}"]`)
    ).trim();
    await shoot(a.page, "team-artifacts-index");
    expect(
      openLink === captured.viewerUrl,
      `the listing linked at ${openLink}, expected ${captured.viewerUrl}`,
    );
    expect(statusShown === "fail", `the listing showed status "${statusShown}"`);
    record(
      "4a. the team's findings page lists the run",
      `/teams/${captured.teamId}/artifacts rendered ${captured.shortId} with status "${statusShown}" and an Open link pointing at exactly ${openLink}`,
    );

    // --- 4. A real browser, following the link for the first time ----------
    const response = await a.page.goto(captured.viewerUrl, {
      waitUntil: "networkidle",
      timeout: 60_000,
    });
    await a.page.waitForSelector("#marker", { timeout: 60_000 });
    const rendered = (await a.page.textContent("#marker")).trim();
    await shoot(a.page, "artifact-rendered-in-browser");

    expect(
      rendered === MARKER,
      `the browser rendered "${rendered}", expected "${MARKER}"`,
    );
    expect(
      a.page.url().startsWith(ARTIFACTS_URL),
      `the browser ended up at ${a.page.url()}`,
    );
    expect(
      response !== null && response.status() === 200,
      `final navigation answered ${response?.status()}`,
    );
    record(
      "4. a browser with no cookie ends up looking at the run",
      `followed ${captured.viewerUrl}, was redirected through /artifacts/authorize, and rendered "${rendered}" at ${a.page.url()} with status ${response.status()}`,
    );

    // The cookies the app just handed this browser, which step 5 spends.
    const jar = await a.context.cookies(ARTIFACTS_URL);
    const cloudfront = jar.filter((cookie) =>
      cookie.name.startsWith("CloudFront-"),
    );
    expect(
      cloudfront.length === 3,
      `expected three CloudFront cookies, got ${JSON.stringify(cloudfront.map((c) => c.name))}`,
    );
    for (const cookie of cloudfront) {
      expect(cookie.httpOnly, `${cookie.name} was not HttpOnly`);
      expect(cookie.secure, `${cookie.name} was not Secure`);
      expect(
        cookie.domain === ".staging.changefabric.org",
        `${cookie.name} had domain ${cookie.domain}`,
      );
    }
    captured.cookieHeader = cloudfront
      .map((cookie) => `${cookie.name}=${cookie.value}`)
      .join("; ");
    record(
      "4b. the cookies are the ones CloudFront wants",
      `${cloudfront.map((c) => c.name).sort().join(", ")}, all HttpOnly, Secure, Domain=.staging.changefabric.org`,
    );

    // --- 5. The same cookies, spent by curl --------------------------------
    //
    // This is the claim the browser cannot make on its own. curl is not a
    // browser and has no session with this app at all: the only thing it
    // carries is the cookie trio, so a 200 here is CloudFront's own key-group
    // verification succeeding and nothing else.
    const signed = await curl(objectPath, {
      credential,
      headers: { Cookie: captured.cookieHeader },
    });
    expect(
      signed.status === 200,
      `object path with the browser's cookies answered ${signed.status}: ${signed.body}`,
    );
    const indexFixture = fixtures.find((row) => row.path === "index.html");
    expect(
      signed.body.includes(MARKER),
      "the fetched object did not contain the fixture marker",
    );
    expect(
      signed.body.trim() === indexFixture.body.trim(),
      "the fetched object did not match the fixture byte for byte",
    );
    record(
      "5. CloudFront's own enforcement accepts the cookies outside a browser",
      `curl with only the cookie trio fetched ${objectPath} (200, ${Buffer.byteLength(signed.body)} bytes) and the body matched the fixture exactly`,
    );

    // A tampered cookie is refused, which is what proves the 200 above was a
    // verification rather than a presence check.
    const tampered = captured.cookieHeader.replace(
      /CloudFront-Signature=(.)/,
      (match, first) => `CloudFront-Signature=${first === "A" ? "B" : "A"}`,
    );
    const forged = await curl(objectPath, {
      credential,
      headers: { Cookie: tampered },
    });
    expect(
      forged.status === 403,
      `a tampered signature answered ${forged.status}, expected 403`,
    );
    record(
      "5b. a tampered signature is refused",
      `changing one character of CloudFront-Signature turned the 200 into a ${forged.status}`,
    );

    // --- 6. Somebody who is not on the team --------------------------------
    const refused = await curl(
      `${APP_URL}/v1/artifacts/authorize?teamId=${captured.teamId}`,
      { credential, headers: { Cookie: bCookie } },
    );
    expect(
      refused.status === 403,
      `an organization member who is not on the team got ${refused.status}, expected 403`,
    );
    expect(
      !/set-cookie:\s*CloudFront-/i.test(refused.rawHeaders),
      `the 403 still set CloudFront cookies:\n${refused.rawHeaders}`,
    );
    // The same session CAN read the listing, which is what makes the 403 a
    // statement about the rule rather than about a session that failed to send.
    const outsiderList = await curl(
      `${APP_URL}/v1/artifacts?teamId=${captured.teamId}`,
      { credential, headers: { Cookie: bCookie } },
    );
    expect(
      outsiderList.status === 200,
      `the outsider could not even list artifacts (${outsiderList.status}), so the 403 proves nothing`,
    );
    record(
      "6. a non-member is refused and gets no cookies",
      `${outsider.email} is in the org but not on the team: authorize answered 403 with no Set-Cookie, while the same session lists artifacts successfully (${outsiderList.status})`,
    );

    // --- 7. The machine download path --------------------------------------
    const download = await curl(
      `${APP_URL}/v1/artifacts/${captured.shortId}/download`,
      { credential, headers: { "x-cf-key": captured.rawKey } },
    );
    expect(download.status === 200, `download answered ${download.status}: ${download.body}`);
    const downloadBody = JSON.parse(download.body);
    expect(
      downloadBody.files.length === fixtures.length,
      `expected ${fixtures.length} presigned URLs, got ${downloadBody.files.length}`,
    );

    for (const file of downloadBody.files) {
      const fixture = fixtures.find((row) => row.path === file.path);
      expect(fixture !== undefined, `download offered an unknown path ${file.path}`);
      // No credentials and no cookies. The URL is the whole authority.
      const fetched = await curl(file.url);
      expect(
        fetched.status === 200,
        `presigned GET for ${file.path} answered ${fetched.status}: ${fetched.body}`,
      );
      expect(
        fetched.body.trim() === fixture.body.trim(),
        `presigned GET for ${file.path} returned different bytes than were uploaded`,
      );
    }
    record(
      "7. the machine path returns working presigned URLs",
      `x-cf-key fetched ${downloadBody.files.length} presigned GET URLs (${downloadBody.files.map((f) => f.path).join(", ")}), and every one returned exactly the bytes that were uploaded, with no cookie and no credential`,
    );

    // --- 8. The bucket is not reachable on its own -------------------------
    const bucketKey = captured.viewerUrl.slice(`${ARTIFACTS_URL}/v/`.length);
    const direct = await curl(
      `https://${ARTIFACTS_BUCKET}.s3.us-east-1.amazonaws.com/${bucketKey}index.html`,
    );
    expect(
      direct.status === 403,
      `an unsigned request to the bucket answered ${direct.status}, expected 403`,
    );

    const unsigned = await run("aws", [
      "s3api", "get-object",
      "--no-sign-request",
      "--region", REGION,
      "--bucket", ARTIFACTS_BUCKET,
      "--key", `${bucketKey}index.html`,
      path.join(shots, ".should-not-exist"),
    ]).then(
      () => ({ failed: false, message: "the call SUCCEEDED" }),
      (error) => ({ failed: true, message: (error.stderr ?? "").trim().split("\n").pop() }),
    );
    expect(unsigned.failed, `aws s3api get-object --no-sign-request succeeded against ${ARTIFACTS_BUCKET}`);

    const publicAccess = await run("aws", [
      "s3api", "get-public-access-block",
      "--region", REGION,
      "--bucket", ARTIFACTS_BUCKET,
      "--query", "PublicAccessBlockConfiguration",
      "--output", "json",
    ]);
    const block = JSON.parse(publicAccess.stdout);
    for (const [name, value] of Object.entries(block)) {
      expect(value === true, `${name} is ${value}, expected true`);
    }
    record(
      "8. the bucket is private",
      `an unsigned HTTPS GET to the regional endpoint answered 403, aws s3api get-object --no-sign-request failed (${unsigned.message}), and all four public access blocks are true`,
    );

    // --- 9. The rows, in Postgres ------------------------------------------
    // Deferred to after the browser is torn down, below.
  } catch (error) {
    for (const [label, person] of [["owner", a], ["outsider", b]]) {
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
        `${label} at failure: ${person.page.url()}\n  console: ${JSON.stringify(person.consoleLines.slice(-15))}`,
      );
    }
    throw error;
  } finally {
    await browser.close().catch(() => {});
    await stopBrowserless(container);
  }

  // --- 9. The rows, in Postgres, not in the API's answer --------------------
  const artifactRows = await queryRows(
    `select a.id, a.short_id, a.status, a.fail_count, a.warn_count,
            a.byte_size, a.key_prefix, a.branch, a.project, a.head_sha,
            a.contributor_user_id, a.contributor_label,
            a.published_at, a.completion_note,
            t.slug as team_slug, o.slug as org_slug
       from artifact a
       join team t on t.id = a.team_id
       join organization o on o.id = a.organization_id
      where o.slug = $1`,
    [organization.slug],
  );
  if (artifactRows.length !== 1) {
    throw new Error(`expected exactly one artifact row, got ${artifactRows.length}`);
  }
  const row = artifactRows[0];

  const expectedPrefix = `${organization.slug}/${team.slug}/${row.short_id}/`;
  if (row.key_prefix !== expectedPrefix) {
    throw new Error(`key_prefix is ${row.key_prefix}, expected ${expectedPrefix}`);
  }
  if (row.short_id !== captured.shortId) {
    throw new Error(`Postgres short_id ${row.short_id} is not the API's ${captured.shortId}`);
  }
  if (row.published_at === null) {
    throw new Error("published_at is still null after complete reported success");
  }
  if (row.completion_note !== null) {
    throw new Error(`completion_note recorded ${row.completion_note}`);
  }
  // Published by a KEY, so there is no contributor user and the key's name is
  // the label. That is the machine case being recorded honestly.
  if (row.contributor_user_id !== null) {
    throw new Error("a key-published run recorded a contributor user");
  }
  if (row.contributor_label !== "artifacts-verification") {
    throw new Error(`contributor_label is ${row.contributor_label}`);
  }

  const declaredBytes = fixtures.reduce(
    (total, fixture) => total + Buffer.byteLength(fixture.body),
    0,
  );
  if (Number(row.byte_size) !== declaredBytes) {
    throw new Error(`byte_size is ${row.byte_size}, expected ${declaredBytes}`);
  }

  const fileRows = await queryRows(
    `select path, content_type, bytes, sha256
       from artifact_file
      where artifact_id = $1
      order by path`,
    [row.id],
  );
  if (fileRows.length !== fixtures.length) {
    throw new Error(`expected ${fixtures.length} artifact_file rows, got ${fileRows.length}`);
  }
  for (const fileRow of fileRows) {
    const fixture = fixtures.find((candidate) => candidate.path === fileRow.path);
    if (fixture === undefined) {
      throw new Error(`artifact_file has an unexpected path ${fileRow.path}`);
    }
    if (Number(fileRow.bytes) !== Buffer.byteLength(fixture.body)) {
      throw new Error(`${fileRow.path} bytes is ${fileRow.bytes}`);
    }
    if (fileRow.sha256 !== sha256(fixture.body)) {
      throw new Error(`${fileRow.path} sha256 does not match the uploaded body`);
    }
    if (fileRow.content_type !== fixture.contentType) {
      throw new Error(`${fileRow.path} content_type is ${fileRow.content_type}`);
    }
  }

  record(
    "9. Postgres agrees with what was uploaded",
    `artifact ${row.short_id} (${row.status}, ${row.fail_count} fail / ${row.warn_count} warn, ${row.byte_size} bytes) at key_prefix ${row.key_prefix}, published_at ${row.published_at}, no completion note, contributor label "${row.contributor_label}" and no contributor user; artifact_file rows ${JSON.stringify(fileRows.map((f) => `${f.path} (${f.bytes}b, ${f.content_type})`))} with every sha-256 matching the bytes that were PUT`,
  );

  // The objects really are in the bucket, under the prefix the row claims.
  const listed = await run("aws", [
    "s3api", "list-objects-v2",
    "--region", REGION,
    "--bucket", ARTIFACTS_BUCKET,
    "--prefix", row.key_prefix,
    "--query", "Contents[].{Key:Key,Size:Size}",
    "--output", "json",
  ]);
  const objects = JSON.parse(listed.stdout || "[]");
  if (objects.length !== fixtures.length) {
    throw new Error(`expected ${fixtures.length} objects under ${row.key_prefix}, got ${objects.length}`);
  }

  const encryption = await run("aws", [
    "s3api", "head-object",
    "--region", REGION,
    "--bucket", ARTIFACTS_BUCKET,
    "--key", `${row.key_prefix}index.html`,
    "--query", "{SSE:ServerSideEncryption,Key:SSEKMSKeyId}",
    "--output", "json",
  ]);
  const sse = JSON.parse(encryption.stdout);
  if (sse.SSE !== "aws:kms") {
    throw new Error(`the object is encrypted with ${sse.SSE}, expected aws:kms`);
  }

  record(
    "9b. the objects are in the bucket, encrypted under the platform CMK",
    `${objects.length} objects under ${row.key_prefix} (${objects.map((o) => `${o.Key.slice(row.key_prefix.length)} ${o.Size}b`).join(", ")}), index.html is ${sse.SSE} under ${sse.Key}`,
  );

  console.log(`\nall ${steps.length} verification steps passed`);
  console.log(`organization: ${organization.name} (${organization.slug})`);
  console.log(`artifact: ${captured.shortId} at ${captured.viewerUrl}`);
  console.log(`screenshots: ${shots}`);
}

main().catch((error) => {
  console.error(`\nverification FAILED: ${error.message}`);
  process.exitCode = 1;
});
