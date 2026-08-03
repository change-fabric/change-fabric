import { fileURLToPath } from "node:url";
import path from "node:path";
import { migrate } from "drizzle-orm/node-postgres/migrator";
import { createDatabase, createPool } from "./db/client.js";
import { ConfigError, readSecureParameter } from "./config.js";
import { createSesSender } from "./email.js";

/**
 * The maintenance Lambda.
 *
 * The database sits in a VPC with no internet path, so nothing outside it can
 * reach 5432. Phase 1 solved that for one bootstrap run with an ephemeral SSM
 * bastion; this function is the standing equivalent for the operations that
 * recur: applying migrations, and reading a row back to confirm something
 * really landed. It has no API Gateway route and is only ever invoked directly.
 *
 * It runs migrations as the RDS master user because the application role holds
 * no DDL privilege by design, and it runs read-only queries as the application
 * role so a check also proves the grants that role actually has.
 */

export type MigrateAction =
  | { action: "migrate" }
  | { action: "query"; sql: string; params?: unknown[] }
  | { action: "sesCheck"; from: string; to: string };

export interface MigrateResult {
  ok: boolean;
  action: string;
  detail?: unknown;
}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (value === undefined || value === "") {
    throw new ConfigError(`missing required environment variable ${name}`);
  }
  return value;
}

function baseSettings() {
  return {
    host: requireEnv("DB_HOST"),
    port: Number.parseInt(requireEnv("DB_PORT"), 10),
    database: requireEnv("DB_NAME"),
  };
}

/** Where esbuild puts the SQL the migrator replays. See build.mjs. */
function migrationsFolder(): string {
  return path.join(path.dirname(fileURLToPath(import.meta.url)), "drizzle");
}

async function runMigrations(): Promise<MigrateResult> {
  const password = await readSecureParameter(
    requireEnv("DB_MASTER_PASSWORD_PARAMETER"),
  );
  const pool = createPool(
    { ...baseSettings(), user: requireEnv("DB_MASTER_USER"), password },
    1,
  );
  try {
    await migrate(createDatabase(pool), { migrationsFolder: migrationsFolder() });
    return { ok: true, action: "migrate" };
  } finally {
    await pool.end();
  }
}

/**
 * Read-only by construction, not by inspection of the statement text. The
 * transaction is opened READ ONLY and always rolled back, so Postgres itself
 * rejects a write no matter what arrives in `sql`.
 */
async function runQuery(sql: string, params: unknown[]): Promise<MigrateResult> {
  const password = await readSecureParameter(
    requireEnv("DB_PASSWORD_PARAMETER"),
  );
  const pool = createPool(
    { ...baseSettings(), user: requireEnv("DB_USER"), password },
    1,
  );
  const client = await pool.connect();
  try {
    await client.query("BEGIN TRANSACTION READ ONLY");
    const result = await client.query(sql, params);
    await client.query("ROLLBACK");
    return { ok: true, action: "query", detail: { rows: result.rows } };
  } finally {
    client.release();
    await pool.end();
  }
}

/**
 * Proves the SES path end to end: IAM, the SDK, and the interface endpoint this
 * phase adds for the SES v2 API. `success@simulator.amazonses.com` accepts mail
 * in the sandbox with no prior verification, so this needs nobody to open an
 * inbox.
 */
async function runSesCheck(from: string, to: string): Promise<MigrateResult> {
  await createSesSender(from)({
    to,
    subject: "change-fabric platform SES path check",
    text: "Sent from the staging maintenance function to confirm the SES v2 API path out of the VPC.\n",
  });
  return { ok: true, action: "sesCheck", detail: { from, to } };
}

function parseEvent(event: unknown): MigrateAction {
  if (typeof event !== "object" || event === null) {
    throw new ConfigError("event must be an object");
  }
  const record = event as Record<string, unknown>;

  switch (record.action) {
    case "migrate":
      return { action: "migrate" };
    case "query": {
      if (typeof record.sql !== "string" || record.sql.trim() === "") {
        throw new ConfigError("query action needs a non-empty sql string");
      }
      const params = record.params;
      if (params !== undefined && !Array.isArray(params)) {
        throw new ConfigError("query params must be an array when present");
      }
      return { action: "query", sql: record.sql, params: params ?? [] };
    }
    case "sesCheck": {
      if (typeof record.from !== "string" || typeof record.to !== "string") {
        throw new ConfigError("sesCheck action needs from and to addresses");
      }
      return { action: "sesCheck", from: record.from, to: record.to };
    }
    default:
      throw new ConfigError(
        "action must be one of migrate, query, sesCheck",
      );
  }
}

export const handler = async (event: unknown): Promise<MigrateResult> => {
  const parsed = parseEvent(event);
  switch (parsed.action) {
    case "migrate":
      return runMigrations();
    case "query":
      return runQuery(parsed.sql, parsed.params ?? []);
    case "sesCheck":
      return runSesCheck(parsed.from, parsed.to);
  }
};
