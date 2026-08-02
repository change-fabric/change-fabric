import { handle } from "hono/aws-lambda";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { createApp } from "./app.js";
import { createAuth, type Auth } from "./auth-options.js";
import { createDatabase, createPool } from "./db/client.js";
import { getApiConfig } from "./config.js";
import { bestEffort, createSesSender } from "./email.js";
import { createDrizzleStore, type PlatformStore } from "./store.js";
import * as schema from "./db/schema.js";

/**
 * Lambda entry point for the staging API.
 *
 * The Hono app is built synchronously and holds no connections, so /healthz
 * answers even when SSM or the database is unreachable. Everything expensive
 * (the SSM reads, the pg pool, the Better Auth instance) is created on the
 * first request that actually needs it and then reused for the life of the
 * execution environment.
 */

interface Runtime {
  auth: Auth;
  store: PlatformStore;
}

let runtime: Promise<Runtime> | undefined;

/**
 * Better Auth and the platform's own store share one connection pool, because
 * they share one database and a second pool would only double the server-side
 * connections this function holds against a db.t4g.small.
 */
async function buildRuntime(): Promise<Runtime> {
  const config = await getApiConfig();
  const database = createDatabase(createPool(config.database));
  const sender = bestEffort(createSesSender(config.sesFromAddress));

  return {
    auth: createAuth({
      database: drizzleAdapter(database, { provider: "pg", schema }),
      secret: config.betterAuthSecret,
      baseURL: config.baseURL,
      cookieDomain: config.cookieDomain,
      trustedOrigins: config.trustedOrigins,
      appOrigin: config.appOrigin,
      sendVerificationEmail: sender,
      // Best-effort for the same reason the verification mail is: SES is still
      // in the sandbox, and an undeliverable mail must not roll back an
      // invitation that was genuinely created.
      sendInvitationEmail: sender,
    }),
    store: createDrizzleStore(database),
  };
}

function getRuntime(): Promise<Runtime> {
  runtime ??= buildRuntime().catch((error: unknown) => {
    // A failed build must not be cached, or one unlucky cold start would leave
    // the container answering 500 for the rest of its life.
    runtime = undefined;
    throw error;
  });
  return runtime;
}

const app = createApp({
  auth: async () => (await getRuntime()).auth,
  store: async () => (await getRuntime()).store,
  basicAuthCredential: async () => (await getApiConfig()).basicAuth,
});

export const handler = handle(app);
