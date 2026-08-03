import { cp, mkdir, rm } from "node:fs/promises";
import { build } from "esbuild";

/**
 * Bundles both handlers into `dist/` for Lambda.
 *
 * Everything is bundled rather than shipped as a node_modules tree, so the
 * deployment package is two files plus the migration SQL. `pg` is bundled too:
 * it is pure JavaScript, and its optional native accelerator is left out on
 * purpose so the artifact stays portable to the arm64 runtime.
 *
 * The generated migration SQL is copied next to the bundle because the drizzle
 * migrator reads it from disk at run time; it is data, not code, so esbuild
 * cannot inline it.
 */

await rm("dist", { recursive: true, force: true });
await mkdir("dist", { recursive: true });

await build({
  entryPoints: {
    index: "src/index.ts",
    migrate: "src/migrate.ts",
  },
  outdir: "dist",
  outExtension: { ".js": ".mjs" },
  bundle: true,
  platform: "node",
  target: "node22",
  format: "esm",
  sourcemap: false,
  minify: false,
  // The AWS SDK is bundled rather than taken from the runtime: the managed
  // runtimes stopped guaranteeing it, and pinning the version in package.json
  // is the difference between a reproducible artifact and one that changes
  // under a runtime patch. Only genuinely optional native or non-Node modules
  // are left out.
  external: ["pg-native", "cloudflare:sockets"],
  // The ESM bundle needs these CommonJS-only globals that some dependencies
  // still reach for.
  banner: {
    js: [
      "import { createRequire as __createRequire } from 'node:module';",
      "import { fileURLToPath as __fileURLToPath } from 'node:url';",
      "import { dirname as __pathDirname } from 'node:path';",
      "const require = __createRequire(import.meta.url);",
      "const __filename = __fileURLToPath(import.meta.url);",
      "const __dirname = __pathDirname(__filename);",
    ].join("\n"),
  },
  logLevel: "info",
});

await cp("drizzle", "dist/drizzle", { recursive: true });
