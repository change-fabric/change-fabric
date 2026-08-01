#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'time'
require_relative 'change_artifacts_config'
require_relative 'change_artifact_bundle'
require_relative 'change_artifact_manifest'
require_relative 'change_artifact_templates'
require_relative 'change_artifact_publish'
require_relative 'change_media'

# The optional artifact step of a run, and the only thing `change_run.rb` talks
# to about artifacts.
#
# `ChangeArtifactStep.for` returns nil unless the repo's CHANGE.md carries a
# `contributors_team.artifacts:` block, and a nil step is the entire opt-out: no
# media sink reaches the browserless lane, no bundle directory is created, and
# nothing is uploaded. A repo that never adopts the block runs exactly as it did
# before this file existed.
#
# The step owns the boundary between "the audit" and "the evidence". Building
# and publishing are wrapped so that no failure here can change what the run
# already decided: `finish` returns log lines, never an exit status, and the
# caller records the gate from the findings alone.
class ChangeArtifactStep
  DESKTOP = File.join(Dir.home, 'Desktop')

  # nil when this repo is not set up for artifacts, which is the common case and
  # not a warning: an unconfigured repo is not a misconfigured one.
  def self.for(repo_root:, publish: true, label: nil)
    artifacts = ChangeArtifactsConfig.load(repo_root)
    artifacts ? new(repo_root: repo_root, artifacts: artifacts, publish: publish, label: label) : nil
  end

  attr_reader :media, :dir

  # `label` is the app name in a monorepo sweep, and nothing in single-app mode.
  # It is in the directory name so two apps swept within the same second get
  # their own bundle rather than writing over each other.
  def initialize(repo_root:, artifacts:, publish: true, label: nil)
    @repo_root = repo_root
    @artifacts = artifacts
    @publish = publish
    @generated_at = Time.now.utc
    suffix = label.to_s.empty? ? '' : "-#{ChangeArtifactTemplates.slug(label)}"
    @dir = File.join(DESKTOP, "change-artifact-#{@generated_at.strftime('%Y%m%dT%H%M%SZ')}#{suffix}")
    FileUtils.mkdir_p(@dir)
    @media = ChangeMedia.new(@dir, screenshots: artifacts.screenshots?, video: artifacts.video?,
                                   video_fps: artifacts.video_fps)
  end

  # Assembles the bundle from what the lanes captured and, unless publishing was
  # turned off for this run, uploads it and rebuilds the team index. Returns the
  # lines the runner should log. Any exception is caught and returned as one of
  # those lines: an artifact problem is reported, never raised into a run whose
  # audit already finished.
  def finish(findings:, report:, run:)
    manifest = build_manifest(findings, report, run)
    result = ChangeArtifactBundle.new(dir: @dir, manifest: manifest, media: @media,
                                      report: report, artifacts: @artifacts).build
    lines = [ "artifact bundle: #{result.dir}" ] + result.warnings.map { |warning| "artifact: #{warning}" }
    lines + publish_lines
  rescue StandardError => e
    [ "artifact: skipped, #{e.message}" ]
  end

  private

  # `run` is the caller's own mechanical facts about the run (project, app,
  # scope, profile, target), passed through untouched: the manifest stays
  # ignorant of ChangeConfig, and the runner stays ignorant of the manifest's
  # shape.
  def build_manifest(findings, report, run)
    ChangeArtifactManifest.new(
      repo_root: @repo_root, findings: findings, report: report, media: @media,
      artifacts: @artifacts, run: run, generated_at: @generated_at
    ).to_h
  end

  def publish_lines
    return [ 'artifact: publish skipped (--no-publish)' ] unless @publish

    result = ChangeArtifactPublish.publish(bundle_dir: @dir, artifacts: @artifacts)
    lines = result.warnings.map { |warning| "artifact: #{warning}" }
    lines << "artifact: uploaded #{result.uploaded} file(s)"
    lines << "artifact: #{result.url}" if result.url
    lines << "artifact index: #{result.index_url}" if result.index_url
    lines
  end
end
