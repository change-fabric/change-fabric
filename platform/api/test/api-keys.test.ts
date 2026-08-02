import { describe, expect, it } from "vitest";
import {
  digestMatches,
  hashKey,
  keyIsUsable,
  keyPrefix,
  KEY_SCHEME,
  mintKey,
} from "../src/api-keys.js";
import {
  call,
  createHarness,
  expectOk,
  ownedOrganization,
  type Harness,
  type SignedUpUser,
} from "./harness.js";

interface MintResponse {
  key: string;
  apiKey: {
    id: string;
    name: string;
    keyPrefix: string;
    lastUsedAt: string | null;
    revokedAt: string | null;
  };
}

async function teamWithKey(name = "ci") {
  const harness = createHarness();
  const { owner, slug } = await ownedOrganization(harness);
  const created = await expectOk<{ team: { id: string } }>(
    await call(harness, owner, "POST", "/v1/teams", {
      name: "Core",
      slug: "core",
    }),
    201,
  );
  const minted = await expectOk<MintResponse>(
    await call(harness, owner, "POST", `/v1/teams/${created.team.id}/keys`, {
      name,
    }),
    201,
  );
  return { harness, owner, teamId: created.team.id, minted, slug };
}

function whoami(
  harness: Harness,
  key: string,
  user: SignedUpUser | null = null,
) {
  return call(harness, user, "GET", "/v1/whoami-key", undefined, {
    "x-cf-key": key,
  });
}

describe("key format", () => {
  it("carries the scheme and the organization slug so a loose key names itself", () => {
    const minted = mintKey("acme-research");

    expect(minted.raw.startsWith(`${KEY_SCHEME}_acme-research_`)).toBe(true);
    expect(minted.prefix.startsWith(`${KEY_SCHEME}_acme-research_`)).toBe(true);
    expect(minted.raw.startsWith(minted.prefix)).toBe(true);
  });

  it("stores a digest, never the key", () => {
    const minted = mintKey("acme");

    expect(minted.hash).toBe(hashKey(minted.raw));
    expect(minted.hash).not.toContain(minted.raw);
    expect(minted.raw).not.toContain(minted.hash);
  });

  it("gives two keys of one organization different prefixes", () => {
    const first = mintKey("acme");
    const second = mintKey("acme");

    expect(first.prefix).not.toBe(second.prefix);
  });

  it("survives a raw value with no separator at all", () => {
    expect(keyPrefix("nonsense")).toBe("nonsen");
    expect(keyPrefix("cfp_only-one-separator")).toBe("cfp_on");
  });

  /**
   * The secret is base64url, and that alphabet contains the underscore. A prefix
   * derived by searching backwards for a separator therefore lands inside the
   * secret and publishes nearly the whole key. This is the regression test for
   * that, written against the property rather than against one example: whatever
   * the random bytes happen to be, the prefix keeps six characters of them and
   * no more.
   */
  it("keeps the prefix short even when the secret contains underscores", () => {
    const expectedLength = `${KEY_SCHEME}_acme-research_`.length + 6;

    for (let attempt = 0; attempt < 200; attempt += 1) {
      const minted = mintKey("acme-research");

      expect(minted.prefix).toBe(minted.raw.slice(0, expectedLength));
      expect(minted.prefix.length).toBe(expectedLength);
      expect(minted.raw.length).toBeGreaterThan(expectedLength);
    }
  });

  it("compares digests without leaking a length", () => {
    expect(digestMatches("abc", "abc")).toBe(true);
    expect(digestMatches("abc", "abcd")).toBe(false);
  });

  it("treats a revoked or expired key as unusable", () => {
    const now = new Date("2026-01-01T00:00:00Z");

    expect(keyIsUsable({ revokedAt: null, expiresAt: null }, now)).toBe(true);
    expect(keyIsUsable({ revokedAt: now, expiresAt: null }, now)).toBe(false);
    expect(
      keyIsUsable({ revokedAt: null, expiresAt: new Date("2025-01-01") }, now),
    ).toBe(false);
    expect(
      keyIsUsable({ revokedAt: null, expiresAt: new Date("2027-01-01") }, now),
    ).toBe(true);
  });
});

describe("minting, listing, and revoking", () => {
  it("returns the raw key exactly once", async () => {
    const { harness, owner, teamId, minted } = await teamWithKey();

    expect(minted.key).toMatch(/^cfp_acme-research_/);

    const listed = await expectOk<{ keys: Record<string, unknown>[] }>(
      await call(harness, owner, "GET", `/v1/teams/${teamId}/keys`),
    );

    expect(listed.keys).toHaveLength(1);
    const row = listed.keys[0] ?? {};
    expect(row.keyPrefix).toBe(minted.apiKey.keyPrefix);
    // The two things a listing must never carry, asserted by absence rather
    // than by reading the code that builds it.
    expect(row).not.toHaveProperty("key");
    expect(row).not.toHaveProperty("keyHash");
    expect(JSON.stringify(listed)).not.toContain(minted.key);
  });

  it("resolves a key to its organization and team, and stamps last used", async () => {
    const { harness, owner, teamId, minted } = await teamWithKey("build");

    const before = await expectOk<{ keys: { lastUsedAt: string | null }[] }>(
      await call(harness, owner, "GET", `/v1/teams/${teamId}/keys`),
    );
    expect(before.keys[0]?.lastUsedAt).toBeNull();

    const resolved = await expectOk<{
      organizationId: string;
      teamId: string;
      keyName: string;
    }>(await whoami(harness, minted.key));

    expect(resolved.teamId).toBe(teamId);
    expect(resolved.keyName).toBe("build");
    expect(resolved.organizationId).toBe(harness.rows.organization[0]?.id);

    const after = await expectOk<{ keys: { lastUsedAt: string | null }[] }>(
      await call(harness, owner, "GET", `/v1/teams/${teamId}/keys`),
    );
    expect(after.keys[0]?.lastUsedAt).not.toBeNull();
  });

  it("stops resolving once the key is revoked", async () => {
    const { harness, owner, teamId, minted } = await teamWithKey();

    await expectOk(await whoami(harness, minted.key));

    const revoked = await expectOk<{ apiKey: { revokedAt: string | null } }>(
      await call(
        harness,
        owner,
        "POST",
        `/v1/teams/${teamId}/keys/${minted.apiKey.id}/revoke`,
      ),
    );
    expect(revoked.apiKey.revokedAt).not.toBeNull();

    const after = await whoami(harness, minted.key);
    expect(after.status).toBe(401);
  });

  it("answers the same 401 for a missing key and a key that never existed", async () => {
    const { harness } = await teamWithKey();

    const missing = await call(harness, null, "GET", "/v1/whoami-key");
    const wrong = await whoami(harness, "cfp_acme-research_not-a-real-key");

    expect(missing.status).toBe(401);
    expect(wrong.status).toBe(401);
    await expect(wrong.json()).resolves.toEqual({ error: "key is not valid" });
  });

  it("still needs the staging Basic Auth gate on top of the key", async () => {
    const { harness, minted } = await teamWithKey();

    const response = await harness.app.request("/v1/whoami-key", {
      headers: { "x-cf-key": minted.key },
    });

    expect(response.status).toBe(401);
    expect(response.headers.get("WWW-Authenticate")).toContain("Basic");
  });

  it("refuses to revoke a key belonging to another team", async () => {
    const { harness, owner, minted } = await teamWithKey();
    const other = await expectOk<{ team: { id: string } }>(
      await call(harness, owner, "POST", "/v1/teams", {
        name: "Docs",
        slug: "docs",
      }),
      201,
    );

    const response = await call(
      harness,
      owner,
      "POST",
      `/v1/teams/${other.team.id}/keys/${minted.apiKey.id}/revoke`,
    );

    // A refusal that changed nothing: the key is still the key it was.
    expect(response.status).toBe(404);
    expect((await whoami(harness, minted.key)).status).toBe(200);
  });
});
