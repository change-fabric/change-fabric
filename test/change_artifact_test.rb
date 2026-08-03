# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../scripts/change_artifacts_config"
require_relative "../scripts/change_artifact_manifest"
require_relative "../scripts/change_artifact_publish"
require_relative "../scripts/change_artifact_templates"
require_relative "../scripts/change_artifact_view"
require_relative "../scripts/change_findings"
require_relative "../scripts/change_media"

# Covers the pure parts of the findings-artifact pipeline: the artifacts config
# block, the media sink's on-disk layout, the manifest a run is described by,
# and the page template's rendering and escaping. The AWS calls (upload, the
# manifest table, the CloudFront invalidation) and the in-Chromium capture are
# exercised by a real run against real infrastructure, not here; what is unit
# testable is the shape of what gets uploaded, which is what these assert.
class ChangeArtifactTest < Minitest::Test
  FakeIdentity = Struct.new(:team_id, :contributor_id, :contributor_name, :repo_id)

  class FakeTeam
    def initialize(identity) = @identity = identity
    def identity = @identity
    def repo_root = "/repo"
  end

  def identity = FakeIdentity.new("acme", "pst", "Pat Taylor", "github.com/acme/web")

  def artifacts(raw = {})
    block = {
      "bucket" => "cf-change-artifacts-acme",
      "__team" => { "team_id" => "acme", "contributors" => [ { "id" => "pst", "name" => "Pat Taylor" } ] }
    }.merge(raw)
    ChangeArtifactsConfig.new(block, team: FakeTeam.new(identity))
  end

  # --- config -------------------------------------------------------------------

  def test_defaults_fill_in_region_profile_and_table
    config = artifacts
    assert_equal "us-east-1", config.region
    assert_equal "personal", config.aws_profile
    assert_equal "cf-change-artifacts", config.manifest_table
    assert config.screenshots?
    assert config.video?
    assert_equal 6, config.video_fps
  end

  def test_media_toggles_and_viewer_url
    config = artifacts("media" => { "video" => false, "video_fps" => 12 }, "domain" => "d1.cloudfront.net")
    refute config.video?
    assert_equal 12, config.video_fps
    assert_equal "https://d1.cloudfront.net", config.base_viewer_url
  end

  def test_no_domain_means_no_viewer_url
    assert_nil artifacts.base_viewer_url
  end

  def test_roster_comes_from_the_committed_contributors_list
    assert_equal [ { "id" => "pst", "name" => "Pat Taylor" } ], artifacts.roster
  end

  def test_load_outside_a_repo_is_nil_not_an_error
    Dir.mktmpdir { |dir| assert_nil ChangeArtifactsConfig.load(dir) }
  end

  # This repo registers a contributors team and no artifacts area, which is the
  # exact shape the opt-out has to keep working for: a team repo that publishes
  # nothing and is not asked to.
  def test_a_team_repo_without_an_artifacts_block_is_not_configured
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

  def test_key_prefix_is_repo_then_contributor_then_run
    data = manifest
    assert data["run_id"].start_with?("20260801T123000Z-")
    assert_equal "github.com/acme/web/pst/#{data['run_id']}", data["key_prefix"]
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

  # --- publish ---------------------------------------------------------------------

  def publisher = ChangeArtifactPublish.new(bundle_dir: "/tmp/bundle", artifacts: artifacts("domain" => "d1.cloudfront.net"))

  def test_the_index_row_is_a_listing_not_a_second_copy_of_the_run
    row = publisher.send(:index_row, manifest)
    assert_equal "Pat Taylor", row["contributor_name"]
    assert_equal "fail", row["status"]
    assert_equal 1, row["fail_count"]
    assert_equal "web", row["project"]
    assert row["url"].start_with?("https://d1.cloudfront.net/github.com/acme/web/pst/")
    refute row.key?("findings")
  end

  def test_content_types_cover_every_asset_a_bundle_holds
    types = %w[index.html manifest.json screenshots/a.jpg video/a.webm pdf/a.pdf report.md report.csv]
            .map { |name| publisher.send(:content_type, name) }
    assert_equal [ "text/html; charset=utf-8", "application/json", "image/jpeg", "video/webm",
                   "application/pdf", "text/markdown; charset=utf-8", "text/csv; charset=utf-8" ], types
  end
end
