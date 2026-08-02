// CloudFront Function (viewer-request) for artifacts.staging.changefabric.org.
//
// This is a TEMPLATE. deploy-artifacts.sh substitutes the placeholders below and
// publishes the result; the compiled source, with the real digest in it, exists
// only in AWS and is never written back into this repository. That is the same
// arrangement basic-auth.function.js uses for the web app, and deliberately so:
// one mechanism, one algorithm, one place to rotate the credential.
//
// ---------------------------------------------------------------------------
// Why there are two kinds of path, and why that is not a preference
// ---------------------------------------------------------------------------
//
// CloudFront evaluates `trusted_key_groups` BEFORE it invokes a viewer-request
// function. That was measured against this distribution, not assumed: with the
// key group on a behavior, a request carrying no signed cookie is answered 403
// by CloudFront and this function is never entered, so it can neither apply the
// Basic Auth gate nor offer a person a way to get a cookie.
//
// The distribution is therefore split in two, and the split is total:
//
//   /v/<org>/<team>/<short>/   the ENTRY POINT. No key group, so this function
//                              runs. It serves no bytes at all and never
//                              reaches the origin: every path through it ends
//                              in a 401 or a 302. That is what makes the
//                              absence of a key group here harmless.
//
//   everything else            the OBJECTS. Key group enforced by CloudFront
//                              itself, on every request, with no exceptions and
//                              no list of file types to keep up to date. This
//                              function still runs, but only after CloudFront
//                              has already accepted the cookie.
//
// The alternative considered and rejected was to leave the default behavior
// unprotected and enumerate protected behaviors by file extension. It would
// have worked for the extensions somebody remembered, and silently served the
// next one in the clear. Making the catch-all the protected side means a path
// nobody anticipated fails closed.
//
// ---------------------------------------------------------------------------
// What each of the three checks is for
// ---------------------------------------------------------------------------
//
// 1. The staging Basic Auth gate, applied to BOTH kinds of path. Identical in
//    mechanism to the other two staging surfaces: a SHA-256 digest of the
//    expected Authorization header, compiled in at deploy time from
//    /cf-platform/staging/basic-auth-credential. A CloudFront Function has no
//    network access at all, so it cannot read SSM per request, which is why it
//    holds a digest and not the credential.
//
// 2. The no-cookie redirect, on the entry point only. A person opening a link
//    to a findings run for the first time has no cookie yet, and that is the
//    expected case rather than an error, so they are sent to the app's
//    /artifacts/authorize route to get one and come back.
//
//    This function does NOT verify the cookie and must not try. It has no
//    private key and no signature verification, so any check it invented would
//    be a check on the cookie's presence dressed up as a check on its validity.
//    A request that HAS the trio is redirected on to the real object path, where
//    CloudFront's own enforcement decides whether the cookie is genuine and
//    unexpired. An expired cookie therefore produces CloudFront's 403 rather
//    than a guess made here, which is exactly the division of labour intended.
//
// 3. Directory index resolution. default_root_object only applies at the root of
//    the distribution, so a URL ending in a slash deeper in the tree resolves to
//    nothing at S3. Appending index.html is what makes a run's own page open.
import crypto from 'crypto';

var EXPECTED_SHA256 = '__CREDENTIAL_SHA256__';
var REALM = '__REALM__';
var APP_ORIGIN = '__APP_ORIGIN__';

// The entry-point prefix. One place, because the function both recognises it
// and strips it, and those two have to agree.
var ENTRY_PREFIX = '/v/';

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

function redirect(location) {
  return {
    statusCode: 302,
    statusDescription: 'Found',
    headers: {
      location: { value: location },
      // Never cached. A cached redirect would be served to a viewer who has
      // since obtained cookies, sending them round the loop again.
      'cache-control': { value: 'no-store' }
    }
  };
}

// All three, not any one. CloudFront needs the whole trio, so a request holding
// two of them is as cookieless as one holding none, and sending it on would
// produce a bare 403 for what is really a first visit.
function hasSignedCookies(cookies) {
  return Boolean(
    cookies &&
      cookies['CloudFront-Policy'] &&
      cookies['CloudFront-Signature'] &&
      cookies['CloudFront-Key-Pair-Id']
  );
}

// charAt rather than endsWith: the CloudFront Functions runtime is a restricted
// JavaScript, and a syntactically valid call to something it does not implement
// fails at request time rather than at publish time.
function withIndex(uri) {
  return uri.charAt(uri.length - 1) === '/' ? uri + 'index.html' : uri;
}

// The team slug in /v/<org-slug>/<team-slug>/<short-id>/..., which is the third
// segment once the empty one before the leading slash is counted. Empty when the
// path is shorter than that, in which case the app asks the person to choose
// rather than guessing on their behalf.
function teamSlugFrom(uri) {
  var parts = uri.split('/');
  return parts.length > 3 ? parts[3] : '';
}

// The URL the person actually asked for, so the app can send them back to it.
function originalUrl(request) {
  var host = request.headers.host ? request.headers.host.value : '';
  var url = 'https://' + host + request.uri;
  var pairs = [];
  for (var name in request.querystring) {
    pairs.push(
      encodeURIComponent(name) +
        '=' +
        encodeURIComponent(request.querystring[name].value)
    );
  }
  return pairs.length > 0 ? url + '?' + pairs.join('&') : url;
}

function handler(event) {
  var request = event.request;

  var header = request.headers.authorization;
  if (!header || !header.value) return unauthorized();

  var digest = crypto.createHash('sha256').update(header.value).digest('hex');
  if (digest !== EXPECTED_SHA256) return unauthorized();

  if (request.uri.indexOf(ENTRY_PREFIX) === 0) {
    if (!hasSignedCookies(request.cookies)) {
      return redirect(
        APP_ORIGIN +
          '/artifacts/authorize?next=' +
          encodeURIComponent(originalUrl(request)) +
          '&team=' +
          encodeURIComponent(teamSlugFrom(request.uri))
      );
    }

    // Onward to the real object path, which CloudFront guards with the key
    // group. The entry point itself never serves a byte.
    return redirect(withIndex(request.uri.substring(ENTRY_PREFIX.length - 1)));
  }

  // An object path. CloudFront has already verified the signed cookie by the
  // time execution reaches here, so all that is left is resolving a directory
  // URL to the file inside it.
  request.uri = withIndex(request.uri);
  return request;
}
