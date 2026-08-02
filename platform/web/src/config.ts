/**
 * Where the app's API calls go.
 *
 * The deployed app talks to its OWN origin (app.staging.changefabric.org) and
 * CloudFront forwards /api/* and /v1/* to the API Gateway custom domain. It is
 * not a stylistic choice, it is the only shape that works:
 *
 *  - Every staging surface sits behind one shared HTTP Basic Auth gate. A
 *    browser only replays Basic credentials to the origin it was challenged by,
 *    so a cross-origin call from app.staging to api.staging arrives with no
 *    Authorization header and is rejected by the API's own gate. The only way to
 *    make that call succeed would be to ship the staging credential inside the
 *    JavaScript bundle, which is worse than the problem it solves.
 *  - A cross-origin JSON POST needs a CORS preflight, and OPTIONS on the API is
 *    answered by the Basic Auth gate (401) or, once past it, by the router's own
 *    404: the API registers GET and POST only. Preflight never carries
 *    credentials, so no arrangement of the gate fixes that from this side.
 *
 * Same-origin removes both problems at once. The single Basic Auth challenge the
 * browser answers for app.staging covers the API calls too, the session cookie
 * (already scoped to .staging.changefabric.org by the API) keeps working, and
 * there is no preflight at all.
 *
 * VITE_API_ORIGIN overrides it, which is what a local `vite dev` run against a
 * different API uses; the dev server proxies the same two path prefixes so the
 * default works there unchanged.
 */
export const API_ORIGIN: string =
  import.meta.env.VITE_API_ORIGIN ?? window.location.origin;
