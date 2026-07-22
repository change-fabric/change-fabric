# Capability A - transcript_ingest (plan section 6.1). Ingests a session
# transcript + metadata: inlines small bodies, offloads large ones to S3 (SSE-KMS),
# writes the cf-telemetry item with scan_status="pending" to enroll it in the
# secret-scan queue. Fire-and-forget: any exception logs and returns 500, never raises.

require "json"
require "base64"
require "digest"
require "time"
require "aws-sdk-dynamodb"
require "aws-sdk-s3"

# Instantiated once at load time for warm-start reuse (plan section 6).
DYNAMODB = Aws::DynamoDB::Client.new
S3 = Aws::S3::Client.new

NINETY_DAYS_SECONDS = 90 * 86_400

# Decode an API Gateway v2 HTTP API proxy body, honoring isBase64Encoded.
def decode_proxy_body(event)
  body = event["body"] || ""
  body = Base64.decode64(body) if event["isBase64Encoded"]
  body
end

def handler(event:, context:)
  payload = JSON.parse(decode_proxy_body(event))
  meta = payload["meta"] || {}
  transcript_bytes = Base64.decode64(payload["transcript_b64"] || "")

  inline_max = Integer(ENV["INLINE_MAX"] || 350_000)
  emitted_at = meta["emitted_at"]
  session_id = meta["session_id"]

  item = {
    "pk" => "SESSION##{session_id}",
    "sk" => "EVENT##{emitted_at}",
    "session_id" => session_id,
    "event_type" => meta["event_type"],
    "emitted_at" => emitted_at,
    "cwd" => meta["cwd"],
    "git_repo" => meta["git_repo"],
    "git_branch" => meta["git_branch"],
    "git_head_sha" => meta["git_head_sha"],
    "git_dirty" => meta["git_dirty"],
    "merge_mode" => meta["merge_mode"],
    "change_gate" => meta["change_gate"],
    "cf_skills_active" => meta["cf_skills_active"],
    "host" => meta["host"],
    "scan_status" => "pending",
    "schema_version" => 2,
    "expires_at" => epoch_of(emitted_at) + NINETY_DAYS_SECONDS
  }

  # Identity fields (Capability C retrofit): write only when present in meta.
  # Do not write empty strings - omit the attribute entirely if absent, so an
  # unattributable transcript stays truly unattributed (plan section 3, 6.4).
  %w[team_id contributor_id contributor_name].each do |key|
    value = meta[key]
    item[key] = value if value && !value.to_s.empty?
  end

  # scan_status is always written "pending" here; the routing-vs-notify
  # distinction (whether a finding becomes a notification) happens in
  # secret_scanner, not here (plan section 6.4). Scanning + CloudWatch logging
  # is still valuable even for an unattributed transcript.

  if transcript_bytes.bytesize <= inline_max
    item["transcript_location"] = "inline"
    item["transcript_raw"] = transcript_bytes
  else
    key = "#{session_id}/#{emitted_at}.jsonl"
    S3.put_object(
      bucket: ENV["BUCKET_NAME"],
      key: key,
      body: transcript_bytes,
      server_side_encryption: "aws:kms"
    )
    item["transcript_location"] = "s3"
    item["transcript_s3_key"] = key
    item["transcript_bytes"] = transcript_bytes.bytesize
    item["transcript_sha256"] = Digest::SHA256.hexdigest(transcript_bytes)
  end

  DYNAMODB.put_item(table_name: ENV["TABLE_NAME"], item: item)

  {
    statusCode: 201,
    headers: { "Content-Type" => "application/json" },
    body: JSON.generate(ok: true, pk: item["pk"], sk: item["sk"])
  }
rescue StandardError => e
  puts "ERROR: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}"
  {
    statusCode: 500,
    headers: { "Content-Type" => "application/json" },
    body: JSON.generate(ok: false)
  }
end

# emitted_at is ISO8601; convert to epoch seconds for the TTL anchor.
def epoch_of(iso8601)
  Time.iso8601(iso8601).to_i
rescue StandardError
  Time.now.utc.to_i
end
