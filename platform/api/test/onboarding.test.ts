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

    expect(harness.rows.user).toHaveLength(1);
    expect(harness.rows.organization).toHaveLength(1);
    expect(harness.rows.member).toHaveLength(1);

    const createdUser = harness.rows.user[0];
    const createdOrg = harness.rows.organization[0];
    const createdMember = harness.rows.member[0];

    expect(createdUser?.email).toBe("founder@example.test");
    expect(createdOrg?.name).toBe("Acme Research");
    expect(createdOrg?.slug).toBe("acme-research");
    expect(createdMember?.userId).toBe(createdUser?.id);
    expect(createdMember?.organizationId).toBe(createdOrg?.id);
    expect(createdMember?.role).toBe("owner");
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
    expect(harness.rows.organization).toHaveLength(0);
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
