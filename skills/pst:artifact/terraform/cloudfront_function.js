// CloudFront viewer-request function (runtime cloudfront-js-2.0).
//
// Routing model: each artifact is BUILT and STORED at /p/<id>/index.html with no
// slug in the stored path. Shared URLs are cosmetic -- /p/<id>/<some-slug> --
// where <some-slug> may be stale, wrong, or absent. We resolve every /p/ request
// to its stable id and discard whatever slug the visitor arrived with.
//
// Everything else falls through unchanged, except bare "directory" URIs ending in
// "/" get an index.html appended so the S3 origin can serve them. Assets and
// special files (/_astro, /robots.txt, /favicon.*, /404.html) are left alone.
function handler(event) {
  var request = event.request;
  var uri = request.uri;

  // Artifact permalinks: collapse /p/<id>/<anything...> down to /p/<id>/index.html.
  if (uri.indexOf("/p/") === 0) {
    // Strip the leading "/p/" then take the first path segment as the stable id.
    var rest = uri.slice(3);
    var id = rest.split("/")[0];

    if (id) {
      request.uri = "/p/" + id + "/index.html";
    }
    return request;
  }

  // Leave build assets and well-known files untouched.
  if (
    uri.indexOf("/_astro/") === 0 ||
    uri === "/robots.txt" ||
    uri.indexOf("/favicon") === 0 ||
    uri === "/404.html"
  ) {
    return request;
  }

  // Directory-style request: map "/foo/" -> "/foo/index.html".
  if (uri.endsWith("/")) {
    request.uri = uri + "index.html";
  }

  return request;
}
