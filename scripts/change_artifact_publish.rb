#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'change_artifacts_config'
require_relative 'change_artifact_templates'
require_relative 'change_artifact_view'

# Publishes one run's artifact bundle to the team's S3 + CloudFront area, then
# rebuilds the team index page that lists every published run across every
# contributor.
#
# Best-effort, always. A failed upload is reported and never changes the run's
# verdict: the four audit lanes are the release gate, and this is the evidence
# attached to it. Every AWS call, and the SDK require itself, is rescued into a
# named warning, so a machine with no credentials, no gems, or no provisioned
# bucket gets a clear sentence instead of a stack trace on top of an otherwise
# successful audit.
#
# The uploader never reads the viewer basic-auth credential. Publishing
# authenticates to AWS with the operator's own profile; the credential in the
# `artifacts.basic_auth` block exists for the CloudFront function and for the
# humans who open the page, and nothing in this path needs it. Keeping it out of
# the publish flow entirely is why a run can publish from any machine that can
# write to the bucket without that machine ever holding the viewing secret.
class ChangeArtifactPublish
  Result = Struct.new(:url, :uploaded, :index_url, :warnings, keyword_init: true)

  CONTENT_TYPES = {
    '.html' => 'text/html; charset=utf-8', '.json' => 'application/json',
    '.jpg' => 'image/jpeg', '.jpeg' => 'image/jpeg', '.png' => 'image/png',
    '.webm' => 'video/webm', '.pdf' => 'application/pdf',
    '.md' => 'text/markdown; charset=utf-8', '.csv' => 'text/csv; charset=utf-8'
  }.freeze
  DEFAULT_CONTENT_TYPE = 'application/octet-stream'

  # A run bundle's own assets are addressed by a key prefix carrying a UTC
  # stamp and the head SHA, so they are immutable by construction and can be
  # cached forever. The index is rewritten on every publish and must not be.
  IMMUTABLE_CACHE = 'public, max-age=31536000, immutable'
  INDEX_CACHE = 'no-cache'
  INDEX_KEY = 'index.html'
  INDEX_DATA_KEY = 'runs.json'
  MAX_INDEX_ROWS = 500

  def self.publish(bundle_dir:, artifacts:)
    new(bundle_dir: bundle_dir, artifacts: artifacts).publish
  end

  def initialize(bundle_dir:, artifacts:)
    @dir = bundle_dir
    @artifacts = artifacts
    @warnings = []
  end

  def publish
    manifest = read_manifest
    return failure('bundle has no manifest.json; nothing to publish') unless manifest

    client = s3
    return Result.new(url: nil, uploaded: 0, index_url: nil, warnings: @warnings) unless client

    uploaded = upload_bundle(client, manifest)
    row = index_row(manifest)
    record(row)
    index_url = rebuild_index(client, manifest['team_id'])
    Result.new(url: run_url(manifest), uploaded: uploaded, index_url: index_url, warnings: @warnings)
  rescue StandardError => e
    failure("publish failed: #{e.message}")
  end

  private

  def failure(message)
    @warnings << message
    Result.new(url: nil, uploaded: 0, index_url: nil, warnings: @warnings)
  end

  def read_manifest
    path = File.join(@dir, 'manifest.json')
    File.exist?(path) ? JSON.parse(File.read(path)) : nil
  rescue StandardError => e
    @warnings << "could not read the bundle manifest: #{e.message}"
    nil
  end

  # --- AWS clients ----------------------------------------------------------------

  # The SDKs are required lazily and optionally. This repo's hooks and lanes
  # carry no AWS dependency, and a repo that has not adopted artifacts should
  # never need one installed; a missing gem is a named warning, exactly like a
  # missing bucket.
  def s3
    @s3 ||= begin
      require 'aws-sdk-s3'
      Aws::S3::Client.new(**aws_options)
    rescue LoadError
      @warnings << 'aws-sdk-s3 is not installed; skipping artifact upload (gem install aws-sdk-s3)'
      nil
    rescue StandardError => e
      @warnings << "could not build an S3 client: #{e.message}"
      nil
    end
  end

  def dynamodb
    @dynamodb ||= begin
      require 'aws-sdk-dynamodb'
      Aws::DynamoDB::Client.new(**aws_options)
    rescue LoadError
      @warnings << 'aws-sdk-dynamodb is not installed; the run is published but the team index cannot be rebuilt'
      nil
    rescue StandardError => e
      @warnings << "could not build a DynamoDB client: #{e.message}"
      nil
    end
  end

  def aws_options
    { region: @artifacts.region, profile: ENV.fetch('AWS_PROFILE', @artifacts.aws_profile) }
  end

  # --- upload ---------------------------------------------------------------------

  def upload_bundle(client, manifest)
    prefix = manifest['key_prefix'].to_s
    files(@dir).count do |relative|
      put(client, key: "#{prefix}/#{relative}", body: File.binread(File.join(@dir, relative)),
                  content_type: content_type(relative), cache_control: IMMUTABLE_CACHE)
    end
  end

  def put(client, key:, body:, content_type:, cache_control:)
    client.put_object(bucket: @artifacts.bucket, key: key, body: body,
                      content_type: content_type, cache_control: cache_control)
    true
  rescue StandardError => e
    @warnings << "upload failed for #{key}: #{e.message}"
    false
  end

  def files(dir)
    Dir.glob(File.join(dir, '**', '*')).select { |path| File.file?(path) }
       .map { |path| path.delete_prefix("#{dir}/") }.sort
  end

  def content_type(relative) = CONTENT_TYPES.fetch(File.extname(relative).downcase, DEFAULT_CONTENT_TYPE)

  def run_url(manifest)
    base = @artifacts.base_viewer_url
    return nil unless base

    "#{base}/#{manifest['key_prefix']}/index.html"
  end

  # --- the manifest table ------------------------------------------------------------

  # One flat row per run: everything the index table shows, and nothing that
  # would make the row a second copy of the artifact. The bundle's own
  # `manifest.json` stays the full record; this is the listing.
  def index_row(manifest)
    git = manifest['git'] || {}
    {
      'run_id' => manifest['run_id'], 'generated_at' => manifest['generated_at'],
      'contributor_id' => manifest['contributor_id'], 'contributor_name' => manifest['contributor_name'],
      'repo_id' => manifest['repo_id'], 'project' => (manifest['run'] || {})['project'],
      'branch' => git['branch'], 'pr_number' => git['pr_number'], 'pr_url' => git['pr_url'],
      'status' => manifest['status'], 'fail_count' => (manifest['counts'] || {})['fail'].to_i,
      'warn_count' => (manifest['counts'] || {})['warn'].to_i,
      'key_prefix' => manifest['key_prefix'], 'url' => run_url(manifest)
    }.compact
  end

  def record(row)
    client = dynamodb
    return unless client

    client.put_item(
      table_name: @artifacts.manifest_table,
      item: row.merge('pk' => "TEAM##{@artifacts.team_id}", 'sk' => "RUN##{row['generated_at']}##{row['run_id']}")
    )
  rescue StandardError => e
    @warnings << "could not record the run in #{@artifacts.manifest_table}: #{e.message}; " \
                 'the artifact is published but will not appear in the team index'
  end

  # --- the team index -----------------------------------------------------------------

  # The index is regenerated from the manifest table rather than by listing the
  # bucket. Listing returns keys, not runs: rebuilding a row's contributor,
  # result, and PR from S3 alone would mean fetching every run's manifest.json
  # (one request per run, paginated, with no consistent point in time), while
  # one query returns every row already sorted newest first. The table is also
  # the thing that survives a bucket lifecycle rule expiring old media: the
  # listing keeps its history even after the bytes age out.
  def rebuild_index(client, team_id)
    rows = query_rows(team_id)
    return nil unless rows

    html = ChangeArtifactIndexView.new(rows, team_id: team_id, generated_at: Time.now.utc.iso8601)
                                  .render(ChangeArtifactTemplates.index)
    put(client, key: INDEX_KEY, body: html, content_type: CONTENT_TYPES['.html'], cache_control: INDEX_CACHE)
    put(client, key: INDEX_DATA_KEY, body: JSON.generate(rows),
                content_type: CONTENT_TYPES['.json'], cache_control: INDEX_CACHE)
    invalidate([ "/#{INDEX_KEY}", "/#{INDEX_DATA_KEY}" ])
    @artifacts.base_viewer_url
  rescue StandardError => e
    @warnings << "could not rebuild the team index: #{e.message}"
    nil
  end

  def query_rows(team_id)
    client = dynamodb
    return nil unless client

    response = client.query(
      table_name: @artifacts.manifest_table,
      key_condition_expression: 'pk = :pk',
      expression_attribute_values: { ':pk' => "TEAM##{team_id}" },
      scan_index_forward: false, limit: MAX_INDEX_ROWS
    )
    response.items.map { |item| normalize(item) }
  rescue StandardError => e
    @warnings << "could not read #{@artifacts.manifest_table}: #{e.message}"
    nil
  end

  # DynamoDB hands numbers back as BigDecimal, which JSON.generate renders in a
  # form no JS number parser wants. Coerce to plain integers and strings before
  # anything is embedded in the page.
  def normalize(item)
    item.reject { |key, _| %w[pk sk].include?(key) }
        .transform_values { |value| value.is_a?(Numeric) ? value.to_i : value.to_s }
  end

  # Only the two rewritten objects are invalidated. A run's own bundle lives
  # under a stamped prefix that has never been requested before, so it is not in
  # any edge cache to begin with, and invalidating it would be a wasted (and,
  # past the free tier, billed) path.
  def invalidate(paths)
    return if @artifacts.distribution_id.empty?

    require 'aws-sdk-cloudfront'
    Aws::CloudFront::Client.new(**aws_options).create_invalidation(
      distribution_id: @artifacts.distribution_id,
      invalidation_batch: {
        paths: { quantity: paths.size, items: paths },
        caller_reference: "cf-change-#{Time.now.utc.to_i}"
      }
    )
  rescue LoadError
    @warnings << 'aws-sdk-cloudfront is not installed; the index was uploaded but the edge cache was not invalidated'
  rescue StandardError => e
    @warnings << "could not invalidate the CloudFront cache: #{e.message}"
  end
end

if __FILE__ == $PROGRAM_NAME
  dir = ARGV.first
  if dir.to_s.empty?
    warn 'usage: change_artifact_publish.rb <bundle-dir>'
    exit 1
  end

  config = ChangeArtifactsConfig.load(Dir.pwd)
  unless config
    warn '[change] this repo carries no contributors_team.artifacts block; nothing to publish'
    exit 1
  end

  result = ChangeArtifactPublish.publish(bundle_dir: dir, artifacts: config)
  result.warnings.each { |warning| warn("[change] artifact: #{warning}") }
  warn("[change] artifact: uploaded #{result.uploaded} file(s)")
  warn("[change] artifact: #{result.url}") if result.url
  warn("[change] artifact index: #{result.index_url}") if result.index_url
  exit(result.url ? 0 : 1)
end
