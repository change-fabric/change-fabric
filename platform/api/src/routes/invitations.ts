import { Hono } from "hono";
import { asObject, optionalText, requireText } from "../validation.js";
import {
  readJsonBody,
  requireOrgAdmin,
  requireParam,
  RouteError,
  type RouteDependencies,
} from "./context.js";
import { requireTeamInOrganization } from "./teams.js";

/**
 * Inviting somebody into an organization, optionally straight onto a team.
 *
 * Both endpoints delegate to the organization plugin's own invitation flow
 * rather than reimplementing one. That matters more here than anywhere else in
 * this phase: accepting an invitation has to create the `member` row and the
 * `team_member` rows in one transaction, roll both back if either fails, and set
 * the accepting session's active organization. The plugin already does exactly
 * that, and a parallel implementation would be a second answer to the same
 * question that only one of the two surfaces would agree with.
 *
 * The invitation mail goes out through the same SES sender the sign-up
 * verification mail uses, configured on the plugin in auth-options.ts.
 */

function toInvitationView(row: unknown) {
  const invitation = row as Record<string, unknown>;
  const expiresAt = invitation.expiresAt;
  return {
    id: String(invitation.id),
    email: String(invitation.email),
    role: typeof invitation.role === "string" ? invitation.role : null,
    status: String(invitation.status),
    organizationId: String(invitation.organizationId),
    teamId: typeof invitation.teamId === "string" ? invitation.teamId : null,
    expiresAt:
      expiresAt instanceof Date
        ? expiresAt.toISOString()
        : typeof expiresAt === "string"
          ? expiresAt
          : null,
  };
}

/**
 * The roles an invitation may name. Nothing outside the plugin's own three, and
 * narrowed to a literal union rather than left as a string so the plugin's own
 * typed role parameter checks it rather than accepting whatever arrived.
 */
const INVITABLE_ROLES = ["member", "admin", "owner"] as const;

type InvitableRole = (typeof INVITABLE_ROLES)[number];

function asInvitableRole(value: string): InvitableRole {
  const match = INVITABLE_ROLES.find((role) => role === value);
  if (match === undefined) {
    throw new RouteError(400, `role must be one of ${INVITABLE_ROLES.join(", ")}`);
  }
  return match;
}

export function registerInvitationRoutes(
  app: Hono,
  deps: RouteDependencies,
): void {
  app.post("/v1/invitations", async (c) => {
    const auth = await deps.auth();
    const caller = await requireOrgAdmin(auth, c.req.raw.headers);
    const body = asObject(await readJsonBody(c));

    const email = requireText(body, "email");
    const role = asInvitableRole(optionalText(body, "role") ?? "member");

    // Optional, and the common case. Placing somebody on their team as part of
    // the invitation is what turns two round trips (invite, then add) into one,
    // and the plugin creates the team membership at accept time inside the same
    // transaction as the organization membership.
    const teamId = optionalText(body, "teamId");
    if (teamId !== undefined) {
      await requireTeamInOrganization(
        auth,
        c.req.raw.headers,
        teamId,
        caller.organizationId,
      );
    }

    const invitation = await auth.api.createInvitation({
      body: {
        email,
        role,
        organizationId: caller.organizationId,
        ...(teamId === undefined ? {} : { teamId }),
      },
      headers: c.req.raw.headers,
    });

    return c.json({ invitation: toInvitationView(invitation) }, 201);
  });

  app.get("/v1/invitations", async (c) => {
    const auth = await deps.auth();
    const caller = await requireOrgAdmin(auth, c.req.raw.headers);

    const invitations = await auth.api.listInvitations({
      query: { organizationId: caller.organizationId },
      headers: c.req.raw.headers,
    });

    return c.json({ invitations: (invitations ?? []).map(toInvitationView) });
  });

  /**
   * What an invited person is shown before they accept.
   *
   * Deliberately not gated on organization membership: the whole point is that
   * the caller is not a member yet. The plugin decides what it will disclose
   * about an invitation to a session that is not the recipient.
   */
  app.get("/v1/invitations/:id", async (c) => {
    const auth = await deps.auth();
    const invitation = await auth.api.getInvitation({
      query: { id: requireParam(c, "id") },
      headers: c.req.raw.headers,
    });
    return c.json({ invitation: toInvitationView(invitation) });
  });

  app.post("/v1/invitations/:id/accept", async (c) => {
    const auth = await deps.auth();
    // A session, but no organization: the caller is joining one. The plugin
    // refuses anybody whose address is not the invitation's recipient.
    const accepted = await auth.api.acceptInvitation({
      body: { invitationId: requireParam(c, "id") },
      headers: c.req.raw.headers,
    });

    if (accepted === null || accepted === undefined) {
      throw new RouteError(400, "invitation could not be accepted");
    }

    return c.json({
      invitation: toInvitationView(accepted.invitation),
      member: accepted.member,
    });
  });
}
