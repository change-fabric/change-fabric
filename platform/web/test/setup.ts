/**
 * The one thing browser code assumes that a node test runner does not provide.
 *
 * src/config.ts resolves the API origin from `window.location.origin` at module
 * load, which is the whole point of that module: the deployed app talks to its
 * own origin. Importing anything that reaches config.ts would otherwise throw
 * before a single assertion ran.
 *
 * A stub rather than jsdom, because one property is what is missing. A test that
 * cares about the value sets its own with `vi.stubGlobal`, and
 * `vi.unstubAllGlobals` restores this default rather than removing it.
 */
Object.defineProperty(globalThis, "window", {
  configurable: true,
  writable: true,
  value: { location: { origin: "https://app.staging.changefabric.org" } },
});
