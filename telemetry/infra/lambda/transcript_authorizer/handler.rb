# Capability A - transcript_authorizer (plan section 6.3). API Gateway v2 HTTP API
# REQUEST authorizer with enableSimpleResponses=true: returns { isAuthorized: bool }
# (the v2.0 simple-response shape), NOT the REST { principalId, policyDocument } shape.
# Constant-time-compares the x-api-key header against TELEMETRY_SECRET. Fails closed:
# this is a real gate, unlike the fail-open hooks.

require "openssl"

# Genuinely constant-time comparison, not `==`. Uses OpenSSL when the input
# lengths already match; otherwise short-circuits false (length is not secret).
def secure_equal?(a, b)
  return false if a.nil? || b.nil?
  return false unless a.bytesize == b.bytesize

  OpenSSL.fixed_length_secure_compare(a, b)
end

def handler(event:, context:)
  headers = event["headers"] || {}
  # API Gateway lowercases header names.
  provided = headers["x-api-key"]
  expected = ENV["TELEMETRY_SECRET"]

  { isAuthorized: secure_equal?(provided, expected) }
rescue StandardError => e
  puts "ERROR: #{e.class}: #{e.message}"
  { isAuthorized: false }
end
