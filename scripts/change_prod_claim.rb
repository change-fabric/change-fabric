# frozen_string_literal: true

require 'json'
require 'open3'
require 'time'

# Where "this approval was consumed" lives: one item in the approval console's
# DynamoDB table, written with a conditional put so a second honest claim for the
# same request is refused. Git refs cannot hold this: anyone with repo write can
# delete a ref and replay an approval inside its TTL, whereas the claim role
# (assumed by OIDC, allowed only PutItem on CLAIM# keys) is the sole writer.
#
# The claim stops honest replays only. IAM cannot force the condition, so the
# holder of the claim role could overwrite an item; that holder is already
# trusted. Nothing later re-reads the table: the issue step only checks that this
# run attempt is the one that claimed.
#
# Item (the console's contract, #575): pk `CLAIM#<request_id>`, sk `CLAIM`, plus
# digest, run_id, run_attempt, claimed_at and expires_at (epoch seconds,
# claimed_at plus 30 days, the table's TTL attribute). `DynamoStore` shells out
# to the aws CLI with an argv array (never a shell string) using the ambient
# credentials: the generated claim job assumes `claim_role` through OIDC before
# it runs. Tests inject `runner` or use a fake store.
module ChangeProdClaim
  class Exists < StandardError; end
  class Unavailable < StandardError; end

  TABLE = /\A[A-Za-z0-9_.-]{3,255}\z/
  ROLE = %r{\Aarn:aws:iam::\d{12}:role/[A-Za-z0-9+=,.@_/-]{1,128}\z}
  REGION = /\A[a-z]{2}(-[a-z]+)+-\d\z/
  RETENTION = 30 * 24 * 3600 # seconds; the table's TTL deletes on expires_at, so the one-use record outlives any approval TTL and doubles as an audit trail

  module_function

  def settings(config)
    runner = config.dig('change_config', 'runners', 'prod') if config.is_a?(Hash)
    runner = {} unless runner.is_a?(Hash)
    table = runner['claim_table'].to_s
    role = runner['claim_role'].to_s
    region = (runner['region'] || 'us-east-1').to_s
    raise Unavailable, 'runners.prod.claim_table is missing or malformed' unless table.match?(TABLE)
    raise Unavailable, 'runners.prod.claim_role is missing or not an IAM role ARN' unless role.match?(ROLE)
    raise Unavailable, 'runners.prod.region is malformed' unless region.match?(REGION)

    { table: table, role: role, region: region }
  end

  def item(request_id:, digest:, run_id:, attempt:, now:)
    { 'pk' => { 'S' => "CLAIM##{request_id}" }, 'sk' => { 'S' => 'CLAIM' }, 'digest' => { 'S' => digest }, 'run_id' => { 'S' => run_id.to_s },
      'run_attempt' => { 'S' => attempt.to_s }, 'claimed_at' => { 'S' => now.utc.iso8601 },
      'expires_at' => { 'N' => (now.to_i + RETENTION).to_s } }
  end

  class DynamoStore
    def initialize(table:, region:, runner: method(:aws))
      @table = table
      @region = region
      @runner = runner
    end

    # Raises Exists when the key is taken, Unavailable on anything else, so a
    # missing role, table or network fails closed.
    def put(item)
      out, ok = @runner.call([ 'aws', 'dynamodb', 'put-item', '--table-name', @table, '--region', @region,
                               '--item', JSON.generate(item), '--condition-expression', 'attribute_not_exists(pk)' ])
      return if ok
      raise Exists, "#{item['pk']['S']} is already claimed" if out.include?('ConditionalCheckFailedException')

      raise Unavailable, "the claim table could not be written: #{out.lines.last.to_s.strip}"
    end

    def aws(argv)
      out, status = Open3.capture2e(*argv)
      [ out, status.success? ]
    rescue SystemCallError => e
      [ e.message, false ]
    end
  end
end
