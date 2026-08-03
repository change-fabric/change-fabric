import { and, asc, desc, eq, lt } from "drizzle-orm";
import type { Database } from "./db/client.js";
import {
  artifact,
  artifactFile,
  contributorAlias,
  organization,
  repoLink,
  team,
  teamApiKey,
  teamMember,
  user,
} from "./db/schema.js";

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

export interface ContributorAliasRow {
  id: string;
  teamId: string;
  legacyContributorId: string;
  displayName: string;
  userId: string | null;
  createdAt: Date;
}

export interface NewContributorAlias {
  id: string;
  teamId: string;
  legacyContributorId: string;
  displayName: string;
  userId: string | null;
}

export interface TeamMemberRow {
  id: string;
  teamId: string;
  userId: string;
  userName: string;
  userEmail: string;
  createdAt: Date | null;
}

/**
 * A team and the organization it belongs to, in the one shape the artifacts
 * routes need: both slugs, because both are in every S3 key.
 */
export interface TeamContext {
  teamId: string;
  teamSlug: string;
  teamName: string;
  archivedAt: Date | null;
  organizationId: string;
  organizationSlug: string;
}

export interface PlatformStore {
  /**
   * Who is on a team, with the names a page has to render. Read-only, and the
   * one place this store touches a table Better Auth owns.
   */
  listTeamMembers(teamId: string): Promise<TeamMemberRow[]>;

  /**
   * A team's own slug and its organization's, or null.
   *
   * Read directly rather than through `auth.api.listOrganizationTeams` for a
   * reason the plugin cannot serve: a machine caller presenting a team API key
   * has no session at all, and every plugin endpoint authorises against one.
   * This is a read of two tables and authorises nothing by itself; the routes
   * that use it still decide separately whether the caller may act on the team
   * it describes.
   */
  findTeamContext(teamId: string): Promise<TeamContext | null>;

  /**
   * Whether a person holds a `team_member` row on a team.
   *
   * This is the check the viewer cookie is minted against, so it asks the
   * database rather than inferring membership from an organization role. An
   * owner who is not on a team is not on that team.
   */
  isTeamMember(teamId: string, userId: string): Promise<boolean>;

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

  /**
   * Whether any team anywhere already carries a legacy team id.
   *
   * A boolean rather than the row, deliberately. `legacy_team_id` is unique
   * across the whole table, so a collision may well be with a team in an
   * organization the caller cannot see, and answering with that team would tell
   * them it exists. The caller needs to know the id is spoken for; it does not
   * need to know by whom.
   */
  legacyTeamIdTaken(legacyTeamId: string): Promise<boolean>;

  /**
   * A person's account by address, or null.
   *
   * Used by the migration path to decide whether a legacy roster entry has a
   * real account behind it. It answers only about existence, never about
   * credentials, and the route that calls it still decides for itself whether
   * the address was verified: an unverified address is a claim, not a match, and
   * linking on one would let anybody inherit somebody else's history by typing
   * their email at sign-up.
   */
  findUserByEmail(
    email: string,
  ): Promise<{ id: string; email: string; emailVerified: boolean } | null>;

  createContributorAlias(
    input: NewContributorAlias,
  ): Promise<ContributorAliasRow>;
  listContributorAliases(teamId: string): Promise<ContributorAliasRow[]>;
  /**
   * The alias for one legacy id on one team, or null.
   *
   * This is what makes re-running a migration a no-op rather than a duplicate:
   * the unique index is the real guarantee, and this lets the ordinary case
   * answer "already there" with the existing row instead of a constraint
   * violation.
   */
  findContributorAlias(
    teamId: string,
    legacyContributorId: string,
  ): Promise<ContributorAliasRow | null>;

  createRepoLink(input: NewRepoLink): Promise<RepoLinkRow>;
  listRepoLinks(organizationId: string): Promise<RepoLinkRow[]>;
  deleteRepoLink(id: string, organizationId: string): Promise<boolean>;
  findRepoLinkByRepoId(repoId: string): Promise<RepoLinkRow | null>;

  /**
   * The artifact and every file it declares, written together.
   *
   * One method rather than a create followed by N inserts, and one transaction
   * underneath, because a partially written artifact is worse than none: the
   * response has already handed out presigned URLs for exactly the file rows
   * that were supposed to exist, and a missing row would mean an upload landing
   * at a key nothing in Postgres knows about.
   */
  createArtifact(input: NewArtifact): Promise<ArtifactRow>;
  /**
   * Whether a short id is already taken on a team, so the caller can retry with
   * another before it ever reaches the unique index. The index is still the
   * guarantee; this only keeps the ordinary case off the error path.
   */
  shortIdTaken(teamId: string, shortId: string): Promise<boolean>;
  findArtifactById(id: string): Promise<ArtifactRow | null>;
  /**
   * By short id ALONE, with no team in the lookup, because the download route
   * is reached with a short id and nothing else. Uniqueness is per team, so
   * this can in principle match more than one row; it returns them all and the
   * route scopes to the caller's own team rather than guessing. That is why it
   * is plural.
   */
  findArtifactsByShortId(shortId: string): Promise<ArtifactRow[]>;
  listArtifactFiles(artifactId: string): Promise<ArtifactFileRow[]>;
  /**
   * One page of a team's artifacts, newest first, plus whether there is more.
   *
   * Keyset pagination on the id rather than an offset: ids are ULIDs, so
   * descending id is descending creation time, and a cursor that is the last id
   * seen cannot skip or repeat a row when something is inserted mid-scan. An
   * offset can do both.
   */
  listArtifacts(
    teamId: string,
    limit: number,
    before: string | null,
  ): Promise<ArtifactRow[]>;
  /** Marks an artifact published, recording whatever the check had to say. */
  completeArtifact(
    id: string,
    at: Date,
    note: string | null,
  ): Promise<ArtifactRow | null>;
}

export interface ArtifactRow {
  id: string;
  organizationId: string;
  teamId: string;
  shortId: string;
  repoId: string | null;
  contributorUserId: string | null;
  contributorLabel: string | null;
  project: string | null;
  branch: string | null;
  headSha: string | null;
  prNumber: number | null;
  prUrl: string | null;
  status: string;
  failCount: number;
  warnCount: number;
  byteSize: number;
  keyPrefix: string;
  generatedAt: Date;
  publishedAt: Date | null;
  expiresAt: Date | null;
  completionNote: string | null;
}

export interface ArtifactFileRow {
  id: string;
  artifactId: string;
  path: string;
  contentType: string;
  bytes: number;
  sha256: string | null;
}

export interface NewArtifactFile {
  id: string;
  path: string;
  contentType: string;
  bytes: number;
  sha256: string | null;
}

export interface NewArtifact {
  id: string;
  organizationId: string;
  teamId: string;
  shortId: string;
  repoId: string | null;
  contributorUserId: string | null;
  contributorLabel: string | null;
  project: string | null;
  branch: string | null;
  headSha: string | null;
  prNumber: number | null;
  prUrl: string | null;
  status: string;
  failCount: number;
  warnCount: number;
  byteSize: number;
  keyPrefix: string;
  generatedAt: Date;
  expiresAt: Date | null;
  files: NewArtifactFile[];
}

/** Raised when a short id collided even after retrying, so a route can say so. */
export class ShortIdExhaustedError extends Error {}

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

    async findTeamContext(teamId) {
      const rows = await db
        .select({
          teamId: team.id,
          teamSlug: team.slug,
          teamName: team.name,
          archivedAt: team.archivedAt,
          organizationId: organization.id,
          organizationSlug: organization.slug,
        })
        .from(team)
        .innerJoin(organization, eq(organization.id, team.organizationId))
        .where(eq(team.id, teamId))
        .limit(1);
      return rows[0] ?? null;
    },

    async isTeamMember(teamId, userId) {
      const rows = await db
        .select({ id: teamMember.id })
        .from(teamMember)
        .where(
          and(eq(teamMember.teamId, teamId), eq(teamMember.userId, userId)),
        )
        .limit(1);
      return rows.length > 0;
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

    async legacyTeamIdTaken(legacyTeamId) {
      const rows = await db
        .select({ id: team.id })
        .from(team)
        .where(eq(team.legacyTeamId, legacyTeamId))
        .limit(1);
      return rows.length > 0;
    },

    async findUserByEmail(email) {
      const rows = await db
        .select({
          id: user.id,
          email: user.email,
          emailVerified: user.emailVerified,
        })
        .from(user)
        .where(eq(user.email, email))
        .limit(1);
      return rows[0] ?? null;
    },

    async createContributorAlias(input) {
      const [row] = await db.insert(contributorAlias).values(input).returning();
      if (row === undefined) {
        throw new Error("insert into contributor_alias returned no row");
      }
      return row;
    },

    async listContributorAliases(teamId) {
      return db
        .select()
        .from(contributorAlias)
        .where(eq(contributorAlias.teamId, teamId))
        .orderBy(asc(contributorAlias.legacyContributorId));
    },

    async findContributorAlias(teamId, legacyContributorId) {
      const rows = await db
        .select()
        .from(contributorAlias)
        .where(
          and(
            eq(contributorAlias.teamId, teamId),
            eq(contributorAlias.legacyContributorId, legacyContributorId),
          ),
        )
        .limit(1);
      return rows[0] ?? null;
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

    async createArtifact(input) {
      const { files, ...header } = input;
      // One transaction, so an artifact never exists without the file rows the
      // response already promised presigned URLs for.
      return db.transaction(async (tx) => {
        const [row] = await tx.insert(artifact).values(header).returning();
        if (row === undefined) {
          throw new Error("insert into artifact returned no row");
        }
        await tx.insert(artifactFile).values(
          files.map((file) => ({ ...file, artifactId: row.id })),
        );
        return row;
      });
    },

    async shortIdTaken(teamId, shortId) {
      const rows = await db
        .select({ id: artifact.id })
        .from(artifact)
        .where(
          and(eq(artifact.teamId, teamId), eq(artifact.shortId, shortId)),
        )
        .limit(1);
      return rows.length > 0;
    },

    async findArtifactById(id) {
      const rows = await db
        .select()
        .from(artifact)
        .where(eq(artifact.id, id))
        .limit(1);
      return rows[0] ?? null;
    },

    async findArtifactsByShortId(shortId) {
      return db.select().from(artifact).where(eq(artifact.shortId, shortId));
    },

    async listArtifactFiles(artifactId) {
      return db
        .select()
        .from(artifactFile)
        .where(eq(artifactFile.artifactId, artifactId))
        .orderBy(asc(artifactFile.path));
    },

    async listArtifacts(teamId, limit, before) {
      const scope =
        before === null
          ? eq(artifact.teamId, teamId)
          : and(eq(artifact.teamId, teamId), lt(artifact.id, before));
      return db
        .select()
        .from(artifact)
        .where(scope)
        .orderBy(desc(artifact.id))
        .limit(limit);
    },

    async completeArtifact(id, at, note) {
      const [row] = await db
        .update(artifact)
        .set({ publishedAt: at, completionNote: note })
        .where(eq(artifact.id, id))
        .returning();
      return row ?? null;
    },
  };
}
