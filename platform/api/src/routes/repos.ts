import { randomUUID } from "node:crypto";
import { Hono } from "hono";
import { asObject, requireRepoId, requireText } from "../validation.js";
import {
  readJsonBody,
  requireCaller,
  requireOrgAdmin,
  requireParam,
  RouteError,
  type RouteDependencies,
} from "./context.js";
import { requireTeamInOrganization } from "./teams.js";

/**
 * Which contributor team owns which repository.
 *
 * This is the lookup a later phase performs the other way round: a run publishes
 * from a git remote and the platform has to decide whose artifact it is. That is
 * why `repo_id` is unique across the whole table rather than per organization,
 * and why the answer to a repeated claim is 409 rather than a second row.
 */

export function registerRepoRoutes(app: Hono, deps: RouteDependencies): void {
  app.post("/v1/repos", async (c) => {
    const auth = await deps.auth();
    const caller = await requireOrgAdmin(auth, c.req.raw.headers);
    const body = asObject(await readJsonBody(c));

    const teamId = requireText(body, "teamId");
    await requireTeamInOrganization(
      auth,
      c.req.raw.headers,
      teamId,
      caller.organizationId,
    );
    const repoId = requireRepoId(body, "repoId");

    const store = await deps.store();
    // Checked before inserting so the common case answers with a sentence
    // rather than a unique-violation, and re-checked by the constraint itself so
    // two simultaneous claims still cannot both win.
    const existing = await store.findRepoLinkByRepoId(repoId);
    if (existing !== null) {
      throw new RouteError(409, `${repoId} is already linked to a team`);
    }

    const created = await store.createRepoLink({
      id: randomUUID(),
      organizationId: caller.organizationId,
      teamId,
      repoId,
    });

    return c.json(
      {
        repo: {
          id: created.id,
          repoId: created.repoId,
          teamId: created.teamId,
          createdAt: created.createdAt.toISOString(),
        },
      },
      201,
    );
  });

  app.get("/v1/repos", async (c) => {
    const auth = await deps.auth();
    const caller = await requireCaller(auth, c.req.raw.headers);

    const store = await deps.store();
    const rows = await store.listRepoLinks(caller.organizationId);

    return c.json({
      repos: rows.map((row) => ({
        id: row.id,
        repoId: row.repoId,
        teamId: row.teamId,
        createdAt: row.createdAt.toISOString(),
      })),
    });
  });

  app.delete("/v1/repos/:id", async (c) => {
    const auth = await deps.auth();
    const caller = await requireOrgAdmin(auth, c.req.raw.headers);

    const store = await deps.store();
    const removed = await store.deleteRepoLink(
      requireParam(c, "id"),
      caller.organizationId,
    );
    if (!removed) {
      throw new RouteError(404, "no such repo link in this organization");
    }

    return c.json({ removed: true });
  });
}
