# Capability C - secret_scanner (plan section 6.4). ONE detection Lambda, TWO
# front ends: the DynamoDB Streams trigger (freshness, per insert) and the hourly
# EventBridge sweep (durable catch-all over the sparse gsi-unscanned index). The
# per-item work (acquire body -> scan -> write findings -> mark scanned) is factored
# into one shared method both paths call; detection is never duplicated per trigger.

require "json"
require "base64"
require "digest"
require "time"
require "aws-sdk-dynamodb"
require "aws-sdk-s3"
require "aws-sdk-ssm"
require_relative "detector"

# Instantiated once at load time for warm-start reuse (plan section 6).
DYNAMODB = Aws::DynamoDB::Client.new
S3 = Aws::S3::Client.new
SSM = Aws::SSM::Client.new

NINETY_DAYS_SECONDS = 90 * 86_400

# --- DynamoDB Streams wire-format helper ------------------------------------
# A stream NewImage arrives in the attribute-value wire shape ({"S"=>v}, {"N"=>v},
# ...), NOT the plain SDK hash. Unmarshal only the handful of types we need rather
# than pulling in a full AttributeValue library.
def unmarshal(av)
  return nil if av.nil?

  if av.key?("S") then av["S"]
  elsif av.key?("N") then (av["N"].include?(".") ? av["N"].to_f : av["N"].to_i)
  elsif av.key?("BOOL") then av["BOOL"]
  elsif av.key?("NULL") then nil
  elsif av.key?("M") then av["M"].transform_values { |v| unmarshal(v) }
  elsif av.key?("L") then av["L"].map { |v| unmarshal(v) }
  else av.values.first
  end
end

def unmarshal_image(image)
  (image || {}).transform_values { |v| unmarshal(v) }
end

# --- body acquisition -------------------------------------------------------
# inline -> read straight from the item; s3 -> fetch the pointed-at object.
def acquire_body(item)
  case item["transcript_location"]
  when "inline"
    item["transcript_raw"].to_s
  when "s3"
    S3.get_object(bucket: ENV["BUCKET_NAME"], key: item["transcript_s3_key"]).body.read
  else
    ""
  end
end

# --- write one finding ------------------------------------------------------
# Deterministic finding_id so the stream and sweep paths collide on the same key;
# conditional PutItem makes double-processing idempotent (plan section 2.4, 6.4).
def write_finding(item, finding)
  session_id = item["session_id"].to_s
  team_id = item["team_id"]
  contributor_id = item["contributor_id"]
  finding_id = Digest::SHA256.hexdigest("#{session_id}#{finding[:rule_id]}#{finding[:match_offset]}")[0, 24]

  # No contributor to notify: log and write no notification (plan section 6.4).
  if team_id.nil? || team_id.to_s.empty? || contributor_id.nil? || contributor_id.to_s.empty?
    puts "FINDING (unattributed, not notified): session=#{session_id} rule=#{finding[:rule_id]} " \
         "offset=#{finding[:match_offset]} preview=#{finding[:masked_preview]} finding_id=#{finding_id}"
    return
  end

  created_at = Time.now.utc
  created_iso = created_at.iso8601

  begin
    DYNAMODB.put_item(
      table_name: ENV["NOTIFICATIONS_TABLE"],
      item: {
        "pk" => "CONTRIB##{team_id}##{contributor_id}",
        "sk" => "FINDING##{created_iso}##{finding_id}",
        "finding_id" => finding_id, # stored for symmetry so notifications can read it directly
        "team_id" => team_id,
        "contributor_id" => contributor_id,
        "session_id" => session_id,
        "transcript_s3_key" => (item["transcript_s3_key"] || "inline"),
        "rule_id" => finding[:rule_id],
        "match_preview" => finding[:masked_preview],
        "match_location" => finding[:match_offset],
        "status" => "pending",
        "created_at" => created_iso,
        "expires_at" => created_at.to_i + NINETY_DAYS_SECONDS
      },
      condition_expression: "attribute_not_exists(pk)"
    )
  rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
    # Same finding already written by the other path - idempotent no-op.
    puts "FINDING already recorded (idempotent): finding_id=#{finding_id}"
  end
end

# --- shared per-item processing (both paths call this) ----------------------
def process_item(item)
  body = acquire_body(item)
  Detector.scan_text(body).each { |finding| write_finding(item, finding) }

  # Flip scan_status pending -> scanned, conditional on it still being pending,
  # which drops the item out of gsi-unscanned (plan section 6.4).
  begin
    DYNAMODB.update_item(
      table_name: ENV["TABLE_NAME"],
      key: { "pk" => item["pk"], "sk" => item["sk"] },
      update_expression: "SET scan_status = :scanned",
      condition_expression: "scan_status = :pending",
      expression_attribute_values: { ":scanned" => "scanned", ":pending" => "pending" }
    )
  rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
    # Already scanned by the other path - fine.
  end
end

# --- stream path ------------------------------------------------------------
def handle_stream(event)
  event["Records"].each do |record|
    next unless record["eventSource"] == "aws:dynamodb"

    new_image = record.dig("dynamodb", "NewImage")
    next if new_image.nil?

    item = unmarshal_image(new_image)
    next unless item["scan_status"] == "pending"

    process_item(item)
  end
end

# --- sweep path -------------------------------------------------------------
def read_cursor
  param = SSM.get_parameter(name: ENV["SWEEP_CURSOR_PARAM"]).parameter.value
  return nil if param.nil? || param.strip.empty?

  JSON.parse(param)
rescue Aws::SSM::Errors::ParameterNotFound
  nil
end

def write_cursor(value)
  SSM.put_parameter(
    name: ENV["SWEEP_CURSOR_PARAM"],
    value: value,
    type: "String",
    overwrite: true
  )
end

def handle_sweep(_event)
  query_args = {
    table_name: ENV["TABLE_NAME"],
    index_name: ENV["UNSCANNED_INDEX"],
    key_condition_expression: "scan_status = :pending",
    expression_attribute_values: { ":pending" => "pending" },
    limit: ENV["SWEEP_PAGE_LIMIT"].to_i
  }
  cursor = read_cursor
  query_args[:exclusive_start_key] = cursor if cursor

  response = DYNAMODB.query(query_args)
  response.items.each { |item| process_item(item) }

  # Persist the pagination watermark. Empty string when the page drained means
  # "start fresh from the oldest pending item next run" (plan section 6.4).
  next_cursor = response.last_evaluated_key ? JSON.generate(response.last_evaluated_key) : ""
  write_cursor(next_cursor)
end

# --- dispatch ---------------------------------------------------------------
def handler(event:, context:)
  if event["Records"] && event["Records"].any? { |r| r["eventSource"] == "aws:dynamodb" }
    # Stream path. NOTE ON ERROR HANDLING: we let per-record processing errors be
    # caught here (whole-handler rescue below) so a scanner bug never blocks the
    # session pipeline (plan section 10). A finding merely delayed until the hourly
    # sweep re-covers the still-"pending" item is acceptable; we deliberately do
    # NOT re-raise to trigger the event-source-mapping bisect/retry, because the
    # sweep is already the durable catch-all and swallowing keeps the stream moving.
    handle_stream(event)
  elsif event["source"] == "aws.events"
    handle_sweep(event)
  else
    puts "WARN: unrecognized event shape, ignoring: keys=#{event.keys.inspect}"
  end
  { ok: true }
rescue StandardError => e
  # Scanner errors can never block a session (plan section 10): log and return
  # normally without raising.
  puts "ERROR: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}"
  { ok: false }
end
