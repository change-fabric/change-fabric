import { describe, expect, it } from "vitest";
import { memoryAdapter } from "better-auth/adapters/memory";
import { buildAuthOptions } from "../src/auth-options.js";

function optionsWithDomain(cookieDomain: string) {
  return buildAuthOptions({
    database: memoryAdapter({}),
    secret: "test-secret-with-more-than-enough-entropy-0123456789",
    baseURL: "https://api.staging.example.org",
    cookieDomain,
    trustedOrigins: ["https://app.staging.example.org"],
    sendVerificationEmail: async () => undefined,
  });
}

describe("cookie configuration", () => {
  it("scopes session cookies to the staging domain so subdomains share them", () => {
    const options = optionsWithDomain(".staging.example.org");

    expect(options.advanced?.crossSubDomainCookies).toEqual({
      enabled: true,
      domain: ".staging.example.org",
    });
  });

  it("marks cookies Secure, HttpOnly and SameSite=Lax", () => {
    const options = optionsWithDomain(".staging.example.org");

    expect(options.advanced?.defaultCookieAttributes).toMatchObject({
      secure: true,
      httpOnly: true,
      sameSite: "lax",
    });
  });

  it("leaves cookies host-only when no domain is configured", () => {
    const options = optionsWithDomain("");

    expect(options.advanced?.crossSubDomainCookies).toEqual({ enabled: false });
  });
});
