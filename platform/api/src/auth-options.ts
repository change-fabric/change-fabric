import { betterAuth, type BetterAuthOptions } from "better-auth";
import { APIError } from "better-auth/api";
import { organization } from "better-auth/plugins/organization";

/**
 * Additional columns this platform hangs off the organization plugin's `team`
 * table. They are declared here rather than in a table of our own because
 * Better Auth owns the team model: a parallel table would need its own
 * lifecycle, its own cascade, and its own consistency story for no gain.
 *
 * `slug` is `input: true` and required, so every create-team call has to supply
 * one. `legacyTeamId` carries the identifier a team had before it was hosted,
 * and is unique so the same legacy team cannot be claimed twice.
 */
export const teamAdditionalFields = {
  slug: {
    type: "string",
    required: true,
    input: true,
  },
  publicKeyEd25519: {
    type: "string",
    required: false,
    input: true,
  },
  legacyTeamId: {
    type: "string",
    required: false,
    input: true,
    unique: true,
  },
} as const;

/** Message used for both slug rejections, so a caller sees one contract. */
export const SLUG_IMMUTABLE_MESSAGE =
  "slug is immutable and cannot be changed after creation";

/**
 * A slug is a public, durable handle: it appears in URLs, in artifact paths,
 * and in whatever a downstream repo has already written down. Renaming one
 * silently breaks every reference, so the platform refuses instead of
 * cascading. The check is presence-based rather than value-based on purpose:
 * "the same slug you already have" is not a meaningful update, and accepting it
 * would leave a code path where a slug write reaches the database at all.
 */
export function assertSlugNotUpdated(payload: Record<string, unknown>): void {
  if (Object.prototype.hasOwnProperty.call(payload, "slug")) {
    throw new APIError("BAD_REQUEST", { message: SLUG_IMMUTABLE_MESSAGE });
  }
}

export interface AuthDependencies {
  /** Whatever adapter or dialect Better Auth should persist through. */
  database: BetterAuthOptions["database"];
  /** Session signing secret, from /cf-platform/staging/better-auth-secret. */
  secret: string;
  /** Public origin this instance answers on, e.g. https://api.staging.example. */
  baseURL: string;
  /**
   * Cookie domain, leading dot included, so a session set by the API host is
   * readable by the web app host. Empty disables cross-subdomain cookies, which
   * is what a test wants.
   */
  cookieDomain: string;
  /** Trusted origins for CORS and cookie-bearing browser calls. */
  trustedOrigins: string[];
  /** Delivery side effect. Injected so a test never reaches for the network. */
  sendVerificationEmail: (message: {
    to: string;
    subject: string;
    text: string;
  }) => Promise<void>;
}

/**
 * The return type is deliberately inferred rather than annotated as
 * `BetterAuthOptions`. Better Auth derives its whole server API surface
 * (`auth.api.createOrganization` and friends) from the literal plugin list, and
 * widening the options to the interface erases that. `satisfies` keeps the
 * checking without the widening.
 */
export function buildAuthOptions(deps: AuthDependencies) {
  return {
    appName: "change-fabric platform",
    secret: deps.secret,
    baseURL: deps.baseURL,
    trustedOrigins: deps.trustedOrigins,
    database: deps.database,

    emailAndPassword: {
      enabled: true,
      // Verification is sent, but not required to hold a session. Staging sits
      // behind the Basic Auth gate already, and SES is still in the sandbox, so
      // gating sign-in on a delivered mail would gate it on an unrelated AWS
      // support ticket.
      requireEmailVerification: false,
    },

    emailVerification: {
      sendOnSignUp: true,
      sendVerificationEmail: async ({ user, url }) => {
        await deps.sendVerificationEmail({
          to: user.email,
          subject: "Verify your change-fabric address",
          text: `Confirm this address to finish setting up your change-fabric account:\n\n${url}\n`,
        });
      },
    },

    advanced: {
      // A session set by api.staging.<domain> has to be readable by
      // app.staging.<domain>. Without a domain the cookie is host-only and the
      // web app in the next phase would see no session at all.
      crossSubDomainCookies: deps.cookieDomain
        ? { enabled: true, domain: deps.cookieDomain }
        : { enabled: false },
      defaultCookieAttributes: {
        secure: true,
        httpOnly: true,
        sameSite: "lax",
      },
    },

    plugins: [
      organization({
        teams: {
          enabled: true,
          // A default team would be created with no slug, and slug is required.
          // Team creation is an explicit call that supplies one; phase 4 owns
          // the surface that makes those calls.
          defaultTeam: { enabled: false },
        },
        schema: {
          team: { additionalFields: teamAdditionalFields },
        },
        organizationHooks: {
          beforeUpdateOrganization: async ({ organization: update }) => {
            assertSlugNotUpdated(update);
          },
          beforeUpdateTeam: async ({ updates }) => {
            assertSlugNotUpdated(updates);
          },
        },
      }),
    ],
  } satisfies BetterAuthOptions;
}

export function createAuth(deps: AuthDependencies) {
  return betterAuth(buildAuthOptions(deps));
}

export type Auth = ReturnType<typeof createAuth>;
