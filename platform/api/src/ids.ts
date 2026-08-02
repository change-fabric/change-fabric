import { randomBytes, randomInt } from "node:crypto";

/**
 * The two identifiers an artifact carries, and why it carries two.
 *
 * `artifact.id` is a ULID: 48 bits of millisecond timestamp followed by 80 bits
 * of randomness, both rendered in Crockford base32, so the lexical order of two
 * ids is the order they were created in. That matters because the listing route
 * pages by id, and a sortable primary key means a cursor is the last id seen
 * rather than an offset that shifts under concurrent inserts.
 *
 * `artifact.short_id` is what a person copies out of a chat message and what
 * appears in a viewer URL. It is ten characters, unique per team rather than
 * globally, and drawn from the same alphabet for the same reason: Crockford
 * base32 has no I, L, O or U, so it cannot spell a word by accident and cannot
 * be misread between one and l or between zero and O.
 *
 * They are separate values rather than one, because they answer different
 * questions. An id has to be unguessable-adjacent and sortable; a short id has
 * to be short enough to say out loud. Deriving one from the other would force
 * whichever property the derivation dropped to be given up.
 */

/**
 * Crockford base32, excluding I, L, O and U. Ordered so that the alphabet's
 * index order is the byte order it encodes, which is what makes a ULID sort.
 */
export const CROCKFORD_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

const ULID_TIME_LENGTH = 10;
const ULID_RANDOM_LENGTH = 16;

/** How long a short id is. Ten characters is 50 bits of Crockford base32. */
export const SHORT_ID_LENGTH = 10;

/**
 * The timestamp half of a ULID: 48 bits, most significant character first, so
 * a later millisecond always sorts after an earlier one.
 */
function encodeTime(millis: number): string {
  let remaining = millis;
  let encoded = "";
  for (let index = 0; index < ULID_TIME_LENGTH; index += 1) {
    const digit = remaining % 32;
    encoded = CROCKFORD_ALPHABET[digit] + encoded;
    remaining = (remaining - digit) / 32;
  }
  return encoded;
}

/**
 * Uniformly distributed characters from the alphabet.
 *
 * `randomInt` rather than a modulo of a random byte: 256 is not a multiple of
 * 32 in general, and while it happens to be here, reaching for the rejection-
 * sampling primitive means this stays correct if the alphabet ever changes
 * length. It is a handful of characters per call, so the cost is irrelevant.
 */
function randomCharacters(count: number): string {
  let out = "";
  for (let index = 0; index < count; index += 1) {
    out += CROCKFORD_ALPHABET[randomInt(CROCKFORD_ALPHABET.length)];
  }
  return out;
}

/**
 * A ULID, as the 26-character canonical string.
 *
 * `now` is a parameter so a test can assert that two ids minted a millisecond
 * apart really do sort, rather than hoping the clock cooperated.
 */
export function newUlid(now: number = Date.now()): string {
  return encodeTime(now) + randomCharacters(ULID_RANDOM_LENGTH);
}

/**
 * A candidate short id. Unique per team is enforced by the database's unique
 * index and by the retry loop in the store, not by this function: fifty bits is
 * a very low collision probability but not a guarantee, and a guarantee is what
 * the index is for.
 */
export function newShortId(): string {
  return randomCharacters(SHORT_ID_LENGTH);
}

/**
 * Whether a string could be a short id at all.
 *
 * Used by the download route before it goes near the database, so an obviously
 * malformed path parameter is a 400 rather than a query that finds nothing and
 * reports 404. The alphabet check is what makes this meaningful: a lower-case
 * or an I/L/O/U cannot be one of ours.
 */
export function looksLikeShortId(value: string): boolean {
  if (value.length !== SHORT_ID_LENGTH) {
    return false;
  }
  for (const character of value) {
    if (!CROCKFORD_ALPHABET.includes(character)) {
      return false;
    }
  }
  return true;
}

/** Random bytes as hex, for anything that needs a nonce and not an id. */
export function randomHex(bytes: number): string {
  return randomBytes(bytes).toString("hex");
}
