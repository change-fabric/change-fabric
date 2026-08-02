import { Hono } from "hono";
import { APIError } from "better-auth/api";
import { basicAuth } from "./basic-auth.js";
import type { BasicAuthCredential } from "./config.js";
import type { Auth } from "./auth-options.js";

/**
 * The HTTP surface. Three things live here and nothing else:
 *
 *   /healthz        liveness, no auth and no database
 *   /api/auth/*     Better Auth's own handler
 *   /v1/onboarding  turn a fresh sign-up into an organization
 *
 * Contributor-team CRUD, artifacts, and the web app belong to later phases.
 */

/** The one path outside the staging Basic Auth gate. */
export const HEALTH_PATH = "/healthz";

const SLUG_PATTERN = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

export interface OnboardingRequest {
  organizationName: string;
  organizationSlug: string;
}

export class ValidationError extends Error {}

/**
 * The organization's name and slug come from the sign-up form, so they are
 * validated here rather than derived from anything. Deriving a slug from a name
 * would quietly produce a different handle than the one the person typed, and
 * the slug is immutable once written.
 */
export function parseOnboardingRequest(body: unknown): OnboardingRequest {
  if (typeof body !== "object" || body === null) {
    throw new ValidationError("body must be a JSON object");
  }
  const { organizationName, organizationSlug } = body as Record<
    string,
    unknown
  >;

  if (typeof organizationName !== "string" || organizationName.trim() === "") {
    throw new ValidationError("organizationName must be a non-empty string");
  }
  if (typeof organizationSlug !== "string") {
    throw new ValidationError("organizationSlug must be a string");
  }
  if (!SLUG_PATTERN.test(organizationSlug)) {
    throw new ValidationError(
      "organizationSlug must be lower-case alphanumeric with internal hyphens",
    );
  }

  return {
    organizationName: organizationName.trim(),
    organizationSlug,
  };
}

type ClientErrorStatus = 400 | 401 | 403 | 404 | 409 | 422;

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
}

export function createApp(deps: AppDependencies): Hono {
  const app = new Hono();

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
    let payload: OnboardingRequest;
    try {
      payload = parseOnboardingRequest(await c.req.json());
    } catch (error: unknown) {
      if (error instanceof ValidationError) {
        return c.json({ error: error.message }, 400);
      }
      return c.json({ error: "body must be valid JSON" }, 400);
    }

    const auth = await deps.auth();
    const session = await auth.api.getSession({
      headers: c.req.raw.headers,
    });
    if (session === null) {
      return c.json({ error: "authentication required" }, 401);
    }

    try {
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
    } catch (error: unknown) {
      if (error instanceof APIError) {
        // Better Auth already decided this is a caller error (a slug already
        // taken, a rejected slug update). Pass its own status through rather
        // than flattening every one of them to 400, but never let a 2xx or a
        // 5xx from the plugin masquerade as a successful onboarding.
        return c.json({ error: error.message }, clientErrorStatus(error));
      }
      throw error;
    }
  });

  app.notFound((c) => c.json({ error: "not found" }, 404));

  app.onError((error, c) => {
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
