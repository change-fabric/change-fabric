/**
 * Reading a JSON request body without trusting a single thing in it.
 *
 * These are deliberately small and deliberately loud: every one of them either
 * returns the narrowed value or throws a ValidationError carrying the field name
 * a person can act on. Nothing here coerces, because a coerced body is a body
 * that quietly meant something other than what was sent.
 */

export class ValidationError extends Error {}

/**
 * The slug rule for organizations and teams alike. One pattern rather than two,
 * because a slug is the same kind of public handle in both places and a caller
 * that learned the rule once should not have to learn it again.
 */
export const SLUG_PATTERN = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

export function asObject(body: unknown): Record<string, unknown> {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    throw new ValidationError("body must be a JSON object");
  }
  return body as Record<string, unknown>;
}

export function requireText(
  body: Record<string, unknown>,
  field: string,
): string {
  const value = body[field];
  if (typeof value !== "string" || value.trim() === "") {
    throw new ValidationError(`${field} must be a non-empty string`);
  }
  return value.trim();
}

export function optionalText(
  body: Record<string, unknown>,
  field: string,
): string | undefined {
  const value = body[field];
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value !== "string" || value.trim() === "") {
    throw new ValidationError(`${field} must be a non-empty string when present`);
  }
  return value.trim();
}

export function requireSlug(
  body: Record<string, unknown>,
  field: string,
): string {
  const value = requireText(body, field);
  if (!SLUG_PATTERN.test(value)) {
    throw new ValidationError(
      `${field} must be lower-case alphanumeric with internal hyphens`,
    );
  }
  return value;
}

/**
 * The normalized `host/path` form of a git remote.
 *
 * `git@github.com:acme/web.git`, `https://github.com/acme/web` and
 * `github.com/acme/web` are the same repository, and a claim on one has to be a
 * claim on all three or the uniqueness constraint means nothing. Normalising at
 * the edge rather than at comparison time is what makes the database constraint
 * the real one.
 */
export function normalizeRepoId(raw: string): string {
  let value = raw.trim();
  value = value.replace(/^[a-z][a-z0-9+.-]*:\/\//i, "");
  // The SCP-like SSH form, git@host:path, whose colon is a separator not a port.
  value = value.replace(/^([^/@]+)@([^/:]+):/, "$2/");
  value = value.replace(/^[^/@]+@/, "");
  value = value.replace(/\.git$/i, "");
  value = value.replace(/\/+$/, "");
  return value.toLowerCase();
}

const REPO_ID_PATTERN = /^[a-z0-9.-]+\.[a-z]{2,}\/[a-z0-9._~-]+(?:\/[a-z0-9._~-]+)+$/;

export function requireRepoId(
  body: Record<string, unknown>,
  field: string,
): string {
  const normalized = normalizeRepoId(requireText(body, field));
  if (!REPO_ID_PATTERN.test(normalized)) {
    throw new ValidationError(
      `${field} must be a git remote resolving to host/owner/name, for example github.com/acme/web`,
    );
  }
  return normalized;
}
