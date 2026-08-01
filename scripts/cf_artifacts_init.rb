#!/usr/bin/env ruby
# frozen_string_literal: true

# cf-artifacts-init: human-run, once per contributors team, to provision the
# shared area cf:change publishes its findings artifacts to.
#
# It creates, in the team's own AWS account:
#
#   1. a private S3 bucket (public access blocked, encrypted at rest, object
#      ownership enforced) holding every contributor's run bundles,
#   2. a CloudFront distribution reaching it through an Origin Access Control,
#      so the bucket itself never becomes public and the only way in is the
#      distribution,
#   3. a CloudFront viewer-request Function enforcing HTTP Basic Auth, compiled
#      from reference/artifact-basic-auth.function.js with the SHA-256 digest of
#      the credential this script reads from SSM Parameter Store, and
#   4. a small DynamoDB table backing the team index page's run listing.
#
# It then prints the paste-ready `artifacts:` block for CHANGE.md and the
# commands the human runs themselves. It never writes the credential anywhere:
# the SSM SecureString is the source of truth, and the `aws ssm put-parameter`
# and 1Password commands are printed for review, exactly as cf_team_init.rb
# prints the team signing key's `op item create`.
#
# Unlike the hooks, this is NOT fail-open. It is a one-time provisioning tool:
# a missing gem, missing credentials, or a failed API call raises a real
# exception and exits nonzero, because half-provisioned infrastructure that
# reports success is worse than a stack trace.
#
# Usage:
#   ruby cf_artifacts_init.rb <team_id> [--region REGION] [--bucket NAME]
#   ruby cf_artifacts_init.rb <team_id> --rotate   # re-read SSM, republish the function

require 'aws-sdk-s3'
require 'aws-sdk-cloudfront'
require 'aws-sdk-dynamodb'
require 'aws-sdk-ssm'
require 'base64'
require 'digest'
require 'json'
require 'optparse'
require 'securerandom'
require 'time'
require_relative 'change_artifact_templates'

module CfArtifactsInit
  DEFAULT_REGION = 'us-east-1'
  DEFAULT_PROFILE = 'personal'
  MANIFEST_TABLE = 'cf-change-artifacts'
  BASIC_AUTH_USERNAME = 'cf'
  # AWS managed CachingOptimized policy: long TTLs plus compression, which is
  # what a bundle of immutable, stamp-prefixed assets wants.
  CACHE_POLICY_CACHING_OPTIMIZED = '658327ea-f89d-4fab-a63d-7e88639e58f6'
  FUNCTION_TEMPLATE = 'artifact-basic-auth.function.js'
  OP_WRAPPER = File.expand_path('~/code/pst/pstaylor-patrick/secrets/bin/op')

  Options = Struct.new(:team_id, :region, :bucket, :rotate, keyword_init: true)

  module_function

  def run(argv)
    options = parse(argv)
    ssm_name = parameter_name(options.team_id)
    credential = read_credential(options, ssm_name)
    return print_credential_setup(options, ssm_name) unless credential

    digest = Digest::SHA256.hexdigest(authorization_header(credential))
    return rotate(options, digest, ssm_name) if options.rotate

    provision(options, digest, ssm_name)
  end

  def parse(argv)
    options = Options.new(region: DEFAULT_REGION, rotate: false)
    parser = OptionParser.new do |o|
      o.banner = 'usage: cf_artifacts_init.rb <team_id> [--region REGION] [--bucket NAME] [--rotate]'
      o.on('--region REGION') { |value| options.region = value }
      o.on('--bucket NAME') { |value| options.bucket = value }
      o.on('--rotate') { options.rotate = true }
    end
    rest = parser.parse(argv)
    options.team_id = rest.first
    abort(parser.banner) if options.team_id.to_s.empty?

    options.bucket ||= "cf-change-artifacts-#{options.team_id}"
    options
  end

  def profile = ENV.fetch('AWS_PROFILE', DEFAULT_PROFILE)
  def client_options(options) = { region: options.region, profile: profile }
  def parameter_name(team_id) = "/cf-change-artifacts/#{team_id}/basic-auth"

  # The credential as `username:password`, read from the SSM SecureString that
  # owns it, or nil when the parameter does not exist yet (the first run, before
  # the human has created it).
  def read_credential(options, name)
    ssm = Aws::SSM::Client.new(**client_options(options))
    ssm.get_parameter(name: name, with_decryption: true).parameter.value.strip
  rescue Aws::SSM::Errors::ParameterNotFound
    nil
  end

  def authorization_header(credential) = "Basic #{Base64.strict_encode64(credential)}"

  # First run: mint a high-entropy credential, print the two commands that store
  # it (SSM, which the function's digest is derived from, and 1Password, which is
  # how a teammate actually gets it), and stop. Nothing is provisioned until the
  # credential exists, so the distribution is never briefly reachable without a
  # working auth check.
  def print_credential_setup(options, ssm_name)
    password = SecureRandom.urlsafe_base64(24)
    credential = "#{BASIC_AUTH_USERNAME}:#{password}"
    puts "No credential found at #{ssm_name}. Nothing has been provisioned."
    puts
    puts 'Store this generated credential first (review, then run yourself):'
    puts
    puts "  aws ssm put-parameter --profile #{profile} --region #{options.region} \\"
    puts "    --name '#{ssm_name}' --type SecureString --value '#{credential}' --overwrite"
    puts
    puts "  #{OP_WRAPPER} item create \\"
    puts '    --category=login \\'
    puts '    --vault=<shared-vault> \\'
    puts "    --title='change-fabric artifacts: #{options.team_id}' \\"
    puts "    'username=#{BASIC_AUTH_USERNAME}' \\"
    puts "    'password=#{password}'"
    puts
    puts "Then re-run: ruby cf_artifacts_init.rb #{options.team_id} --region #{options.region}"
  end

  # --- provisioning ----------------------------------------------------------------

  def provision(options, digest, ssm_name)
    create_bucket(options)
    create_manifest_table(options)
    function_arn = publish_function(options, digest)
    oac_id = create_oac(options)
    distribution = create_distribution(options, function_arn, oac_id)
    attach_bucket_policy(options, distribution[:arn])
    print_change_md_block(options, distribution, ssm_name)
  end

  # Private by every available means: public access blocked at the bucket, ACLs
  # disabled outright (ownership enforced, so no object can be made public by
  # its writer either), and SSE-S3 on by default. The only reader is the
  # CloudFront distribution, through the OAC-scoped bucket policy below.
  def create_bucket(options)
    s3 = Aws::S3::Client.new(**client_options(options))
    create_params = { bucket: options.bucket }
    unless options.region == 'us-east-1'
      create_params[:create_bucket_configuration] = { location_constraint: options.region }
    end
    s3.create_bucket(**create_params)
    s3.put_public_access_block(
      bucket: options.bucket,
      public_access_block_configuration: {
        block_public_acls: true, ignore_public_acls: true,
        block_public_policy: true, restrict_public_buckets: true
      }
    )
    s3.put_bucket_ownership_controls(
      bucket: options.bucket, ownership_controls: { rules: [ { object_ownership: 'BucketOwnerEnforced' } ] }
    )
    s3.put_bucket_encryption(
      bucket: options.bucket,
      server_side_encryption_configuration: {
        rules: [ { apply_server_side_encryption_by_default: { sse_algorithm: 'AES256' }, bucket_key_enabled: true } ]
      }
    )
    puts "Created private bucket #{options.bucket} in #{options.region}."
  end

  # The listing behind the team index page. On-demand billing: a team publishes
  # a handful of runs a day, and a provisioned-capacity table for that traffic
  # is a standing cost for nothing.
  def create_manifest_table(options)
    ddb = Aws::DynamoDB::Client.new(**client_options(options))
    ddb.create_table(
      table_name: MANIFEST_TABLE,
      billing_mode: 'PAY_PER_REQUEST',
      attribute_definitions: [
        { attribute_name: 'pk', attribute_type: 'S' }, { attribute_name: 'sk', attribute_type: 'S' }
      ],
      key_schema: [
        { attribute_name: 'pk', key_type: 'HASH' }, { attribute_name: 'sk', key_type: 'RANGE' }
      ]
    )
    puts "Created DynamoDB table #{MANIFEST_TABLE}."
  rescue Aws::DynamoDB::Errors::ResourceInUseException
    puts "DynamoDB table #{MANIFEST_TABLE} already exists; reusing it."
  end

  def function_name(team_id) = "cf-change-artifacts-auth-#{team_id}"

  def function_code(team_id, digest)
    File.read(ChangeArtifactTemplates.path(FUNCTION_TEMPLATE))
        .gsub('__CREDENTIAL_SHA256__', digest)
        .gsub('__REALM__', "change-fabric artifacts #{team_id}")
  end

  def publish_function(options, digest)
    cf = Aws::CloudFront::Client.new(**client_options(options))
    name = function_name(options.team_id)
    created = cf.create_function(
      name: name,
      function_config: { comment: "HTTP Basic Auth for #{options.team_id} change-fabric artifacts", runtime: 'cloudfront-js-2.0' },
      function_code: function_code(options.team_id, digest)
    )
    published = cf.publish_function(name: name, if_match: created.etag)
    puts "Published CloudFront function #{name}."
    published.function_summary.function_metadata.function_arn
  end

  def create_oac(options)
    cf = Aws::CloudFront::Client.new(**client_options(options))
    response = cf.create_origin_access_control(
      origin_access_control_config: {
        name: "cf-change-artifacts-#{options.team_id}",
        description: "OAC for the #{options.team_id} change-fabric artifact bucket",
        signing_protocol: 'sigv4', signing_behavior: 'always', origin_access_control_origin_type: 's3'
      }
    )
    response.origin_access_control.id
  end

  def create_distribution(options, function_arn, oac_id)
    cf = Aws::CloudFront::Client.new(**client_options(options))
    origin_id = "s3-#{options.bucket}"
    response = cf.create_distribution(
      distribution_config: {
        caller_reference: "cf-change-artifacts-#{options.team_id}-#{Time.now.utc.to_i}",
        comment: "change-fabric artifacts: #{options.team_id}",
        enabled: true, default_root_object: 'index.html', price_class: 'PriceClass_100',
        origins: {
          quantity: 1,
          items: [ {
            id: origin_id,
            domain_name: "#{options.bucket}.s3.#{options.region}.amazonaws.com",
            origin_access_control_id: oac_id,
            s3_origin_config: { origin_access_identity: '' }
          } ]
        },
        default_cache_behavior: {
          target_origin_id: origin_id, viewer_protocol_policy: 'redirect-to-https', compress: true,
          allowed_methods: {
            quantity: 2, items: %w[GET HEAD], cached_methods: { quantity: 2, items: %w[GET HEAD] }
          },
          cache_policy_id: CACHE_POLICY_CACHING_OPTIMIZED,
          function_associations: {
            quantity: 1, items: [ { function_arn: function_arn, event_type: 'viewer-request' } ]
          }
        },
        viewer_certificate: { cloud_front_default_certificate: true }
      }
    )
    distribution = response.distribution
    puts "Created CloudFront distribution #{distribution.id} (#{distribution.domain_name})."
    { id: distribution.id, domain: distribution.domain_name, arn: distribution.arn }
  end

  # The only statement on the bucket: this one distribution may GET objects.
  # Scoped by SourceArn, so another account's distribution pointed at this
  # bucket's origin cannot read it either.
  def attach_bucket_policy(options, distribution_arn)
    policy = {
      'Version' => '2012-10-17',
      'Statement' => [ {
        'Sid' => 'AllowCloudFrontServicePrincipalReadOnly',
        'Effect' => 'Allow',
        'Principal' => { 'Service' => 'cloudfront.amazonaws.com' },
        'Action' => 's3:GetObject',
        'Resource' => "arn:aws:s3:::#{options.bucket}/*",
        'Condition' => { 'StringEquals' => { 'AWS:SourceArn' => distribution_arn } }
      } ]
    }
    Aws::S3::Client.new(**client_options(options)).put_bucket_policy(bucket: options.bucket, policy: JSON.generate(policy))
    puts 'Attached the OAC-scoped bucket policy.'
  end

  # --- rotation ----------------------------------------------------------------------

  # Rotating the viewer credential is a two-step the human owns: write the new
  # value to the SSM parameter, then run this, which re-reads the parameter and
  # republishes the function with the new digest. Nothing else changes: same
  # bucket, same distribution, same published runs.
  def rotate(options, digest, ssm_name)
    cf = Aws::CloudFront::Client.new(**client_options(options))
    name = function_name(options.team_id)
    described = cf.describe_function(name: name)
    updated = cf.update_function(
      name: name, if_match: described.etag,
      function_config: { comment: "HTTP Basic Auth for #{options.team_id} change-fabric artifacts", runtime: 'cloudfront-js-2.0' },
      function_code: function_code(options.team_id, digest)
    )
    cf.publish_function(name: name, if_match: updated.etag)
    puts "Republished #{name} with the current credential from #{ssm_name}."
  end

  # --- output ------------------------------------------------------------------------

  def print_change_md_block(options, distribution, ssm_name)
    puts
    puts 'Paste this into the CHANGE.md frontmatter, under the existing contributors_team: block:'
    puts '---8<--- CHANGE.md frontmatter ---8<---'
    puts '  artifacts:'
    puts "    bucket: #{options.bucket}"
    puts "    region: #{options.region}"
    puts "    aws_profile: #{profile}"
    puts "    distribution_id: #{distribution[:id]}"
    puts "    domain: #{distribution[:domain]}"
    puts "    manifest_table: #{MANIFEST_TABLE}"
    puts '    basic_auth:'
    puts "      username: #{BASIC_AUTH_USERNAME}"
    puts "      ssm_parameter: #{ssm_name}"
    puts "      secret_ref: op://<shared-vault>/change-fabric artifacts: #{options.team_id}/password"
    puts '---8<--------------------------------8<---'
    puts
    puts 'The distribution takes a few minutes to deploy. Once it has:'
    puts "  https://#{distribution[:domain]}/  (the team index; basic auth, credential in 1Password)"
    puts
    puts 'Nothing above is a secret. The viewer credential lives only in the SSM SecureString and'
    puts '1Password; the function carries its SHA-256 digest, and no repo carries either.'
  end
end

CfArtifactsInit.run(ARGV) if __FILE__ == $PROGRAM_NAME
