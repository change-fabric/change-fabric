// CloudFront Function (viewer-request) applying the staging-wide HTTP Basic Auth
// gate to app.staging.changefabric.org, in front of both the S3 origin serving
// the SPA and the API Gateway origin behind /api/* and /v1/*.
//
// This is a TEMPLATE. deploy.sh substitutes the two placeholders below and
// publishes the result; the compiled source, with the real digest in it, exists
// only in AWS and is never written back into this repository.
//
// Why a digest and not the credential itself: a CloudFront Function runs at the
// edge with no network access at all, so it cannot call SSM, Secrets Manager, or
// anything else at request time. The credential's home stays
// /cf-platform/staging/basic-auth-credential, which is what phase 1 provisioned
// and what the API's own Lambda gate reads live. deploy.sh reads that parameter
// and compiles only its SHA-256 digest in here. Rotating the credential is a
// put-parameter followed by a re-run of deploy.sh.
//
// The digest covers the whole Authorization header value, matching the existing
// precedent in skills/change/reference/artifact-basic-auth.function.js so there
// is one algorithm across the estate rather than two.
//
// This gate is coarse and deliberately not the product's authentication. Better
// Auth's sessions and organization membership run underneath it, in the API. A
// request that clears this one has proved only that it belongs on staging.
import crypto from 'crypto';

const EXPECTED_SHA256 = '__CREDENTIAL_SHA256__';
const REALM = '__REALM__';

function unauthorized() {
  return {
    statusCode: 401,
    statusDescription: 'Unauthorized',
    headers: {
      'www-authenticate': { value: 'Basic realm="' + REALM + '", charset="UTF-8"' },
      'cache-control': { value: 'no-store' }
    }
  };
}

// The two path prefixes CloudFront forwards to the API rather than to S3. They
// are named here for one reason: this function must never rewrite a request that
// is on its way to the API.
function isApiPath(uri) {
  return uri.indexOf('/api/') === 0 || uri.indexOf('/v1/') === 0;
}

// Whether a path is asking for a file or for one of the app's own routes.
// /assets/index-abc123.js has an extension and is a file; /teams/xyz does not
// and is a route the client router resolves.
function looksLikeFile(uri) {
  const lastSlash = uri.lastIndexOf('/');
  return uri.slice(lastSlash + 1).indexOf('.') >= 0;
}

function handler(event) {
  const request = event.request;
  const header = request.headers.authorization;
  if (!header || !header.value) return unauthorized();

  const digest = crypto.createHash('sha256').update(header.value).digest('hex');
  if (digest !== EXPECTED_SHA256) return unauthorized();

  // Client-routed SPA. An unknown path is one of the app's routes, not a
  // missing file, so it is served index.html and the router resolves it.
  //
  // This replaced a distribution-wide custom_error_response mapping 403 and 404
  // to index.html with a 200. That mapping could not tell a missing S3 key from
  // a real refusal by the API, so once the API grew routes that legitimately
  // answer 403 and 404, every one of them reached the browser as a 200 carrying
  // an HTML page. The app then reported "no readable body" instead of the reason
  // the server actually gave. Rewriting here instead is scoped by construction:
  // an API path is returned untouched, so its status reaches the caller intact.
  if (!isApiPath(request.uri) && !looksLikeFile(request.uri)) {
    request.uri = '/index.html';
  }

  return request;
}
