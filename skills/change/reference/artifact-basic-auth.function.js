// CloudFront Function (viewer-request) gating the team's artifact area behind
// HTTP Basic Auth. Published by scripts/cf_artifacts_init.rb, which substitutes
// the two placeholders below before uploading it.
//
// Why a digest and not the credential itself: a CloudFront Function runs at the
// edge with no network access at all, so it cannot call Secrets Manager, SSM,
// or anything else at request time. The credential's home is therefore the SSM
// SecureString parameter named in the CHANGE.md artifacts block, which is the
// single source of truth a human writes and rotates; the init script reads that
// parameter at deploy time and compiles only its SHA-256 digest into this file.
// The plaintext credential is never written into this source, into CHANGE.md,
// or into any repo. Rotating it is `cf_artifacts_init.rb <team_id> --rotate`,
// which re-reads the parameter and republishes this function.
//
// The digest is compared against a hash of the whole Authorization header
// value, so neither the username nor the password is recoverable from the
// function source. That is only true while the credential itself is high
// entropy, which is why the init script generates one rather than accepting a
// chosen password.
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
