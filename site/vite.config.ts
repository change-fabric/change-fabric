import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Static single-page build. No server runtime: `vite build` emits plain
// HTML/JS/CSS to dist/, which is what deploys to S3 behind CloudFront.
export default defineConfig({
  plugins: [react()],
  base: "/",
  build: {
    outDir: "dist",
    emptyOutDir: true,
  },
});
