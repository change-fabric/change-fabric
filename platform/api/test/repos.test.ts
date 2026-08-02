import { describe, expect, it } from "vitest";
import { normalizeRepoId } from "../src/validation.js";
import {
  call,
  createHarness,
  expectOk,
  ownedOrganization,
  signUp,
} from "./harness.js";

async function orgWithTeam() {
  const harness = createHarness();
  const { owner } = await ownedOrganization(harness);
  const created = await expectOk<{ team: { id: string } }>(
    await call(harness, owner, "POST", "/v1/teams", {
      name: "Core",
      slug: "core",
    }),
    201,
  );
  return { harness, owner, teamId: created.team.id };
}

describe("normalising a git remote", () => {
  it("reduces every spelling of one repository to the same id", () => {
    const expected = "github.com/acme/web";

    expect(normalizeRepoId("github.com/acme/web")).toBe(expected);
    expect(normalizeRepoId("https://github.com/acme/web")).toBe(expected);
    expect(normalizeRepoId("https://github.com/acme/web.git")).toBe(expected);
    expect(normalizeRepoId("git@github.com:acme/web.git")).toBe(expected);
    expect(normalizeRepoId("ssh://git@github.com/acme/web.git")).toBe(expected);
    expect(normalizeRepoId("https://user@github.com/acme/web/")).toBe(expected);
    expect(normalizeRepoId("  GitHub.com/Acme/Web  ")).toBe(expected);
  });
});

describe("linking a repository to a team", () => {
  it("stores the normalized form, whatever spelling arrived", async () => {
    const { harness, owner, teamId } = await orgWithTeam();

    const body = await expectOk<{ repo: { repoId: string } }>(
      await call(harness, owner, "POST", "/v1/repos", {
        teamId,
        repoId: "git@github.com:acme/web.git",
      }),
      201,
    );

    expect(body.repo.repoId).toBe("github.com/acme/web");
  });

  it("refuses a second claim on the same repository, however spelled", async () => {
    const { harness, owner, teamId } = await orgWithTeam();
    await call(harness, owner, "POST", "/v1/repos", {
      teamId,
      repoId: "github.com/acme/web",
    });

    const response = await call(harness, owner, "POST", "/v1/repos", {
      teamId,
      repoId: "https://github.com/acme/web.git",
    });

    expect(response.status).toBe(409);
    const listed = await expectOk<{ repos: unknown[] }>(
      await call(harness, owner, "GET", "/v1/repos"),
    );
    expect(listed.repos).toHaveLength(1);
  });

  it("refuses something that is not a repository remote", async () => {
    const { harness, owner, teamId } = await orgWithTeam();

    const response = await call(harness, owner, "POST", "/v1/repos", {
      teamId,
      repoId: "not-a-remote",
    });

    expect(response.status).toBe(400);
  });

  it("refuses a team from another organization", async () => {
    const { harness, teamId } = await orgWithTeam();
    const stranger = await signUp(harness, "stranger@example.test");
    await expectOk(
      await call(harness, stranger, "POST", "/v1/onboarding", {
        organizationName: "Other Co",
        organizationSlug: "other-co",
      }),
      201,
    );

    const response = await call(harness, stranger, "POST", "/v1/repos", {
      teamId,
      repoId: "github.com/other/thing",
    });

    expect(response.status).toBe(404);
  });

  it("unlinks only within the caller's own organization", async () => {
    const { harness, owner, teamId } = await orgWithTeam();
    const created = await expectOk<{ repo: { id: string } }>(
      await call(harness, owner, "POST", "/v1/repos", {
        teamId,
        repoId: "github.com/acme/web",
      }),
      201,
    );

    const stranger = await signUp(harness, "stranger@example.test");
    await expectOk(
      await call(harness, stranger, "POST", "/v1/onboarding", {
        organizationName: "Other Co",
        organizationSlug: "other-co",
      }),
      201,
    );

    const refused = await call(
      harness,
      stranger,
      "DELETE",
      `/v1/repos/${created.repo.id}`,
    );
    expect(refused.status).toBe(404);

    await expectOk(
      await call(harness, owner, "DELETE", `/v1/repos/${created.repo.id}`),
    );
    const listed = await expectOk<{ repos: unknown[] }>(
      await call(harness, owner, "GET", "/v1/repos"),
    );
    expect(listed.repos).toHaveLength(0);
  });
});
