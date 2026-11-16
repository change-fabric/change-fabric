# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require_relative "../scripts/change_docker"

# The image track's invariants: release-image.yml runs only on a human-pushed
# image/v* tag, holds the least privilege that publishing needs, and the derived
# Dockerfile builds FROM the upstream browserless pin, never the runtime pin.
class ReleaseImageWorkflowTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  WORKFLOW = File.join(ROOT, ".github/workflows/release-image.yml")
  DOCKERFILE = File.join(ROOT, "docker/browserless-cf/Dockerfile")
  LOCK = File.join(ROOT, "docker/browserless-cf/fonts.lock")

  def workflow = @workflow ||= YAML.safe_load_file(WORKFLOW, aliases: true)
  # Psych reads the bare `on:` key as boolean true.
  def triggers = workflow["on"] || workflow[true]

  def test_runs_only_on_an_image_tag_push
    assert_equal({ "push" => { "tags" => [ "image/v*" ] } }, triggers)
  end

  def test_permissions_are_read_contents_and_write_packages_only
    assert_equal({ "contents" => "read", "packages" => "write" }, workflow["permissions"])
  end

  def test_guard_rejects_moved_malformed_and_non_increasing_tags
    text = File.read(WORKFLOW)
    assert_includes text, "REF_WAS_CREATED"
    assert_includes text, "grep -Eq '^[0-9]+\\.[0-9]+\\.[0-9]+$'"
    assert_includes text, "git tag --list 'image/v*'"
    assert_includes text, "Version goes backwards"
  end

  def test_workflow_never_creates_a_tag
    refute_match(/git (tag|push)\s+(-a|origin)|gh release create/, File.read(WORKFLOW))
  end

  def test_third_party_actions_are_sha_pinned
    uses = File.read(WORKFLOW).scan(/uses:\s*(\S+)/).flatten.reject { |u| u.start_with?("actions/") }
    refute_empty uses
    uses.each { |u| assert_match(/@[0-9a-f]{40}\z/, u) }
  end

  def test_dockerfile_from_is_the_upstream_pin
    from = File.read(DOCKERFILE)[/^FROM\s+(\S+)/, 1]
    assert_equal ChangeDocker::BROWSERLESS_UPSTREAM, from
  end

  def test_dockerfile_verifies_fonts_and_rebuilds_the_cache
    text = File.read(DOCKERFILE)
    assert_includes text, "sha256sum -c"
    assert_includes text, "fc-cache -f"
    assert_match(/^USER blessuser$/, text)
  end

  def test_fonts_lock_entries_are_sha_pinned_and_cover_the_default_faces
    rows = File.readlines(LOCK, chomp: true).grep_v(/\A\s*(#|\z)/).map(&:split)
    rows.each do |sha, path, url|
      assert_match(/\A[0-9a-f]{64}\z/, sha)
      refute_includes path, ".."
      assert_match(%r{\Ahttps://raw\.githubusercontent\.com/google/fonts/[0-9a-f]{40}/ofl/}, url)
    end
    paths = rows.map { |row| row[1] }
    %w[sourceserif4 inter jetbrainsmono].each { |dir| assert_includes paths, "#{dir}/OFL.txt" }
  end
end
