import { randomUUID } from "node:crypto";
import { Hono } from "hono";
import type { ContributorAliasRow } from "../store.js";
import { asObject, optionalText, requireText } from "../validation.js";
import {
  readJsonBody,
  requireCaller,
  requireOrgAdmin,
  requireParam,
  type RouteDependencies,
} from "./context.js";
import { requireTeamInOrganization } from "./teams.js";

/**
 * Contributor aliases: who somebody was on a team before the team was hosted
 * here.
 *
 * A repository's CHANGE.md carries a self-asserted roster of `{id, name}` pairs
 * and every run published before this platform existed is attributed to one of
 * those ids. These routes are how such an id keeps meaning something: an alias
 * records the legacy id, the display name it was registered under, and the
 * account behind it when there turns out to be one.
 *
 * Creating an alias is an owner-or-admin act because it asserts an identity.
 * Reading them is a member's right, because the names are what a team's own
 * history renders as.
 */

export interface ContributorAliasView {
  id: string;
  teamId: string;
  legacyContributorId: string;
  displayName: string;
  userId: string | null;
  createdAt: string;
}

function toAliasView(row: ContributorAliasRow): ContributorAliasView {
  return {
    id: row.id,
    teamId: row.teamId,
    legacyContributorId: row.legacyContributorId,
    displayName: row.displayName,
    userId: row.userId,
    createdAt: row.createdAt.toISOString(),
  };
}

export function registerAliasRoutes(app: Hono, deps: RouteDependencies): void {
  /**
   * Idempotent by design, and that is the requirement rather than a
   * convenience: this is called by a migration tool run against a repository,
   * and a repository gets migrated more than once (a dry run, a real run, a
   * re-run after somebody edited the roster). A second call for a legacy id
   * that is already mapped answers 200 with the row that already exists, so
   * re-running changes nothing and still tells the caller what is there.
   *
   * `userId` is never taken from the body. A caller naming a user id would be
   * asserting that somebody else's account is the same person as a roster
   * entry, which is exactly the claim that must not be self-served. Instead the
   * caller may name an EMAIL, and the link is made only when an account with
   * that address exists AND has verified it. An unverified address is a claim
   * somebody typed at sign-up, not a proof, so it leaves `user_id` null and the
   * alias still carries the display name. Historical attribution reads
   * correctly either way; only the link to a live account waits.
   */
  app.post("/v1/teams/:id/aliases", async (c) => {
    const auth = await deps.auth();
    const caller = await requireOrgAdmin(auth, c.req.raw.headers);
    const teamId = requireParam(c, "id");
    await requireTeamInOrganization(
      auth,
      c.req.raw.headers,
      teamId,
      caller.organizationId,
    );

    const body = asObject(await readJsonBody(c));
    const legacyContributorId = requireText(body, "legacyContributorId");
    const displayName = requireText(body, "displayName");
    const email = optionalText(body, "email");

    const store = await deps.store();

    const existing = await store.findContributorAlias(
      teamId,
      legacyContributorId,
    );
    if (existing !== null) {
      return c.json({ alias: toAliasView(existing), created: false });
    }

    let userId: string | null = null;
    if (email !== undefined) {
      const account = await store.findUserByEmail(email.toLowerCase());
      userId =
        account !== null && account.emailVerified ? account.id : null;
    }

    const created = await store.createContributorAlias({
      id: randomUUID(),
      teamId,
      legacyContributorId,
      displayName,
      userId,
    });

    return c.json({ alias: toAliasView(created), created: true }, 201);
  });

  app.get("/v1/teams/:id/aliases", async (c) => {
    const auth = await deps.auth();
    const caller = await requireCaller(auth, c.req.raw.headers);
    const teamId = requireParam(c, "id");
    await requireTeamInOrganization(
      auth,
      c.req.raw.headers,
      teamId,
      caller.organizationId,
    );

    const store = await deps.store();
    const rows = await store.listContributorAliases(teamId);
    return c.json({ aliases: rows.map(toAliasView) });
  });
}
