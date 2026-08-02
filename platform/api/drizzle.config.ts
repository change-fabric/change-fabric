import { defineConfig } from "drizzle-kit";

/**
 * `drizzle-kit generate` reads the schema and writes SQL; it needs no database
 * connection, which matters because the target instance is only reachable from
 * inside the VPC. The generated SQL is applied by the cf-platform-migrate
 * Lambda, not from a laptop, so no credentials belong in this file.
 */
export default defineConfig({
  dialect: "postgresql",
  schema: "./src/db/schema.ts",
  out: "./drizzle",
  strict: true,
  verbose: true,
});
