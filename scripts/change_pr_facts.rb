#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'

# Shared plumbing for the two content-diff merge hooks (change_stale_remind.rb,
# change_post_merge_check.rb): resolving the repo root, the PR a `gh pr merge`
# command targets, and fetching a branch before diffing against it.
module ChangePrFacts
  # Raised when the PR facts cannot be read completely; callers fail closed.
  class Unreadable < StandardError; end

  # The approval console signs at most this many files (Canonical::MAX_FILES).
  MAX_FILES = 3000
  PR_URL = %r{\Ahttps://([^/\s]+)/([^/\s]+)/([^/\s]+)/pull/(\d+)/?\z}

  module_function

  # [host, owner, name, number] from a pull request URL, else nil.
  def parse_url(url) = PR_URL.match(url.to_s)&.captures

  # The console's repo identity for a PR URL's repository: repo:host/owner/name.
  def repo_id(url)
    host, owner, name, = require_pr_url(url)
    "repo:#{host}/#{owner}/#{name}"
  end

  # { sha:, base:, title: } from `gh pr view <url>`. The head sha is what the
  # approval binds; never the working tree's HEAD.
  def head(url, runner: method(:gh))
    out = runner.call('pr', 'view', url, '--json', 'headRefOid,baseRefName,title')
    data = JSON.parse(out)
    sha, base, title = data.values_at('headRefOid', 'baseRefName', 'title')
    raise Unreadable, "gh returned no head for #{url}" if [ sha, base, title ].any? { |v| v.to_s.strip.empty? }

    { sha: sha, base: base, title: title }
  rescue JSON::ParserError => e
    raise Unreadable, "gh pr view returned unreadable JSON (#{e.message})"
  end

  # The sorted, unique file names a PR changes, both `filename` and
  # `previous_filename` for a rename. Fails closed (Unreadable) at 3000 files
  # (the API limit), when the PR's own changed_files count is not matched by
  # the pages (a truncated page), or on any gh or JSON error.
  def files(url, runner: method(:gh))
    host, owner, name, number = require_pr_url(url)
    path = "repos/#{owner}/#{name}/pulls/#{number}"
    args = host == 'github.com' ? [] : [ '--hostname', host ]
    count = Integer(runner.call('api', *args, path, '--jq', '.changed_files').strip, 10)
    raise Unreadable, "#{url} changes #{count} files; the API lists at most #{MAX_FILES}" if count >= MAX_FILES

    entries = JSON.parse(runner.call('api', *args, "#{path}/files", '--paginate', '--slurp')).flatten
    raise Unreadable, "the file list for #{url} is truncated (#{entries.size} of #{count})" unless entries.size == count

    entries.flat_map { |entry| [ entry['filename'], entry['previous_filename'] ] }.compact.uniq.sort
  rescue JSON::ParserError, ArgumentError, TypeError => e
    raise Unreadable, "the file list for #{url} is unreadable (#{e.message})"
  end

  def require_pr_url(url) = parse_url(url) || raise(Unreadable, "#{url} is not a pull request URL")

  def gh(*args)
    out, status = Open3.capture2e('gh', *args)
    raise Unreadable, "gh #{args.first(2).join(' ')} failed: #{out.strip[0, 200]}" unless status.success?

    out
  rescue SystemCallError => e
    raise Unreadable, "gh is unavailable (#{e.message})"
  end

  def repo_root
    out, status = Open3.capture2e('git', 'rev-parse', '--show-toplevel')
    status.success? ? out.strip : nil
  rescue StandardError
    nil
  end

  def fetch(root, branch)
    Open3.capture2e('git', '-C', root, 'fetch', '--quiet', 'origin', branch)
  rescue StandardError
    nil
  end

  # [base_branch, head_sha] for the PR the command targets, or nil. Pass
  # `state: 'MERGED'` to require the PR be in that state, which
  # change_post_merge_check.rb uses to make sure a merge actually went
  # through before treating trunk as something that should already reflect
  # the head.
  def resolve(command, state: nil)
    ref = merge_ref(command)
    fields = %w[baseRefName headRefOid]
    fields.unshift('state') if state
    args = [ 'gh', 'pr', 'view' ]
    args << ref if ref
    args += [ '--json', fields.join(','), '-q', fields.map { |f| ".#{f}" }.join(' + "\t" + ') ]
    out, status = Open3.capture2e(*args)
    return nil unless status.success?

    values = out.strip.split("\t", fields.size)
    return nil if state && values.shift != state

    base, sha = values
    base && sha ? [ base, sha ] : nil
  rescue StandardError
    nil
  end

  def merge_ref(command)
    tokens = command.to_s.split
    idx = tokens.index('merge')
    return nil unless idx

    tokens[(idx + 1)..].find { |token| !token.start_with?('-') }
  end
end
