import { describe, expect, it } from "vitest";
import { invitationUrl } from "../src/auth-options.js";
import {
  call,
  createHarness,
  expectOk,
  ownedOrganization,
  signUp,
} from "./harness.js";

interface InvitationBody {
  invitation: { id: string; email: string; teamId: string | null };
}

async function orgWithTeams() {
  const harness = createHarness();
  const { owner } = await ownedOrganization(harness);
  const first = await expectOk<{ team: { id: string } }>(
    await call(harness, owner, "POST", "/v1/teams", {
      name: "Core",
      slug: "core",
    }),
    201,
  );
  const second = await expectOk<{ team: { id: string } }>(
    await call(harness, owner, "POST", "/v1/teams", {
      name: "Docs",
      slug: "docs",
    }),
    201,
  );
  return { harness, owner, first: first.team, second: second.team };
}

describe("invitation links", () => {
  it("points at the app's accept route with the invitation id", () => {
    expect(invitationUrl("https://app.example.org/", "inv-1")).toBe(
      "https://app.example.org/accept-invite?invitation=inv-1",
    );
  });

  it("escapes an id rather than pasting it into a query string raw", () => {
    expect(invitationUrl("https://app.example.org", "a b&c")).toBe(
      "https://app.example.org/accept-invite?invitation=a%20b%26c",
    );
  });
});

describe("inviting somebody into an organization", () => {
  it("sends a mail carrying the accept link", async () => {
    const { harness, owner } = await orgWithTeams();

    const body = await expectOk<InvitationBody>(
      await call(harness, owner, "POST", "/v1/invitations", {
        email: "newcomer@example.test",
      }),
      201,
    );

    expect(harness.sentInvitations).toHaveLength(1);
    const mail = harness.sentInvitations[0];
    expect(mail?.to).toBe("newcomer@example.test");
    expect(mail?.text).toContain(
      invitationUrl("http://localhost", body.invitation.id),
    );
  });

  it("places the accepting person on the team the invitation named", async () => {
    const { harness, owner, first } = await orgWithTeams();

    const body = await expectOk<InvitationBody>(
      await call(harness, owner, "POST", "/v1/invitations", {
        email: "newcomer@example.test",
        teamId: first.id,
      }),
      201,
    );

    const invitee = await signUp(harness, "newcomer@example.test");
    await expectOk(
      await call(
        harness,
        invitee,
        "POST",
        `/v1/invitations/${body.invitation.id}/accept`,
      ),
    );

    expect(harness.rows.member).toHaveLength(2);
    expect(harness.rows.teamMember).toHaveLength(1);
    expect(harness.rows.teamMember[0]?.teamId).toBe(first.id);
  });

  it("defaults an invitation to the member role, not an elevated one", async () => {
    const { harness, owner } = await orgWithTeams();

    await expectOk<InvitationBody>(
      await call(harness, owner, "POST", "/v1/invitations", {
        email: "newcomer@example.test",
      }),
      201,
    );

    expect(harness.rows.invitation[0]?.role).toBe("member");
  });

  it("refuses a team from another organization", async () => {
    const { harness, owner, first } = await orgWithTeams();

    const stranger = await signUp(harness, "stranger@example.test");
    await expectOk(
      await call(harness, stranger, "POST", "/v1/onboarding", {
        organizationName: "Other Co",
        organizationSlug: "other-co",
      }),
      201,
    );

    const response = await call(harness, stranger, "POST", "/v1/invitations", {
      email: "newcomer@example.test",
      teamId: first.id,
    });

    expect(response.status).toBe(404);
    expect(harness.sentInvitations).toHaveLength(0);
  });

  it("refuses an unknown role rather than inventing one", async () => {
    const { harness, owner } = await orgWithTeams();

    const response = await call(harness, owner, "POST", "/v1/invitations", {
      email: "newcomer@example.test",
      role: "superuser",
    });

    expect(response.status).toBe(400);
  });

  it("refuses somebody who is not the recipient", async () => {
    const { harness, owner } = await orgWithTeams();
    const body = await expectOk<InvitationBody>(
      await call(harness, owner, "POST", "/v1/invitations", {
        email: "newcomer@example.test",
      }),
      201,
    );

    const impostor = await signUp(harness, "impostor@example.test");
    const response = await call(
      harness,
      impostor,
      "POST",
      `/v1/invitations/${body.invitation.id}/accept`,
    );

    expect(response.status).toBe(403);
    expect(harness.rows.member).toHaveLength(1);
  });

  it("refuses a member issuing an invitation", async () => {
    const { harness, owner } = await orgWithTeams();
    const body = await expectOk<InvitationBody>(
      await call(harness, owner, "POST", "/v1/invitations", {
        email: "newcomer@example.test",
      }),
      201,
    );
    const invitee = await signUp(harness, "newcomer@example.test");
    await expectOk(
      await call(
        harness,
        invitee,
        "POST",
        `/v1/invitations/${body.invitation.id}/accept`,
      ),
    );

    const response = await call(harness, invitee, "POST", "/v1/invitations", {
      email: "another@example.test",
    });

    expect(response.status).toBe(403);
  });
});
