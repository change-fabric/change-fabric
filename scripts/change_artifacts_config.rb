#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'change_frontmatter'
require_relative 'contributors_team'

# Typed, fail-soft view over the `contributors_team.artifacts:` block a repo may
# carry in its CHANGE.md frontmatter (schema 0.5.0). Its presence is the single
# switch that turns the findings-artifact pipeline on: a repo without the block
# runs, reports, and gates exactly as it did before the block existed, and no
# media is captured, no bundle is built, and nothing is uploaded.
#
# It deliberately sits next to ContributorsTeam rather than inside ChangeConfig:
# the bucket, the distribution, and the roster are team-scoped facts shared by
# every repo the team owns, while `change_config:` is the per-repo audit surface.
# Nothing here is a credential. `basic_auth` names where the viewer credential
# lives (an SSM parameter, a 1Password reference), never the credential itself,
# the same indirection `lanes.<lane>.basic_auth.username_env` already uses.
class ChangeArtifactsConfig
  DEFAULT_REGION = 'us-east-1'
  DEFAULT_PROFILE = 'personal'
  DEFAULT_MANIFEST_TABLE = 'cf-change-artifacts'
  DEFAULT_VIDEO_FPS = 6

  # Loads the block for the repo rooted at `start_dir`, or nil when this repo is
  # not a registered team repo, carries no `artifacts:` block, or has it
  # explicitly disabled. Never raises: an unreadable or malformed CHANGE.md
  # means "not configured", which is the same, already-supported no-op path.
  def self.load(start_dir)
    team = ContributorsTeam.new(start_dir)
    root = team.repo_root
    return nil unless root

    block = artifacts_block(root)
    return nil unless block
    return nil if block['enabled'] == false

    new(block, team: team)
  rescue StandardError
    nil
  end

  def self.artifacts_block(root)
    front = ChangeFrontmatter.parse_file(File.join(root, 'CHANGE.md'))
    team = front['contributors_team']
    return nil unless team.is_a?(Hash)

    block = team['artifacts']
    block.is_a?(Hash) && !block['bucket'].to_s.empty? ? block.merge('__team' => team) : nil
  end
  private_class_method :artifacts_block

  def initialize(raw, team:)
    @raw = raw
    @team = team
  end

  def bucket = @raw['bucket'].to_s
  def region = value_or('region', DEFAULT_REGION)
  def aws_profile = value_or('aws_profile', DEFAULT_PROFILE)
  def distribution_id = @raw['distribution_id'].to_s
  def domain = @raw['domain'].to_s
  def manifest_table = value_or('manifest_table', DEFAULT_MANIFEST_TABLE)

  # The resolved local identity (team_id, contributor_id, contributor_name,
  # repo_id) or nil when this machine has not joined the team. A run whose
  # identity is unresolved still builds a bundle: the artifact reports the
  # contributor as unknown rather than refusing to render, since an unjoined
  # machine is a setup gap, not an audit failure.
  def identity = @team.identity

  # The team's registered roster, `[{ 'id' =>, 'name' => }, ...]`, straight from
  # the committed `contributors:` list. Rendered as team context on the artifact
  # so a reader sees who else's runs live in the same bucket.
  def roster
    list = (@raw['__team'] || {})['contributors']
    return [] unless list.is_a?(Array)

    list.select { |entry| entry.is_a?(Hash) }.map { |entry| { 'id' => entry['id'].to_s, 'name' => entry['name'].to_s } }
  end

  def team_id = (@raw['__team'] || {})['team_id'].to_s

  # Per-viewport media capture. Both default on once `artifacts:` exists, since
  # a findings artifact with no screenshots is the thing this block is for.
  def screenshots? = media.fetch('screenshots', true) != false
  def video? = media.fetch('video', true) != false
  def video_fps = Integer(media.fetch('video_fps', DEFAULT_VIDEO_FPS))

  # Where a viewer reaches a published run. Prefers the CloudFront domain the
  # init script printed; a bucket-only config (a distribution not provisioned
  # yet) has no viewer url at all, which the publisher reports rather than
  # inventing an s3:// or a public website endpoint that basic auth does not
  # cover.
  def base_viewer_url
    domain.empty? ? nil : "https://#{domain}"
  end

  private

  def media
    raw = @raw['media']
    raw.is_a?(Hash) ? raw : {}
  end

  def value_or(key, fallback)
    value = @raw[key].to_s
    value.empty? ? fallback : value
  end
end
