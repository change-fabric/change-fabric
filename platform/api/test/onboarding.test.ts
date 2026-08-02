import { describe, expect, it } from "vitest";
import { AUTHORIZED_HEADER, createHarness, onboard, signUp } from "./harness.js";

describe("signup then onboarding", () => {
  it("produces a user, an organization, and an owner membership", async () => {
    const harness = createHarness();

    const user = await signUp(harness, "founder@example.test");
    const response = await onboard(harness, user, {
      organizationName: "Acme Research",
      organizationSlug: "acme-research",
    });

    expect(response.status).toBe(201);
    const body = (await response.json()) as {
      organization: { id: string; name: string; slug: string };
    };
    expect(body.organization.slug).toBe("acme-research");

    const users = harness.store.user ?? [];
    const organizations = harness.store.organization ?? [];
    const members = harness.store.member ?? [];

    expect(users).toHaveLength(1);
    expect(organizations).toHaveLength(1);
    expect(members).toHaveLength(1);

    const createdUser = users[0] as { id: string; email: string };
    const createdOrg = organizations[0] as { id: string; name: string; slug: string };
    const createdMember = members[0] as {
      userId: string;
      organizationId: string;
      role: string;
    };

    expect(createdUser.email).toBe("founder@example.test");
    expect(createdOrg.name).toBe("Acme Research");
    expect(createdOrg.slug).toBe("acme-research");
    expect(createdMember.userId).toBe(createdUser.id);
    expect(createdMember.organizationId).toBe(createdOrg.id);
    expect(createdMember.role).toBe("owner");
  });

  it("sends a verification mail on sign-up", async () => {
    const harness = createHarness();

    await signUp(harness, "mailed@example.test");

    expect(harness.sentEmails).toHaveLength(1);
    expect(harness.sentEmails[0]?.to).toBe("mailed@example.test");
  });

  it("refuses onboarding without a session", async () => {
    const { app } = createHarness();

    const response = await app.request("/v1/onboarding", {
      method: "POST",
      headers: {
        Authorization: AUTHORIZED_HEADER,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        organizationName: "Acme",
        organizationSlug: "acme",
      }),
    });

    expect(response.status).toBe(401);
  });

  it("rejects a malformed slug rather than deriving one", async () => {
    const harness = createHarness();
    const user = await signUp(harness, "picky@example.test");

    const response = await onboard(harness, user, {
      organizationName: "Acme Research",
      organizationSlug: "Acme Research",
    });

    expect(response.status).toBe(400);
    expect(harness.store.organization).toHaveLength(0);
  });

  it("rejects a missing organization name", async () => {
    const harness = createHarness();
    const user = await signUp(harness, "nameless@example.test");

    const response = await onboard(harness, user, {
      organizationSlug: "acme-research",
    });

    expect(response.status).toBe(400);
  });
});
