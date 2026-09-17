#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'

# Shared plumbing for the two content-diff merge hooks (change_stale_remind.rb,
# change_post_merge_check.rb): resolving the repo root, the PR a `gh pr merge`
# command targets, and fetching a branch before diffing against it.
module ChangePrFacts
  module_function

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
