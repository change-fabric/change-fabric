# Capability B - presence (plan section 6.2). Live file-collision detection.
# Verifies an Ed25519-signed probe against the team public key in cf-teams, then
# does a strongly-consistent Query on cf-presence to report whether a teammate is
# already editing the same file, and records this contributor's own claim.
#
# Container-built (package_type = Image) because the ed25519 gem ships a native
# C extension that must link against the Lambda runtime.
#
# HTTP status split (plan section 6.2):
#   401 - collision-adjacent AUTH failures that must fail closed: unknown team,
#         bad/absent signature, stale ts. These are deliberate rejections of an
#         untrusted caller, not server faults.
#   500 - genuine server errors (parse failure, DynamoDB error, etc). The pst
#         PreToolUse hook fails OPEN on any 5xx/timeout (plan section 10), so a
#         real error degrades to "no collision" and never blocks an edit.

require "json"
require "base64"
require "time"
require "digest"
require "ed25519"
require "aws-sdk-dynamodb"

# Instantiated once at load time for warm-start reuse (plan section 6).
DYNAMODB = Aws::DynamoDB::Client.new

# ============================================================================
# CANONICAL SIGNING CONTRACT - PRESENCE (7 fields). MUST match the pst-side hook
# byte-for-byte (see telemetry/infra/lambda/SIGNING.md). This is the single most
# important cross-component contract in the presence path. Any drift here breaks
# every signature.
#
#   canonical_bytes = [
#     team_id,
#     contributor_id,
#     contributor_name,
#     repo_id,
#     file_path,
#     ts,
#     nonce
#   ].join("\n").encode("UTF-8")
#
# Fixed field order, newline-joined ("\n", 0x0A), UTF-8 encoded, NO trailing
# newline, every field EXCEPT `sig`. Copy-pasteable and identical on both sides.
# ============================================================================
PRESENCE_CANONICAL_FIELDS = %w[
  team_id contributor_id contributor_name repo_id file_path ts nonce
].freeze

def canonical_bytes(body)
  PRESENCE_CANONICAL_FIELDS.map { |f| body[f].to_s }.join("\n").encode("UTF-8")
end

class AuthError < StandardError; end

def json_response(status, hash)
  {
    statusCode: status,
    headers: { "Content-Type" => "application/json" },
    body: JSON.generate(hash)
  }
end

def handler(event:, context:)
  body = JSON.parse(event["body"] || "{}")

  # --- ts-skew check (replay / clock guard) -> 401 -------------------------
  skew = ENV["TS_SKEW_SECONDS"].to_i
  parsed_ts = Time.iso8601(body["ts"].to_s) rescue (raise AuthError, "bad ts")
  raise AuthError, "ts skew" if (Time.now.utc - parsed_ts.utc).abs > skew

  # --- team public key lookup -> 401 if absent -----------------------------
  team_id = body["team_id"].to_s
  team = DYNAMODB.get_item(
    table_name: ENV["TEAMS_TABLE"],
    key: { "pk" => "TEAM##{team_id}" },
    consistent_read: true
  ).item
  raise AuthError, "unknown team" if team.nil?

  # --- Ed25519 verification -> 401 on any failure --------------------------
  begin
    verify_key = Ed25519::VerifyKey.new(Base64.decode64(team["public_key_ed25519"]))
    ok = verify_key.verify(Base64.decode64(body["sig"].to_s), canonical_bytes(body))
    raise AuthError, "bad signature" unless ok
  rescue AuthError
    raise
  rescue StandardError
    # Ed25519::VerifyError and friends all mean "not a valid signature".
    raise AuthError, "bad signature"
  end

  # --- presence lookup + claim ---------------------------------------------
  contributor_id = body["contributor_id"].to_s
  contributor_name = body["contributor_name"].to_s
  repo_id = body["repo_id"].to_s
  file_path = body["file_path"].to_s
  file_hash = Digest::SHA256.hexdigest(file_path)
  pk = "TEAM##{team_id}#REPO##{repo_id}#FILE##{file_hash}"
  my_sk = "CONTRIB##{contributor_id}"

  now = Time.now.utc
  now_iso = now.iso8601
  presence_ttl = ENV["PRESENCE_TTL"].to_i
  stale_before = now.to_i - presence_ttl

  rows = DYNAMODB.query(
    table_name: ENV["PRESENCE_TABLE"],
    key_condition_expression: "pk = :pk",
    expression_attribute_values: { ":pk" => pk },
    consistent_read: true
  ).items

  my_row = nil
  collision = nil
  rows.each do |row|
    if row["sk"] == my_sk
      my_row = row
      next # never collide with myself
    end
    # TTL-lag double-check: ignore rows staler than PRESENCE_TTL even if TTL
    # has not yet reaped them (plan section 2.2).
    last_seen = row["last_seen_at"].to_s
    last_seen_epoch = (Time.iso8601(last_seen).to_i rescue 0)
    next if last_seen_epoch < stale_before

    collision ||= row
  end

  # detected_at: reuse my own existing claim's value (read-before-write) so a
  # continuing claim keeps its first-seen time; otherwise stamp now.
  detected_at = my_row && my_row["detected_at"] ? my_row["detected_at"] : now_iso

  DYNAMODB.put_item(
    table_name: ENV["PRESENCE_TABLE"],
    item: {
      "pk" => pk,
      "sk" => my_sk,
      "contributor_id" => contributor_id,
      "contributor_name" => contributor_name,
      "repo_id" => repo_id,
      "file_path" => file_path,
      "detected_at" => detected_at,
      "last_seen_at" => now_iso,
      "expires_at" => now.to_i + presence_ttl
    }
  )

  if collision
    json_response(200, status: "collision",
                       other_name: collision["contributor_name"],
                       detected_at: collision["detected_at"])
  else
    json_response(200, status: "clear")
  end
rescue AuthError => e
  puts "AUTH: #{e.message}"
  json_response(401, status: "unauthorized")
rescue StandardError => e
  puts "ERROR: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}"
  json_response(500, status: "error")
end
