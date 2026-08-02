import { timingSafeEqual } from "node:crypto";
import type { MiddlewareHandler } from "hono";
import type { BasicAuthCredential } from "./config.js";

/**
 * The staging-wide HTTP Basic Auth gate.
 *
 * This is a coarse outer fence, not the product's authentication: it keeps the
 * whole staging environment off the open internet while the real per-
 * organization auth underneath it is built. Both apply, in that order.
 */

const CHALLENGE = 'Basic realm="staging"';

/**
 * Constant-time string comparison. `===` on a credential leaks its prefix
 * through timing; this credential is a deliberate shared placeholder, but the
 * comparison is the same code the real one would use, so it is written
 * correctly now rather than left as a thing to remember later.
 */
export function safeEqual(a: string, b: string): boolean {
  const left = Buffer.from(a, "utf8");
  const right = Buffer.from(b, "utf8");
  // timingSafeEqual throws on a length mismatch, which would itself be a
  // timing signal. Comparing each side against itself keeps the work constant
  // for a given input and returns the length difference as a plain false.
  if (left.length !== right.length) {
    timingSafeEqual(left, left);
    return false;
  }
  return timingSafeEqual(left, right);
}

export function credentialMatches(
  header: string | undefined,
  expected: BasicAuthCredential,
): boolean {
  if (header === undefined) {
    return false;
  }
  const [scheme, encoded] = header.split(" ");
  if (scheme?.toLowerCase() !== "basic" || encoded === undefined) {
    return false;
  }

  let decoded: string;
  try {
    decoded = Buffer.from(encoded, "base64").toString("utf8");
  } catch {
    return false;
  }

  const separator = decoded.indexOf(":");
  if (separator < 0) {
    return false;
  }

  const username = decoded.slice(0, separator);
  const password = decoded.slice(separator + 1);

  // Both halves are always compared, so a wrong username costs the same as a
  // wrong password.
  const usernameOk = safeEqual(username, expected.username);
  const passwordOk = safeEqual(password, expected.password);
  return usernameOk && passwordOk;
}

/**
 * Wraps every route except the ones the caller exempts. The credential is
 * resolved through the caller's function so the middleware itself holds no
 * opinion about where it came from, which is what lets a test drive it without
 * SSM.
 */
export function basicAuth(options: {
  credential: () => Promise<BasicAuthCredential>;
  exempt: (path: string) => boolean;
}): MiddlewareHandler {
  return async (c, next) => {
    if (options.exempt(c.req.path)) {
      return next();
    }

    const expected = await options.credential();
    if (!credentialMatches(c.req.header("Authorization"), expected)) {
      return c.text("Unauthorized", 401, { "WWW-Authenticate": CHALLENGE });
    }

    return next();
  };
}
