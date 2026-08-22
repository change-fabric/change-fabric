import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Static single-page build. No server runtime: `vite build` emits plain
// HTML/JS/CSS to dist/, which is what deploys to S3 behind CloudFront.
export default defineConfig({
  plugins: [react()],
  base: "/",
  // Dev-server only, and it affects nothing in dist/. Vite 5.4.12+ rejects a
  // request whose Host header is a name it was not told about, so the audit
  // lanes, which run in containers and address this process as
  // host.docker.internal, get "Blocked request" instead of the page. Naming
  // that one host keeps the DNS-rebinding protection for every other name.
  server: {
    allowedHosts: ["host.docker.internal"],
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
  },
});
