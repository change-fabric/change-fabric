import { generateKeyPairSync } from "node:crypto";
import type { Hono } from "hono";
import { memoryAdapter, type MemoryDB } from "better-auth/adapters/memory";
import { createApp } from "../src/app.js";
import { createAuth } from "../src/auth-options.js";
import type { EmailMessage } from "../src/email.js";
import type { PlatformStore } from "../src/store.js";
import { createMemoryStore } from "./memory-store.js";
import { createMemoryStorage, type MemoryStorage } from "./memory-storage.js";

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

export const TEST_ARTIFACTS_ORIGIN = "https://artifacts.staging.example.test";
export const TEST_KEY_PAIR_ID = "K1TESTKEYPAIRID";

/**
 * A throwaway RSA key pair, generated once for the whole test process.
 *
 * A real key rather than a placeholder string, because the point of the signing
 * tests is that the signer produces something a verifier would accept, and a
 * stub key would only prove that a string was copied into a cookie. 2048 bits is
 * what CloudFront requires, and generating it once at module load costs a tenth
 * of a second across the entire suite.
 */
const signerKeyPair = generateKeyPairSync("rsa", {
  modulusLength: 2048,
  publicKeyEncoding: { type: "spki", format: "pem" },
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
});

export const TEST_SIGNER_PUBLIC_KEY = signerKeyPair.publicKey;

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

export interface StoredTeamMember {
  id: string;
  teamId: string;
  userId: string;
}

export interface StoredInvitation {
  id: string;
  email: string;
  role: string;
  status: string;
  teamId?: string;
}

export interface StoredRows {
  user: StoredUser[];
  organization: StoredOrganization[];
  member: StoredMember[];
  team: StoredTeam[];
  teamMember: StoredTeamMember[];
  invitation: StoredInvitation[];
}

export interface Harness {
  app: Hono;
  store: MemoryDB;
  /** The platform's own tables, so a test can read what a route wrote. */
  platformStore: PlatformStore;
  /**
   * The same rows as `store`, typed. The memory adapter holds `any[]` per
   * model, so every assertion would otherwise repeat the same cast.
   */
  rows: StoredRows;
  sentEmails: EmailMessage[];
  /** Every invitation mail the plugin asked to be sent. */
  sentInvitations: EmailMessage[];
  /** The artifacts bucket, so a test can simulate an upload arriving. */
  storage: MemoryStorage;
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
  const sentInvitations: EmailMessage[] = [];

  const auth = createAuth({
    database: memoryAdapter(store),
    secret: "test-secret-with-more-than-enough-entropy-0123456789",
    baseURL: "http://localhost",
    // Host-only cookies keep the in-process client simple; the cross-subdomain
    // configuration is asserted separately against the options object.
    cookieDomain: "",
    trustedOrigins: ["http://localhost"],
    appOrigin: "http://localhost",
    sendVerificationEmail: async (message) => {
      sentEmails.push(message);
    },
    sendInvitationEmail: async (message) => {
      sentInvitations.push(message);
    },
  });

  const platformStore = createMemoryStore(store);
  const storage = createMemoryStorage();

  const app = createApp({
    auth: async () => auth,
    store: async () => platformStore,
    artifacts: async () => ({
      settings: {
        bucket: "test-artifacts",
        origin: TEST_ARTIFACTS_ORIGIN,
        keyPairId: TEST_KEY_PAIR_ID,
        privateKey: signerKeyPair.privateKey,
        cookieDomain: ".staging.example.test",
      },
      storage,
    }),
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
    get teamMember() {
      return store.teamMember as StoredTeamMember[];
    },
    get invitation() {
      return store.invitation as StoredInvitation[];
    },
  };

  return {
    app,
    store,
    platformStore,
    rows,
    sentEmails,
    sentInvitations,
    storage,
  };
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
  return call(harness, user, "POST", "/v1/onboarding", body);
}

/**
 * An authenticated request to a /v1 route, carrying both layers of auth: the
 * staging Basic Auth header every route except /healthz needs, and the session
 * cookie the route's own check reads.
 */
export async function call(
  harness: Harness,
  user: SignedUpUser | null,
  method: string,
  path: string,
  body?: unknown,
  extraHeaders: Record<string, string> = {},
): Promise<Response> {
  const headers: Record<string, string> = {
    Authorization: AUTHORIZED_HEADER,
    ...extraHeaders,
  };
  if (user !== null) {
    headers.Cookie = user.cookie;
  }
  if (body !== undefined) {
    headers["Content-Type"] = "application/json";
  }

  return harness.app.request(path, {
    method,
    headers,
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

/** The parsed body of a call that was expected to succeed, or a loud failure. */
export async function expectOk<T>(
  response: Response,
  expected = 200,
): Promise<T> {
  if (response.status !== expected) {
    throw new Error(
      `expected ${expected}, got ${response.status}: ${await response.text()}`,
    );
  }
  return (await response.json()) as T;
}

/**
 * An organization with an owner, which is where nearly every test starts.
 * Returns the owner's session and the organization's id and slug.
 */
export async function ownedOrganization(
  harness: Harness,
  email = "owner@example.test",
  slug = "acme-research",
): Promise<{ owner: SignedUpUser; organizationId: string; slug: string }> {
  const owner = await signUp(harness, email);
  const created = await expectOk<{ organization: { id: string } }>(
    await onboard(harness, owner, {
      organizationName: "Acme Research",
      organizationSlug: slug,
    }),
    201,
  );
  return { owner, organizationId: created.organization.id, slug };
}

/**
 * A second account invited into an organization and accepted, so a test has a
 * genuine `member`-role caller rather than one written straight into the store.
 * Going through the real invitation flow is the point: it is the same path the
 * deployed app uses, so a test's member is a member the same way.
 */
export async function invitedMember(
  harness: Harness,
  inviter: SignedUpUser,
  email: string,
  teamId?: string,
): Promise<SignedUpUser> {
  const invitation = await expectOk<{ invitation: { id: string } }>(
    await call(harness, inviter, "POST", "/v1/invitations", {
      email,
      role: "member",
      ...(teamId === undefined ? {} : { teamId }),
    }),
    201,
  );

  const invitee = await signUp(harness, email);
  await expectOk(
    await call(
      harness,
      invitee,
      "POST",
      `/v1/invitations/${invitation.invitation.id}/accept`,
    ),
  );
  return invitee;
}
