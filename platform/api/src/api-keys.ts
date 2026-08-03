import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

/**
 * Minting and recognising a team API key.
 *
 * Everything here is pure and synchronous on purpose: the format, the digest,
 * and the displayable prefix are the three facts a stored key depends on, and
 * they are worth being able to test without a database anywhere near them.
 *
 * The raw key is returned to its creator exactly once and never stored. What is
 * stored is the SHA-256 digest, so a copy of `team_api_key` is not a copy of
 * anyone's credentials. SHA-256 rather than a password hash is deliberate: this
 * is a 256-bit random value, not a human-chosen secret, so there is no
 * dictionary for a slow hash to defend against, and a lookup has to be a single
 * indexed read rather than a scan that bcrypts every row.
 */

/** Scheme marker, so a leaked key is recognisable as one at a glance. */
export const KEY_SCHEME = "cfp";

/** How many random bytes back a key. 256 bits, base64url encoded. */
const SECRET_BYTES = 32;

/** How much of the random segment the stored, displayable prefix keeps. */
const SECRET_PREFIX_LENGTH = 6;

export interface MintedKey {
  /** Shown once, never stored. */
  raw: string;
  hash: string;
  prefix: string;
}

/**
 * `cfp_<org-slug>_<random>`. The organization slug is in the key so a key found
 * loose in a log or a CI configuration says who it belongs to without anyone
 * having to look it up, and the scheme marker makes it greppable by a secret
 * scanner.
 */
export function mintKey(organizationSlug: string): MintedKey {
  const secret = randomBytes(SECRET_BYTES).toString("base64url");
  const raw = `${KEY_SCHEME}_${organizationSlug}_${secret}`;
  return { raw, hash: hashKey(raw), prefix: keyPrefix(raw) };
}

export function hashKey(raw: string): string {
  return createHash("sha256").update(raw, "utf8").digest("hex");
}

/**
 * The part of a key that is safe to show forever.
 *
 * A fixed character count from the front would be the wrong cut: the segment
 * before the random one is the organization slug, which is variable-length and
 * identical for every key the organization owns, so a fixed twelve characters
 * would sometimes be entirely constant and tell a person nothing about which of
 * their keys they are looking at. Keeping the scheme, the slug, and the first
 * few characters of the random segment is still a strict prefix of the raw key
 * and still discloses nothing usable, while actually distinguishing two keys.
 */
export function keyPrefix(raw: string): string {
  // The secret segment is base64url, whose alphabet INCLUDES the underscore, so
  // the last underscore in a key is very often inside the secret rather than
  // before it. Finding the separator from the front is not a stylistic
  // preference: searching from the back returns almost the entire raw key, which
  // this function would then have published as a display prefix. The slug in
  // between cannot contain an underscore, so the second one from the front is
  // always the separator.
  const afterScheme = raw.indexOf("_");
  const separator =
    afterScheme < 0 ? -1 : raw.indexOf("_", afterScheme + 1);
  if (separator < 0) {
    return raw.slice(0, SECRET_PREFIX_LENGTH);
  }
  return raw.slice(0, separator + 1 + SECRET_PREFIX_LENGTH);
}

/**
 * Whether a key presented now is one that was minted then.
 *
 * Both sides are fixed-length hex digests, so this never leaks a length. The
 * comparison is constant-time because the digest of a guess is still a value an
 * attacker controls and can iterate against.
 */
export function digestMatches(a: string, b: string): boolean {
  const left = Buffer.from(a, "utf8");
  const right = Buffer.from(b, "utf8");
  if (left.length !== right.length) {
    timingSafeEqual(left, left);
    return false;
  }
  return timingSafeEqual(left, right);
}

/**
 * A key is usable only if nobody revoked it and no expiry has passed. Both are
 * checked here rather than in a WHERE clause so the reason is one expression a
 * reader can see whole, and so a route can answer the same way for both.
 */
export function keyIsUsable(
  key: { revokedAt: Date | null; expiresAt: Date | null },
  now: Date = new Date(),
): boolean {
  if (key.revokedAt !== null) {
    return false;
  }
  return key.expiresAt === null || key.expiresAt.getTime() > now.getTime();
}
