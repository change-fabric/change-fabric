import { defineConfig } from "vitest/config";

// Same shape as platform/api's config on purpose: node environment, tests in
// test/, nothing global. Nothing here needs a DOM. The components are exercised
// against real staging by verify/, and a jsdom render of a page that only talks
// to the network would assert the mock rather than the app.
export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
    setupFiles: ["test/setup.ts"],
  },
});
