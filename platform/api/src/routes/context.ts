import type { Context } from "hono";
import type { Auth } from "../auth-options.js";
import type { PlatformStore } from "../store.js";

/**
 * What every /v1 route needs before it can decide anything, and the one place
 * that decides it.
 *
 * Two questions are answered here and nowhere else: who is calling, and what
 * they are allowed to do in the organization they are calling about. Both are
 * answered from the session and the `member` row, never from the request body,
 * so no caller can name an organization or a role it does not hold.
 */

export type ClientErrorStatus = 400 | 401 | 403 | 404 | 409 | 422;

/**
 * A refusal a caller caused, carrying the status it should be answered with.
 * Routes throw these instead of returning early so one error handler owns the
 * response shape for every one of them.
 */
export class RouteError extends Error {
  constructor(
    readonly status: ClientErrorStatus,
    message: string,
  ) {
    super(message);
  }
}

export interface RouteDependencies {
  auth: () => Promise<Auth>;
  store: () => Promise<PlatformStore>;
  /** Injected so a test can assert on a timestamp it chose. */
  now: () => Date;
}

/** Roles that may change an organization's shape rather than just read it. */
const ADMIN_ROLES = new Set(["owner", "admin"]);

/**
 * Better Auth stores a member's roles as a comma-separated string, so a role is
 * a set even when it usually holds one element. Splitting rather than comparing
 * the whole string is what keeps `owner,admin` from being read as neither.
 */
export function isOrgAdmin(role: string): boolean {
  return role
    .split(",")
    .map((part) => part.trim())
    .some((part) => ADMIN_ROLES.has(part));
}

export interface Caller {
  userId: string;
  userEmail: string;
  organizationId: string;
  role: string;
}

/** The session, or a 401. Used by the routes that need no organization at all. */
export async function requireSession(
  auth: Auth,
  headers: Headers,
): Promise<{ userId: string; userEmail: string }> {
  const session = await auth.api.getSession({ headers });
  if (session === null) {
    throw new RouteError(401, "authentication required");
  }
  return { userId: session.user.id, userEmail: session.user.email };
}

/**
 * The caller and their role in the session's active organization.
 *
 * The organization is the session's active one, not one named in the body. A
 * body-supplied organization id would have to be authorised anyway, and having
 * one route accept it while the plugin's own routes use the session's would
 * leave two different answers to "which organization is this about".
 */
export async function requireCaller(
  auth: Auth,
  headers: Headers,
): Promise<Caller> {
  const session = await requireSession(auth, headers);
  const member = await auth.api.getActiveMember({ headers });
  if (member === null || member === undefined) {
    throw new RouteError(400, "no active organization on this session");
  }
  return {
    userId: session.userId,
    userEmail: session.userEmail,
    organizationId: member.organizationId,
    role: member.role,
  };
}

/**
 * The caller, refused unless they own or administer the organization.
 *
 * This is the real authorization check. The web app hides the buttons a member
 * cannot use, but hiding a button is a courtesy and this is the rule: a member
 * calling any of these routes directly gets a 403 with nothing written.
 */
export async function requireOrgAdmin(
  auth: Auth,
  headers: Headers,
): Promise<Caller> {
  const caller = await requireCaller(auth, headers);
  if (!isOrgAdmin(caller.role)) {
    throw new RouteError(
      403,
      "only an organization owner or admin may do this",
    );
  }
  return caller;
}

/** A path parameter, refused rather than silently treated as the string "undefined". */
export function requireParam(c: Context, name: string): string {
  const value = c.req.param(name);
  if (value === undefined || value === "") {
    throw new RouteError(400, `${name} is required`);
  }
  return value;
}

/** A JSON body, refused as a 400 rather than surfacing as a parse crash. */
export async function readJsonBody(c: Context): Promise<unknown> {
  try {
    return await c.req.json();
  } catch {
    throw new RouteError(400, "body must be valid JSON");
  }
}
