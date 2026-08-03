import { looksLikeShortId } from "./ids.js";
import { ValidationError } from "./validation.js";

/**
 * Everything about an artifact that is decidable without AWS or Postgres: what
 * a key prefix is, what a file path is allowed to be, and what a caller is
 * allowed to declare.
 *
 * It lives apart from the route for one reason: the path rules below are the
 * only thing standing between a caller-supplied string and an S3 key that a
 * presigned URL then makes writable. That is worth being testable on its own,
 * with no bucket anywhere near it.
 */

/** The largest manifest this phase accepts. A findings bundle is tens of files. */
export const MAX_FILES_PER_ARTIFACT = 200;

/** How long a presigned upload URL is good for. */
export const UPLOAD_URL_TTL_SECONDS = 15 * 60;

/** How long a browser's CloudFront signed cookies last. */
export const VIEWER_COOKIE_TTL_SECONDS = 8 * 60 * 60;

const STATUSES = new Set(["pass", "fail", "warn"]);

/**
 * Where one run's files live, as a prefix ending in a slash.
 *
 * Both slugs are already constrained to lower-case alphanumerics and internal
 * hyphens by validation.SLUG_PATTERN, and the short id to Crockford base32, so
 * no component here can contain a slash, a dot segment, or anything else that
 * would change the shape of the key. That is why this function does no escaping:
 * there is nothing left to escape.
 */
export function artifactKeyPrefix(
  organizationSlug: string,
  teamSlug: string,
  shortId: string,
): string {
  return `${teamKeyPrefix(organizationSlug, teamSlug)}${shortId}/`;
}

/**
 * Everything one team owns, as a prefix ending in a slash.
 *
 * A separate function rather than `artifactKeyPrefix(org, team, "")`, which is
 * what this started as. That spelling produced a trailing double slash, and the
 * double slash was not cosmetic: the web app checks the URL it was asked to
 * redirect to against this prefix, and `org/team//` is not a prefix of
 * `org/team/ABCDEFGHJK/`, so every authorize round trip silently discarded where
 * the person was going and dropped them at a directory that does not exist. It
 * is written out here so the two prefixes cannot drift into disagreeing again.
 */
export function teamKeyPrefix(
  organizationSlug: string,
  teamSlug: string,
): string {
  return `${organizationSlug}/${teamSlug}/`;
}

/**
 * A file path inside an artifact, or a refusal.
 *
 * This is the security-carrying function in this file. A presigned PUT is
 * issued for exactly the key this returns, so anything that lets a path escape
 * its own prefix lets a caller write somewhere it was never authorised for.
 * Rather than trying to sanitise, it refuses: leading slashes, any `.` or `..`
 * segment, backslashes, empty segments, and control characters are all rejected
 * outright rather than stripped, because a stripped path is a path that meant
 * something different from what was sent.
 */
export function normalizeArtifactPath(raw: string): string {
  const value = raw.trim();
  if (value === "") {
    throw new ValidationError("a file path must not be empty");
  }
  if (value.length > 512) {
    throw new ValidationError(`file path is too long: ${value.slice(0, 40)}`);
  }
  if (value.startsWith("/")) {
    throw new ValidationError(`file path must be relative: ${value}`);
  }
  if (value.includes("\\")) {
    throw new ValidationError(`file path must use forward slashes: ${value}`);
  }
  // Control characters, including the newline that would let a path forge a
  // second line in anything that logs it. Written as escapes so the checked-in
  // source carries no literal control bytes.
  if (/[\u0000-\u001f\u007f]/.test(value)) {
    throw new ValidationError("file path must not contain control characters");
  }

  const segments = value.split("/");
  for (const segment of segments) {
    if (segment === "") {
      throw new ValidationError(`file path has an empty segment: ${value}`);
    }
    if (segment === "." || segment === "..") {
      throw new ValidationError(`file path must not contain ${segment}: ${value}`);
    }
  }
  return value;
}

export interface DeclaredFile {
  path: string;
  contentType: string;
  bytes: number;
  sha256: string | null;
}

export interface ArtifactManifest {
  teamId: string;
  repoId: string | null;
  project: string | null;
  branch: string | null;
  headSha: string | null;
  prNumber: number | null;
  prUrl: string | null;
  status: string;
  failCount: number;
  warnCount: number;
  contributorLabel: string | null;
  generatedAt: Date | null;
  files: DeclaredFile[];
}

function optionalString(
  body: Record<string, unknown>,
  field: string,
): string | null {
  const value = body[field];
  if (value === undefined || value === null || value === "") {
    return null;
  }
  if (typeof value !== "string") {
    throw new ValidationError(`${field} must be a string when present`);
  }
  return value.trim() === "" ? null : value.trim();
}

/**
 * A non-negative integer, refused rather than coerced. `Number.isSafeInteger`
 * rather than `Number.isInteger` because these end up in a bigint column and a
 * value past 2^53 would already have lost precision before it got here.
 */
function countField(
  body: Record<string, unknown>,
  field: string,
  fallback: number | null = null,
): number {
  const value = body[field];
  if (value === undefined || value === null) {
    if (fallback === null) {
      throw new ValidationError(`${field} is required`);
    }
    return fallback;
  }
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new ValidationError(`${field} must be a non-negative whole number`);
  }
  return value;
}

/**
 * A SHA-256 digest as 64 lower-case hex characters, or null.
 *
 * Normalised to lower case here so the completion check compares like with
 * like: S3 reports an object's checksum in one casing and a caller may well
 * declare it in another, and a mismatch on casing alone would be a note about
 * nothing.
 */
function digestField(
  body: Record<string, unknown>,
  field: string,
): string | null {
  const value = body[field];
  if (value === undefined || value === null || value === "") {
    return null;
  }
  if (typeof value !== "string" || !/^[0-9a-fA-F]{64}$/.test(value.trim())) {
    throw new ValidationError(`${field} must be a 64-character hex sha-256`);
  }
  return value.trim().toLowerCase();
}

/**
 * A content type, defaulted rather than guessed from the extension.
 *
 * Guessing here would mean two places in the estate decide what an `.html` file
 * is, and the caller's tooling already knows. `application/octet-stream` is the
 * honest answer when nobody said.
 */
function contentTypeField(value: unknown): string {
  if (value === undefined || value === null || value === "") {
    return "application/octet-stream";
  }
  if (typeof value !== "string" || !/^[\w.+-]+\/[\w.+-]+/.test(value.trim())) {
    throw new ValidationError("contentType must be a media type");
  }
  return value.trim();
}

function parseDeclaredFile(raw: unknown, index: number): DeclaredFile {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw new ValidationError(`files[${index}] must be an object`);
  }
  const record = raw as Record<string, unknown>;
  const path = record.path;
  if (typeof path !== "string") {
    throw new ValidationError(`files[${index}].path must be a string`);
  }
  return {
    path: normalizeArtifactPath(path),
    contentType: contentTypeField(record.contentType),
    bytes: countField(record, "bytes"),
    sha256: digestField(record, "sha256"),
  };
}

/** An ISO timestamp, or null. Refused rather than silently becoming Invalid Date. */
function timestampField(
  body: Record<string, unknown>,
  field: string,
): Date | null {
  const value = body[field];
  if (value === undefined || value === null || value === "") {
    return null;
  }
  if (typeof value !== "string") {
    throw new ValidationError(`${field} must be an ISO 8601 string`);
  }
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    throw new ValidationError(`${field} must be an ISO 8601 string`);
  }
  return parsed;
}

export function parseArtifactManifest(body: unknown): ArtifactManifest {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    throw new ValidationError("body must be a JSON object");
  }
  const record = body as Record<string, unknown>;

  const teamId = record.teamId;
  if (typeof teamId !== "string" || teamId.trim() === "") {
    throw new ValidationError("teamId must be a non-empty string");
  }

  const status = record.status;
  if (typeof status !== "string" || !STATUSES.has(status)) {
    throw new ValidationError("status must be one of pass, fail, warn");
  }

  const files = record.files;
  if (!Array.isArray(files) || files.length === 0) {
    throw new ValidationError("files must be a non-empty array");
  }
  if (files.length > MAX_FILES_PER_ARTIFACT) {
    throw new ValidationError(
      `an artifact may declare at most ${MAX_FILES_PER_ARTIFACT} files`,
    );
  }

  const parsed = files.map(parseDeclaredFile);
  const seen = new Set<string>();
  for (const file of parsed) {
    if (seen.has(file.path)) {
      throw new ValidationError(`files declares ${file.path} twice`);
    }
    seen.add(file.path);
  }

  return {
    teamId: teamId.trim(),
    repoId: optionalString(record, "repoId"),
    project: optionalString(record, "project"),
    branch: optionalString(record, "branch"),
    headSha: optionalString(record, "headSha"),
    prNumber:
      record.prNumber === undefined || record.prNumber === null
        ? null
        : countField(record, "prNumber"),
    prUrl: optionalString(record, "prUrl"),
    status,
    failCount: countField(record, "failCount", 0),
    warnCount: countField(record, "warnCount", 0),
    contributorLabel: optionalString(record, "contributorLabel"),
    generatedAt: timestampField(record, "generatedAt"),
    files: parsed,
  };
}

/**
 * The entry-point prefix on the artifacts host.
 *
 * Everything under it is served by a cache behavior with NO CloudFront key
 * group, which is what lets the viewer-request function run at all: CloudFront
 * evaluates a key group before it invokes a function, so a cookieless request to
 * a protected path is refused before anything can challenge for Basic Auth or
 * offer the person a way to get a cookie. Nothing under this prefix ever returns
 * bytes; the function answers every one of them with a 401 or a 302 onto the
 * real object path, which IS key-group protected. See platform/infra/artifacts.tf.
 */
export const VIEWER_ENTRY_PREFIX = "v";

/**
 * The URL a person opens.
 *
 * It ends in a slash, and the edge redirects it to the run's index.html once the
 * viewer holds cookies. It is NOT the same string as the S3 key prefix, and the
 * difference is the entry prefix above.
 */
export function artifactViewerUrl(
  artifactsOrigin: string,
  keyPrefix: string,
): string {
  return `${artifactsOrigin.replace(/\/+$/, "")}/${VIEWER_ENTRY_PREFIX}/${keyPrefix}`;
}

/**
 * The CloudFront resource a browser's cookies are scoped to.
 *
 * A TEAM, not an artifact. Scoping per artifact would mean a fresh round trip
 * to the authorize route on every run a person opens, and the question the
 * cookie answers ("may this person read this team's artifacts") does not change
 * between two runs of the same team. Eight hours of that answer is the trade
 * this phase makes, and it is stated in the plan.
 */
export function viewerResource(
  artifactsOrigin: string,
  organizationSlug: string,
  teamSlug: string,
): string {
  return `${artifactsOrigin.replace(/\/+$/, "")}/${organizationSlug}/${teamSlug}/*`;
}

export { looksLikeShortId };
