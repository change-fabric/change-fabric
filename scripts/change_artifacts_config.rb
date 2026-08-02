#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require_relative 'change_frontmatter'
require_relative 'contributors_team'

# Typed, fail-soft view over the artifact-publishing configuration a repo may
# carry under `contributors_team:` in its CHANGE.md frontmatter (schema 0.6.0).
# Its presence is the single switch that turns the findings-artifact pipeline
# on: a repo without it runs, reports, and gates exactly as it did before the
# block existed, and no media is captured, no bundle is built, and nothing is
# published.
#
# Two shapes are accepted, and which one a repo carries decides where its runs
# land:
#
#   contributors_team.platform.*    (0.6.0, primary) the hosted artifacts
#                                   service. The repo names its organization,
#                                   its team, the API it publishes through, and
#                                   the env var holding a team API key. The
#                                   SERVER owns the bucket, the key prefix, the
#                                   index, and the access rules; nothing about
#                                   any of them appears here.
#
#   contributors_team.artifacts.*   (0.5.0, deprecated) the per-team bucket a
#                                   team provisioned for itself before the
#                                   hosted service existed. Still read, so a
#                                   repo that has not migrated still resolves a
#                                   configuration and still builds its bundle.
#                                   Slated for removal at schema 0.7.0.
#
# `platform:` wins whenever both are present. It is not a merge: the two
# describe different destinations, and quietly blending a bucket with a service
# would publish half a run to each.
#
# Nothing here is a credential, under either shape. The new block names the
# ENV VAR the team API key arrives in, never the key; the legacy block names
# where the viewer credential lives (an SSM parameter, a 1Password reference),
# never the credential itself. This is the same indirection
# `lanes.<lane>.basic_auth.username_env` already uses.
class ChangeArtifactsConfig
  DEFAULT_REGION = 'us-east-1'
  DEFAULT_PROFILE = 'personal'
  DEFAULT_MANIFEST_TABLE = 'cf-change-artifacts'
  DEFAULT_VIDEO_FPS = 6

  # Where the hosted service answers unless a repo says otherwise. Staging is
  # the default because staging is what exists; a production estate overrides it
  # with one field rather than by shipping a second build of this script.
  DEFAULT_API_URL = 'https://api.staging.changefabric.org'

  # The env var a team API key is read from unless a repo names another. One
  # default keeps the common case (one team, one machine) free of configuration
  # while leaving a machine that publishes for two teams able to distinguish
  # them.
  DEFAULT_API_KEY_ENV = 'CF_TEAM_API_KEY'

  # The Keychain service `cf_team_join.rb --platform` writes a team API key to,
  # so a contributor's own machine can publish without the key living in the
  # environment of every shell. Deliberately NOT the presence key's service
  # (`change-fabric-presence`): these are two different credentials with two
  # different blast radii, and one service holding both would make revoking one
  # mean re-provisioning the other.
  KEYCHAIN_SERVICE = 'change-fabric-platform'

  # Loads the configuration for the repo rooted at `start_dir`, or nil when this
  # repo is not a registered team repo, carries neither block, or has the block
  # it carries explicitly disabled. Never raises: an unreadable or malformed
  # CHANGE.md means "not configured", which is the same, already-supported
  # no-op path.
  def self.load(start_dir)
    team = ContributorsTeam.new(start_dir)
    root = team.repo_root
    return nil unless root

    block = team_block(root)
    return nil unless block

    config = new(block, team: team)
    config.configured? ? config : nil
  rescue StandardError
    nil
  end

  def self.team_block(root)
    front = ChangeFrontmatter.parse_file(File.join(root, 'CHANGE.md'))
    block = front['contributors_team']
    block.is_a?(Hash) ? block : nil
  end
  private_class_method :team_block

  # `raw` is the whole `contributors_team:` hash, not one of its sub-blocks: the
  # roster and the team id sit beside `platform:`/`artifacts:` and are read by
  # both shapes, so splitting them apart here would only mean stitching them
  # back together in three callers.
  def initialize(raw, team:)
    @raw = raw.is_a?(Hash) ? raw : {}
    @team = team
  end

  # True when this repo has a destination to publish to that is not switched
  # off. The two shapes answer it differently on purpose: the hosted service is
  # configured by naming an organization and a team, while the legacy shape was
  # only ever enabled by a bucket name.
  def configured?
    return false if block['enabled'] == false

    platform? ? !organization.empty? && !team_slug.empty? : !bucket.empty?
  end

  # Which shape this repo carries. Everything that differs between publishing to
  # the hosted service and publishing to a team's own bucket keys off this one
  # predicate rather than off the presence of individual fields, so a
  # half-migrated block cannot end up taking half of each path.
  def platform? = @raw['platform'].is_a?(Hash)

  # --- the hosted service (0.6.0) --------------------------------------------

  # The organization slug, as the platform knows it. It is here rather than
  # derived from the API key because it names the repo's team in a form a human
  # reading the committed file recognises, and because it is half of the
  # Keychain account the key is looked up under.
  def organization = @raw['organization'].to_s

  # The team slug. Named `team_slug` rather than `team` only because
  # `ContributorsTeam` already occupies the shorter name inside this class.
  def team_slug = @raw['team'].to_s

  def api_url = platform_value_or('api_url', DEFAULT_API_URL).sub(%r{/+\z}, '')
  def api_key_env = platform_value_or('api_key_env', DEFAULT_API_KEY_ENV)

  # The platform team id, when a repo pins it. Usually absent: the API key is
  # already scoped to exactly one team, so the publisher asks the API which team
  # that is rather than making every repo commit an id it cannot verify. Pinning
  # it saves that one round trip for a repo that would rather be explicit.
  def platform_team_id = platform['team_id'].to_s

  # The team API key, or nil. Two sources, in order: the named env var, then
  # this machine's Keychain entry for this org and team. The env var wins so a
  # CI job can supply a key without a Keychain at all, and so a run can be
  # pointed at a different key for one invocation.
  #
  # Never cached across calls and never logged. It is returned to exactly one
  # caller, the publisher, which spends it on one request and drops it.
  def api_key
    from_env = ENV[api_key_env].to_s.strip
    return from_env unless from_env.empty?

    from_keychain = keychain_api_key
    from_keychain.to_s.empty? ? nil : from_keychain
  end

  # The staging-wide HTTP Basic Auth fence in front of the platform API, as a
  # `"username:password"` string, or nil when this deployment has none. Named
  # env vars, never values, exactly like `lanes.<lane>.basic_auth`.
  #
  # This is a property of the DEPLOYMENT, not of the team: production will not
  # have it, and a repo that publishes to production simply omits the block.
  def api_basic_auth
    auth = platform['basic_auth']
    return nil unless auth.is_a?(Hash)

    username = ENV[auth['username_env'].to_s].to_s
    password = ENV[auth['password_env'].to_s].to_s
    return nil if username.empty? && password.empty?

    "#{username}:#{password}"
  end

  # --- the legacy team bucket (0.5.0, deprecated) -----------------------------

  def bucket = legacy['bucket'].to_s
  def region = legacy_value_or('region', DEFAULT_REGION)
  def aws_profile = legacy_value_or('aws_profile', DEFAULT_PROFILE)
  def distribution_id = legacy['distribution_id'].to_s
  def domain = legacy['domain'].to_s
  def manifest_table = legacy_value_or('manifest_table', DEFAULT_MANIFEST_TABLE)

  # --- shared ------------------------------------------------------------------

  # The resolved local identity (team_id, contributor_id, contributor_name,
  # repo_id) or nil when this machine has not joined the team. A run whose
  # identity is unresolved still builds a bundle: the artifact reports the
  # contributor as unknown rather than refusing to render, since an unjoined
  # machine is a setup gap, not an audit failure.
  def identity = @team.identity

  # The team's registered roster, `[{ 'id' =>, 'name' => }, ...]`, straight from
  # the committed `contributors:` list. Rendered as team context on the artifact
  # so a reader sees who else's runs sit beside this one.
  def roster
    list = @raw['contributors']
    return [] unless list.is_a?(Array)

    list.select { |entry| entry.is_a?(Hash) }.map { |entry| { 'id' => entry['id'].to_s, 'name' => entry['name'].to_s } }
  end

  def team_id = @raw['team_id'].to_s

  # Per-viewport media capture. Both default on once the repo is configured,
  # since a findings artifact with no screenshots is the thing this is for.
  def screenshots? = media.fetch('screenshots', true) != false
  def video? = media.fetch('video', true) != false
  def video_fps = Integer(media.fetch('video_fps', DEFAULT_VIDEO_FPS))

  # Where a viewer reaches a published run, when that is knowable before
  # publishing. Under the hosted service it is not: the server mints the viewer
  # URL as part of accepting the run, and inventing one here would mean this
  # file and the API each holding an opinion about a URL only one of them
  # controls. Under the legacy shape it is the team's own CloudFront domain, and
  # a bucket-only config (a distribution never provisioned) has none at all.
  def base_viewer_url
    return nil if platform?

    domain.empty? ? nil : "https://#{domain}"
  end

  private

  # The block that decides this repo's destination: the new one when present,
  # the legacy one otherwise. Shared settings (`enabled`, `media`) are read from
  # it so they sit beside the fields they modify rather than in a third place.
  def block = platform? ? platform : legacy

  def platform
    raw = @raw['platform']
    raw.is_a?(Hash) ? raw : {}
  end

  def legacy
    raw = @raw['artifacts']
    raw.is_a?(Hash) ? raw : {}
  end

  def media
    raw = block['media']
    raw.is_a?(Hash) ? raw : {}
  end

  # This machine's stored key for this org and team. Fail-soft in every
  # direction: no Keychain, no entry, or a `security` that is not on this
  # platform all mean "no key here", which the publisher reports as a named
  # warning rather than a stack trace.
  def keychain_api_key
    account = "#{organization}/#{team_slug}"
    out, status = Open3.capture2e(
      'security', 'find-generic-password', '-s', KEYCHAIN_SERVICE, '-a', account, '-w'
    )
    status.success? ? out.strip : nil
  rescue StandardError
    nil
  end

  def platform_value_or(key, fallback) = value_or(platform, key, fallback)
  def legacy_value_or(key, fallback) = value_or(legacy, key, fallback)

  def value_or(source, key, fallback)
    value = source[key].to_s
    value.empty? ? fallback : value
  end
end
