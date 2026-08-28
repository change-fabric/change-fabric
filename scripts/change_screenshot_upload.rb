#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'open3'
require 'uri'

# Uploads a captured screenshot to GitHub and returns the url that renders it
# inline in a pull request body.
#
# This is the toolkit's one raw HTTPS call to GitHub; every other GitHub
# interaction goes through a `gh` subcommand. That is forced, not a preference:
# `POST https://uploads.github.com/user-attachments/assets` is the endpoint the
# web UI itself uses when an image is pasted into a comment, and it has no `gh`
# subcommand and no Octokit support. The token still comes from `gh auth token`,
# so no new credential is introduced, and the token is never logged, never
# echoed into an error message, and never written to the manifest.
#
# The endpoint is undocumented. GitHub has acknowledged the gap without shipping
# docs, so it can break silently, and there is no delete API, so an attachment
# uploaded by a run that then failed is an orphan that 404s publicly until
# something references it. Both are accepted risks, recorded here and in
# skills/screenshot/SKILL.md rather than designed around.
#
# Every failure degrades rather than raises. A non-201, a missing or
# unauthenticated `gh`, a network error: report the local file paths and stop
# uploading. The screenshots were captured and are useful without the inline
# embed, and a second upload mechanism for a fallback nobody has built would
# only add a way to be wrong quietly. Nothing here retries against anything
# else.
class ChangeScreenshotUpload
  ENDPOINT = 'https://uploads.github.com/user-attachments/assets'
  MIME_TYPES = { '.png' => 'image/png', '.jpg' => 'image/jpeg', '.jpeg' => 'image/jpeg' }.freeze
  DEFAULT_MIME = 'application/octet-stream'

  # One upload attempt's outcome. `url` is set only on a real 201; otherwise
  # `path` is what the caller reports instead, and `error` says why.
  Result = Struct.new(:path, :url, :error, keyword_init: true) do
    def uploaded? = !url.to_s.empty?
  end

  # `repo` is "<owner>/<name>". Both the numeric repository id and the token are
  # resolved lazily and remembered, so a run uploading twenty images shells out
  # to `gh` twice, not forty times.
  def initialize(repo: nil, http: Net::HTTP)
    @repo = repo
    @http = http
    @degraded = nil
  end

  # True once something has failed. The caller stops offering an inline Demo
  # section at that point rather than posting a half-uploaded one.
  def degraded? = !@degraded.nil?
  def degradation_reason = @degraded

  # Uploads one file. Returns a Result carrying either the attachment url or
  # the local path and the reason it stayed local. Never raises.
  def upload(path)
    return Result.new(path: path, error: @degraded) if degraded?

    credentials = resolve_credentials
    return Result.new(path: path, error: @degraded) unless credentials

    post_file(path, credentials)
  rescue StandardError => e
    degrade("upload failed: #{e.class}: #{e.message}")
    Result.new(path: path, error: @degraded)
  end

  # Uploads a list of files in order, stopping at the first failure. The
  # remaining files come back as local-path Results carrying the same reason,
  # so the caller reports one degradation rather than one per file.
  def upload_all(paths)
    paths.map { |path| upload(path) }
  end

  # The request this class makes, as a shell command a human can paste to
  # reproduce a failure by hand. Kept next to the code that makes it so the two
  # cannot drift; `$(gh auth token)` stays a substitution rather than a value,
  # so copying this line never copies a credential.
  def self.curl_equivalent(path, repo_id)
    "curl -sS -w '\\n%{http_code}\\n' -X POST " \
      "-H \"Authorization: Bearer $(gh auth token)\" " \
      "-H \"Content-Type: #{mime_for(path)}\" " \
      "--data-binary @\"#{path}\" " \
      "\"#{ENDPOINT}?name=#{File.basename(path)}" \
      "&content_type=#{URI.encode_www_form_component(mime_for(path))}&repository_id=#{repo_id}\""
  end

  def self.mime_for(path) = MIME_TYPES.fetch(File.extname(path).downcase, DEFAULT_MIME)

  private

  def post_file(path, credentials)
    uri = request_uri(path, credentials[:repo_id])
    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "Bearer #{credentials[:token]}"
    request['Content-Type'] = self.class.mime_for(path)
    request.body = File.binread(path)
    interpret(path, @http.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) })
  end

  def request_uri(path, repo_id)
    query = URI.encode_www_form('name' => File.basename(path),
                                'content_type' => self.class.mime_for(path),
                                'repository_id' => repo_id)
    URI("#{ENDPOINT}?#{query}")
  end

  # 201 is the only success. The response body carries the attachment url; a
  # 201 whose body does not is a contract change in an undocumented endpoint,
  # which is exactly the failure this class is built to survive.
  def interpret(path, response)
    unless response.code.to_s == '201'
      degrade("GitHub returned HTTP #{response.code} from the user-attachments endpoint")
      return Result.new(path: path, error: @degraded)
    end

    url = parse_url(response.body)
    return Result.new(path: path, url: url) if url

    degrade('GitHub returned 201 but no attachment url')
    Result.new(path: path, error: @degraded)
  end

  def parse_url(body)
    parsed = JSON.parse(body.to_s)
    parsed.is_a?(Hash) ? parsed['url'] : nil
  rescue JSON::ParserError
    nil
  end

  def resolve_credentials
    @credentials ||= begin
      token = gh_token
      repo_id = token && numeric_repository_id
      token && repo_id ? { token: token, repo_id: repo_id } : nil
    end
  end

  # Never interpolated into a message, a log line, or the manifest.
  def gh_token
    out, ok = capture('gh', 'auth', 'token')
    return out unless out.empty? || !ok

    degrade('no GitHub token: `gh auth token` returned nothing (run `gh auth login`)')
    nil
  end

  # The numeric database id, not the GraphQL node id `gh repo view --json id`
  # returns. The attachment endpoint rejects the node id, and it does so with a
  # status that reads like an auth problem, which is why this is spelled out.
  def numeric_repository_id
    args = [ 'gh', 'api' ]
    args << "repos/#{@repo}" if @repo
    args << 'repos/{owner}/{repo}' unless @repo
    out, ok = capture(*args, '--jq', '.id')
    return out if ok && out.match?(/\A\d+\z/)

    degrade('could not resolve the numeric repository id via `gh api repos/<owner>/<repo> --jq .id`')
    nil
  end

  def capture(*argv)
    out, status = Open3.capture2e(*argv)
    [ out.to_s.strip, status.success? ]
  rescue StandardError => e
    [ e.message, false ]
  end

  def degrade(reason)
    @degraded ||= reason
  end
end
