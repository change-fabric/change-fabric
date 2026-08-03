// CloudFront Function (viewer-request) applying the staging-wide HTTP Basic Auth
// gate to mailpit.staging.changefabric.org.
//
// This is a TEMPLATE. deploy.sh substitutes the two placeholders below and
// publishes the result; the compiled source, with the real digest in it, exists
// only in AWS and is never written back into this repository.
//
// The mechanism is the one platform/web/basic-auth.function.js established and
// platform/web/artifacts-auth.function.js repeated: a CloudFront Function runs
// at the edge with no network access at all, so it cannot read SSM per request.
// The credential's home stays /cf-platform/staging/basic-auth-credential, the
// same single parameter every other staging surface reads; deploy.sh reads it at
// deploy time and compiles in only the SHA-256 digest of the expected
// Authorization header. Rotating the credential is a put-parameter followed by a
// re-run of deploy.sh here and in platform/web.
//
// There is no path rewriting and no exemption list, unlike the web app's
// function. Mailpit serves its own UI, its own JSON API under /api/v1/ and its
// own websocket under /api/events off one origin, and every one of them is a
// view of the staging mailbox. Exempting anything would be exempting mail.
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

function handler(event) {
  const request = event.request;
  const header = request.headers.authorization;
  if (!header || !header.value) return unauthorized();

  const digest = crypto.createHash('sha256').update(header.value).digest('hex');
  if (digest !== EXPECTED_SHA256) return unauthorized();

  return request;
}
