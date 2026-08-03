import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { SLUG_PATTERN } from "../src/api";

/**
 * SLUG_PATTERN is the one rule in this package that exists to be a COPY. The API
 * owns it; api.ts mirrors it so a typo is caught before a round trip. A mirror
 * that has drifted is worse than no mirror at all: it either rejects a slug the
 * server would have taken, or waves through one it will not.
 *
 * So there are two things to check. That the rule does what it says, and that it
 * is still the same rule the server compiled.
 */
const here = path.dirname(fileURLToPath(import.meta.url));
const API_VALIDATION = path.join(here, "..", "..", "api", "src", "validation.ts");

describe("SLUG_PATTERN", () => {
  it("is character-for-character the pattern platform/api enforces", async () => {
    const source = await readFile(API_VALIDATION, "utf8");
    const declared = /export const SLUG_PATTERN = (\/.*\/);/.exec(source);

    // A rename or a move on the API side should fail here loudly rather than
    // quietly skipping the comparison and reporting green.
    expect(declared, `no SLUG_PATTERN found in ${API_VALIDATION}`).not.toBeNull();
    expect(SLUG_PATTERN.toString()).toBe(declared?.[1]);
  });

  it("accepts the slugs a person actually types", () => {
    for (const slug of [
      "core",
      "docs",
      "a",
      "9",
      "acme-research",
      "team-2",
      "a-b-c-d",
      "verify-org-1785699055860",
      "a".repeat(63),
    ]) {
      expect(SLUG_PATTERN.test(slug), slug).toBe(true);
    }
  });

  it("rejects the shapes that would break a URL or a bucket prefix", () => {
    for (const slug of [
      "",
      "-leading",
      "trailing-",
      "-",
      "Upper",
      "with space",
      "under_score",
      "dot.ted",
      "sla/sh",
      "a".repeat(64),
    ]) {
      expect(SLUG_PATTERN.test(slug), slug).toBe(false);
    }
  });

  it("is anchored at both ends, so a bad slug cannot hide inside a good one", () => {
    // A pattern missing its anchors would match the "ok" inside either of these
    // and the form would let both through.
    expect(SLUG_PATTERN.test("../ok")).toBe(false);
    expect(SLUG_PATTERN.test("ok\nnot ok")).toBe(false);
  });
});
