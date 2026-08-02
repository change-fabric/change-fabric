import type { Hono } from "hono";
import { memoryAdapter, type MemoryDB } from "better-auth/adapters/memory";
import { createApp } from "../src/app.js";
import { createAuth } from "../src/auth-options.js";
import type { EmailMessage } from "../src/email.js";

/**
 * A whole API instance backed by an in-memory store.
 *
 * The point is to exercise the real Better Auth configuration, the real
 * organization plugin, the real hooks and the real Hono routing, and to swap
 * out only the two things a test has no business touching: the database and
 * the network. Everything asserted below is therefore behaviour the deployed
 * function shares, not a reimplementation of it.
 */

export const TEST_BASIC_AUTH = { username: "staging", password: "s3cret:pair" };

export const AUTHORIZED_HEADER = `Basic ${Buffer.from(
  `${TEST_BASIC_AUTH.username}:${TEST_BASIC_AUTH.password}`,
).toString("base64")}`;

/** The columns a test asserts on. The store itself is untyped by design. */
export interface StoredUser {
  id: string;
  email: string;
}

export interface StoredOrganization {
  id: string;
  name: string;
  slug: string;
}

export interface StoredMember {
  userId: string;
  organizationId: string;
  role: string;
}

export interface StoredTeam {
  id: string;
  name: string;
  slug: string;
}

export interface StoredRows {
  user: StoredUser[];
  organization: StoredOrganization[];
  member: StoredMember[];
  team: StoredTeam[];
}

export interface Harness {
  app: Hono;
  store: MemoryDB;
  /**
   * The same rows as `store`, typed. The memory adapter holds `any[]` per
   * model, so every assertion would otherwise repeat the same cast.
   */
  rows: StoredRows;
  sentEmails: EmailMessage[];
}

export function createHarness(): Harness {
  const store: MemoryDB = {
    user: [],
    session: [],
    account: [],
    verification: [],
    organization: [],
    member: [],
    invitation: [],
    team: [],
    teamMember: [],
  };
  const sentEmails: EmailMessage[] = [];

  const auth = createAuth({
    database: memoryAdapter(store),
    secret: "test-secret-with-more-than-enough-entropy-0123456789",
    baseURL: "http://localhost",
    // Host-only cookies keep the in-process client simple; the cross-subdomain
    // configuration is asserted separately against the options object.
    cookieDomain: "",
    trustedOrigins: ["http://localhost"],
    sendVerificationEmail: async (message) => {
      sentEmails.push(message);
    },
  });

  const app = createApp({
    auth: async () => auth,
    basicAuthCredential: async () => TEST_BASIC_AUTH,
  });

  const rows: StoredRows = {
    get user() {
      return store.user as StoredUser[];
    },
    get organization() {
      return store.organization as StoredOrganization[];
    },
    get member() {
      return store.member as StoredMember[];
    },
    get team() {
      return store.team as StoredTeam[];
    },
  };

  return { app, store, rows, sentEmails };
}

/** Collects the cookies Better Auth set, so the next call is authenticated. */
export function cookieHeader(response: Response): string {
  return response.headers
    .getSetCookie()
    .map((cookie) => cookie.split(";", 1)[0] ?? "")
    .filter((pair) => pair !== "")
    .join("; ");
}

export interface SignedUpUser {
  cookie: string;
  email: string;
}

export async function signUp(
  harness: Harness,
  email: string,
): Promise<SignedUpUser> {
  const response = await harness.app.request("/api/auth/sign-up/email", {
    method: "POST",
    headers: {
      Authorization: AUTHORIZED_HEADER,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      name: "Test Person",
      email,
      password: "correct-horse-battery-staple",
    }),
  });

  if (!response.ok) {
    throw new Error(`sign-up failed: ${response.status} ${await response.text()}`);
  }

  return { cookie: cookieHeader(response), email };
}

export async function onboard(
  harness: Harness,
  user: SignedUpUser,
  body: unknown,
): Promise<Response> {
  return harness.app.request("/v1/onboarding", {
    method: "POST",
    headers: {
      Authorization: AUTHORIZED_HEADER,
      Cookie: user.cookie,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
}
