import { and, asc, desc, eq } from "drizzle-orm";
import type { Database } from "./db/client.js";
import { repoLink, teamApiKey, teamMember, user } from "./db/schema.js";

/**
 * The platform's own persistence, for the two tables Better Auth does not own.
 *
 * It is an interface with a Drizzle implementation rather than routes reaching
 * for `db` directly, for the same reason `sendVerificationEmail` is injected:
 * the deployed function talks to Postgres inside a VPC nothing else can reach,
 * so a test that needed the real thing could not run at all. Every method here
 * is a whole operation the routes actually perform, not a thin passthrough, so
 * an in-memory implementation is a genuine substitute rather than a
 * reimplementation of query building.
 *
 * Every WRITE to a Better Auth table is deliberately absent: those go through
 * `auth.api`, so the plugin's hooks, permissions and cascades all fire. There is
 * one read that does not, `listTeamMembers`, and the reason is specific: the
 * plugin's own `list-team-members` refuses a caller who is not themselves on
 * that team, which is exactly the person a team detail page is for. Reading two
 * tables cannot bypass a hook, so the constraint that matters is untouched.
 */

export interface ApiKeyRow {
  id: string;
  organizationId: string;
  teamId: string;
  name: string;
  keyPrefix: string;
  createdByUserId: string;
  createdAt: Date;
  lastUsedAt: Date | null;
  expiresAt: Date | null;
  revokedAt: Date | null;
}

/** The same row plus the digest, which never leaves the API. */
export interface ApiKeyWithHash extends ApiKeyRow {
  keyHash: string;
}

export interface RepoLinkRow {
  id: string;
  organizationId: string;
  teamId: string;
  repoId: string;
  createdAt: Date;
}

export interface NewApiKey {
  id: string;
  organizationId: string;
  teamId: string;
  name: string;
  keyHash: string;
  keyPrefix: string;
  createdByUserId: string;
  expiresAt: Date | null;
}

export interface NewRepoLink {
  id: string;
  organizationId: string;
  teamId: string;
  repoId: string;
}

export interface TeamMemberRow {
  id: string;
  teamId: string;
  userId: string;
  userName: string;
  userEmail: string;
  createdAt: Date | null;
}

export interface PlatformStore {
  /**
   * Who is on a team, with the names a page has to render. Read-only, and the
   * one place this store touches a table Better Auth owns.
   */
  listTeamMembers(teamId: string): Promise<TeamMemberRow[]>;

  createApiKey(input: NewApiKey): Promise<ApiKeyRow>;
  /** Never returns `keyHash`: the listing surface has no use for it. */
  listApiKeys(teamId: string): Promise<ApiKeyRow[]>;
  findApiKeyByHash(hash: string): Promise<ApiKeyWithHash | null>;
  touchApiKey(id: string, at: Date): Promise<void>;
  /**
   * Returns the row as it now stands, or null if that key is not on that team in
   * that organization.
   *
   * The scoping is part of the statement rather than a check the caller makes
   * afterwards, and that is the whole point: a route that revoked first and then
   * noticed the key belonged elsewhere would answer 404 having already written
   * the revocation. Deciding in the WHERE clause means a refusal changed
   * nothing.
   */
  revokeApiKey(
    id: string,
    teamId: string,
    organizationId: string,
    at: Date,
  ): Promise<ApiKeyRow | null>;

  createRepoLink(input: NewRepoLink): Promise<RepoLinkRow>;
  listRepoLinks(organizationId: string): Promise<RepoLinkRow[]>;
  deleteRepoLink(id: string, organizationId: string): Promise<boolean>;
  findRepoLinkByRepoId(repoId: string): Promise<RepoLinkRow | null>;
}

/** Raised when a repo is already claimed, so a route can answer 409 rather than 500. */
export class RepoAlreadyLinkedError extends Error {}

function toApiKeyRow(row: ApiKeyWithHash): ApiKeyRow {
  const { keyHash: _hash, ...rest } = row;
  return rest;
}

export function createDrizzleStore(db: Database): PlatformStore {
  return {
    async listTeamMembers(teamId) {
      return db
        .select({
          id: teamMember.id,
          teamId: teamMember.teamId,
          userId: teamMember.userId,
          userName: user.name,
          userEmail: user.email,
          createdAt: teamMember.createdAt,
        })
        .from(teamMember)
        .innerJoin(user, eq(user.id, teamMember.userId))
        .where(eq(teamMember.teamId, teamId))
        .orderBy(asc(teamMember.createdAt));
    },

    async createApiKey(input) {
      const [row] = await db.insert(teamApiKey).values(input).returning();
      if (row === undefined) {
        throw new Error("insert into team_api_key returned no row");
      }
      return toApiKeyRow(row);
    },

    async listApiKeys(teamId) {
      const rows = await db
        .select()
        .from(teamApiKey)
        .where(eq(teamApiKey.teamId, teamId))
        .orderBy(desc(teamApiKey.createdAt));
      return rows.map(toApiKeyRow);
    },

    async findApiKeyByHash(hash) {
      const rows = await db
        .select()
        .from(teamApiKey)
        .where(eq(teamApiKey.keyHash, hash))
        .limit(1);
      return rows[0] ?? null;
    },

    async touchApiKey(id, at) {
      await db
        .update(teamApiKey)
        .set({ lastUsedAt: at })
        .where(eq(teamApiKey.id, id));
    },

    async revokeApiKey(id, teamId, organizationId, at) {
      // Already-revoked keys are not excluded from the WHERE clause: revoking
      // twice is the same outcome as revoking once, and answering 404 for the
      // second attempt would report a missing key that plainly exists.
      const [row] = await db
        .update(teamApiKey)
        .set({ revokedAt: at })
        .where(
          and(
            eq(teamApiKey.id, id),
            eq(teamApiKey.teamId, teamId),
            eq(teamApiKey.organizationId, organizationId),
          ),
        )
        .returning();
      return row === undefined ? null : toApiKeyRow(row);
    },

    async createRepoLink(input) {
      const [row] = await db.insert(repoLink).values(input).returning();
      if (row === undefined) {
        throw new Error("insert into repo_link returned no row");
      }
      return row;
    },

    async listRepoLinks(organizationId) {
      return db
        .select()
        .from(repoLink)
        .where(eq(repoLink.organizationId, organizationId))
        .orderBy(desc(repoLink.createdAt));
    },

    async deleteRepoLink(id, organizationId) {
      const rows = await db
        .delete(repoLink)
        .where(
          and(eq(repoLink.id, id), eq(repoLink.organizationId, organizationId)),
        )
        .returning({ id: repoLink.id });
      return rows.length > 0;
    },

    async findRepoLinkByRepoId(repoId) {
      const rows = await db
        .select()
        .from(repoLink)
        .where(eq(repoLink.repoId, repoId))
        .limit(1);
      return rows[0] ?? null;
    },
  };
}
