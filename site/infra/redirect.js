// CloudFront Function (viewer-request) on the apex distribution. It 301s every
// apex request to the canonical www host, preserving the path and query, so
// https://changefabric.org/... redirects to https://www.changefabric.org/...
// The apex distribution's origin is therefore never actually read.
function handler(event) {
  const request = event.request;
  let query = "";
  if (request.querystring && Object.keys(request.querystring).length > 0) {
    const parts = Object.keys(request.querystring).map(function (key) {
      return key + "=" + request.querystring[key].value;
    });
    query = "?" + parts.join("&");
  }
  return {
    statusCode: 301,
    statusDescription: "Moved Permanently",
    headers: {
      location: { value: "https://www.changefabric.org" + request.uri + query },
    },
  };
}
