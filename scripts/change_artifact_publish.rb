#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'json'
require 'net/http'
require 'uri'
require_relative 'change_artifacts_config'

# Publishes one run's artifact bundle to the hosted artifacts service.
#
# Three calls, in this order:
#
#   POST /v1/artifacts             declare the run and every file in it, and
#                                  receive one presigned PUT per file
#   PUT  <presigned url>           the bytes, straight to object storage
#   POST /v1/artifacts/:id/complete say the upload finished
#
# Everything this used to decide, the server decides now. It assigns the key
# prefix, it owns the index every team member reads, and it enforces who may
# open a run. That is why this file requires nothing but Ruby's standard
# library: there is no bucket to write to, no table to keep, and no edge cache
# to invalidate, so there is no AWS SDK to load and no AWS credential to hold.
# The only secret involved is the team API key, which arrives from an env var or
# this machine's Keychain, is spent on two requests, and is never written
# anywhere.
#
# Best-effort, always, and that contract is the reason this file is structured
# the way it is. Every step is rescued into a named warning and the run's verdict
# is untouched by all of them: the audit lanes are the release gate, and
# this is the evidence attached to it. A machine with no key, an API that is
# down, and a presigned URL that expired mid-upload each produce a clear sentence
# on an otherwise successful audit rather than a stack trace or a red run.
class ChangeArtifactPublish
  Result = Struct.new(:url, :uploaded, :short_id, :warnings, keyword_init: true)

  CONTENT_TYPES = {
    '.html' => 'text/html; charset=utf-8', '.json' => 'application/json',
    '.jpg' => 'image/jpeg', '.jpeg' => 'image/jpeg', '.png' => 'image/png',
    '.webm' => 'video/webm', '.pdf' => 'application/pdf',
    '.md' => 'text/markdown; charset=utf-8', '.csv' => 'text/csv; charset=utf-8'
  }.freeze
  DEFAULT_CONTENT_TYPE = 'application/octet-stream'

  # The server's own ceiling (platform/api/src/artifacts.ts). Checked here as
  # well so an oversized bundle is reported as the local fact it is, naming the
  # count, instead of arriving as a 400 whose body a reader has to decode.
  MAX_FILES = 200

  # Generous, because a video can be tens of megabytes on a slow uplink, and
  # bounded, because a publish that hangs would hold up a finished audit.
  OPEN_TIMEOUT = 15
  READ_TIMEOUT = 180

  def self.publish(bundle_dir:, artifacts:)
    new(bundle_dir: bundle_dir, artifacts: artifacts).publish
  end

  def initialize(bundle_dir:, artifacts:)
    @dir = bundle_dir
    @artifacts = artifacts
    @warnings = []
  end

  def publish
    return legacy_refusal unless @artifacts.platform?

    manifest = read_manifest
    return failure('bundle has no manifest.json; nothing to publish') unless manifest

    key = @artifacts.api_key
    return failure(missing_key_message) unless key

    files = declared_files
    return failure('the bundle is empty; nothing to publish') if files.empty?
    return failure("the bundle holds #{files.size} files, more than the #{MAX_FILES} an artifact may declare") if
      files.size > MAX_FILES

    run(manifest, files, key)
  rescue StandardError => e
    failure("publish failed: #{e.message}")
  end

  private

  # The three calls, each one gated on the previous having produced what the
  # next needs. A failure at any step stops the sequence and leaves the warnings
  # already collected in place: half a publish is worth reporting precisely
  # because it is half.
  def run(manifest, files, key)
    team = resolve_team_id(key)
    return Result.new(url: nil, uploaded: 0, short_id: nil, warnings: @warnings) unless team

    created = create(manifest, files, team, key)
    return Result.new(url: nil, uploaded: 0, short_id: nil, warnings: @warnings) unless created

    uploaded = upload(created['uploads'], files)
    complete(created['artifactId'], key)

    Result.new(url: created['viewerUrl'], uploaded: uploaded, short_id: created['shortId'], warnings: @warnings)
  end

  def failure(message)
    @warnings << message
    Result.new(url: nil, uploaded: 0, short_id: nil, warnings: @warnings)
  end

  # A repo still on the 0.5.0 `artifacts:` block reaches here. It is reported
  # rather than attempted: publishing to a team's own bucket needed the AWS SDKs
  # and an AWS credential, and this client deliberately carries neither. The
  # bundle is still built and still sits on the Desktop, which is what keeps
  # this a migration prompt instead of a lost run.
  def legacy_refusal
    failure('this repo still carries the deprecated contributors_team.artifacts block; ' \
            'the bundle was built but not published. Migrate to contributors_team.platform ' \
            '(see scripts/CF_TEAM_SETUP.md); the legacy block is removed at schema 0.7.0')
  end

  def missing_key_message
    "no team API key: set #{@artifacts.api_key_env}, or run " \
      "`ruby scripts/cf_team_join.rb --platform #{@artifacts.organization} #{@artifacts.team_slug} --stdin` " \
      'to store one in the Keychain'
  end

  def read_manifest
    path = File.join(@dir, 'manifest.json')
    File.exist?(path) ? JSON.parse(File.read(path)) : nil
  rescue StandardError => e
    @warnings << "could not read the bundle manifest: #{e.message}"
    nil
  end

  # --- what is being published -----------------------------------------------

  # Every file in the bundle, declared by relative path with its size and
  # digest. The digest is computed here rather than left out because the
  # completion check compares it against what storage actually holds, which is
  # the only thing that turns "the PUT returned 200" into "the right bytes
  # landed".
  def declared_files
    Dir.glob(File.join(@dir, '**', '*')).select { |path| File.file?(path) }.sort.map do |path|
      relative = path.delete_prefix("#{@dir}/")
      body = File.binread(path)
      {
        'path' => relative, 'contentType' => content_type(relative),
        'bytes' => body.bytesize, 'sha256' => Digest::SHA256.hexdigest(body)
      }
    end
  rescue StandardError => e
    @warnings << "could not read the bundle contents: #{e.message}"
    []
  end

  def content_type(relative) = CONTENT_TYPES.fetch(File.extname(relative).downcase, DEFAULT_CONTENT_TYPE)

  # The run, in the shape the API's manifest parser accepts. Fields the local
  # manifest could not resolve (a detached HEAD's branch, a branch with no PR)
  # are omitted rather than sent empty: the API treats absent as "not known",
  # and an empty string would be recorded as a value somebody chose.
  def payload(manifest, files, team_id)
    git = manifest['git'] || {}
    counts = manifest['counts'] || {}
    {
      'teamId' => team_id, 'repoId' => manifest['repo_id'],
      'project' => (manifest['run'] || {})['project'], 'branch' => git['branch'],
      'headSha' => git['head_sha'], 'prNumber' => git['pr_number'], 'prUrl' => git['pr_url'],
      'status' => manifest['status'], 'failCount' => counts['fail'].to_i, 'warnCount' => counts['warn'].to_i,
      'contributorLabel' => manifest['contributor_name'], 'generatedAt' => manifest['generated_at'],
      'files' => files
    }.reject { |_, value| value.nil? || value == '' }
  end

  # --- the three calls ---------------------------------------------------------

  # Which team this key speaks for. A repo may pin it, but usually does not: the
  # key is already scoped to exactly one team, so asking the API is both fewer
  # committed facts and the only answer that cannot be stale.
  def resolve_team_id(key)
    pinned = @artifacts.platform_team_id
    return pinned unless pinned.empty?

    body = get_json('/v1/whoami-key', key)
    return nil unless body

    id = body['teamId'].to_s
    return id unless id.empty?

    @warnings << 'the API did not say which team this key belongs to'
    nil
  end

  def create(manifest, files, team_id, key)
    post_json('/v1/artifacts', payload(manifest, files, team_id), key, expect: 201)
  end

  # The presigned PUTs. No credential of any kind travels on these: the URL is
  # the whole authority, and it is good for exactly one key for a few minutes.
  # Counted rather than aborted on the first failure, so a run whose video did
  # not make it still publishes its findings page.
  def upload(uploads, files)
    return 0 unless uploads.is_a?(Array)

    by_path = files.to_h { |file| [ file['path'], file ] }
    uploads.count { |upload| put(upload, by_path[upload['path'].to_s]) }
  end

  def put(upload, declared)
    return false unless declared

    uri = URI.parse(upload['url'].to_s)
    request = Net::HTTP::Put.new(uri)
    request['Content-Type'] = declared['contentType']
    request.body = File.binread(File.join(@dir, declared['path']))

    response = perform(uri, request)
    return true if response.is_a?(Net::HTTPSuccess)

    @warnings << "upload failed for #{declared['path']}: #{response.code}"
    false
  rescue StandardError => e
    @warnings << "upload failed for #{upload['path']}: #{e.message}"
    false
  end

  # Completion is what makes a run visible as finished, and its failure is worth
  # its own sentence: the bytes are already stored, so the artifact exists but
  # will read as never having finished until somebody says otherwise.
  def complete(artifact_id, key)
    return if artifact_id.to_s.empty?

    body = post_json("/v1/artifacts/#{artifact_id}/complete", {}, key, expect: 200)
    return unless body

    note = body['note']
    @warnings << "the service checked the upload and found: #{note}" unless note.to_s.empty?
  end

  # --- HTTP --------------------------------------------------------------------

  def get_json(path, key) = send_json(Net::HTTP::Get, path, nil, key, 200)
  def post_json(path, body, key, expect:) = send_json(Net::HTTP::Post, path, body, key, expect)

  def send_json(verb, path, body, key, expect)
    uri = URI.parse("#{@artifacts.api_url}#{path}")
    request = verb.new(uri)
    request['x-cf-key'] = key
    request['Accept'] = 'application/json'
    if body
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(body)
    end
    apply_basic_auth(request)

    parse(path, perform(uri, request), expect)
  rescue StandardError => e
    @warnings << "#{path} failed: #{e.message}"
    nil
  end

  # The staging-wide Basic Auth fence, when the deployment has one. It is a
  # second, coarser gate in front of the API's own authentication rather than a
  # replacement for it, so it is set alongside the key and never instead of it.
  def apply_basic_auth(request)
    credential = @artifacts.api_basic_auth
    return unless credential

    username, password = credential.split(':', 2)
    request.basic_auth(username.to_s, password.to_s)
  end

  def parse(path, response, expect)
    unless response.code.to_i == expect
      @warnings << "#{path} answered #{response.code}#{detail(response)}"
      return nil
    end

    JSON.parse(response.body.to_s)
  rescue JSON::ParserError
    @warnings << "#{path} answered #{response.code} with a body that is not JSON"
    nil
  end

  # The API's own error message when it sent one, and nothing when it did not.
  # Truncated because a warning is a line in a run's log, not a transcript.
  def detail(response)
    message = JSON.parse(response.body.to_s)['error'].to_s
    message.empty? ? '' : ": #{message[0, 200]}"
  rescue StandardError
    ''
  end

  def perform(uri, request)
    Net::HTTP.start(
      uri.hostname, uri.port,
      use_ssl: uri.scheme == 'https', open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT
    ) { |http| http.request(request) }
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
    warn '[change] this repo carries no contributors_team publishing block; nothing to publish'
    exit 1
  end

  result = ChangeArtifactPublish.publish(bundle_dir: dir, artifacts: config)
  result.warnings.each { |warning| warn("[change] artifact: #{warning}") }
  warn("[change] artifact: uploaded #{result.uploaded} file(s)")
  warn("[change] artifact: #{result.url}") if result.url
  exit(result.url ? 0 : 1)
end
