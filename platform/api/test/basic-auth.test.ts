import { describe, expect, it } from "vitest";
import { credentialMatches, safeEqual } from "../src/basic-auth.js";
import { parseBasicAuthCredential } from "../src/config.js";
import {
  AUTHORIZED_HEADER,
  TEST_BASIC_AUTH,
  createHarness,
} from "./harness.js";

describe("the staging basic auth gate", () => {
  it("challenges an unauthenticated request to a real route", async () => {
    const { app } = createHarness();

    const response = await app.request("/v1/onboarding", { method: "POST" });

    expect(response.status).toBe(401);
    expect(response.headers.get("WWW-Authenticate")).toBe(
      'Basic realm="staging"',
    );
  });

  it("challenges a request carrying the wrong credential", async () => {
    const { app } = createHarness();
    const wrong = `Basic ${Buffer.from("staging:nope").toString("base64")}`;

    const response = await app.request("/v1/onboarding", {
      method: "POST",
      headers: { Authorization: wrong },
    });

    expect(response.status).toBe(401);
  });

  it("lets /healthz through with no credential and no database", async () => {
    const { app } = createHarness();

    const response = await app.request("/healthz");

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({ status: "ok" });
  });

  it("admits the configured credential", async () => {
    const { app } = createHarness();

    const response = await app.request("/api/auth/ok", {
      headers: { Authorization: AUTHORIZED_HEADER },
    });

    expect(response.status).not.toBe(401);
  });
});

describe("credential parsing and comparison", () => {
  it("splits a user:pass pair on its first colon only", () => {
    expect(parseBasicAuthCredential("user:pa:ss")).toEqual({
      username: "user",
      password: "pa:ss",
    });
  });

  it("rejects a pair missing either half", () => {
    expect(() => parseBasicAuthCredential("nocolon")).toThrow();
    expect(() => parseBasicAuthCredential(":pass")).toThrow();
    expect(() => parseBasicAuthCredential("user:")).toThrow();
  });

  it("compares unequal lengths without throwing", () => {
    expect(safeEqual("short", "considerably-longer")).toBe(false);
    expect(safeEqual("same", "same")).toBe(true);
  });

  it("rejects a header that is absent, malformed, or another scheme", () => {
    expect(credentialMatches(undefined, TEST_BASIC_AUTH)).toBe(false);
    expect(credentialMatches("Basic", TEST_BASIC_AUTH)).toBe(false);
    expect(credentialMatches("Bearer abc", TEST_BASIC_AUTH)).toBe(false);
    expect(
      credentialMatches(
        `Basic ${Buffer.from("nocolon").toString("base64")}`,
        TEST_BASIC_AUTH,
      ),
    ).toBe(false);
  });

  it("accepts a password that itself contains a colon", () => {
    expect(credentialMatches(AUTHORIZED_HEADER, TEST_BASIC_AUTH)).toBe(true);
  });
});
