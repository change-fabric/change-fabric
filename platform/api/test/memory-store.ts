import type {
  ApiKeyRow,
  ApiKeyWithHash,
  ArtifactFileRow,
  ArtifactRow,
  PlatformStore,
  RepoLinkRow,
  TeamContext,
  TeamMemberRow,
} from "../src/store.js";
import type { MemoryDB } from "better-auth/adapters/memory";

/**
 * The platform store, backed by arrays.
 *
 * It exists so the same routes that run in Lambda can be driven in a test
 * without the Postgres instance they normally talk to, which sits in a VPC a
 * test could not reach even if it wanted to. `listTeamMembers` reads the same
 * in-memory store Better Auth's own memory adapter writes, so a team membership
 * created through the plugin is visible here exactly as the join would see it.
 */
export function createMemoryStore(betterAuthStore: MemoryDB): PlatformStore {
  const apiKeys: ApiKeyWithHash[] = [];
  const repoLinks: RepoLinkRow[] = [];
  const artifacts: ArtifactRow[] = [];
  const artifactFiles: ArtifactFileRow[] = [];

  function withoutHash(row: ApiKeyWithHash): ApiKeyRow {
    const { keyHash: _hash, ...rest } = row;
    return { ...rest };
  }

  return {
    async listTeamMembers(teamId) {
      const users = betterAuthStore.user as {
        id: string;
        name: string;
        email: string;
      }[];
      const members = betterAuthStore.teamMember as {
        id: string;
        teamId: string;
        userId: string;
        createdAt?: Date | null;
      }[];

      const rows: TeamMemberRow[] = [];
      for (const member of members.filter((row) => row.teamId === teamId)) {
        const owner = users.find((row) => row.id === member.userId);
        if (owner === undefined) {
          continue;
        }
        rows.push({
          id: member.id,
          teamId: member.teamId,
          userId: member.userId,
          userName: owner.name,
          userEmail: owner.email,
          createdAt: member.createdAt ?? null,
        });
      }
      return rows;
    },

    async createApiKey(input) {
      const row: ApiKeyWithHash = {
        ...input,
        createdAt: new Date(),
        lastUsedAt: null,
        revokedAt: null,
      };
      apiKeys.push(row);
      return withoutHash(row);
    },

    async listApiKeys(teamId) {
      return apiKeys
        .filter((row) => row.teamId === teamId)
        .map(withoutHash)
        .reverse();
    },

    async findApiKeyByHash(hash) {
      const row = apiKeys.find((candidate) => candidate.keyHash === hash);
      return row === undefined ? null : { ...row };
    },

    async touchApiKey(id, at) {
      const row = apiKeys.find((candidate) => candidate.id === id);
      if (row !== undefined) {
        row.lastUsedAt = at;
      }
    },

    async revokeApiKey(id, teamId, organizationId, at) {
      const row = apiKeys.find(
        (candidate) =>
          candidate.id === id &&
          candidate.teamId === teamId &&
          candidate.organizationId === organizationId,
      );
      if (row === undefined) {
        return null;
      }
      row.revokedAt = at;
      return withoutHash(row);
    },

    async createRepoLink(input) {
      const row: RepoLinkRow = { ...input, createdAt: new Date() };
      repoLinks.push(row);
      return { ...row };
    },

    async listRepoLinks(organizationId) {
      return repoLinks
        .filter((row) => row.organizationId === organizationId)
        .map((row) => ({ ...row }))
        .reverse();
    },

    async deleteRepoLink(id, organizationId) {
      const index = repoLinks.findIndex(
        (row) => row.id === id && row.organizationId === organizationId,
      );
      if (index < 0) {
        return false;
      }
      repoLinks.splice(index, 1);
      return true;
    },

    async findRepoLinkByRepoId(repoId) {
      const row = repoLinks.find((candidate) => candidate.repoId === repoId);
      return row === undefined ? null : { ...row };
    },

    // Reads the same in-memory store Better Auth's memory adapter writes, so a
    // team created through the plugin is visible here exactly as the join in
    // the Drizzle implementation would see it.
    async findTeamContext(teamId) {
      const teams = betterAuthStore.team as {
        id: string;
        name: string;
        slug?: string;
        organizationId: string;
        archivedAt?: Date | null;
      }[];
      const organizations = betterAuthStore.organization as {
        id: string;
        slug: string;
      }[];

      const found = teams.find((row) => row.id === teamId);
      if (found === undefined) {
        return null;
      }
      const owner = organizations.find(
        (row) => row.id === found.organizationId,
      );
      if (owner === undefined) {
        return null;
      }
      const context: TeamContext = {
        teamId: found.id,
        teamSlug: found.slug ?? "",
        teamName: found.name,
        archivedAt: found.archivedAt ?? null,
        organizationId: owner.id,
        organizationSlug: owner.slug,
      };
      return context;
    },

    async isTeamMember(teamId, userId) {
      const members = betterAuthStore.teamMember as {
        teamId: string;
        userId: string;
      }[];
      return members.some(
        (row) => row.teamId === teamId && row.userId === userId,
      );
    },

    async createArtifact(input) {
      const { files, ...header } = input;
      const row: ArtifactRow = {
        ...header,
        publishedAt: null,
        completionNote: null,
      };
      artifacts.push(row);
      for (const file of files) {
        artifactFiles.push({ ...file, artifactId: row.id });
      }
      return { ...row };
    },

    async shortIdTaken(teamId, shortId) {
      return artifacts.some(
        (row) => row.teamId === teamId && row.shortId === shortId,
      );
    },

    async findArtifactById(id) {
      const row = artifacts.find((candidate) => candidate.id === id);
      return row === undefined ? null : { ...row };
    },

    async findArtifactsByShortId(shortId) {
      return artifacts
        .filter((row) => row.shortId === shortId)
        .map((row) => ({ ...row }));
    },

    async listArtifactFiles(artifactId) {
      return artifactFiles
        .filter((row) => row.artifactId === artifactId)
        .map((row) => ({ ...row }))
        .sort((left, right) => left.path.localeCompare(right.path));
    },

    async listArtifacts(teamId, limit, before) {
      return artifacts
        .filter(
          (row) =>
            row.teamId === teamId && (before === null || row.id < before),
        )
        .sort((left, right) => (left.id < right.id ? 1 : -1))
        .slice(0, limit)
        .map((row) => ({ ...row }));
    },

    async completeArtifact(id, at, note) {
      const row = artifacts.find((candidate) => candidate.id === id);
      if (row === undefined) {
        return null;
      }
      row.publishedAt = at;
      row.completionNote = note;
      return { ...row };
    },
  };
}
