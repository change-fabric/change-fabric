import { randomUUID } from "node:crypto";
import { Hono } from "hono";
import { hashKey, keyIsUsable, mintKey } from "../api-keys.js";
import type { ApiKeyRow } from "../store.js";
import { asObject, requireText } from "../validation.js";
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
 * Team API keys: minting, listing, revoking, and one route that proves a key
 * resolves.
 *
 * The raw key exists in exactly one response and nowhere else. It is not logged,
 * not returned by the listing, and not recoverable from the row, because the row
 * holds only its SHA-256 digest. Losing it means minting another one, which is
 * the correct trade: a key that can be read back later is a key that a database
 * dump hands over.
 */

/** The response shape for a stored key. It cannot express a hash or a raw key. */
function toKeyView(row: ApiKeyRow) {
  return {
    id: row.id,
    name: row.name,
    keyPrefix: row.keyPrefix,
    teamId: row.teamId,
    createdByUserId: row.createdByUserId,
    createdAt: row.createdAt.toISOString(),
    lastUsedAt: row.lastUsedAt?.toISOString() ?? null,
    expiresAt: row.expiresAt?.toISOString() ?? null,
    revokedAt: row.revokedAt?.toISOString() ?? null,
  };
}

/** The organization slug, needed because it is part of the key's own format. */
async function organizationSlug(
  auth: Awaited<ReturnType<RouteDependencies["auth"]>>,
  headers: Headers,
  organizationId: string,
): Promise<string> {
  const full = await auth.api.getFullOrganization({
    query: { organizationId },
    headers,
  });
  const slug = (full as { slug?: unknown } | null)?.slug;
  if (typeof slug !== "string" || slug === "") {
    throw new RouteError(400, "the active organization has no slug");
  }
  return slug;
}

export function registerKeyRoutes(app: Hono, deps: RouteDependencies): void {
  app.post("/v1/teams/:id/keys", async (c) => {
    const auth = await deps.auth();
    const caller = await requireOrgAdmin(auth, c.req.raw.headers);
    const teamId = requireParam(c, "id");
    const team = await requireTeamInOrganization(
      auth,
      c.req.raw.headers,
      teamId,
      caller.organizationId,
    );
    if (team.archivedAt !== null) {
      throw new RouteError(409, "this team is archived and cannot mint keys");
    }

    const body = asObject(await readJsonBody(c));
    const name = requireText(body, "name");

    const slug = await organizationSlug(
      auth,
      c.req.raw.headers,
      caller.organizationId,
    );
    const minted = mintKey(slug);

    const store = await deps.store();
    const row = await store.createApiKey({
      id: randomUUID(),
      organizationId: caller.organizationId,
      teamId,
      name,
      keyHash: minted.hash,
      keyPrefix: minted.prefix,
      createdByUserId: caller.userId,
      expiresAt: null,
    });

    // The one and only time this value is ever transmitted. Named `key` rather
    // than folded into the row so nothing downstream can start expecting a key
    // to be present on an ordinary listing.
    return c.json({ key: minted.raw, apiKey: toKeyView(row) }, 201);
  });

  app.get("/v1/teams/:id/keys", async (c) => {
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
    const rows = await store.listApiKeys(teamId);
    return c.json({ keys: rows.map(toKeyView) });
  });

  app.post("/v1/teams/:id/keys/:keyId/revoke", async (c) => {
    const auth = await deps.auth();
    const caller = await requireOrgAdmin(auth, c.req.raw.headers);
    const teamId = requireParam(c, "id");
    await requireTeamInOrganization(
      auth,
      c.req.raw.headers,
      teamId,
      caller.organizationId,
    );

    const store = await deps.store();
    const revoked = await store.revokeApiKey(
      requireParam(c, "keyId"),
      teamId,
      caller.organizationId,
      deps.now(),
    );
    if (revoked === null) {
      throw new RouteError(404, "no such key on this team");
    }

    return c.json({ apiKey: toKeyView(revoked) });
  });

  /**
   * The one route a key authenticates rather than a session.
   *
   * It exists to prove the mechanism end to end in this phase and does nothing
   * else: no data, no side effect beyond stamping `last_used_at`. Phase 6 owns
   * the first real consumer. The staging Basic Auth gate still applies, as it
   * does to every route except /healthz.
   *
   * A missing, unknown, revoked or expired key all produce the same 401. Telling
   * the difference would tell a caller which of their guesses was a real key.
   */
  app.get("/v1/whoami-key", async (c) => {
    const presented = c.req.header("x-cf-key");
    if (presented === undefined || presented === "") {
      throw new RouteError(401, "x-cf-key header required");
    }

    const store = await deps.store();
    const row = await store.findApiKeyByHash(hashKey(presented));
    if (row === null || !keyIsUsable(row, deps.now())) {
      throw new RouteError(401, "key is not valid");
    }

    await store.touchApiKey(row.id, deps.now());

    return c.json({
      organizationId: row.organizationId,
      teamId: row.teamId,
      keyName: row.name,
    });
  });
}
