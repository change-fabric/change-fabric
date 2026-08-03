import { Hono } from "hono";
import { SLUG_IMMUTABLE_MESSAGE } from "../auth-options.js";
import {
  asObject,
  optionalText,
  requireSlug,
  requireText,
} from "../validation.js";
import {
  readJsonBody,
  requireCaller,
  requireOrgAdmin,
  requireParam,
  RouteError,
  type RouteDependencies,
} from "./context.js";

/**
 * Contributor teams.
 *
 * Every write goes through the organization plugin's own endpoints rather than
 * the database, so its permission model, its hooks (including the slug
 * immutability rule phase 2 installed) and its cascades all apply exactly as
 * they do to any other caller. What these routes add on top is the platform's
 * own contract: a required slug, an explicit owner-or-admin gate stated before
 * the plugin's own, and archiving instead of deletion.
 *
 * The explicit gate is not redundant with the plugin's. The plugin answers
 * "does this role hold the team:create permission"; this answers "is this caller
 * an owner or an admin of this organization", which is the sentence the product
 * is written in and the one the web app mirrors when it decides which buttons to
 * render. Stating it here means the rule is testable in one place and does not
 * silently change if the plugin's default access control is ever customised.
 */

export interface TeamView {
  id: string;
  name: string;
  slug: string;
  organizationId: string;
  createdAt: string | null;
  archivedAt: string | null;
  /**
   * The two columns phase 2 put on `team` and nothing has written until now.
   * They are returned rather than write-only because the migration tool has to
   * be able to ask "is this legacy team already here" and get an answer, which
   * is what makes a second run of it a no-op instead of a duplicate. Neither is
   * a secret: `public_key_ed25519` is the verify-only half of a keypair whose
   * private half never leaves 1Password and the Keychain, and it is already
   * committed in plain sight in every registered repo's CHANGE.md.
   */
  legacyTeamId: string | null;
  publicKeyEd25519: string | null;
}

/**
 * Better Auth returns whatever the adapter stored, and the drizzle adapter
 * returns Dates where the memory adapter may return strings. Normalising to ISO
 * here means every consumer sees one shape.
 */
function toIsoString(value: unknown): string | null {
  if (value instanceof Date) {
    return Number.isNaN(value.getTime()) ? null : value.toISOString();
  }
  if (typeof value === "string" && value !== "") {
    const parsed = new Date(value);
    return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString();
  }
  return null;
}

/** An optional text column, as null rather than as the string "null". */
function toNullableString(value: unknown): string | null {
  return typeof value === "string" && value !== "" ? value : null;
}

export function toTeamView(row: unknown): TeamView {
  const team = row as Record<string, unknown>;
  return {
    id: String(team.id),
    name: String(team.name),
    slug: typeof team.slug === "string" ? team.slug : "",
    organizationId: String(team.organizationId),
    createdAt: toIsoString(team.createdAt),
    archivedAt: toIsoString(team.archivedAt),
    legacyTeamId: toNullableString(team.legacyTeamId),
    publicKeyEd25519: toNullableString(team.publicKeyEd25519),
  };
}

export function registerTeamRoutes(app: Hono, deps: RouteDependencies): void {
  app.post("/v1/teams", async (c) => {
    const auth = await deps.auth();
    const caller = await requireOrgAdmin(auth, c.req.raw.headers);
    const body = asObject(await readJsonBody(c));

    const name = requireText(body, "name");
    // Required and typed, never derived from the name. A team slug is the same
    // kind of permanent public handle an organization slug is, and phase 2's
    // hook refuses to change one afterwards.
    const slug = requireSlug(body, "slug");

    // The `(organization_id, slug)` unique index is the real guarantee, and it
    // stays the real guarantee: two simultaneous creates still cannot both win.
    // This check exists so the ordinary case answers 409 with a sentence rather
    // than surfacing a unique violation as a 500, which is what a caller would
    // otherwise get for the most predictable mistake there is.
    const existing = await auth.api.listOrganizationTeams({
      query: { organizationId: caller.organizationId },
      headers: c.req.raw.headers,
    });
    if ((existing ?? []).map(toTeamView).some((team) => team.slug === slug)) {
      throw new RouteError(409, `a team with the slug ${slug} already exists`);
    }

    /**
     * What a team was called before it was hosted here, and the verify-only key
     * its repositories already commit. Both optional, because a team created
     * fresh in the web app has no history to carry, and both accepted here
     * rather than patched in afterwards: `legacy_team_id` is unique, so writing
     * it in the same statement that creates the row is what makes claiming a
     * legacy team an atomic decision instead of a two-step one that can be lost
     * halfway.
     */
    const legacyTeamId = optionalText(body, "legacyTeamId");
    const publicKeyEd25519 = optionalText(body, "publicKeyEd25519");

    // Same reasoning as the slug check above: the unique index is still the
    // guarantee, and this only keeps the predictable case (re-running a
    // migration against a team somebody already claimed) off the 500 path.
    if (legacyTeamId !== undefined) {
      const store = await deps.store();
      if (await store.legacyTeamIdTaken(legacyTeamId)) {
        throw new RouteError(
          409,
          `the legacy team id ${legacyTeamId} is already claimed`,
        );
      }
    }

    const created = await auth.api.createTeam({
      body: {
        name,
        slug,
        organizationId: caller.organizationId,
        ...(legacyTeamId === undefined ? {} : { legacyTeamId }),
        ...(publicKeyEd25519 === undefined ? {} : { publicKeyEd25519 }),
      },
      headers: c.req.raw.headers,
    });

    return c.json({ team: toTeamView(created) }, 201);
  });

  app.get("/v1/teams", async (c) => {
    const auth = await deps.auth();
    // Reading is a member's right. Only changing the shape of an organization
    // needs the admin gate.
    const caller = await requireCaller(auth, c.req.raw.headers);

    const teams = await auth.api.listOrganizationTeams({
      query: { organizationId: caller.organizationId },
      headers: c.req.raw.headers,
    });

    return c.json({ teams: (teams ?? []).map(toTeamView) });
  });

  app.patch("/v1/teams/:id", async (c) => {
    const auth = await deps.auth();
    await requireOrgAdmin(auth, c.req.raw.headers);
    const teamId = requireParam(c, "id");
    const body = asObject(await readJsonBody(c));

    // Refused here as well as in the plugin's hook, so the message a caller
    // sees is the same whether they addressed this route or the plugin's.
    if (Object.prototype.hasOwnProperty.call(body, "slug")) {
      throw new RouteError(400, SLUG_IMMUTABLE_MESSAGE);
    }

    const updated = await auth.api.updateTeam({
      body: { teamId, data: { name: requireText(body, "name") } },
      headers: c.req.raw.headers,
    });

    return c.json({ team: toTeamView(updated) });
  });

  /**
   * Archiving, not deleting. The team's slug is already in artifact paths and in
   * whatever a downstream repository recorded, and its keys and repo links point
   * at it, so removing the row would strand references rather than retire them.
   * POST rather than DELETE for the same reason: nothing is deleted.
   */
  app.post("/v1/teams/:id/archive", async (c) => {
    const auth = await deps.auth();
    await requireOrgAdmin(auth, c.req.raw.headers);
    const teamId = requireParam(c, "id");

    const updated = await auth.api.updateTeam({
      body: { teamId, data: { archivedAt: deps.now() } },
      headers: c.req.raw.headers,
    });

    return c.json({ team: toTeamView(updated) });
  });

  app.get("/v1/teams/:id/members", async (c) => {
    const auth = await deps.auth();
    const caller = await requireCaller(auth, c.req.raw.headers);
    const teamId = requireParam(c, "id");
    await requireTeamInOrganization(auth, c.req.raw.headers, teamId, caller.organizationId);

    const store = await deps.store();
    const members = await store.listTeamMembers(teamId);

    return c.json({
      members: members.map((member) => ({
        id: member.id,
        userId: member.userId,
        name: member.userName,
        email: member.userEmail,
        createdAt: toIsoString(member.createdAt),
      })),
    });
  });

  /**
   * Adding requires the person to already be a member of the organization. That
   * is Better Auth's own constraint and it is left alone on purpose: a team is a
   * grouping inside an organization, so team membership without organization
   * membership would be a row with nothing to belong to. The way to put an
   * outsider on a team is to invite them to the organization and name the team
   * in the invitation, which POST /v1/invitations does.
   */
  app.post("/v1/teams/:id/members", async (c) => {
    const auth = await deps.auth();
    await requireOrgAdmin(auth, c.req.raw.headers);
    const teamId = requireParam(c, "id");
    const body = asObject(await readJsonBody(c));

    const added = await auth.api.addTeamMember({
      body: { teamId, userId: requireText(body, "userId") },
      headers: c.req.raw.headers,
    });

    return c.json({ member: added }, 201);
  });

  app.delete("/v1/teams/:id/members/:userId", async (c) => {
    const auth = await deps.auth();
    await requireOrgAdmin(auth, c.req.raw.headers);

    await auth.api.removeTeamMember({
      body: {
        teamId: requireParam(c, "id"),
        userId: requireParam(c, "userId"),
      },
      headers: c.req.raw.headers,
    });

    return c.json({ removed: true });
  });
}

/**
 * That a team exists and belongs to the caller's organization.
 *
 * Every route reached by team id needs this: without it, an id from another
 * organization would be answered rather than refused, and 404 rather than 403 is
 * the right answer because the caller has no business learning that the id
 * exists at all.
 */
export async function requireTeamInOrganization(
  auth: Awaited<ReturnType<RouteDependencies["auth"]>>,
  headers: Headers,
  teamId: string,
  organizationId: string,
): Promise<TeamView> {
  const teams = await auth.api.listOrganizationTeams({
    query: { organizationId },
    headers,
  });
  const found = (teams ?? []).map(toTeamView).find((team) => team.id === teamId);
  if (found === undefined) {
    throw new RouteError(404, "no such team in this organization");
  }
  return found;
}
