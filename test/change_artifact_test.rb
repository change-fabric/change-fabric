# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "socket"
require_relative "../scripts/change_artifacts_config"
require_relative "../scripts/change_artifact_manifest"
require_relative "../scripts/change_artifact_publish"
require_relative "../scripts/change_artifact_templates"
require_relative "../scripts/change_artifact_view"
require_relative "../scripts/change_findings"
require_relative "../scripts/change_media"

# Covers the findings-artifact pipeline: the two config shapes, the media sink's
# on-disk layout, the manifest a run is described by, the page template's
# rendering and escaping, and the publish client's three HTTP calls.
#
# The publish tests drive a real HTTP server on loopback rather than stubbing
# Net::HTTP. That costs a few milliseconds and buys the thing worth buying here:
# the assertions are about what the client actually put on the wire (the
# `x-cf-key` header, the JSON body's field names, the bytes of each PUT) rather
# than about how it was asked to. The best-effort contract is the other half of
# what these assert, and it is asserted one failure at a time, because "nothing
# fails the gate" is only true if it is true of each call independently.
class ChangeArtifactTest < Minitest::Test
  FakeIdentity = Struct.new(:team_id, :contributor_id, :contributor_name, :repo_id)

  class FakeTeam
    def initialize(identity) = @identity = identity
    def identity = @identity
    def repo_root = "/repo"
  end

  def identity = FakeIdentity.new("acme", "pst", "Pat Taylor", "github.com/acme/web")

  # The 0.6.0 shape: an organization, a team, and a platform block.
  def artifacts(platform = {}, extra = {})
    block = {
      "team_id" => "acme", "organization" => "acme", "team" => "web",
      "contributors" => [ { "id" => "pst", "name" => "Pat Taylor" } ],
      "platform" => platform
    }.merge(extra)
    ChangeArtifactsConfig.new(block, team: FakeTeam.new(identity))
  end

  # The deprecated 0.5.0 shape, kept working as a dual read.
  def legacy(raw = {}, extra = {})
    block = {
      "team_id" => "acme", "contributors" => [ { "id" => "pst", "name" => "Pat Taylor" } ],
      "artifacts" => { "bucket" => "cf-change-artifacts-acme" }.merge(raw)
    }.merge(extra)
    ChangeArtifactsConfig.new(block, team: FakeTeam.new(identity))
  end

  # --- config: the platform shape (0.6.0) ----------------------------------------

  def test_the_platform_block_is_the_primary_shape
    config = artifacts
    assert config.platform?
    assert config.configured?
    assert_equal "acme", config.organization
    assert_equal "web", config.team_slug
  end

  def test_platform_defaults_fill_in_the_api_url_and_the_key_var
    config = artifacts
    assert_equal ChangeArtifactsConfig::DEFAULT_API_URL, config.api_url
    assert_equal "CF_TEAM_API_KEY", config.api_key_env
    assert_empty config.platform_team_id
  end

  def test_the_api_url_is_a_field_not_a_constant_and_never_keeps_a_trailing_slash
    config = artifacts("api_url" => "https://api.example.test/")
    assert_equal "https://api.example.test", config.api_url
  end

  def test_the_api_key_comes_from_the_named_env_var
    config = artifacts("api_key_env" => "CF_TEST_TEAM_KEY")
    with_env("CF_TEST_TEAM_KEY" => "  key-from-the-environment  ") do
      assert_equal "key-from-the-environment", config.api_key
    end
  end

  # No env var and (on a machine with no matching Keychain entry) no stored key
  # is a nil, never a raise: the publisher turns it into a named warning that
  # says how to fix it.
  def test_an_unresolvable_api_key_is_nil_not_an_error
    config = artifacts("api_key_env" => "CF_TEST_ABSENT_KEY_#{Process.pid}")
    assert_nil config.api_key
  end

  # The staging fence is named by env var, exactly like lanes.<lane>.basic_auth,
  # so no credential is ever in the committed file.
  def test_the_api_basic_auth_fence_is_named_never_valued
    config = artifacts(
      "basic_auth" => { "username_env" => "CF_TEST_BA_USER", "password_env" => "CF_TEST_BA_PASS" }
    )
    assert_nil config.api_basic_auth
    with_env("CF_TEST_BA_USER" => "cf", "CF_TEST_BA_PASS" => "shh") do
      assert_equal "cf:shh", config.api_basic_auth
    end
  end

  # The service mints the viewer URL when it accepts the run, so there is
  # nothing for the client to compute and nothing it may assert.
  def test_the_platform_shape_has_no_client_side_viewer_url
    assert_nil artifacts("api_url" => "https://api.example.test").base_viewer_url
  end

  def test_platform_enabled_false_is_the_committed_opt_out
    refute artifacts("enabled" => false).configured?
  end

  def test_an_organization_without_a_team_is_not_configured
    config = ChangeArtifactsConfig.new(
      { "organization" => "acme", "platform" => {} }, team: FakeTeam.new(identity)
    )
    refute config.configured?
  end

  # --- config: the deprecated legacy shape (0.5.0) --------------------------------

  def test_the_legacy_block_still_resolves_a_configuration
    config = legacy
    refute config.platform?
    assert config.configured?
    assert_equal "cf-change-artifacts-acme", config.bucket
    assert_equal "us-east-1", config.region
    assert_equal "personal", config.aws_profile
    assert_equal "cf-change-artifacts", config.manifest_table
  end

  def test_the_legacy_viewer_url_still_comes_from_the_teams_own_domain
    assert_equal "https://d1.cloudfront.net", legacy("domain" => "d1.cloudfront.net").base_viewer_url
    assert_nil legacy.base_viewer_url
  end

  def test_legacy_enabled_false_is_still_the_opt_out
    refute legacy("enabled" => false).configured?
  end

  # Both blocks present is a half-finished migration, not a merge: the two name
  # different destinations, and taking half of each would publish half a run to
  # each of them.
  def test_the_platform_block_wins_when_both_are_present
    config = artifacts({}, "artifacts" => { "bucket" => "cf-change-artifacts-acme",
                                            "domain" => "d1.cloudfront.net" })
    assert config.platform?
    assert_nil config.base_viewer_url
  end

  # --- config: shared -------------------------------------------------------------

  def test_media_toggles_read_from_whichever_block_is_primary
    config = artifacts("media" => { "video" => false, "video_fps" => 12 })
    assert config.screenshots?
    refute config.video?
    assert_equal 12, config.video_fps

    assert legacy.video?
    assert_equal 3, legacy("media" => { "video_fps" => 3 }).video_fps
  end

  def test_roster_comes_from_the_committed_contributors_list
    assert_equal [ { "id" => "pst", "name" => "Pat Taylor" } ], artifacts.roster
  end

  def test_load_outside_a_repo_is_nil_not_an_error
    Dir.mktmpdir { |dir| assert_nil ChangeArtifactsConfig.load(dir) }
  end

  # This repo registers a contributors team and no publishing destination, which
  # is the exact shape the opt-out has to keep working for: a team repo that
  # publishes nothing and is not asked to.
  def test_a_team_repo_without_a_publishing_block_is_not_configured
    assert_nil ChangeArtifactsConfig.load(File.expand_path("..", __dir__))
  end

  # --- media sink ----------------------------------------------------------------

  def test_media_writes_screenshots_and_videos_under_the_bundle
    Dir.mktmpdir do |dir|
      media = ChangeMedia.new(dir)
      media.add_screenshot(viewport: "mobile", route: "/sign-in", data: Base64.strict_encode64("jpeg"))
      media.add_video(viewport: "mobile", data: Base64.strict_encode64("webm"))

      assert_equal [ "screenshots/mobile--sign-in.jpg" ], media.screenshots.map(&:path)
      assert_equal "video/mobile.webm", media.video_for("mobile").path
      assert_equal "webm", File.binread(File.join(dir, "video/mobile.webm"))
      assert_equal [ "screenshots/mobile--sign-in.jpg", "video/mobile.webm" ], media.files
    end
  end

  def test_site_root_route_gets_a_named_file_not_an_empty_segment
    Dir.mktmpdir do |dir|
      media = ChangeMedia.new(dir)
      media.add_screenshot(viewport: "desktop", route: "/", data: Base64.strict_encode64("jpeg"))
      assert_equal "screenshots/desktop--root.jpg", media.screenshots.first.path
    end
  end

  def test_a_failed_recording_is_recorded_as_a_gap_not_dropped
    Dir.mktmpdir do |dir|
      media = ChangeMedia.new(dir)
      media.add_video(viewport: "tablet", error: "MediaRecorder unavailable")
      video = media.videos.first
      assert_nil video.path
      assert_equal "MediaRecorder unavailable", video.error
      assert media.empty?
    end
  end

  # --- manifest -------------------------------------------------------------------

  def findings
    findings = Findings.new
    findings.add(Finding.new(lane: "a11y", check: "color-contrast", status: "fail", severity: "serious",
                             location: "/sign-in", detail: "insufficient contrast"))
    findings.add(Finding.new(lane: "browserless", check: "mobile 390x844", status: "warn", severity: "low",
                             location: "/sign-in", detail: "1 console error"))
    findings.add(Finding.new(lane: "k6", check: "http_req_duration", status: "pass", severity: "info"))
    findings
  end

  def manifest(media: nil)
    ChangeArtifactManifest.new(
      repo_root: Dir.pwd, findings: findings, report: nil, media: media, artifacts: artifacts,
      run: { project: "web", app: nil, scope: "all", profile: "(none)", target: "http://app:3000" },
      generated_at: Time.utc(2026, 8, 1, 12, 30, 0)
    ).to_h
  end

  def test_manifest_carries_contributor_team_and_run_context
    data = manifest
    assert_equal "acme", data["team_id"]
    assert_equal "pst", data["contributor_id"]
    assert_equal "Pat Taylor", data["contributor_name"]
    assert_equal "github.com/acme/web", data["repo_id"]
    assert_equal "all", data["run"]["scope"]
    assert_equal "fail", data["status"]
    assert_equal({ "total" => 3, "fail" => 1, "warn" => 1, "pass" => 1 }, data["counts"])
  end

  def test_failing_findings_sort_first
    assert_equal %w[fail warn pass], manifest["findings"].map { |row| row["status"] }
  end

  # The service assigns every run's key prefix from the organization and team the
  # publishing key belongs to. A client-side prefix would be an assertion about a
  # location the client has no authority over, so the manifest states none.
  def test_the_manifest_states_no_key_prefix
    data = manifest
    assert data["run_id"].start_with?("20260801T123000Z-")
    refute data.key?("key_prefix")
  end

  def test_viewport_sections_attach_that_viewport_s_own_findings
    Dir.mktmpdir do |dir|
      media = ChangeMedia.new(dir)
      media.add_screenshot(viewport: "mobile", route: "/sign-in", data: Base64.strict_encode64("jpeg"))
      section = manifest(media: media)["viewports"].first

      assert_equal "mobile", section["name"]
      assert_equal "pdf/mobile.pdf", section["pdf"]
      assert_equal [ "/sign-in" ], section["screenshots"].map { |shot| shot["route"] }
      assert_equal [ "mobile 390x844" ], section["findings"].map { |row| row["check"] }
    end
  end

  def test_no_media_means_no_viewport_sections
    assert_empty manifest["viewports"]
  end

  # --- rendering -------------------------------------------------------------------

  def rendered
    ChangeArtifactView.new(manifest, artifacts: artifacts).render(ChangeArtifactTemplates.page)
  end

  def test_the_page_renders_the_run_and_its_findings
    html = rendered
    assert_includes html, "Pat Taylor"
    assert_includes html, "github.com/acme/web"
    assert_includes html, "color-contrast"
    assert_includes html, "insufficient contrast"
    assert_includes html, "No media was captured for this run."
  end

  def test_a_finding_s_free_text_is_escaped_not_rendered
    findings = Findings.new
    findings.add(Finding.new(lane: "zap", check: "xss", status: "fail", detail: "<script>alert(1)</script>"))
    data = ChangeArtifactManifest.new(
      repo_root: Dir.pwd, findings: findings, report: nil, media: nil, artifacts: artifacts,
      run: { project: "web", app: nil, scope: "all", profile: "(none)", target: "http://app:3000" }
    ).to_h
    html = ChangeArtifactView.new(data, artifacts: artifacts).render(ChangeArtifactTemplates.page)

    refute_includes html, "<script>alert(1)</script>"
    assert_includes html, "&lt;script&gt;alert(1)&lt;/script&gt;"
  end

  def test_the_embedded_json_cannot_close_its_own_script_block
    view = ChangeArtifactView.new(manifest, artifacts: artifacts)
    assert_equal '{"a":"<\\/script>"}', view.json({ "a" => "</script>" })
  end

  # --- publish: the client's own decisions -----------------------------------------

  def test_content_types_cover_every_asset_a_bundle_holds
    publisher = ChangeArtifactPublish.new(bundle_dir: "/tmp/bundle", artifacts: artifacts)
    types = %w[index.html manifest.json screenshots/a.jpg video/a.webm pdf/a.pdf report.md report.csv]
            .map { |name| publisher.send(:content_type, name) }
    assert_equal [ "text/html; charset=utf-8", "application/json", "image/jpeg", "video/webm",
                   "application/pdf", "text/markdown; charset=utf-8", "text/csv; charset=utf-8" ], types
  end

  # The three calls carry the run, not a second copy of the artifact: the counts
  # and the git context, never the findings themselves.
  def test_the_declared_run_is_a_summary_not_the_whole_artifact
    with_bundle do |dir|
      publisher = ChangeArtifactPublish.new(bundle_dir: dir, artifacts: artifacts)
      body = publisher.send(:payload, sample_manifest, publisher.send(:declared_files), "team_01")

      assert_equal "team_01", body["teamId"]
      assert_equal "fail", body["status"]
      assert_equal 1, body["failCount"]
      assert_equal 2, body["warnCount"]
      assert_equal "web", body["project"]
      assert_equal "verify/artifacts", body["branch"]
      assert_equal "Pat Taylor", body["contributorLabel"]
      refute body.key?("findings")
      # Absent is absent, never an empty string somebody chose.
      refute body.key?("prUrl")
    end
  end

  def test_every_file_in_the_bundle_is_declared_with_its_size_and_digest
    with_bundle do |dir|
      files = ChangeArtifactPublish.new(bundle_dir: dir, artifacts: artifacts).send(:declared_files)
      assert_equal [ "index.html", "manifest.json", "screenshots/mobile.jpg" ], files.map { |f| f["path"] }

      index = files.first
      assert_equal "text/html; charset=utf-8", index["contentType"]
      assert_equal INDEX_HTML.bytesize, index["bytes"]
      assert_equal Digest::SHA256.hexdigest(INDEX_HTML), index["sha256"]
    end
  end

  # --- publish: the three calls, against a real server ------------------------------

  def test_a_successful_publish_makes_three_kinds_of_call_and_returns_the_services_viewer_url
    with_server do |server, dir|
      result = publish_to(server, dir)

      assert_empty result.warnings
      assert_equal 3, result.uploaded
      assert_equal "ABCDEFGHJK", result.short_id
      assert_equal "https://artifacts.example.test/v/acme/web/ABCDEFGHJK/", result.url

      assert_equal [ "/v1/whoami-key", "/v1/artifacts", "/upload/index.html",
                     "/upload/manifest.json", "/upload/screenshots/mobile.jpg",
                     "/v1/artifacts/art_01/complete" ], server.log.map { |call| call[:path] }
    end
  end

  # The key is a header on the API calls and is deliberately absent from the
  # uploads: a presigned URL is the whole authority, and attaching a credential
  # to it would be handing out a second one for no reason.
  def test_the_team_key_authenticates_the_api_calls_and_never_the_uploads
    with_server do |server, dir|
      publish_to(server, dir)

      api = server.log.select { |call| call[:path].start_with?("/v1/") }
      assert_equal [ "team-key-under-test" ], api.map { |call| call[:key] }.uniq
      assert_equal [ nil ], server.log.reject { |call| call[:path].start_with?("/v1/") }
                                     .map { |call| call[:key] }.uniq
    end
  end

  def test_each_files_bytes_arrive_on_its_own_presigned_url
    with_server do |server, dir|
      publish_to(server, dir)

      upload = server.log.find { |call| call[:path] == "/upload/index.html" }
      assert_equal INDEX_HTML, upload[:body]
      assert_equal "text/html; charset=utf-8", upload[:content_type]
    end
  end

  # A repo that pins the team id skips the lookup. Everything else is identical,
  # which is the point: it is a saved round trip, not a different path.
  def test_a_pinned_team_id_skips_the_whoami_lookup
    with_server do |server, dir|
      result = publish_to(server, dir, platform: { "team_id" => "team_pinned" })

      assert_empty result.warnings
      refute_includes server.log.map { |call| call[:path] }, "/v1/whoami-key"
      assert_equal "team_pinned", JSON.parse(server.log.first[:body])["teamId"]
    end
  end

  # --- publish: the best-effort contract, one failure at a time ----------------------
  #
  # Each of these asserts the same two things: the publisher returns a Result
  # rather than raising, and it names what went wrong. Nothing here can reach the
  # run's verdict, because `finish` in change_artifact.rb turns a Result into log
  # lines and the gate is recorded from the findings alone.

  def test_a_failing_create_is_a_named_warning_not_an_exception
    with_server(fail_at: :create) do |server, dir|
      result = publish_to(server, dir)
      assert_nil result.url
      assert_equal 0, result.uploaded
      assert_includes result.warnings.join("\n"), "/v1/artifacts answered 500"
    end
  end

  # One failed upload does not abandon the rest, and does not skip completion:
  # the service's own check is what reports precisely which file never arrived.
  def test_a_failing_upload_is_counted_as_a_gap_and_the_run_still_completes
    with_server(fail_at: :upload) do |server, dir|
      result = publish_to(server, dir)

      assert_equal 2, result.uploaded
      assert_includes result.warnings.join("\n"), "upload failed for index.html"
      assert_includes server.log.map { |call| call[:path] }, "/v1/artifacts/art_01/complete"
      # The run still published: the bytes that did arrive are reachable.
      refute_nil result.url
    end
  end

  def test_a_failing_completion_is_a_named_warning_and_the_uploads_still_count
    with_server(fail_at: :complete) do |server, dir|
      result = publish_to(server, dir)

      assert_equal 3, result.uploaded
      refute_nil result.url
      assert_includes result.warnings.join("\n"), "complete answered 500"
    end
  end

  def test_the_services_completion_note_is_surfaced_rather_than_swallowed
    with_server(note: "index.html was never uploaded") do |server, dir|
      result = publish_to(server, dir)
      assert_includes result.warnings.join("\n"), "index.html was never uploaded"
    end
  end

  # An unreachable API is the same shape of failure as a refused one. Pointed at
  # a port nothing is listening on, the client reports and returns.
  def test_an_unreachable_api_is_a_named_warning
    with_bundle do |dir|
      config = artifacts("api_url" => "http://127.0.0.1:1", "api_key_env" => "CF_TEST_TEAM_KEY")
      result = with_env("CF_TEST_TEAM_KEY" => "team-key-under-test") do
        ChangeArtifactPublish.publish(bundle_dir: dir, artifacts: config)
      end

      assert_nil result.url
      assert_includes result.warnings.join("\n"), "/v1/whoami-key failed"
    end
  end

  def test_no_resolvable_key_names_both_ways_of_supplying_one
    with_bundle do |dir|
      config = artifacts("api_key_env" => "CF_TEST_ABSENT_KEY_#{Process.pid}")
      result = ChangeArtifactPublish.publish(bundle_dir: dir, artifacts: config)

      assert_nil result.url
      warning = result.warnings.join("\n")
      assert_includes warning, "CF_TEST_ABSENT_KEY_#{Process.pid}"
      assert_includes warning, "cf_team_join.rb --platform acme web"
    end
  end

  def test_a_bundle_with_no_manifest_publishes_nothing_and_says_so
    Dir.mktmpdir do |dir|
      result = ChangeArtifactPublish.publish(bundle_dir: dir, artifacts: artifacts)
      assert_nil result.url
      assert_includes result.warnings.join("\n"), "no manifest.json"
    end
  end

  # A repo still on the deprecated block is told to migrate rather than silently
  # publishing nowhere. The bundle is already on disk, which is what keeps this a
  # prompt instead of a lost run.
  def test_the_legacy_block_reports_the_migration_instead_of_publishing
    with_bundle do |dir|
      result = ChangeArtifactPublish.publish(bundle_dir: dir, artifacts: legacy)

      assert_nil result.url
      assert_equal 0, result.uploaded
      warning = result.warnings.join("\n")
      assert_includes warning, "deprecated contributors_team.artifacts block"
      assert_includes warning, "schema 0.7.0"
    end
  end

  private

  INDEX_HTML = "<!doctype html><title>Findings</title><h1>run</h1>\n"

  def sample_manifest
    {
      "status" => "fail", "counts" => { "fail" => 1, "warn" => 2 },
      "repo_id" => "github.com/acme/web", "contributor_name" => "Pat Taylor",
      "generated_at" => "2026-08-01T12:30:00Z",
      "run" => { "project" => "web" },
      "git" => { "branch" => "verify/artifacts", "head_sha" => "0" * 40, "pr_url" => "" }
    }
  end

  # A bundle on disk: three files, one of them nested, so path handling is
  # exercised rather than assumed.
  def with_bundle
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "manifest.json"), JSON.generate(sample_manifest))
      File.write(File.join(dir, "index.html"), INDEX_HTML)
      Dir.mkdir(File.join(dir, "screenshots"))
      File.binwrite(File.join(dir, "screenshots", "mobile.jpg"), "jpeg-bytes")
      yield dir
    end
  end

  def publish_to(server, dir, platform: {})
    config = artifacts({ "api_url" => server.origin, "api_key_env" => "CF_TEST_TEAM_KEY" }.merge(platform))
    with_env("CF_TEST_TEAM_KEY" => "team-key-under-test") do
      ChangeArtifactPublish.publish(bundle_dir: dir, artifacts: config)
    end
  end

  def with_env(pairs)
    previous = pairs.keys.to_h { |name| [ name, ENV[name] ] }
    pairs.each { |name, value| ENV[name] = value }
    yield
  ensure
    previous.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  # A real HTTP server standing in for the artifacts service, recording every
  # call it receives. `fail_at` makes exactly one step answer 500, which is how
  # the best-effort contract is asserted one failure at a time.
  def with_server(fail_at: nil, note: nil)
    server = FakeArtifactsService.new(fail_at: fail_at, note: note)
    server.start
    with_bundle { |dir| yield server, dir }
  ensure
    server&.stop
  end

  # A hand-rolled server over TCPServer rather than a web framework, for the same
  # reason change_artifact_publish.rb is hand-rolled over Net::HTTP: this repo
  # ships a toolkit that must run wherever Ruby does, and a test dependency the
  # code under test does not have would be a dependency all the same. The client
  # speaks a small, predictable dialect (four paths, JSON in and out, one PUT per
  # file), so a small, predictable server is enough to hold it to it.
  class FakeArtifactsService
    attr_reader :log

    def initialize(fail_at: nil, note: nil)
      @fail_at = fail_at
      @note = note
      @log = []
    end

    def origin = "http://127.0.0.1:#{@port}"

    def start
      @socket = TCPServer.new("127.0.0.1", 0)
      @port = @socket.addr[1]
      @thread = Thread.new { accept_loop }
    end

    def stop
      @running = false
      @socket&.close
      @thread&.kill
    end

    private

    def accept_loop
      @running = true
      while @running
        client = begin
          @socket.accept
        rescue IOError, Errno::EBADF
          break
        end
        handle(client)
      end
    end

    def handle(client)
      request = read_request(client)
      return client.close unless request

      @log << request
      client.write(response_for(request))
    rescue StandardError
      nil
    ensure
      client.close unless client.closed?
    end

    # Request line, headers, then exactly Content-Length bytes of body. Nothing
    # here handles chunked encoding, and nothing needs to: Net::HTTP sends a
    # Content-Length for every body this client produces.
    def read_request(client)
      line = client.gets
      return nil unless line

      path = line.split(" ")[1].to_s.split("?").first
      headers = {}
      while (header = client.gets) && header.strip != ""
        name, value = header.split(":", 2)
        headers[name.to_s.strip.downcase] = value.to_s.strip
      end
      length = headers["content-length"].to_i
      body = length.positive? ? client.read(length) : nil

      { path: path, key: headers["x-cf-key"], body: body, content_type: headers["content-type"] }
    end

    def response_for(request)
      case request[:path]
      when "/v1/whoami-key" then json(200, { "teamId" => "team_01" })
      when "/v1/artifacts" then created
      when %r{\A/v1/artifacts/.+/complete\z} then completed
      when %r{\A/upload/} then upload_response(request[:path])
      else raw(404, "")
      end
    end

    def created
      return json(500, { "error" => "boom" }) if @fail_at == :create

      json(201, {
        "artifactId" => "art_01", "shortId" => "ABCDEFGHJK",
        "viewerUrl" => "https://artifacts.example.test/v/acme/web/ABCDEFGHJK/",
        "uploads" => %w[index.html manifest.json screenshots/mobile.jpg].map do |path|
          { "path" => path, "url" => "#{origin}/upload/#{path}" }
        end
      })
    end

    def completed
      return json(500, { "error" => "boom" }) if @fail_at == :complete

      json(200, { "uploadedBytes" => 42, "note" => @note })
    end

    def upload_response(path)
      raw((@fail_at == :upload && path == "/upload/index.html") ? 500 : 200, "")
    end

    def json(status, body) = raw(status, JSON.generate(body), "application/json")

    def raw(status, body, content_type = "text/plain")
      reason = { 200 => "OK", 201 => "Created", 404 => "Not Found", 500 => "Internal Server Error" }
               .fetch(status, "OK")
      "HTTP/1.1 #{status} #{reason}\r\n" \
        "Content-Type: #{content_type}\r\n" \
        "Content-Length: #{body.bytesize}\r\n" \
        "Connection: close\r\n\r\n#{body}"
    end
  end
end
