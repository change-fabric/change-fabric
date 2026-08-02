import { Pool } from "pg";
import { drizzle } from "drizzle-orm/node-postgres";
import * as schema from "./schema.js";
import type { DatabaseSettings } from "../config.js";

export type Database = ReturnType<typeof drizzle<typeof schema>>;

/**
 * RDS terminates TLS with an Amazon-issued certificate that the default Node
 * trust store does not carry, and the instance is only reachable from inside a
 * VPC that has no internet path at all. Verification is therefore relaxed while
 * the transport stays encrypted, which matches how `postgres.tf` connects.
 */
export function createPool(settings: DatabaseSettings, maxConnections = 2): Pool {
  return new Pool({
    host: settings.host,
    port: settings.port,
    database: settings.database,
    user: settings.user,
    password: settings.password,
    ssl: { rejectUnauthorized: false },
    // A Lambda handles one request at a time, so a large pool would only hold
    // idle server-side connections open across the whole concurrency ceiling.
    max: maxConnections,
    idleTimeoutMillis: 10_000,
    connectionTimeoutMillis: 5_000,
  });
}

export function createDatabase(pool: Pool): Database {
  return drizzle(pool, { schema });
}
