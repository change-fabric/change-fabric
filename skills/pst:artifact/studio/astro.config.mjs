// @ts-check
import { defineConfig } from "astro/config";
import mdx from "@astrojs/mdx";

// Static output. Each artifact builds to /p/<id>/index.html (slug-less canonical
// path); the cosmetic slug in shared URLs is stripped by the CloudFront function
// at the edge (see ../terraform/cloudfront_function.js). The comment round-trip
// runs only under `astro dev` via src/middleware.ts — no adapter needed, so the
// published bundle stays a pure static, no-index artifact.
export default defineConfig({
  integrations: [mdx()],
  build: { format: "directory" },
  devToolbar: { enabled: false },
});
