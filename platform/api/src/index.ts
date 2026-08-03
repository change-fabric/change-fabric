import { handle } from "hono/aws-lambda";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { createApp } from "./app.js";
import { createAuth, type Auth } from "./auth-options.js";
import { createDatabase, createPool } from "./db/client.js";
import { getApiConfig } from "./config.js";
import { bestEffort, createSesSender } from "./email.js";
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

let auth: Promise<Auth> | undefined;

async function buildAuth(): Promise<Auth> {
  const config = await getApiConfig();
  const database = createDatabase(createPool(config.database));

  return createAuth({
    database: drizzleAdapter(database, { provider: "pg", schema }),
    secret: config.betterAuthSecret,
    baseURL: config.baseURL,
    cookieDomain: config.cookieDomain,
    trustedOrigins: config.trustedOrigins,
    sendVerificationEmail: bestEffort(createSesSender(config.sesFromAddress)),
  });
}

function getAuth(): Promise<Auth> {
  auth ??= buildAuth().catch((error: unknown) => {
    // A failed build must not be cached, or one unlucky cold start would leave
    // the container answering 500 for the rest of its life.
    auth = undefined;
    throw error;
  });
  return auth;
}

const app = createApp({
  auth: getAuth,
  basicAuthCredential: async () => (await getApiConfig()).basicAuth,
});

export const handler = handle(app);
