# Capability C - notifications (plan section 6.5). Serves the two client routes
# for secret-finding delivery, dispatched by path inside this one Lambda:
#   POST /notifications      -> poll (deliver the oldest un-acked finding)
#   POST /notifications/ack  -> record the contributor's chosen option
# Both are Ed25519-signed against the same cf-teams public key (plan section 5.4).
#
# Container-built (package_type = Image) because the ed25519 gem ships a native
# C extension. The signature-verification / ts-skew logic is intentionally a copy
# of presence's (plan says code duplication between the two deployments is fine and
# expected for this POC; they are separate Lambda packages).
#
# HTTP status split: 401 for auth failures (bad/absent sig, unknown team, stale
# ts), 500 for genuine server errors. The pst hooks fail open on any non-2xx
# (plan section 10), but a clean 401-vs-500 split still matters for CloudWatch.

require "json"
require "base64"
require "time"
require "ed25519"
require "aws-sdk-dynamodb"

# Instantiated once at load time for warm-start reuse (plan section 6).
DYNAMODB = Aws::DynamoDB::Client.new

# ============================================================================
# CANONICAL SIGNING CONTRACTS - NOTIFICATIONS. Each endpoint has its OWN field
# set (the payloads differ). Both MUST match the pst-side hook byte-for-byte
# (see telemetry/infra/lambda/SIGNING.md). Newline-joined ("\n", 0x0A), UTF-8,
# NO trailing newline, every field EXCEPT `sig`, in this exact order.
#
# POLL (POST /notifications) - 4 fields:
#   [team_id, contributor_id, ts, nonce].join("\n")
#
# ACK (POST /notifications/ack) - 6 fields:
#   [team_id, contributor_id, ts, nonce, finding_id, chosen_option].join("\n")
#
# NOTE: these differ from presence's 7-field scheme. Do not confuse them.
# ============================================================================
POLL_CANONICAL_FIELDS = %w[team_id contributor_id ts nonce].freeze
ACK_CANONICAL_FIELDS  = %w[team_id contributor_id ts nonce finding_id chosen_option].freeze

class AuthError < StandardError; end

def json_response(status, hash)
  {
    statusCode: status,
    headers: { "Content-Type" => "application/json" },
    body: JSON.generate(hash)
  }
end

# Shared verification: ts-skew, cf-teams lookup, Ed25519 over the given fields.
# Raises AuthError (=> 401) on any failure.
def verify!(body, canonical_fields)
  skew = ENV["TS_SKEW_SECONDS"].to_i
  parsed_ts = Time.iso8601(body["ts"].to_s) rescue (raise AuthError, "bad ts")
  raise AuthError, "ts skew" if (Time.now.utc - parsed_ts.utc).abs > skew

  team = DYNAMODB.get_item(
    table_name: ENV["TEAMS_TABLE"],
    key: { "pk" => "TEAM##{body['team_id']}" },
    consistent_read: true
  ).item
  raise AuthError, "unknown team" if team.nil?

  canonical = canonical_fields.map { |f| body[f].to_s }.join("\n").encode("UTF-8")
  begin
    verify_key = Ed25519::VerifyKey.new(Base64.decode64(team["public_key_ed25519"]))
    ok = verify_key.verify(Base64.decode64(body["sig"].to_s), canonical)
    raise AuthError, "bad signature" unless ok
  rescue AuthError
    raise
  rescue StandardError
    raise AuthError, "bad signature"
  end
end

# --- POST /notifications (poll) ---------------------------------------------
def handle_poll(body)
  verify!(body, POLL_CANONICAL_FIELDS)

  pk = "CONTRIB##{body['team_id']}##{body['contributor_id']}"
  # Query the whole partition oldest-first (sk starts with created_at). Filter
  # out acknowledged rows; no separate status index at POC scale (plan section 6.5).
  rows = DYNAMODB.query(
    table_name: ENV["NOTIFICATIONS_TABLE"],
    key_condition_expression: "pk = :pk",
    filter_expression: "#s <> :acked",
    expression_attribute_names: { "#s" => "status" },
    expression_attribute_values: { ":pk" => pk, ":acked" => "acknowledged" },
    scan_index_forward: true
  ).items

  finding = rows.first
  return json_response(200, status: "none") if finding.nil?

  now_iso = Time.now.utc.iso8601
  # Conditionally flip pending -> delivered so it fires once. If it is already
  # "delivered" (re-poll before ack), we still return it, just skip the update.
  begin
    DYNAMODB.update_item(
      table_name: ENV["NOTIFICATIONS_TABLE"],
      key: { "pk" => finding["pk"], "sk" => finding["sk"] },
      update_expression: "SET #s = :delivered, delivered_at = :now",
      condition_expression: "#s = :pending",
      expression_attribute_names: { "#s" => "status" },
      expression_attribute_values: {
        ":delivered" => "delivered", ":now" => now_iso, ":pending" => "pending"
      }
    )
  rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
    # Already delivered; still surface it to the caller.
  end

  json_response(200,
                status: "found",
                finding_id: finding["finding_id"],
                rule_id: finding["rule_id"],
                masked_preview: finding["match_preview"],
                session_id: finding["session_id"],
                match_location: finding["match_location"])
end

# --- POST /notifications/ack ------------------------------------------------
def handle_ack(body)
  verify!(body, ACK_CANONICAL_FIELDS)

  pk = "CONTRIB##{body['team_id']}##{body['contributor_id']}"
  finding_id = body["finding_id"].to_s
  # We know the partition from the signed payload; find the row by finding_id.
  rows = DYNAMODB.query(
    table_name: ENV["NOTIFICATIONS_TABLE"],
    key_condition_expression: "pk = :pk",
    filter_expression: "finding_id = :fid",
    expression_attribute_values: { ":pk" => pk, ":fid" => finding_id }
  ).items

  finding = rows.first
  raise AuthError, "unknown finding" if finding.nil?

  now_iso = Time.now.utc.iso8601
  DYNAMODB.update_item(
    table_name: ENV["NOTIFICATIONS_TABLE"],
    key: { "pk" => finding["pk"], "sk" => finding["sk"] },
    update_expression: "SET #s = :acked, acknowledged_at = :now, chosen_option = :opt",
    expression_attribute_names: { "#s" => "status" },
    expression_attribute_values: {
      ":acked" => "acknowledged",
      ":now" => now_iso,
      ":opt" => body["chosen_option"]
    }
  )

  json_response(200, status: "ok")
end

def handler(event:, context:)
  path = event["rawPath"] || event.dig("requestContext", "http", "path")
  body = JSON.parse(event["body"] || "{}")

  if path && path.end_with?("/notifications/ack")
    handle_ack(body)
  else
    handle_poll(body)
  end
rescue AuthError => e
  puts "AUTH: #{e.message}"
  json_response(401, status: "unauthorized")
rescue StandardError => e
  puts "ERROR: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}"
  json_response(500, status: "error")
end
