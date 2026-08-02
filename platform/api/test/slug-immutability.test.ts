import { describe, expect, it } from "vitest";
import { SLUG_IMMUTABLE_MESSAGE } from "../src/auth-options.js";
import { AUTHORIZED_HEADER, createHarness, onboard, signUp } from "./harness.js";

/**
 * A slug is a public handle that ends up in URLs and in whatever a downstream
 * repository already recorded. These tests drive the real Better Auth endpoints
 * so the rejection is proven where a caller would actually hit it, not on a
 * helper function nothing routes through.
 */
describe("slug immutability", () => {
  async function organizationWithTeam() {
    const harness = createHarness();
    const user = await signUp(harness, "owner@example.test");
    const created = await onboard(harness, user, {
      organizationName: "Acme Research",
      organizationSlug: "acme-research",
    });
    const { organization } = (await created.json()) as {
      organization: { id: string };
    };

    const teamResponse = await harness.app.request(
      "/api/auth/organization/create-team",
      {
        method: "POST",
        headers: {
          Authorization: AUTHORIZED_HEADER,
          Cookie: user.cookie,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          name: "Core",
          slug: "core",
          organizationId: organization.id,
        }),
      },
    );

    return { harness, user, organizationId: organization.id, teamResponse };
  }

  it("rejects an attempt to change an organization slug", async () => {
    const { harness, user, organizationId } = await organizationWithTeam();

    const response = await harness.app.request(
      "/api/auth/organization/update",
      {
        method: "POST",
        headers: {
          Authorization: AUTHORIZED_HEADER,
          Cookie: user.cookie,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          organizationId,
          data: { slug: "acme-renamed" },
        }),
      },
    );

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toMatchObject({
      message: SLUG_IMMUTABLE_MESSAGE,
    });

    const stored = harness.rows.organization;
    expect(stored[0]?.slug).toBe("acme-research");
  });

  it("allows an organization rename that leaves the slug alone", async () => {
    const { harness, user, organizationId } = await organizationWithTeam();

    const response = await harness.app.request(
      "/api/auth/organization/update",
      {
        method: "POST",
        headers: {
          Authorization: AUTHORIZED_HEADER,
          Cookie: user.cookie,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          organizationId,
          data: { name: "Acme Research Group" },
        }),
      },
    );

    expect(response.status).toBe(200);
    const stored = harness.rows.organization;
    expect(stored[0]?.name).toBe("Acme Research Group");
    expect(stored[0]?.slug).toBe("acme-research");
  });

  it("stores the extra team columns the platform adds", async () => {
    const { harness, teamResponse } = await organizationWithTeam();

    expect(teamResponse.status).toBe(200);
    const teams = harness.rows.team;
    expect(teams).toHaveLength(1);
    expect(teams[0]?.slug).toBe("core");
  });

  it("rejects an attempt to change a team slug", async () => {
    const { harness, user } = await organizationWithTeam();
    const teams = harness.rows.team;
    const teamId = teams[0]?.id;
    expect(teamId).toBeDefined();

    const response = await harness.app.request(
      "/api/auth/organization/update-team",
      {
        method: "POST",
        headers: {
          Authorization: AUTHORIZED_HEADER,
          Cookie: user.cookie,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          teamId,
          data: { slug: "renamed" },
        }),
      },
    );

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toMatchObject({
      message: SLUG_IMMUTABLE_MESSAGE,
    });

    const after = harness.rows.team;
    expect(after[0]?.slug).toBe("core");
  });
});
