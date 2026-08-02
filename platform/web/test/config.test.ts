import { afterEach, describe, expect, it, vi } from "vitest";

/**
 * config.ts resolves the API origin once, at module load. Both branches are
 * load-time decisions, so each case imports the module fresh rather than
 * re-reading an export that was already frozen by whichever branch ran first.
 */
async function loadOrigin(): Promise<string> {
  vi.resetModules();
  return (await import("../src/config")).API_ORIGIN;
}

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

describe("API_ORIGIN", () => {
  it("falls back to the page's own origin, which is what the deployed app uses", async () => {
    vi.stubEnv("VITE_API_ORIGIN", undefined as unknown as string);
    vi.stubGlobal("window", {
      location: { origin: "https://app.staging.changefabric.org" },
    });

    expect(await loadOrigin()).toBe("https://app.staging.changefabric.org");
  });

  it("honours VITE_API_ORIGIN, which is what a local run against another API uses", async () => {
    vi.stubEnv("VITE_API_ORIGIN", "https://api.example.test");
    vi.stubGlobal("window", { location: { origin: "http://localhost:5173" } });

    expect(await loadOrigin()).toBe("https://api.example.test");
  });

  it("never carries a trailing slash, because every caller concatenates a rooted path", async () => {
    vi.stubEnv("VITE_API_ORIGIN", undefined as unknown as string);
    vi.stubGlobal("window", {
      location: { origin: "https://app.staging.changefabric.org" },
    });

    // `${API_ORIGIN}${path}` in api.ts would otherwise produce a double slash,
    // which CloudFront does not normalise away before the API sees it.
    expect(await loadOrigin()).not.toMatch(/\/$/);
  });
});
