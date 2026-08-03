import { API_ORIGIN } from "./config";

/**
 * The platform's own routes, the ones that are not Better Auth's: onboarding,
 * contributor teams, their members and keys, repository links, and invitations.
 *
 * Every one of them goes through `request` below, so there is exactly one place
 * that knows how this API reports a failure. That matters because the answer is
 * always the same shape (`{ error }`) and the wrong thing to do with it is the
 * easy thing: swallow it, or let a non-JSON edge response become a parse crash
 * that reaches a person as a blank screen.
 */

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

async function request<T>(
  path: string,
  init: { method?: string; body?: unknown } = {},
): Promise<T> {
  const response = await fetch(`${API_ORIGIN}${path}`, {
    method: init.method ?? "GET",
    credentials: "include",
    ...(init.body === undefined
      ? {}
      : {
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(init.body),
        }),
  });

  // The routes answer JSON on every path they own, but a gateway or edge error
  // in front of them does not, so a non-JSON body has to become a message
  // rather than a parse crash.
  let payload: { error?: string } & Record<string, unknown>;
  try {
    payload = (await response.json()) as typeof payload;
  } catch {
    throw new ApiError(
      `the server answered ${response.status} with no readable body`,
      response.status,
    );
  }

  if (!response.ok) {
    throw new ApiError(
      payload.error ?? `the server answered ${response.status}`,
      response.status,
    );
  }
  return payload as T;
}

export interface Organization {
  id: string;
  name: string;
  slug: string;
}

export async function createOrganization(input: {
  organizationName: string;
  organizationSlug: string;
}): Promise<Organization> {
  const body = await request<{ organization?: Organization }>(
    "/v1/onboarding",
    { method: "POST", body: input },
  );
  if (body.organization === undefined) {
    // A 2xx that did not carry what it promised. Reported as a server fault
    // rather than silently returning an empty organization the dashboard would
    // then render as blank.
    throw new ApiError("the server did not return an organization", 500);
  }
  return body.organization;
}

/** The slug rule the API enforces, mirrored so a typo is caught before a round trip. */
export const SLUG_PATTERN = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

export interface Team {
  id: string;
  name: string;
  slug: string;
  organizationId: string;
  createdAt: string | null;
  archivedAt: string | null;
}

export interface TeamMember {
  id: string;
  userId: string;
  name: string;
  email: string;
  createdAt: string | null;
}

export interface ApiKey {
  id: string;
  name: string;
  keyPrefix: string;
  teamId: string;
  createdByUserId: string;
  createdAt: string;
  lastUsedAt: string | null;
  expiresAt: string | null;
  revokedAt: string | null;
}

export interface Invitation {
  id: string;
  email: string;
  role: string | null;
  status: string;
  organizationId: string;
  teamId: string | null;
  expiresAt: string | null;
}

export async function listTeams(): Promise<Team[]> {
  return (await request<{ teams: Team[] }>("/v1/teams")).teams;
}

export async function createTeam(input: {
  name: string;
  slug: string;
}): Promise<Team> {
  return (
    await request<{ team: Team }>("/v1/teams", { method: "POST", body: input })
  ).team;
}

export async function renameTeam(id: string, name: string): Promise<Team> {
  return (
    await request<{ team: Team }>(`/v1/teams/${id}`, {
      method: "PATCH",
      body: { name },
    })
  ).team;
}

export async function archiveTeam(id: string): Promise<Team> {
  return (
    await request<{ team: Team }>(`/v1/teams/${id}/archive`, { method: "POST" })
  ).team;
}

export async function listTeamMembers(id: string): Promise<TeamMember[]> {
  return (await request<{ members: TeamMember[] }>(`/v1/teams/${id}/members`))
    .members;
}

export async function addTeamMember(
  id: string,
  userId: string,
): Promise<void> {
  await request(`/v1/teams/${id}/members`, {
    method: "POST",
    body: { userId },
  });
}

export async function removeTeamMember(
  id: string,
  userId: string,
): Promise<void> {
  await request(`/v1/teams/${id}/members/${userId}`, { method: "DELETE" });
}

export async function listKeys(teamId: string): Promise<ApiKey[]> {
  return (await request<{ keys: ApiKey[] }>(`/v1/teams/${teamId}/keys`)).keys;
}

/**
 * The raw key comes back on this one call and never again. The caller is
 * responsible for putting it in front of a person before it is lost, which is
 * why it is returned alongside the row rather than folded into it.
 */
export async function mintKey(
  teamId: string,
  name: string,
): Promise<{ key: string; apiKey: ApiKey }> {
  return request<{ key: string; apiKey: ApiKey }>(
    `/v1/teams/${teamId}/keys`,
    { method: "POST", body: { name } },
  );
}

export async function revokeKey(
  teamId: string,
  keyId: string,
): Promise<ApiKey> {
  return (
    await request<{ apiKey: ApiKey }>(
      `/v1/teams/${teamId}/keys/${keyId}/revoke`,
      { method: "POST" },
    )
  ).apiKey;
}

export interface Artifact {
  id: string;
  shortId: string;
  teamId: string;
  organizationId: string;
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
  viewerUrl: string;
  generatedAt: string;
  publishedAt: string | null;
  expiresAt: string | null;
  completionNote: string | null;
}

export interface ArtifactPage {
  artifacts: Artifact[];
  nextCursor: string | null;
}

export async function listArtifacts(
  teamId: string,
  before?: string | null,
): Promise<ArtifactPage> {
  const query = new URLSearchParams({ teamId });
  if (before !== undefined && before !== null && before !== "") {
    query.set("before", before);
  }
  return request<ArtifactPage>(`/v1/artifacts?${query.toString()}`);
}

/**
 * What the authorize route says once it has set the cookies.
 *
 * `viewerPrefix` is the part that matters to the caller: every URL the cookies
 * just granted starts with it, so it is what a `next` is checked against before
 * the browser is sent anywhere.
 */
export interface ViewerAuthorization {
  teamId: string;
  teamSlug: string;
  organizationSlug: string;
  viewerPrefix: string;
  expiresAt: string;
}

/**
 * Asks the API for CloudFront viewer cookies for a team.
 *
 * The cookies arrive as Set-Cookie headers on this very response and are
 * scoped to .staging.changefabric.org, so they are the browser's from the
 * moment this resolves. That only works because the call is same-origin
 * through the /v1/* proxy: a cross-origin response's Set-Cookie for a parent
 * domain would be dropped, which is one more reason config.ts points at this
 * app's own origin.
 */
export async function authorizeViewer(
  teamId: string,
): Promise<ViewerAuthorization> {
  return request<ViewerAuthorization>(
    `/v1/artifacts/authorize?teamId=${encodeURIComponent(teamId)}`,
  );
}

export async function createInvitation(input: {
  email: string;
  teamId?: string;
}): Promise<Invitation> {
  return (
    await request<{ invitation: Invitation }>("/v1/invitations", {
      method: "POST",
      body: {
        email: input.email,
        ...(input.teamId === undefined || input.teamId === ""
          ? {}
          : { teamId: input.teamId }),
      },
    })
  ).invitation;
}

export async function getInvitation(id: string): Promise<Invitation> {
  return (await request<{ invitation: Invitation }>(`/v1/invitations/${id}`))
    .invitation;
}

export async function acceptInvitation(id: string): Promise<Invitation> {
  return (
    await request<{ invitation: Invitation }>(`/v1/invitations/${id}/accept`, {
      method: "POST",
    })
  ).invitation;
}
