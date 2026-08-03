import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Static single-page build, same shape as site/: `vite build` emits plain
// HTML/JS/CSS to dist/, which deploys to S3 behind CloudFront. This app is a
// separate deployable from site/ on purpose. site/ is a hard-cached marketing
// page; this is an authenticated shell with its own release cadence, and the
// two share design tokens rather than a build.
//
// The dev server proxies the API paths to the deployed staging API so a local
// run exercises the same origin-relative paths the deployed app uses. See
// src/config.ts for why the deployed app talks to its own origin.
export default defineConfig({
  plugins: [react()],
  base: "/",
  build: {
    outDir: "dist",
    emptyOutDir: true,
  },
  server: {
    proxy: {
      "/api": {
        target: "https://api.staging.changefabric.org",
        changeOrigin: true,
      },
      "/v1": {
        target: "https://api.staging.changefabric.org",
        changeOrigin: true,
      },
    },
  },
});
