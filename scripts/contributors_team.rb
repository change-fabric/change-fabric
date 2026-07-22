#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'change_frontmatter'
require_relative 'shell_git'

# Shared, fail-soft resolver for the `contributors_team` registration a repo
# carries in its CHANGE.md frontmatter, plus the local "which contributor am I"
# config, plus a normalized `repo_id`. Reused by telemetry_emit.rb (Capability
# A), presence_probe.rb (Capability B), and secret_alert_poll.rb (Capability C),
# so the CHANGE.md parsing and identity resolution live in exactly one place -
# the same ChangeFrontmatter/ChangeConfig split this repo already models.
#
# Everything here is fail-soft: a missing repo, a git that is not installed, a
# malformed block, or an unregistered contributor all yield nil rather than
# raising, because every caller runs inside a hook that must never crash.
class ContributorsTeam
  # A resolved local identity: the three self-asserted identity fields plus the
  # normalized repo id. `nil` from #identity means "not a registered team repo,
  # or this machine has no contributor configured for it".
  Identity = Struct.new(:team_id, :contributor_id, :contributor_name, :repo_id)

  # `start_dir` is a directory to resolve the git repo from. Callers holding a
  # file path should pass its dirname (a not-yet-created file's dir still
  # resolves the repo).
  def initialize(start_dir)
    @start_dir = start_dir.to_s
  end

  # Absolute path of the enclosing git repo root, or nil when not a git repo or
  # git is unavailable.
  def repo_root
    return @repo_root if defined?(@repo_root)

    out = git('rev-parse', '--show-toplevel')
    @repo_root = (out && !out.empty?) ? out : nil
  end

  # The main entry point (besides #repo_root, which presence_probe.rb also
  # needs to compute a repo-relative file path): the fully resolved local
  # identity, or nil unless this is a registered team repo AND this machine
  # has a configured, registered contributor for it. Never returns a
  # partial/empty-string identity.
  def identity
    block = team
    return nil unless block

    team_id = block['team_id'].to_s
    return nil if team_id.empty?

    contributor_id = local_contributor_id(team_id)
    return nil unless contributor_id

    name = contributor_name(block['contributors'], contributor_id)
    return nil unless name

    Identity.new(team_id, contributor_id, name, repo_id)
  rescue StandardError
    nil
  end

  private

  # The parsed `contributors_team` block (a Hash with team_id,
  # public_key_ed25519, contributors: [{id,name},...]) or nil if absent/malformed.
  def team
    return @team if defined?(@team)

    root = repo_root
    @team = nil
    if root
      front = ChangeFrontmatter.parse_file(File.join(root, 'CHANGE.md'))
      block = front['contributors_team']
      @team = block if block.is_a?(Hash) && block['team_id']
    end
    @team
  rescue StandardError
    @team = nil
  end

  # The stable, remote-agnostic repo id per section 9.2: the git origin remote
  # (or the first remote) normalized to `host/path` so SSH and HTTPS clones of
  # the same repo collapse to one value (e.g. `github.com/acme/web`). nil when
  # there is no remote.
  def repo_id
    return @repo_id if defined?(@repo_id)

    url = remote_url
    @repo_id = url ? normalize_remote(url) : nil
  end

  # The locally configured contributor_id for a team, read from the one-line
  # file cf-team-join writes (section 4.2), or nil when this machine has not
  # joined the team.
  def local_contributor_id(team_id)
    path = contributor_id_path(team_id)
    return nil unless File.exist?(path)

    value = File.read(path).strip
    value.empty? ? nil : value
  rescue StandardError
    nil
  end

  # Resolve a contributor_id to its registered display name using the block's
  # `contributors` list, or nil when the id is not registered.
  def contributor_name(contributors, contributor_id)
    return nil unless contributors.is_a?(Array)

    entry = contributors.find { |c| c.is_a?(Hash) && c['id'].to_s == contributor_id.to_s }
    (entry && entry['name']) ? entry['name'].to_s : nil
  end

  # Local path holding just the contributor_id string, written by cf-team-join.
  def contributor_id_path(team_id)
    File.join(Dir.home, '.claude', 'cf', 'teams', team_id.to_s, 'contributor_id')
  end

  def git(*args) = ShellGit.run(@start_dir, *args)

  def remote_url
    root = repo_root
    return nil unless root

    url = git('remote', 'get-url', 'origin')
    return url if url && !url.empty?

    first = git('remote')
    return nil unless first && !first.empty?

    name = first.lines.first.to_s.strip
    return nil if name.empty?

    out = git('remote', 'get-url', name)
    (out && !out.empty?) ? out : nil
  end

  # Collapse an SSH or HTTPS remote to a stable `host/path` (no scheme, no user,
  # no trailing `.git`) so both forms of the same repo normalize identically.
  def normalize_remote(url)
    value = url.strip.sub(/\.git\z/, '')

    case value
    when %r{\Agit@([^:]+):(.+)\z}                      # git@github.com:acme/web
      "#{Regexp.last_match(1)}/#{Regexp.last_match(2)}"
    when %r{\Assh://(?:[^@/]+@)?([^/]+)/(.+)\z}         # ssh://git@github.com/acme/web
      "#{Regexp.last_match(1)}/#{Regexp.last_match(2)}"
    when %r{\A[a-z]+://(?:[^@/]+@)?([^/]+)/(.+)\z}      # https://github.com/acme/web
      "#{Regexp.last_match(1)}/#{Regexp.last_match(2)}"
    else
      value
    end
  end
end
