# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/change_screenshot_upload"

# The GitHub user-attachments upload, and its one job beyond uploading: failing
# without taking the run down with it. The captures are useful whether or not
# they ever get an inline url, so every failure path here degrades to reporting
# local paths rather than raising.
#
# Nothing here talks to GitHub. The Net::HTTP collaborator is injected and the
# `gh` shell-outs are stubbed, so what is covered is the request this class
# builds and what it does with each answer.
class ChangeScreenshotUploadTest < Minitest::Test
  # Stands in for Net::HTTP. Records the request it was handed so the url, the
  # headers, and the body can be asserted, and answers with a canned response.
  class FakeHttp
    Response = Struct.new(:code, :body)

    attr_reader :requests, :hosts

    def initialize(code:, body: "")
      @code = code
      @body = body
      @requests = []
      @hosts = []
    end

    def start(host, port, use_ssl:)
      @hosts << [ host, port, use_ssl ]
      yield self
    end

    def request(req)
      @requests << req
      Response.new(@code, @body)
    end
  end

  # Records every `gh` invocation so a test can assert what was asked for and,
  # crucially, that nothing ever logs the token.
  class StubbedUploader < ChangeScreenshotUpload
    attr_reader :shellouts

    def initialize(token: "ghp_secret_value", repo_id: "123456789", **kwargs)
      super(**kwargs)
      @token = token
      @repo_id = repo_id
      @shellouts = []
    end

    def capture(*argv)
      @shellouts << argv
      return [ @token.to_s, !@token.nil? ] if argv[1] == "auth"
      return [ @repo_id.to_s, !@repo_id.nil? ] if argv[1] == "api"

      [ "", false ]
    end
  end

  def png
    @png ||= begin
      dir = Dir.mktmpdir
      path = File.join(dir, "desktop--spec.png")
      File.binwrite(path, "\x89PNG binary".b)
      path
    end
  end

  def uploader(code: "201", body: nil, **kwargs)
    body ||= JSON.generate("url" => "https://github.com/user-attachments/assets/abc-123")
    http = FakeHttp.new(code: code, body: body)
    [ StubbedUploader.new(http: http, **kwargs), http ]
  end

  # --- the request ----------------------------------------------------------------

  def test_the_request_url_carries_name_content_type_and_repository_id
    subject, http = uploader
    subject.upload(png)
    query = URI.decode_www_form(URI(http.requests.first.uri.to_s).query).to_h

    assert_equal "https://uploads.github.com/user-attachments/assets", http.requests.first.uri.to_s.split("?").first
    assert_equal "desktop--spec.png", query["name"]
    assert_equal "image/png", query["content_type"]
    assert_equal "123456789", query["repository_id"]
  end

  def test_the_authorization_header_is_a_bearer_token_and_the_body_is_the_raw_file
    subject, http = uploader
    subject.upload(png)
    request = http.requests.first

    assert_equal "Bearer ghp_secret_value", request["Authorization"]
    assert_equal "image/png", request["Content-Type"]
    assert_equal File.binread(png), request.body
    assert_equal [ [ "uploads.github.com", 443, true ] ], http.hosts
  end

  # The repository id the endpoint wants is the numeric database id, not the
  # GraphQL node id `gh repo view --json id` returns.
  def test_the_repository_id_comes_from_the_numeric_database_id_not_the_node_id
    subject, = uploader
    subject.upload(png)
    api_call = subject.shellouts.find { |argv| argv[1] == "api" }

    assert_includes api_call, "--jq"
    assert_includes api_call, ".id"
    assert(api_call.any? { |arg| arg.to_s.start_with?("repos/") }, "must ask the repos REST endpoint")
    refute(subject.shellouts.any? { |argv| argv.include?("repo") && argv.include?("view") },
           "`gh repo view --json id` returns the node id the endpoint rejects")
  end

  def test_the_token_never_reaches_a_result_a_message_or_the_curl_equivalent
    subject, = uploader(code: "422", body: "nope")
    result = subject.upload(png)

    refute_includes result.error.to_s, "ghp_secret_value"
    refute_includes result.to_s, "ghp_secret_value"
    refute_includes subject.degradation_reason.to_s, "ghp_secret_value"
    refute_includes ChangeScreenshotUpload.curl_equivalent(png, "123456789"), "ghp_secret_value"
    assert_includes ChangeScreenshotUpload.curl_equivalent(png, "123456789"), "$(gh auth token)"
  end

  # --- the answers ------------------------------------------------------------------

  def test_a_201_yields_the_attachment_url
    subject, = uploader
    result = subject.upload(png)

    assert result.uploaded?
    assert_equal "https://github.com/user-attachments/assets/abc-123", result.url
    refute subject.degraded?
  end

  def test_a_4xx_degrades_to_the_local_path_without_raising
    subject, = uploader(code: "404", body: "Not Found")
    result = subject.upload(png)

    refute result.uploaded?
    assert_equal png, result.path
    assert_includes result.error, "404"
    assert subject.degraded?
  end

  def test_a_missing_gh_auth_token_degrades_to_the_local_path_without_raising
    subject, http = uploader(token: nil)
    result = subject.upload(png)

    refute result.uploaded?
    assert_equal png, result.path
    assert_includes result.error, "gh auth token"
    assert_empty http.requests, "nothing may be posted without a token"
  end

  def test_an_unresolvable_repository_id_degrades_rather_than_posting
    subject, http = uploader(repo_id: nil)
    result = subject.upload(png)

    refute result.uploaded?
    assert_includes result.error, "repository id"
    assert_empty http.requests
  end

  def test_a_network_error_degrades_rather_than_raising
    subject, = uploader
    def subject.post_file(*) = raise(Errno::ECONNREFUSED)
    result = subject.upload(png)

    refute result.uploaded?
    assert_includes result.error, "upload failed"
  end

  # A 201 with no url is a contract change in an undocumented endpoint, which
  # is precisely what this class is built to survive.
  def test_a_201_with_no_url_degrades_rather_than_reporting_a_success
    subject, = uploader(body: "{}")
    result = subject.upload(png)

    refute result.uploaded?
    assert_includes result.error, "no attachment url"
  end

  # Once something has failed, the rest stay local carrying the same reason, so
  # the caller reports one degradation rather than one per file.
  def test_the_first_failure_stops_the_rest_from_being_attempted
    subject, http = uploader(code: "500", body: "boom")
    results = subject.upload_all([ png, png, png ])

    assert_equal 3, results.size
    assert(results.none?(&:uploaded?))
    assert_equal 1, http.requests.size, "only the first file may be attempted"
    assert_equal [ results.first.error ], results.map(&:error).uniq
  end
end
