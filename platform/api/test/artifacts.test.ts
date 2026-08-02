import { createVerify } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  artifactKeyPrefix,
  artifactViewerUrl,
  normalizeArtifactPath,
  parseArtifactManifest,
  viewerResource,
} from "../src/artifacts.js";
import {
  CROCKFORD_ALPHABET,
  looksLikeShortId,
  newShortId,
  newUlid,
  SHORT_ID_LENGTH,
} from "../src/ids.js";
import { ValidationError } from "../src/validation.js";
import {
  call,
  createHarness,
  expectOk,
  invitedMember,
  ownedOrganization,
  signUp,
  TEST_ARTIFACTS_ORIGIN,
  TEST_KEY_PAIR_ID,
  TEST_SIGNER_PUBLIC_KEY,
  type Harness,
  type SignedUpUser,
} from "./harness.js";

/**
 * The artifacts service, from the identifiers up.
 *
 * Three layers get their own tests, and the split is deliberate. The id and path
 * helpers are pure and are tested without an app at all, because they are what
 * stands between a caller's string and a writable S3 key. The signing is tested
 * by actually verifying a signature with the public half of the key, so a
 * passing test means CloudFront would accept the cookie rather than merely that
 * a string was produced. The routes are driven through the real app, the real
 * Better Auth configuration and the real organization plugin, so an
 * authorization result here is the same one the deployed function would give.
 */

interface CreatedArtifact {
  artifactId: string;
  shortId: string;
  viewerUrl: string;
  uploads: { path: string; url: string }[];
}

const FIXTURE_FILES = [
  { path: "index.html", contentType: "text/html", bytes: 11 },
  { path: "assets/manifest.json", contentType: "application/json", bytes: 2 },
];

async function teamWithMember(
  harness: Harness,
): Promise<{
  owner: SignedUpUser;
  organizationId: string;
  slug: string;
  teamId: string;
  teamSlug: string;
}> {
  const org = await ownedOrganization(harness);
  const created = await expectOk<{ team: { id: string; slug: string } }>(
    await call(harness, org.owner, "POST", "/v1/teams", {
      name: "Core Platform",
      slug: "core",
    }),
    201,
  );
  // The owner is not put on the team by creating it, so the membership the
  // routes actually check is created explicitly here, exactly as the UI does.
  const ownerId = harness.rows.user.find(
    (row) => row.email === org.owner.email,
  )?.id;
  await expectOk(
    await call(
      harness,
      org.owner,
      "POST",
      `/v1/teams/${created.team.id}/members`,
      { userId: ownerId },
    ),
    201,
  );
  return {
    ...org,
    teamId: created.team.id,
    teamSlug: created.team.slug,
  };
}

async function publish(
  harness: Harness,
  user: SignedUpUser,
  teamId: string,
  overrides: Record<string, unknown> = {},
): Promise<CreatedArtifact> {
  return expectOk<CreatedArtifact>(
    await call(harness, user, "POST", "/v1/artifacts", {
      teamId,
      status: "pass",
      files: FIXTURE_FILES,
      ...overrides,
    }),
    201,
  );
}

describe("identifiers", () => {
  it("mints short ids from the Crockford alphabet only", () => {
    for (let attempt = 0; attempt < 200; attempt += 1) {
      const id = newShortId();
      expect(id).toHaveLength(SHORT_ID_LENGTH);
      expect(looksLikeShortId(id)).toBe(true);
      for (const character of id) {
        expect(CROCKFORD_ALPHABET).toContain(character);
      }
    }
  });

  it("excludes the characters that are misread", () => {
    // I, L, O and U are absent by design: the first three are confusable with
    // one and zero, and the fourth is what keeps an id from spelling a word.
    for (const character of "ILOU") {
      expect(CROCKFORD_ALPHABET).not.toContain(character);
    }
  });

  it("rejects anything that is not a short id", () => {
    expect(looksLikeShortId("")).toBe(false);
    expect(looksLikeShortId("SHORT")).toBe(false);
    expect(looksLikeShortId("abcdefghij")).toBe(false);
    // Right length, wrong alphabet: L and O are not in it.
    expect(looksLikeShortId("ABCDELOABC")).toBe(false);
  });

  it("sorts ULIDs by the time they were minted", () => {
    const earlier = newUlid(1_700_000_000_000);
    const later = newUlid(1_700_000_000_001);
    expect(earlier < later).toBe(true);
    expect(newUlid(0) < newUlid(Date.now())).toBe(true);
  });

  it("does not repeat a ULID inside one millisecond", () => {
    const minted = new Set<string>();
    for (let attempt = 0; attempt < 500; attempt += 1) {
      minted.add(newUlid(1_700_000_000_000));
    }
    expect(minted.size).toBe(500);
  });
});

describe("artifact paths", () => {
  it("builds a key prefix from two slugs and a short id", () => {
    expect(artifactKeyPrefix("acme", "core", "ABCDEFGHJK")).toBe(
      "acme/core/ABCDEFGHJK/",
    );
  });

  it("accepts an ordinary relative path", () => {
    expect(normalizeArtifactPath("index.html")).toBe("index.html");
    expect(normalizeArtifactPath("assets/app.css")).toBe("assets/app.css");
    expect(normalizeArtifactPath("  report.json  ")).toBe("report.json");
  });

  it("refuses every way out of its own prefix", () => {
    // Each of these, allowed through, would produce a presigned PUT for a key
    // outside the artifact the caller was authorised for.
    for (const bad of [
      "/etc/passwd",
      "../other-team/index.html",
      "assets/../../escape.html",
      "./index.html",
      "assets//app.css",
      "assets\\app.css",
      "",
      "   ",
    ]) {
      expect(() => normalizeArtifactPath(bad)).toThrow(ValidationError);
    }
  });

  it("refuses a path carrying a control character", () => {
    expect(() =>
      normalizeArtifactPath(`index${String.fromCharCode(10)}.html`),
    ).toThrow(ValidationError);
  });

  it("builds a viewer URL under the entry prefix and a resource under the key prefix", () => {
    const prefix = artifactKeyPrefix("acme", "core", "ABCDEFGHJK");
    const viewer = artifactViewerUrl(TEST_ARTIFACTS_ORIGIN, prefix);
    const resource = viewerResource(TEST_ARTIFACTS_ORIGIN, "acme", "core");

    expect(viewer).toBe(`${TEST_ARTIFACTS_ORIGIN}/v/acme/core/ABCDEFGHJK/`);
    expect(resource).toBe(`${TEST_ARTIFACTS_ORIGIN}/acme/core/*`);

    // The cookie resource covers the OBJECT path, not the entry point, and that
    // is the whole arrangement in one assertion: the entry point is unprotected
    // because it serves nothing, and the path it redirects onto is the one the
    // cookie has to cover.
    const objectPath = viewer.replace(`${TEST_ARTIFACTS_ORIGIN}/v/`, "");
    expect(`${TEST_ARTIFACTS_ORIGIN}/${objectPath}index.html`).toContain(
      resource.slice(0, -1),
    );
  });
});

describe("the manifest", () => {
  it("requires a team, a status and at least one file", () => {
    expect(() => parseArtifactManifest({})).toThrow(ValidationError);
    expect(() =>
      parseArtifactManifest({ teamId: "t", status: "pass", files: [] }),
    ).toThrow(ValidationError);
    expect(() =>
      parseArtifactManifest({ teamId: "t", status: "maybe", files: FIXTURE_FILES }),
    ).toThrow(ValidationError);
  });

  it("refuses the same path twice", () => {
    expect(() =>
      parseArtifactManifest({
        teamId: "t",
        status: "pass",
        files: [
          { path: "index.html", bytes: 1 },
          { path: "index.html", bytes: 2 },
        ],
      }),
    ).toThrow(ValidationError);
  });

  it("defaults a missing content type rather than guessing one", () => {
    const manifest = parseArtifactManifest({
      teamId: "t",
      status: "warn",
      files: [{ path: "report.bin", bytes: 4 }],
    });
    expect(manifest.files[0]?.contentType).toBe("application/octet-stream");
  });

  it("refuses a digest that is not a sha-256", () => {
    expect(() =>
      parseArtifactManifest({
        teamId: "t",
        status: "pass",
        files: [{ path: "a", bytes: 1, sha256: "nope" }],
      }),
    ).toThrow(ValidationError);
  });
});

describe("publishing an artifact", () => {
  it("creates the rows, the prefix and one presigned upload per file", async () => {
    const harness = createHarness();
    const team = await teamWithMember(harness);

    const created = await publish(harness, team.owner, team.teamId);

    expect(looksLikeShortId(created.shortId)).toBe(true);
    expect(created.viewerUrl).toBe(
      `${TEST_ARTIFACTS_ORIGIN}/v/${team.slug}/${team.teamSlug}/${created.shortId}/`,
    );
    expect(created.uploads.map((upload) => upload.path).sort()).toEqual([
      "assets/manifest.json",
      "index.html",
    ]);

    // Every URL is for a key under this artifact's own prefix and nowhere else.
    const prefix = `${team.slug}/${team.teamSlug}/${created.shortId}/`;
    for (const key of harness.storage.signedUploads()) {
      expect(key.startsWith(prefix)).toBe(true);
    }

    const files = await harness.platformStore.listArtifactFiles(
      created.artifactId,
    );
    expect(files.map((file) => file.path)).toEqual([
      "assets/manifest.json",
      "index.html",
    ]);
    const row = await harness.platformStore.findArtifactById(
      created.artifactId,
    );
    expect(row?.keyPrefix).toBe(prefix);
    expect(row?.publishedAt).toBeNull();
    expect(row?.byteSize).toBe(13);
  });

  it("refuses somebody who is not on the team", async () => {
    const harness = createHarness();
    const team = await teamWithMember(harness);
    // In the organization, but never added to the team.
    const outsider = await invitedMember(
      harness,
      team.owner,
      "outsider@example.test",
    );

    const response = await call(harness, outsider, "POST", "/v1/artifacts", {
      teamId: team.teamId,
      status: "pass",
      files: FIXTURE_FILES,
    });
    expect(response.status).toBe(403);
  });

  it("hides a team belonging to another organization behind a 404", async () => {
    const harness = createHarness();
    const team = await teamWithMember(harness);

    const stranger = await signUp(harness, "stranger@example.test");
    await expectOk(
      await call(harness, stranger, "POST", "/v1/onboarding", {
        organizationName: "Other",
        organizationSlug: "other-org",
      }),
      201,
    );

    const response = await call(harness, stranger, "POST", "/v1/artifacts", {
      teamId: team.teamId,
      status: "pass",
      files: FIXTURE_FILES,
    });
    // 404, not 403: a caller in another organization has no business learning
    // that the id exists.
    expect(response.status).toBe(404);
  });

  it("refuses a caller with no session at all", async () => {
    const harness = createHarness();
    const team = await teamWithMember(harness);

    const response = await call(harness, null, "POST", "/v1/artifacts", {
      teamId: team.teamId,
      status: "pass",
      files: FIXTURE_FILES,
    });
    expect(response.status).toBe(401);
  });

  it("refuses a path that would escape the prefix", async () => {
    const harness = createHarness();
    const team = await teamWithMember(harness);

    const response = await call(harness, team.owner, "POST", "/v1/artifacts", {
      teamId: team.teamId,
      status: "pass",
      files: [{ path: "../elsewhere/index.html", bytes: 1 }],
    });
    expect(response.status).toBe(400);
    // Nothing was signed, so nothing could have been written.
    expect(harness.storage.signedUploads()).toEqual([]);
  });
});

describe("completing an artifact", () => {
  it("publishes with no note when the upload matches", async () => {
    const harness = createHarness();
    const team = await teamWithMember(harness);
    const created = await publish(harness, team.owner, team.teamId);
    const prefix = `${team.slug}/${team.teamSlug}/${created.shortId}/`;

    harness.storage.put(`${prefix}index.html`, "hello world");
    harness.storage.put(`${prefix}assets/manifest.json`, "{}");

    const completed = await expectOk<{
      artifact: { publishedAt: string | null };
      note: string | null;
    }>(
      await call(
        harness,
        team.owner,
        "POST",
        `/v1/artifacts/${created.artifactId}/complete`,
      ),
    );

    expect(completed.note).toBeNull();
    expect(completed.artifact.publishedAt).not.toBeNull();
  });

  it("records a note rather than refusing when a file never arrived", async () => {
    const harness = createHarness();
    const team = await teamWithMember(harness);
    const created = await publish(harness, team.owner, team.teamId);
    const prefix = `${team.slug}/${team.teamSlug}/${created.shortId}/`;

    // Only one of the two files uploaded, and the one that did is the wrong
    // size. Both are findings; neither is a failure.
    harness.storage.put(`${prefix}index.html`, "not eleven bytes at all");

    const completed = await expectOk<{
      artifact: { publishedAt: string | null };
      note: string | null;
    }>(
      await call(
        harness,
        team.owner,
        "POST",
        `/v1/artifacts/${created.artifactId}/complete`,
      ),
    );

    expect(completed.note).toContain("assets/manifest.json was never uploaded");
    expect(completed.note).toContain("index.html declared 11 bytes");
    // Published anyway: the bytes are in the bucket and refusing would only
    // make them unreachable.
    expect(completed.artifact.publishedAt).not.toBeNull();
  });
});

describe("listing artifacts", () => {
  it("returns a team's artifacts newest first and pages by cursor", async () => {
    const harness = createHarness();
    const team = await teamWithMember(harness);

    const ids: string[] = [];
    for (let index = 0; index < 3; index += 1) {
      ids.push((await publish(harness, team.owner, team.teamId)).artifactId);
    }

    const first = await expectOk<{
      artifacts: { id: string }[];
      nextCursor: string | null;
    }>(
      await call(
        harness,
        team.owner,
        "GET",
        `/v1/artifacts?teamId=${team.teamId}&limit=2`,
      ),
    );
    expect(first.artifacts).toHaveLength(2);
    expect(first.nextCursor).not.toBeNull();

    const second = await expectOk<{
      artifacts: { id: string }[];
      nextCursor: string | null;
    }>(
      await call(
        harness,
        team.owner,
        "GET",
        `/v1/artifacts?teamId=${team.teamId}&limit=2&before=${first.nextCursor}`,
      ),
    );
    expect(second.artifacts).toHaveLength(1);
    expect(second.nextCursor).toBeNull();

    // Every id appears exactly once across the two pages, which an offset
    // cursor could not promise under a concurrent insert.
    const seen = [...first.artifacts, ...second.artifacts].map((row) => row.id);
    expect([...seen].sort()).toEqual([...ids].sort());
  });

  it("lets an organization member who is not on the team read the listing", async () => {
    const harness = createHarness();
    const team = await teamWithMember(harness);
    await publish(harness, team.owner, team.teamId);
    const member = await invitedMember(
      harness,
      team.owner,
      "reader@example.test",
    );

    const listed = await expectOk<{ artifacts: unknown[] }>(
      await call(
        harness,
        member,
        "GET",
        `/v1/artifacts?teamId=${team.teamId}`,
      ),
    );
    expect(listed.artifacts).toHaveLength(1);
  });
});

describe("authorizing a browser", () => {
  it("sets three signed cookies a verifier accepts", async () => {
    const harness = createHarness();
    const team = await teamWithMember(harness);

    const response = await call(
      harness,
      team.owner,
      "GET",
      `/v1/artifacts/authorize?teamId=${team.teamId}`,
    );
    expect(response.status).toBe(200);

    const cookies = response.headers.getSetCookie();
    expect(cookies).toHaveLength(3);

    const byName = new Map(
      cookies.map((cookie) => {
        const [pair = ""] = cookie.split(";", 1);
        const separator = pair.indexOf("=");
        return [pair.slice(0, separator), pair.slice(separator + 1)];
      }),
    );
    expect([...byName.keys()].sort()).toEqual([
      "CloudFront-Key-Pair-Id",
      "CloudFront-Policy",
      "CloudFront-Signature",
    ]);
    expect(byName.get("CloudFront-Key-Pair-Id")).toBe(TEST_KEY_PAIR_ID);

    // Every cookie carries the attributes that make it reach the artifacts host
    // and no script.
    for (const cookie of cookies) {
      expect(cookie).toContain("Domain=.staging.example.test");
      expect(cookie).toContain("Secure");
      expect(cookie).toContain("HttpOnly");
      expect(cookie).toContain("SameSite=Lax");
    }

    // The real check: the signature verifies against the public half of the
    // key, which is what CloudFront does with the key group's public key. The
    // cookie encoding replaces the three base64 characters that are unsafe in a
    // cookie, so it is reversed before verifying.
    const decode = (value: string) =>
      Buffer.from(
        value.replaceAll("-", "+").replaceAll("_", "=").replaceAll("~", "/"),
        "base64",
      );
    const policy = decode(byName.get("CloudFront-Policy") ?? "");
    const signature = decode(byName.get("CloudFront-Signature") ?? "");

    const verifier = createVerify("RSA-SHA1");
    verifier.update(policy);
    expect(verifier.verify(TEST_SIGNER_PUBLIC_KEY, signature)).toBe(true);

    // And the policy names this team's prefix, not the whole host.
    const parsed = JSON.parse(policy.toString("utf8")) as {
      Statement: { Resource: string }[];
    };
    expect(parsed.Statement[0]?.Resource).toBe(
      `${TEST_ARTIFACTS_ORIGIN}/${team.slug}/${team.teamSlug}/*`,
    );
  });

  it("returns a viewerPrefix that is a real prefix of a real viewer URL", async () => {
    const harness = createHarness();
    const team = await teamWithMember(harness);
    const created = await publish(harness, team.owner, team.teamId);

    const granted = await expectOk<{ viewerPrefix: string }>(
      await call(
        harness,
        team.owner,
        "GET",
        `/v1/artifacts/authorize?teamId=${team.teamId}`,
      ),
    );

    // The regression this pins: viewerPrefix was once built by asking for the
    // key prefix of an artifact with an empty short id, which produced a
    // trailing double slash. It looked right and it is not a prefix of
    // anything, so the web app discarded every `next` it was given and dropped
    // people at a directory that does not exist. Live verification found it;
    // this keeps it found.
    // Checked after the scheme's own "//", which is the only legitimate one.
    expect(granted.viewerPrefix.slice("https://".length)).not.toContain("//");
    expect(created.viewerUrl.startsWith(granted.viewerPrefix)).toBe(true);
  });

  it("refuses an organization member who is not on the team, and sets nothing", async () => {
    const harness = createHarness();
    const team = await teamWithMember(harness);
    const outsider = await invitedMember(
      harness,
      team.owner,
      "not-on-team@example.test",
    );

    const response = await call(
      harness,
      outsider,
      "GET",
      `/v1/artifacts/authorize?teamId=${team.teamId}`,
    );
    expect(response.status).toBe(403);
    // The refusal has to be silent as well as loud: a 403 that still set the
    // cookies would be no refusal at all.
    expect(
      response.headers
        .getSetCookie()
        .filter((cookie) => cookie.startsWith("CloudFront-")),
    ).toEqual([]);
  });

  it("refuses an anonymous caller", async () => {
    const harness = createHarness();
    const team = await teamWithMember(harness);

    const response = await call(
      harness,
      null,
      "GET",
      `/v1/artifacts/authorize?teamId=${team.teamId}`,
    );
    expect(response.status).toBe(401);
  });
});

describe("the machine download path", () => {
  async function mintKey(
    harness: Harness,
    owner: SignedUpUser,
    teamId: string,
  ): Promise<string> {
    const minted = await expectOk<{ key: string }>(
      await call(harness, owner, "POST", `/v1/teams/${teamId}/keys`, {
        name: "ci",
      }),
      201,
    );
    return minted.key;
  }

  it("returns one presigned URL per file for a key scoped to that team", async () => {
    const harness = createHarness();
    const team = await teamWithMember(harness);
    const created = await publish(harness, team.owner, team.teamId);
    const key = await mintKey(harness, team.owner, team.teamId);

    const download = await expectOk<{
      files: { path: string; url: string }[];
    }>(
      await call(
        harness,
        null,
        "GET",
        `/v1/artifacts/${created.shortId}/download`,
        undefined,
        { "x-cf-key": key },
      ),
    );

    expect(download.files.map((file) => file.path).sort()).toEqual([
      "assets/manifest.json",
      "index.html",
    ]);
    const prefix = `${team.slug}/${team.teamSlug}/${created.shortId}/`;
    for (const file of download.files) {
      expect(file.url).toContain(`${prefix}${file.path}`);
      expect(file.url).toContain("X-Amz-Operation=GET");
    }
  });

  it("publishes through a key, recording the key name as the contributor", async () => {
    const harness = createHarness();
    const team = await teamWithMember(harness);
    const key = await mintKey(harness, team.owner, team.teamId);

    const created = await expectOk<CreatedArtifact>(
      await call(
        harness,
        null,
        "POST",
        "/v1/artifacts",
        { teamId: team.teamId, status: "fail", failCount: 2, files: FIXTURE_FILES },
        { "x-cf-key": key },
      ),
      201,
    );

    const row = await harness.platformStore.findArtifactById(
      created.artifactId,
    );
    expect(row?.contributorUserId).toBeNull();
    expect(row?.contributorLabel).toBe("ci");
    expect(row?.status).toBe("fail");
    expect(row?.failCount).toBe(2);
  });

  it("refuses a key scoped to a different team", async () => {
    const harness = createHarness();
    const team = await teamWithMember(harness);
    const created = await publish(harness, team.owner, team.teamId);

    const other = await expectOk<{ team: { id: string } }>(
      await call(harness, team.owner, "POST", "/v1/teams", {
        name: "Docs",
        slug: "docs",
      }),
      201,
    );
    const otherKey = await mintKey(harness, team.owner, other.team.id);

    const response = await call(
      harness,
      null,
      "GET",
      `/v1/artifacts/${created.shortId}/download`,
      undefined,
      { "x-cf-key": otherKey },
    );
    // 404, because a short id on somebody else's team is indistinguishable
    // from one that does not exist.
    expect(response.status).toBe(404);
  });

  it("refuses a caller with no key", async () => {
    const harness = createHarness();
    const team = await teamWithMember(harness);
    const created = await publish(harness, team.owner, team.teamId);

    const response = await call(
      harness,
      team.owner,
      "GET",
      `/v1/artifacts/${created.shortId}/download`,
    );
    // A session is not a substitute here: this route is the machine path and
    // answers only to a key.
    expect(response.status).toBe(401);
  });

  it("refuses something that is not a short id before touching the database", async () => {
    const harness = createHarness();
    const team = await teamWithMember(harness);
    const key = await mintKey(harness, team.owner, team.teamId);

    const response = await call(
      harness,
      null,
      "GET",
      "/v1/artifacts/not-a-short-id/download",
      undefined,
      { "x-cf-key": key },
    );
    expect(response.status).toBe(400);
  });
});
