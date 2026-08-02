import { describe, expect, it } from "vitest";
import { SLUG_IMMUTABLE_MESSAGE } from "../src/auth-options.js";
import {
  call,
  createHarness,
  expectOk,
  invitedMember,
  ownedOrganization,
  signUp,
  type Harness,
  type SignedUpUser,
} from "./harness.js";

interface TeamBody {
  team: { id: string; name: string; slug: string; archivedAt: string | null };
}

async function createTeam(
  harness: Harness,
  user: SignedUpUser,
  name: string,
  slug: string,
): Promise<TeamBody["team"]> {
  const body = await expectOk<TeamBody>(
    await call(harness, user, "POST", "/v1/teams", { name, slug }),
    201,
  );
  return body.team;
}

describe("team creation", () => {
  it("creates a team with the slug the caller supplied", async () => {
    const harness = createHarness();
    const { owner } = await ownedOrganization(harness);

    const team = await createTeam(harness, owner, "Core", "core");

    expect(team.slug).toBe("core");
    expect(team.name).toBe("Core");
    expect(team.archivedAt).toBeNull();
    expect(harness.rows.team).toHaveLength(1);
  });

  it("refuses a malformed slug rather than deriving one", async () => {
    const harness = createHarness();
    const { owner } = await ownedOrganization(harness);

    const response = await call(harness, owner, "POST", "/v1/teams", {
      name: "Core Team",
      slug: "Core Team",
    });

    expect(response.status).toBe(400);
    expect(harness.rows.team).toHaveLength(0);
  });

  it("refuses a team with no slug at all", async () => {
    const harness = createHarness();
    const { owner } = await ownedOrganization(harness);

    const response = await call(harness, owner, "POST", "/v1/teams", {
      name: "Core",
    });

    expect(response.status).toBe(400);
    expect(harness.rows.team).toHaveLength(0);
  });

  it("refuses a duplicate slug within one organization", async () => {
    const harness = createHarness();
    const { owner } = await ownedOrganization(harness);
    await createTeam(harness, owner, "Core", "core");

    const response = await call(harness, owner, "POST", "/v1/teams", {
      name: "Core Again",
      slug: "core",
    });

    expect(response.status).toBe(409);
    expect(harness.rows.team).toHaveLength(1);
  });

  it("refuses an unauthenticated caller", async () => {
    const harness = createHarness();

    const response = await call(harness, null, "POST", "/v1/teams", {
      name: "Core",
      slug: "core",
    });

    expect(response.status).toBe(401);
  });
});

/**
 * The authorization rule, proven where a caller would actually hit it. The web
 * app also hides these controls from a member, but hiding a button is a
 * courtesy; this is the rule, and it holds against a caller who never loaded the
 * web app at all.
 */
describe("only an owner or admin may change an organization's shape", () => {
  async function orgWithMember() {
    const harness = createHarness();
    const { owner } = await ownedOrganization(harness);
    const team = await createTeam(harness, owner, "Core", "core");
    const member = await invitedMember(harness, owner, "member@example.test");
    return { harness, owner, member, team };
  }

  it("refuses a member creating a team", async () => {
    const { harness, member } = await orgWithMember();

    const response = await call(harness, member, "POST", "/v1/teams", {
      name: "Shadow",
      slug: "shadow",
    });

    expect(response.status).toBe(403);
    await expect(response.json()).resolves.toMatchObject({
      error: "only an organization owner or admin may do this",
    });
    expect(harness.rows.team).toHaveLength(1);
  });

  it("refuses a member minting a key", async () => {
    const { harness, member, team } = await orgWithMember();

    const response = await call(
      harness,
      member,
      "POST",
      `/v1/teams/${team.id}/keys`,
      { name: "ci" },
    );

    expect(response.status).toBe(403);
  });

  it("refuses a member renaming, archiving, or adding to a team", async () => {
    const { harness, member, team } = await orgWithMember();

    const renamed = await call(harness, member, "PATCH", `/v1/teams/${team.id}`, {
      name: "Renamed",
    });
    const archived = await call(
      harness,
      member,
      "POST",
      `/v1/teams/${team.id}/archive`,
    );
    const added = await call(
      harness,
      member,
      "POST",
      `/v1/teams/${team.id}/members`,
      { userId: "whoever" },
    );

    expect([renamed.status, archived.status, added.status]).toEqual([
      403, 403, 403,
    ]);
  });

  it("refuses a member linking or unlinking a repository", async () => {
    const { harness, member, team } = await orgWithMember();

    const linked = await call(harness, member, "POST", "/v1/repos", {
      teamId: team.id,
      repoId: "github.com/acme/web",
    });

    expect(linked.status).toBe(403);
  });

  it("still lets a member read teams and repositories", async () => {
    const { harness, member } = await orgWithMember();

    const teams = await expectOk<{ teams: unknown[] }>(
      await call(harness, member, "GET", "/v1/teams"),
    );
    const repos = await expectOk<{ repos: unknown[] }>(
      await call(harness, member, "GET", "/v1/repos"),
    );

    expect(teams.teams).toHaveLength(1);
    expect(repos.repos).toHaveLength(0);
  });
});

describe("renaming and archiving", () => {
  it("renames the display name and leaves the slug alone", async () => {
    const harness = createHarness();
    const { owner } = await ownedOrganization(harness);
    const team = await createTeam(harness, owner, "Core", "core");

    const body = await expectOk<TeamBody>(
      await call(harness, owner, "PATCH", `/v1/teams/${team.id}`, {
        name: "Core Platform",
      }),
    );

    expect(body.team.name).toBe("Core Platform");
    expect(body.team.slug).toBe("core");
  });

  it("refuses a rename that carries a slug, the same way an org rename does", async () => {
    const harness = createHarness();
    const { owner } = await ownedOrganization(harness);
    const team = await createTeam(harness, owner, "Core", "core");

    const response = await call(harness, owner, "PATCH", `/v1/teams/${team.id}`, {
      name: "Core Platform",
      slug: "core-platform",
    });

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toMatchObject({
      error: SLUG_IMMUTABLE_MESSAGE,
    });
    expect(harness.rows.team[0]?.slug).toBe("core");
  });

  it("archives without deleting the row", async () => {
    const harness = createHarness();
    const { owner } = await ownedOrganization(harness);
    const team = await createTeam(harness, owner, "Core", "core");

    const body = await expectOk<TeamBody>(
      await call(harness, owner, "POST", `/v1/teams/${team.id}/archive`),
    );

    expect(body.team.archivedAt).not.toBeNull();
    expect(harness.rows.team).toHaveLength(1);
  });

  it("refuses minting a key on an archived team", async () => {
    const harness = createHarness();
    const { owner } = await ownedOrganization(harness);
    const team = await createTeam(harness, owner, "Core", "core");
    await call(harness, owner, "POST", `/v1/teams/${team.id}/archive`);

    const response = await call(
      harness,
      owner,
      "POST",
      `/v1/teams/${team.id}/keys`,
      { name: "ci" },
    );

    expect(response.status).toBe(409);
  });
});

describe("team membership", () => {
  it("puts one person on as many teams as they are added to", async () => {
    const harness = createHarness();
    const { owner } = await ownedOrganization(harness);
    const first = await createTeam(harness, owner, "Core", "core");
    const second = await createTeam(harness, owner, "Docs", "docs");

    await invitedMember(harness, owner, "both@example.test", first.id);
    const memberUserId = harness.rows.user.find(
      (row) => row.email === "both@example.test",
    )?.id;
    expect(memberUserId).toBeDefined();

    await expectOk(
      await call(harness, owner, "POST", `/v1/teams/${second.id}/members`, {
        userId: memberUserId,
      }),
      201,
    );

    const memberships = harness.rows.teamMember.filter(
      (row) => row.userId === memberUserId,
    );
    expect(memberships.map((row) => row.teamId).sort()).toEqual(
      [first.id, second.id].sort(),
    );
  });

  it("refuses adding somebody who is not in the organization yet", async () => {
    const harness = createHarness();
    const { owner } = await ownedOrganization(harness);
    const team = await createTeam(harness, owner, "Core", "core");

    // Signed up, but never invited. Better Auth's own constraint, kept rather
    // than worked around: a team is a grouping inside an organization, so a
    // team membership with no organization membership belongs to nothing.
    await signUp(harness, "outsider@example.test");
    const outsiderId = harness.rows.user.find(
      (row) => row.email === "outsider@example.test",
    )?.id;

    const response = await call(
      harness,
      owner,
      "POST",
      `/v1/teams/${team.id}/members`,
      { userId: outsiderId },
    );

    expect(response.status).toBe(400);
    expect(harness.rows.teamMember).toHaveLength(0);
  });

  it("removes a team membership without touching the organization one", async () => {
    const harness = createHarness();
    const { owner } = await ownedOrganization(harness);
    const team = await createTeam(harness, owner, "Core", "core");
    await invitedMember(harness, owner, "leaver@example.test", team.id);
    const userId = harness.rows.user.find(
      (row) => row.email === "leaver@example.test",
    )?.id;

    await expectOk(
      await call(
        harness,
        owner,
        "DELETE",
        `/v1/teams/${team.id}/members/${userId}`,
      ),
    );

    expect(harness.rows.teamMember).toHaveLength(0);
    expect(harness.rows.member).toHaveLength(2);
  });

  it("lists a team's members to an owner who is not on that team", async () => {
    const harness = createHarness();
    const { owner } = await ownedOrganization(harness);
    const team = await createTeam(harness, owner, "Core", "core");
    await invitedMember(harness, owner, "onteam@example.test", team.id);

    const body = await expectOk<{ members: { email: string }[] }>(
      await call(harness, owner, "GET", `/v1/teams/${team.id}/members`),
    );

    expect(body.members.map((row) => row.email)).toEqual([
      "onteam@example.test",
    ]);
  });
});

describe("organization scoping", () => {
  it("answers 404 for a team id belonging to another organization", async () => {
    const harness = createHarness();
    const { owner } = await ownedOrganization(harness);
    const team = await createTeam(harness, owner, "Core", "core");

    const stranger = await signUp(harness, "stranger@example.test");
    await expectOk(
      await call(harness, stranger, "POST", "/v1/onboarding", {
        organizationName: "Other Co",
        organizationSlug: "other-co",
      }),
      201,
    );

    const response = await call(
      harness,
      stranger,
      "GET",
      `/v1/teams/${team.id}/keys`,
    );

    expect(response.status).toBe(404);
  });
});
