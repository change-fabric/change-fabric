import { describe, expect, it } from "vitest";
import type { StoredUser } from "./harness.js";
import {
  call,
  createHarness,
  expectOk,
  invitedMember,
  ownedOrganization,
  signUp,
} from "./harness.js";

/**
 * The migration surface: carrying a team's pre-hosted identity onto a real
 * team, and mapping the roster ids that identity was written in terms of.
 *
 * Everything here is asserted through the routes rather than against the store,
 * because the property that matters is what a migration tool run against a
 * repository actually observes, not what a row looks like.
 */

interface TeamBody {
  team: {
    id: string;
    slug: string;
    legacyTeamId: string | null;
    publicKeyEd25519: string | null;
  };
}

interface AliasBody {
  alias: {
    id: string;
    legacyContributorId: string;
    displayName: string;
    userId: string | null;
  };
  created: boolean;
}

const PUBLIC_KEY = "3BXo6b9PO7gy35dZT1i7Znsaky4sOPn9b6V5JwdnW+4=";

async function migratedTeam(slug = "core") {
  const harness = createHarness();
  const { owner } = await ownedOrganization(harness);
  const created = await expectOk<TeamBody>(
    await call(harness, owner, "POST", "/v1/teams", {
      name: "Core",
      slug,
      legacyTeamId: "acme-core",
      publicKeyEd25519: PUBLIC_KEY,
    }),
    201,
  );
  return { harness, owner, team: created.team };
}

describe("carrying a legacy team identity onto a hosted team", () => {
  it("stores both fields at creation and reads them back", async () => {
    const { harness, owner, team } = await migratedTeam();

    expect(team.legacyTeamId).toBe("acme-core");
    expect(team.publicKeyEd25519).toBe(PUBLIC_KEY);

    // The listing is what a second run of a migration reads to decide the team
    // is already there, so it has to carry the same two fields.
    const listed = await expectOk<{ teams: TeamBody["team"][] }>(
      await call(harness, owner, "GET", "/v1/teams"),
    );
    expect(listed.teams).toHaveLength(1);
    expect(listed.teams[0]?.legacyTeamId).toBe("acme-core");
    expect(listed.teams[0]?.publicKeyEd25519).toBe(PUBLIC_KEY);
  });

  it("leaves both null for a team created without a history", async () => {
    const harness = createHarness();
    const { owner } = await ownedOrganization(harness);

    const created = await expectOk<TeamBody>(
      await call(harness, owner, "POST", "/v1/teams", {
        name: "Docs",
        slug: "docs",
      }),
      201,
    );

    expect(created.team.legacyTeamId).toBeNull();
    expect(created.team.publicKeyEd25519).toBeNull();
  });

  it("refuses a legacy team id another team already claimed", async () => {
    const { harness, owner } = await migratedTeam();

    const response = await call(harness, owner, "POST", "/v1/teams", {
      name: "Core Again",
      slug: "core-again",
      legacyTeamId: "acme-core",
    });

    expect(response.status).toBe(409);
    const failure = (await response.json()) as { error: string };
    expect(failure.error).toContain("already claimed");
  });
});

describe("mapping a legacy roster onto a hosted team", () => {
  it("records the display name and leaves the account unlinked", async () => {
    const { harness, owner, team } = await migratedTeam();

    const body = await expectOk<AliasBody>(
      await call(harness, owner, "POST", `/v1/teams/${team.id}/aliases`, {
        legacyContributorId: "pst",
        displayName: "Patrick Taylor",
      }),
      201,
    );

    expect(body.created).toBe(true);
    expect(body.alias.legacyContributorId).toBe("pst");
    expect(body.alias.displayName).toBe("Patrick Taylor");
    // Nobody claimed this roster entry, so the history is attributed by name
    // and to no account. That is the point of the column being nullable.
    expect(body.alias.userId).toBeNull();
  });

  it("is idempotent: a second call returns the first row and creates nothing", async () => {
    const { harness, owner, team } = await migratedTeam();
    const payload = { legacyContributorId: "pst", displayName: "Patrick Taylor" };

    const first = await expectOk<AliasBody>(
      await call(harness, owner, "POST", `/v1/teams/${team.id}/aliases`, payload),
      201,
    );
    const second = await expectOk<AliasBody>(
      await call(harness, owner, "POST", `/v1/teams/${team.id}/aliases`, payload),
    );

    expect(second.created).toBe(false);
    expect(second.alias.id).toBe(first.alias.id);

    const listed = await expectOk<{ aliases: unknown[] }>(
      await call(harness, owner, "GET", `/v1/teams/${team.id}/aliases`),
    );
    expect(listed.aliases).toHaveLength(1);
  });

  it("links an account only once that address is verified", async () => {
    const { harness, owner, team } = await migratedTeam();
    const teammate = await invitedMember(harness, owner, "pat@example.test");

    // Sign-up does not verify an address, so at this point the account exists
    // and the alias must still refuse to claim it is the same person.
    const unlinked = await expectOk<AliasBody>(
      await call(harness, owner, "POST", `/v1/teams/${team.id}/aliases`, {
        legacyContributorId: "pat",
        displayName: "Pat Example",
        email: teammate.email,
      }),
      201,
    );
    expect(unlinked.alias.userId).toBeNull();

    // Verify it the way Better Auth would have, then map a second roster entry
    // for the same person and watch the link be made.
    const account = harness.rows.user.find(
      (row: StoredUser) => row.email === teammate.email,
    ) as (StoredUser & { emailVerified: boolean }) | undefined;
    expect(account).toBeDefined();
    if (account !== undefined) {
      account.emailVerified = true;
    }

    const linked = await expectOk<AliasBody>(
      await call(harness, owner, "POST", `/v1/teams/${team.id}/aliases`, {
        legacyContributorId: "pat-old",
        displayName: "Pat Example",
        email: teammate.email,
      }),
      201,
    );
    expect(linked.alias.userId).toBe(account?.id);
  });

  it("never takes a user id from the body", async () => {
    const { harness, owner, team } = await migratedTeam();
    const somebodyElse = await invitedMember(
      harness,
      owner,
      "victim@example.test",
    );
    const victimId = harness.rows.user.find(
      (row: StoredUser) => row.email === somebodyElse.email,
    )?.id;

    const body = await expectOk<AliasBody>(
      await call(harness, owner, "POST", `/v1/teams/${team.id}/aliases`, {
        legacyContributorId: "impostor",
        displayName: "Impostor",
        userId: victimId,
      }),
      201,
    );

    expect(body.alias.userId).toBeNull();
  });

  it("lets a member read the roster but not write to it", async () => {
    const { harness, owner, team } = await migratedTeam();
    await call(harness, owner, "POST", `/v1/teams/${team.id}/aliases`, {
      legacyContributorId: "pst",
      displayName: "Patrick Taylor",
    });
    const member = await invitedMember(harness, owner, "member@example.test");

    const read = await expectOk<{ aliases: unknown[] }>(
      await call(harness, member, "GET", `/v1/teams/${team.id}/aliases`),
    );
    expect(read.aliases).toHaveLength(1);

    const write = await call(
      harness,
      member,
      "POST",
      `/v1/teams/${team.id}/aliases`,
      { legacyContributorId: "nope", displayName: "Nope" },
    );
    expect(write.status).toBe(403);
  });

  it("refuses a team in another organization with 404, not 403", async () => {
    const { team } = await migratedTeam();

    // A whole separate organization, so the id is real but none of the
    // outsider's business. Answering 403 would confirm the id exists.
    const other = createHarness();
    const outsider = await signUp(other, "outsider@example.test");
    await expectOk(
      await call(other, outsider, "POST", "/v1/onboarding", {
        organizationName: "Other",
        organizationSlug: "other-org",
      }),
      201,
    );

    const response = await call(
      other,
      outsider,
      "GET",
      `/v1/teams/${team.id}/aliases`,
    );
    expect(response.status).toBe(404);
  });
});
