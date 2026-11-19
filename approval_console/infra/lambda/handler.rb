# frozen_string_literal: true

# Placeholder handler. It exists so the function URL host exists and can be
# pinned as the WebAuthn rpId before the real handler ships. Every request is
# refused with 503 and no body that names a route.
def handler(event:, context:)
  {
    statusCode: 503,
    headers: { 'content-type' => 'text/plain; charset=utf-8', 'cache-control' => 'no-store' },
    body: 'approval console is not deployed yet'
  }
end
