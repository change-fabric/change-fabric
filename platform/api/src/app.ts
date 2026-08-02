import { Hono } from "hono";
import { APIError } from "better-auth/api";
import { basicAuth } from "./basic-auth.js";
import type { ArtifactsSettings, BasicAuthCredential } from "./config.js";
import type { Auth } from "./auth-options.js";
import type { ArtifactStorage } from "./storage.js";
import type { PlatformStore } from "./store.js";
import { RouteError, type ClientErrorStatus } from "./routes/context.js";
import { registerTeamRoutes } from "./routes/teams.js";
import { registerKeyRoutes } from "./routes/keys.js";
import { registerInvitationRoutes } from "./routes/invitations.js";
import { registerRepoRoutes } from "./routes/repos.js";
import { registerAliasRoutes } from "./routes/aliases.js";
import { registerArtifactRoutes } from "./routes/artifacts.js";
import { asObject, requireSlug, requireText, ValidationError } from "./validation.js";

/**
 * The HTTP surface.
 *
 *   /healthz          liveness, no auth and no database
 *   /api/auth/*       Better Auth's own handler
 *   /v1/onboarding    turn a fresh sign-up into an organization
 *   /v1/teams/*       contributor teams, their members, and their API keys
 *   /v1/invitations/* inviting somebody in, and accepting
 *   /v1/repos/*       which team owns which repository
 *   /v1/teams/:id/aliases  who somebody was on a team before it was hosted here
 *   /v1/whoami-key    the one route a team API key authenticates
 *   /v1/artifacts/*   publishing a findings run, listing runs, and the two ways
 *                     of reading one back (signed cookies for a browser,
 *                     presigned URLs for a machine)
 */

/** The one path outside the staging Basic Auth gate. */
export const HEALTH_PATH = "/healthz";

export interface OnboardingRequest {
  organizationName: string;
  organizationSlug: string;
}

export { ValidationError };

/**
 * The organization's name and slug come from the sign-up form, so they are
 * validated here rather than derived from anything. Deriving a slug from a name
 * would quietly produce a different handle than the one the person typed, and
 * the slug is immutable once written.
 */
export function parseOnboardingRequest(body: unknown): OnboardingRequest {
  const record = asObject(body);
  return {
    organizationName: requireText(record, "organizationName"),
    organizationSlug: requireSlug(record, "organizationSlug"),
  };
}

const CLIENT_ERROR_STATUSES: readonly ClientErrorStatus[] = [
  400, 401, 403, 404, 409, 422,
];

function clientErrorStatus(error: APIError): ClientErrorStatus {
  const raw = Number(error.statusCode);
  const match = CLIENT_ERROR_STATUSES.find((status) => status === raw);
  return match ?? 400;
}

export interface AppDependencies {
  /**
   * Resolved per request rather than passed in built, so constructing the app
   * touches neither SSM nor the database. That is what lets /healthz answer on
   * a cold start where the database is unreachable.
   */
  auth: () => Promise<Auth>;
  basicAuthCredential: () => Promise<BasicAuthCredential>;
  /** The platform's own tables. Same laziness, same reason. */
  store: () => Promise<PlatformStore>;
  /**
   * The artifacts bucket and the CloudFront signing key, or null in a
   * deployment that has no artifacts host. Same laziness again: the signing key
   * is an SSM read, and /healthz must not depend on one.
   */
  artifacts?: () => Promise<{
    settings: ArtifactsSettings;
    storage: ArtifactStorage;
  } | null>;
  /** Injected so a test can assert on a timestamp it chose. */
  now?: () => Date;
}

export function createApp(deps: AppDependencies): Hono {
  const app = new Hono();
  const routeDeps = {
    auth: deps.auth,
    store: deps.store,
    now: deps.now ?? (() => new Date()),
  };
  const artifactDeps = {
    ...routeDeps,
    artifacts: deps.artifacts ?? (async () => null),
  };

  // First in the chain, so nothing below it is reachable without the staging
  // credential. /healthz is exempt on purpose: it has to answer before the
  // database or SSM is reachable, which is what makes it useful for confirming
  // the Lambda and API Gateway wiring on its own.
  app.use(
    "*",
    basicAuth({
      credential: deps.basicAuthCredential,
      exempt: (path) => path === HEALTH_PATH,
    }),
  );

  app.get(HEALTH_PATH, (c) => c.json({ status: "ok" }));

  app.on(["GET", "POST"], "/api/auth/*", async (c) => {
    const auth = await deps.auth();
    return auth.handler(c.req.raw);
  });

  app.post("/v1/onboarding", async (c) => {
    const payload = parseOnboardingRequest(await c.req.json());

    const auth = await deps.auth();
    const session = await auth.api.getSession({ headers: c.req.raw.headers });
    if (session === null) {
      throw new RouteError(401, "authentication required");
    }

    // The plugin's own create-org path, so the owner membership, the active
    // organization on the session, and every hook fire exactly as they would
    // for any other caller.
    const created = await auth.api.createOrganization({
      body: {
        name: payload.organizationName,
        slug: payload.organizationSlug,
        userId: session.user.id,
      },
      headers: c.req.raw.headers,
    });

    if (created === null || created === undefined) {
      return c.json({ error: "organization was not created" }, 500);
    }

    return c.json(
      {
        organization: {
          id: created.id,
          name: created.name,
          slug: created.slug,
        },
      },
      201,
    );
  });

  registerTeamRoutes(app, routeDeps);
  registerKeyRoutes(app, routeDeps);
  registerInvitationRoutes(app, routeDeps);
  registerRepoRoutes(app, routeDeps);
  registerAliasRoutes(app, routeDeps);
  registerArtifactRoutes(app, artifactDeps);

  app.notFound((c) => c.json({ error: "not found" }, 404));

  /**
   * One place decides what a failure looks like to a caller, so no route has to
   * carry its own try/catch and no two of them can disagree.
   *
   * Three kinds arrive here. A ValidationError is a malformed body, always 400.
   * A RouteError is a refusal a route made deliberately and already chose the
   * status for. An APIError is Better Auth's own rejection, whose status is
   * passed through when it is a caller error and flattened to 400 otherwise, so
   * a 2xx or a 5xx from the plugin can never masquerade as one. Anything else is
   * a bug: it is logged and answered 500 without leaking its message.
   */
  app.onError((error, c) => {
    if (error instanceof ValidationError) {
      return c.json({ error: error.message }, 400);
    }
    if (error instanceof RouteError) {
      return c.json({ error: error.message }, error.status);
    }
    if (error instanceof APIError) {
      return c.json({ error: error.message }, clientErrorStatus(error));
    }
    if (error instanceof SyntaxError) {
      // A body that was not JSON at all, from c.req.json().
      return c.json({ error: "body must be valid JSON" }, 400);
    }

    console.error(
      JSON.stringify({
        event: "request.failed",
        path: c.req.path,
        reason: error instanceof Error ? error.message : String(error),
      }),
    );
    return c.json({ error: "internal error" }, 500);
  });

  return app;
}
