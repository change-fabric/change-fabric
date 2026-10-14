#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'shell_git'

# The git and GitHub facts a run is identified by: branch, head commit, its
# subject line, and the pull request it belongs to. Shared by the artifact
# manifest and the QA coverage record so both name a run the same way.
#
# Git is asked first. A CI checkout is usually a detached HEAD, so when git
# reports the branch as `HEAD` the GitHub Actions variables fill in:
# GITHUB_HEAD_REF (set on pull_request events), then GITHUB_REF_NAME. The sha
# falls back to GITHUB_SHA only when git has none, and a PR number is read
# from a GITHUB_REF of the form `refs/pull/N/merge` when `gh` has no answer.
#
# Every lookup is best-effort: a missing `gh`, an unauthenticated one, or a
# branch with no PR yields a nil field, never an exception.
class ChangeGitContext
  PULL_REF = %r{\Arefs/pull/(\d+)/merge\z}
  DEFAULT_TRUNK = 'main'

  # `{branch, sha, short_sha, subject, pr}` with string keys; `pr` is
  # `{number, url}` or nil.
  def self.read(repo_root, env: ENV, gh: 'gh') = new(repo_root, env:, gh:).to_h

  # The trunk branch when CHANGE.md does not name one: what origin/HEAD points
  # at, else `main`.
  def self.trunk_default(repo_root)
    ref = ShellGit.run(repo_root, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD').to_s
    trunk = ref.delete_prefix('origin/')
    trunk.empty? ? DEFAULT_TRUNK : trunk
  end

  # The committer time of HEAD, or nil outside a repo. An imported CI file
  # older than this describes an earlier commit.
  def self.head_commit_time(repo_root)
    stamp = ShellGit.run(repo_root, 'log', '-1', '--format=%ct').to_s
    stamp.match?(/\A\d+\z/) ? Time.at(stamp.to_i).utc : nil
  end

  # The origin remote URL with any `user:token@` userinfo removed, or nil.
  def self.origin_url(repo_root) = sanitize_url(ShellGit.run(repo_root, 'remote', 'get-url', 'origin'))

  # Strips userinfo from a scheme URL so a credential never lands in a record.
  # An scp-style remote (`git@host:org/repo.git`) has no scheme and carries no
  # secret, so it is left as is.
  def self.sanitize_url(url)
    text = url.to_s.strip
    return nil if text.empty?

    text.sub(%r{\A([a-z][a-z0-9+.-]*://)[^/@]*@}i, '\1')
  end

  def initialize(repo_root, env: ENV, gh: 'gh')
    @repo_root = repo_root
    @env = env
    @gh = gh
  end

  def to_h
    {
      'branch' => branch, 'sha' => sha, 'short_sha' => short_sha,
      'subject' => subject, 'pr' => pr
    }
  end

  def branch
    name = git('rev-parse', '--abbrev-ref', 'HEAD')
    return name unless name.nil? || name == 'HEAD'

    env_value('GITHUB_HEAD_REF') || env_value('GITHUB_REF_NAME') || name
  end

  def sha = @sha ||= git('rev-parse', 'HEAD') || env_value('GITHUB_SHA')

  def short_sha = sha && sha[0, 7]

  def subject = git('log', '-1', '--pretty=%s')

  # `{number, url}` from `gh`, else the number from GITHUB_REF, else nil.
  def pr
    found = pull_request
    return { 'number' => found['number'], 'url' => found['url'] } if found

    number = env_value('GITHUB_REF').to_s[PULL_REF, 1]
    number && { 'number' => number.to_i, 'url' => nil }
  end

  # The full `gh pr view` answer (number, url, title) for the repo's current
  # branch, or nil. Run in the repo, not the process cwd, so a sweep started
  # from elsewhere still asks about the right checkout.
  def pull_request
    return @pull_request if defined?(@pull_request)

    out, status = Open3.capture2e(@gh, 'pr', 'view', '--json', 'number,url,title', chdir: @repo_root.to_s)
    @pull_request = status.success? ? JSON.parse(out) : nil
  rescue StandardError
    @pull_request = nil
  end

  private

  def git(*args)
    out = ShellGit.run(@repo_root, *args)
    out.nil? || out.empty? ? nil : out
  end

  def env_value(name)
    value = @env[name].to_s.strip
    value.empty? ? nil : value
  end
end
