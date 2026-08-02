import type { Hono } from "hono";
import {
  artifactKeyPrefix,
  artifactViewerUrl,
  looksLikeShortId,
  parseArtifactManifest,
  teamKeyPrefix,
  UPLOAD_URL_TTL_SECONDS,
  VIEWER_COOKIE_TTL_SECONDS,
  viewerResource,
} from "../artifacts.js";
import type { ArtifactsSettings } from "../config.js";
import { newShortId, newUlid } from "../ids.js";
import { cookieHeaders, signViewerCookies } from "../signed-cookies.js";
import type { ArtifactStorage } from "../storage.js";
import type {
  ArtifactFileRow,
  ArtifactRow,
  PlatformStore,
  TeamContext,
} from "../store.js";
import {
  readJsonBody,
  requireCaller,
  requireKeyCaller,
  requireParam,
  requireSession,
  RouteError,
  type RouteDependencies,
} from "./context.js";

/**
 * Publishing, listing and reading a findings artifact.
 *
 * Three callers reach these routes, and they are authorised in three different
 * ways on purpose:
 *
 *   a person's browser   session, plus a team_member row, and it leaves with
 *                        CloudFront signed cookies rather than with bytes
 *   a person's tooling   session, for the publish path when a human runs it
 *   a machine            an x-cf-key team API key, which has no user at all
 *
 * The bytes themselves never pass through this Lambda in either direction. An
 * upload is a presigned PUT straight to S3 and a machine download is a
 * presigned GET straight back out, so a hundred-megabyte bundle costs this
 * function one signature and no transfer. A browser does not even get a
 * presigned URL: it gets cookies, and CloudFront enforces them at the edge on
 * every object.
 *
 * The staging Basic Auth gate in app.ts still sits in front of all of it, as it
 * does for every route except /healthz.
 */

/** Default and ceiling for the listing route's page size. */
const DEFAULT_PAGE_SIZE = 25;
const MAX_PAGE_SIZE = 100;

/** How long a machine's presigned download URLs stay good. */
const DOWNLOAD_URL_TTL_SECONDS = 15 * 60;

/** How many short ids to try before giving up. Fifty bits collides rarely. */
const SHORT_ID_ATTEMPTS = 5;

export interface ArtifactRouteDependencies extends RouteDependencies {
  /**
   * Null when this deployment has no artifacts host. Resolved per request for
   * the same reason `auth` and `store` are: constructing the app must not read
   * SSM, or /healthz would stop answering on a cold start that cannot.
   */
  artifacts: () => Promise<{
    settings: ArtifactsSettings;
    storage: ArtifactStorage;
  } | null>;
}

/** The response shape for an artifact. It never carries a key or a raw prefix. */
function toArtifactView(row: ArtifactRow, origin: string) {
  return {
    id: row.id,
    shortId: row.shortId,
    teamId: row.teamId,
    organizationId: row.organizationId,
    repoId: row.repoId,
    contributorUserId: row.contributorUserId,
    contributorLabel: row.contributorLabel,
    project: row.project,
    branch: row.branch,
    headSha: row.headSha,
    prNumber: row.prNumber,
    prUrl: row.prUrl,
    status: row.status,
    failCount: row.failCount,
    warnCount: row.warnCount,
    byteSize: row.byteSize,
    viewerUrl: artifactViewerUrl(origin, row.keyPrefix),
    generatedAt: row.generatedAt.toISOString(),
    publishedAt: row.publishedAt?.toISOString() ?? null,
    expiresAt: row.expiresAt?.toISOString() ?? null,
    completionNote: row.completionNote,
  };
}

/**
 * The artifacts host, or a refusal a caller can act on.
 *
 * 404 rather than 500: an API deployed without the artifacts environment is
 * correctly configured for everything else it serves, and these routes simply
 * do not exist in that deployment. Answering as though something broke would
 * send whoever is looking at it hunting for a fault that is not there.
 */
async function requireArtifacts(deps: ArtifactRouteDependencies) {
  const resolved = await deps.artifacts();
  if (resolved === null) {
    throw new RouteError(404, "this deployment has no artifacts host");
  }
  return resolved;
}

/** A team that exists, or a 404 that does not say whose it is. */
async function requireTeam(
  store: PlatformStore,
  teamId: string,
): Promise<TeamContext> {
  const context = await store.findTeamContext(teamId);
  if (context === null) {
    throw new RouteError(404, "no such team");
  }
  return context;
}

/**
 * A team the CALLER may act on, refused with 404 rather than 403 when it
 * belongs to another organization.
 *
 * The distinction matters. A caller who names a team id from an organization
 * they are not in has no business learning that the id exists, so the answer is
 * the same one they would get for an id that never existed. A 403 is reserved
 * for a team they can see and an action they may not take on it.
 */
function requireSameOrganization(
  team: TeamContext,
  organizationId: string,
): TeamContext {
  if (team.organizationId !== organizationId) {
    throw new RouteError(404, "no such team");
  }
  return team;
}

/**
 * A short id nobody on this team is using, or a refusal.
 *
 * The unique index is the guarantee and stays the guarantee. This loop exists
 * so the ordinary case never reaches it: a collision at fifty bits is rare
 * enough that hitting the index would surface as an opaque 500 for something
 * that has an obvious retry.
 */
async function allocateShortId(
  store: PlatformStore,
  teamId: string,
): Promise<string> {
  for (let attempt = 0; attempt < SHORT_ID_ATTEMPTS; attempt += 1) {
    const candidate = newShortId();
    if (!(await store.shortIdTaken(teamId, candidate))) {
      return candidate;
    }
  }
  throw new RouteError(
    409,
    "could not allocate a short id for this team, try again",
  );
}

/**
 * What the upload actually turned out to be, compared with what was declared.
 *
 * Best effort by design, and the design is stated here rather than implied: a
 * mismatch does NOT fail the completion. The bytes are already in the bucket by
 * the time this runs, and refusing to publish would leave a paid-for upload
 * unreachable while changing nothing about what is stored. Recording a note
 * makes the discrepancy visible to a person without making it destructive.
 *
 * A missing object is the one finding worth its own wording, because it is the
 * difference between "this run uploaded something unexpected" and "this run
 * never finished".
 */
async function completionNote(
  storage: ArtifactStorage,
  keyPrefix: string,
  files: ArtifactFileRow[],
): Promise<{ note: string | null; uploadedBytes: number }> {
  const findings: string[] = [];
  let uploadedBytes = 0;

  for (const file of files) {
    const stored = await storage.head(`${keyPrefix}${file.path}`);
    if (stored === null) {
      findings.push(`${file.path} was never uploaded`);
      continue;
    }
    uploadedBytes += stored.bytes;
    if (stored.bytes !== file.bytes) {
      findings.push(
        `${file.path} declared ${file.bytes} bytes and stored ${stored.bytes}`,
      );
    }
    if (
      file.sha256 !== null &&
      stored.sha256 !== null &&
      stored.sha256 !== file.sha256
    ) {
      findings.push(`${file.path} sha-256 does not match what was declared`);
    }
  }

  return {
    note: findings.length === 0 ? null : findings.join("; "),
    uploadedBytes,
  };
}

/** A positive integer query parameter within a ceiling, or the default. */
function pageSize(raw: string | undefined): number {
  if (raw === undefined || raw === "") {
    return DEFAULT_PAGE_SIZE;
  }
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isInteger(parsed) || parsed < 1) {
    throw new RouteError(400, "limit must be a positive whole number");
  }
  return Math.min(parsed, MAX_PAGE_SIZE);
}

export function registerArtifactRoutes(
  app: Hono,
  deps: ArtifactRouteDependencies,
): void {
  /**
   * Announce a run and get somewhere to put it.
   *
   * The row and the presigned URLs are produced together and the URLs are for
   * exactly the keys the rows describe, so there is no window in which a caller
   * holds a URL for a file the database does not know about.
   */
  app.post("/v1/artifacts", async (c) => {
    const { settings, storage } = await requireArtifacts(deps);
    const store = await deps.store();
    const manifest = parseArtifactManifest(await readJsonBody(c));
    const now = deps.now();

    // Either identity is acceptable here, and which one it is changes only what
    // is recorded as the contributor. A key names a team, so it can name no
    // user; a session names a person, so it does.
    let organizationId: string;
    let contributorUserId: string | null = null;
    let contributorLabel = manifest.contributorLabel;
    let sessionUserId: string | null = null;

    if (c.req.header("x-cf-key") !== undefined) {
      const key = await requireKeyCaller(store, c.req.raw.headers, now);
      if (key.teamId !== manifest.teamId) {
        throw new RouteError(403, "this key is not scoped to that team");
      }
      organizationId = key.organizationId;
      contributorLabel ??= key.keyName;
    } else {
      const auth = await deps.auth();
      const caller = await requireCaller(auth, c.req.raw.headers);
      organizationId = caller.organizationId;
      contributorUserId = caller.userId;
      sessionUserId = caller.userId;
      // A person publishing under their own session is the contributor, and
      // their address is the label that means something to whoever reads the
      // listing later.
      contributorLabel ??= caller.userEmail;
    }

    // Ordered so the two refusals cannot be confused with each other. Whether
    // the team is even visible to this caller is settled first, so a team in
    // another organization answers 404 rather than the 403 that would confirm
    // it exists. Only then is "you are not on it" asked.
    const team = requireSameOrganization(
      await requireTeam(store, manifest.teamId),
      organizationId,
    );
    if (
      sessionUserId !== null &&
      !(await store.isTeamMember(team.teamId, sessionUserId))
    ) {
      throw new RouteError(403, "you are not on that team");
    }
    if (team.archivedAt !== null) {
      throw new RouteError(409, "this team is archived and cannot publish");
    }

    const shortId = await allocateShortId(store, team.teamId);
    const keyPrefix = artifactKeyPrefix(
      team.organizationSlug,
      team.teamSlug,
      shortId,
    );

    const row = await store.createArtifact({
      id: newUlid(now.getTime()),
      organizationId,
      teamId: team.teamId,
      shortId,
      repoId: manifest.repoId,
      contributorUserId,
      contributorLabel,
      project: manifest.project,
      branch: manifest.branch,
      headSha: manifest.headSha,
      prNumber: manifest.prNumber,
      prUrl: manifest.prUrl,
      status: manifest.status,
      failCount: manifest.failCount,
      warnCount: manifest.warnCount,
      byteSize: manifest.files.reduce((total, file) => total + file.bytes, 0),
      keyPrefix,
      generatedAt: manifest.generatedAt ?? now,
      expiresAt: null,
      files: manifest.files.map((file) => ({
        id: newUlid(now.getTime()),
        path: file.path,
        contentType: file.contentType,
        bytes: file.bytes,
        sha256: file.sha256,
      })),
    });

    const uploads = await storage.presignUploads(
      manifest.files.map((file) => ({
        path: file.path,
        key: `${keyPrefix}${file.path}`,
        contentType: file.contentType,
      })),
      UPLOAD_URL_TTL_SECONDS,
    );

    return c.json(
      {
        artifactId: row.id,
        shortId: row.shortId,
        viewerUrl: artifactViewerUrl(settings.origin, keyPrefix),
        expiresInSeconds: UPLOAD_URL_TTL_SECONDS,
        uploads,
      },
      201,
    );
  });

  /**
   * Say the upload finished.
   *
   * Authorised the same two ways as the create, and scoped to the artifact's
   * own team either way, so one team cannot complete another's run.
   */
  app.post("/v1/artifacts/:id/complete", async (c) => {
    const { settings, storage } = await requireArtifacts(deps);
    const store = await deps.store();
    const now = deps.now();
    const artifactId = requireParam(c, "id");

    const row = await store.findArtifactById(artifactId);
    if (row === null) {
      throw new RouteError(404, "no such artifact");
    }

    if (c.req.header("x-cf-key") !== undefined) {
      const key = await requireKeyCaller(store, c.req.raw.headers, now);
      if (key.teamId !== row.teamId) {
        throw new RouteError(404, "no such artifact");
      }
    } else {
      const auth = await deps.auth();
      const caller = await requireCaller(auth, c.req.raw.headers);
      if (caller.organizationId !== row.organizationId) {
        throw new RouteError(404, "no such artifact");
      }
      if (!(await store.isTeamMember(row.teamId, caller.userId))) {
        throw new RouteError(403, "you are not on that team");
      }
    }

    const files = await store.listArtifactFiles(row.id);
    const checked = await completionNote(storage, row.keyPrefix, files);

    const completed = await store.completeArtifact(row.id, now, checked.note);
    if (completed === null) {
      throw new RouteError(404, "no such artifact");
    }

    return c.json({
      artifact: toArtifactView(completed, settings.origin),
      uploadedBytes: checked.uploadedBytes,
      note: checked.note,
    });
  });

  /**
   * A team's artifacts, newest first.
   *
   * Reading is an organization member's right, which is why this asks only for
   * organization membership and not for a team_member row: a person who can see
   * that a team exists can see what it published. Reading the FILES is a
   * different question and is answered by the authorize route below.
   */
  app.get("/v1/artifacts", async (c) => {
    const { settings } = await requireArtifacts(deps);
    const auth = await deps.auth();
    const caller = await requireCaller(auth, c.req.raw.headers);
    const store = await deps.store();

    const teamId = c.req.query("teamId");
    if (teamId === undefined || teamId === "") {
      throw new RouteError(400, "teamId is required");
    }
    const team = requireSameOrganization(
      await requireTeam(store, teamId),
      caller.organizationId,
    );

    const limit = pageSize(c.req.query("limit"));
    // One more than asked for, so "is there another page" is a fact about rows
    // rather than a guess from a full page.
    const rows = await store.listArtifacts(
      team.teamId,
      limit + 1,
      c.req.query("before") ?? null,
    );
    const page = rows.slice(0, limit);

    return c.json({
      artifacts: page.map((row) => toArtifactView(row, settings.origin)),
      nextCursor: rows.length > limit ? (page.at(-1)?.id ?? null) : null,
    });
  });

  /**
   * The browser's path in: a session becomes CloudFront signed cookies.
   *
   * This is the only route that answers with Set-Cookie, and the cookies it
   * sets are not this application's. They are CloudFront's, verified at the
   * edge by a trusted key group against a public key Terraform manages, so this
   * route's own correctness is not the last line of defence: a forged cookie
   * fails at CloudFront regardless of what this decided.
   *
   * The scope is the team's whole prefix for eight hours, not one artifact,
   * because the question answered here does not change between two runs of the
   * same team.
   */
  app.get("/v1/artifacts/authorize", async (c) => {
    const { settings } = await requireArtifacts(deps);
    const auth = await deps.auth();
    const store = await deps.store();
    const session = await requireSession(auth, c.req.raw.headers);

    const teamId = c.req.query("teamId");
    if (teamId === undefined || teamId === "") {
      throw new RouteError(400, "teamId is required");
    }
    const team = await requireTeam(store, teamId);

    // The team_member row, and nothing else. Not the organization role: an
    // owner who is not on a team is not on that team, and the cookie this mints
    // is a key to that team's files.
    if (!(await store.isTeamMember(team.teamId, session.userId))) {
      throw new RouteError(403, "you are not on that team");
    }

    const expires = new Date(
      deps.now().getTime() + VIEWER_COOKIE_TTL_SECONDS * 1000,
    );
    const cookies = signViewerCookies(
      { keyPairId: settings.keyPairId, privateKey: settings.privateKey },
      viewerResource(
        settings.origin,
        team.organizationSlug,
        team.teamSlug,
      ),
      expires,
    );

    for (const header of cookieHeaders(cookies, {
      domain: settings.cookieDomain,
      expires,
    })) {
      // append, not set: three Set-Cookie headers, not one joined value. A
      // comma-joined Set-Cookie is not what a browser parses.
      c.header("Set-Cookie", header, { append: true });
    }

    return c.json({
      teamId: team.teamId,
      teamSlug: team.teamSlug,
      organizationSlug: team.organizationSlug,
      resourcePrefix: teamKeyPrefix(team.organizationSlug, team.teamSlug),
      // Every URL these cookies are good for starts with this string. The web
      // app checks the `next` it was handed against it before following it,
      // which is what keeps the authorize route from being an open redirect: the
      // only thing that can send a browser somewhere is a value the server just
      // said it had authorised.
      viewerPrefix: artifactViewerUrl(
        settings.origin,
        teamKeyPrefix(team.organizationSlug, team.teamSlug),
      ),
      expiresAt: expires.toISOString(),
    });
  });

  /**
   * The machine's path in: a team API key becomes presigned GET URLs.
   *
   * No cookies are involved and none would help, because the caller is a CI job
   * with no cookie jar and no browser. It gets one URL per file, each good for
   * fifteen minutes and each for exactly one key.
   *
   * Short ids are unique per team, so the lookup is by short id and then
   * narrowed to the key's own team rather than the other way round. A short id
   * that exists on somebody else's team answers 404, which is the same answer
   * as one that exists nowhere.
   */
  app.get("/v1/artifacts/:shortId/download", async (c) => {
    const { settings, storage } = await requireArtifacts(deps);
    const store = await deps.store();
    const shortId = requireParam(c, "shortId");
    if (!looksLikeShortId(shortId)) {
      throw new RouteError(400, "that is not a short id");
    }

    const caller = await requireKeyCaller(store, c.req.raw.headers, deps.now());
    const candidates = await store.findArtifactsByShortId(shortId);
    const row = candidates.find(
      (candidate) => candidate.teamId === caller.teamId,
    );
    if (row === undefined) {
      throw new RouteError(404, "no such artifact");
    }

    const files = await store.listArtifactFiles(row.id);
    const downloads = await storage.presignDownloads(
      files.map((file) => ({
        path: file.path,
        key: `${row.keyPrefix}${file.path}`,
      })),
      DOWNLOAD_URL_TTL_SECONDS,
    );

    return c.json({
      artifact: toArtifactView(row, settings.origin),
      expiresInSeconds: DOWNLOAD_URL_TTL_SECONDS,
      files: downloads.map((download) => {
        const declared = files.find((file) => file.path === download.path);
        return {
          path: download.path,
          url: download.url,
          bytes: declared?.bytes ?? 0,
          contentType: declared?.contentType ?? "application/octet-stream",
          sha256: declared?.sha256 ?? null,
        };
      }),
    });
  });
}
