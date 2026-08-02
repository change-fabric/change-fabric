import { getSignedCookies } from "@aws-sdk/cloudfront-signer";

/**
 * CloudFront signed cookies for the artifacts host.
 *
 * This is the only mechanism in the platform where the EDGE, not the API,
 * decides whether a request is allowed to read bytes. The API's part is to
 * answer one question ("is this person on this team") and, if the answer is
 * yes, to hand the browser three cookies that CloudFront itself then verifies
 * against a trusted key group on every single object request. Nothing is
 * proxied, so a large findings bundle never passes through a Lambda, and a
 * person who is removed from a team stops being able to fetch new objects when
 * their cookies expire rather than when someone remembers to revoke something.
 *
 * A custom policy rather than a canned one, because the resource is a wildcard
 * over a team's whole prefix and a canned policy cannot express one.
 *
 * The private key never appears here as a literal. It is read once from SSM by
 * config.ts and passed in, and it is the one value in this service that must
 * not reach a log, a Terraform state file, or this repository.
 */

/** The three cookies CloudFront looks for, in the order it documents them. */
export interface SignedCookieSet {
  "CloudFront-Policy": string;
  "CloudFront-Signature": string;
  "CloudFront-Key-Pair-Id": string;
}

export interface SignerSettings {
  keyPairId: string;
  privateKey: string;
}

/**
 * Cookies granting read access to `resource` until `expiresAt`.
 *
 * `expiresAt` is passed as a Date rather than a duration so the caller owns the
 * clock, which is what lets a test assert on an expiry it chose instead of on
 * one that happened.
 */
export function signViewerCookies(
  settings: SignerSettings,
  resource: string,
  expiresAt: Date,
): SignedCookieSet {
  const policy = JSON.stringify({
    Statement: [
      {
        Resource: resource,
        Condition: {
          DateLessThan: {
            // CloudFront wants seconds, and a fractional second here is a
            // policy CloudFront rejects rather than rounds.
            "AWS:EpochTime": Math.floor(expiresAt.getTime() / 1000),
          },
        },
      },
    ],
  });

  const signed = getSignedCookies({
    keyPairId: settings.keyPairId,
    privateKey: settings.privateKey,
    policy,
  });

  // The signer types every cookie as optionally absent, because its canned and
  // custom policy modes populate different subsets. A custom policy populates
  // all three, so an absent one here is not a case to handle gracefully: it is
  // a broken signer, and silently sending two of three cookies would produce a
  // 403 at the edge with nothing to explain it.
  for (const name of [
    "CloudFront-Policy",
    "CloudFront-Signature",
    "CloudFront-Key-Pair-Id",
  ] as const) {
    if (typeof signed[name] !== "string" || signed[name] === "") {
      throw new Error(`the CloudFront signer produced no ${name}`);
    }
  }

  return {
    "CloudFront-Policy": String(signed["CloudFront-Policy"]),
    "CloudFront-Signature": String(signed["CloudFront-Signature"]),
    "CloudFront-Key-Pair-Id": String(signed["CloudFront-Key-Pair-Id"]),
  };
}

export interface CookieAttributes {
  /** Leading dot, so the cookie is sent to every staging host. */
  domain: string;
  expires: Date;
}

/**
 * One `Set-Cookie` header value.
 *
 * The attributes are not negotiable and are stated in one place so no two
 * cookies in the trio can disagree:
 *
 *   Domain=.staging.changefabric.org  the cookie is minted by a response from
 *                                     the app host and spent on the artifacts
 *                                     host, so it has to span both.
 *   Path=/                            CloudFront matches cookies by name, not
 *                                     by path, and a narrower path would simply
 *                                     stop them being sent.
 *   Secure, HttpOnly                  no script needs to read these, and they
 *                                     are a bearer credential for a team's
 *                                     findings.
 *   SameSite=Lax                      the journey that spends them is a
 *                                     top-level navigation from the app to the
 *                                     artifacts host, which Lax allows. Strict
 *                                     would drop them on exactly that hop and
 *                                     turn every first visit into a 403.
 */
export function cookieHeader(
  name: string,
  value: string,
  attributes: CookieAttributes,
): string {
  return [
    `${name}=${value}`,
    `Domain=${attributes.domain}`,
    "Path=/",
    `Expires=${attributes.expires.toUTCString()}`,
    "Secure",
    "HttpOnly",
    "SameSite=Lax",
  ].join("; ");
}

/** The three headers, ready to be appended to a response. */
export function cookieHeaders(
  cookies: SignedCookieSet,
  attributes: CookieAttributes,
): string[] {
  return Object.entries(cookies).map(([name, value]) =>
    cookieHeader(name, value, attributes),
  );
}
