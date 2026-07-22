#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'

# Read-only classifier behind cf:prune's step 3. Runs the same git checks the
# skill used to ask an agent to run by hand (rev-list count, diff against
# trunk, worktree cleanliness) and returns one verdict per local branch. It
# only decides; deleting anything still goes through the skill's
# AskUserQuestion gates.
module BranchClassify
  Result = Data.define(:branch, :kind, :unmerged_count, :dirty, :upstream)

  class TrunkUnresolved < StandardError; end

  module_function

  # trunk is a short name ("main"), matched against origin/<trunk>. Raises
  # TrunkUnresolved if that ref does not exist (unfetched, wrong name, or the
  # remote has no such branch) rather than guessing a baseline to diff against.
  def run(trunk, dir: Dir.pwd)
    raise TrunkUnresolved, trunk unless ref_exists?(dir, "origin/#{trunk}")

    worktree_by_branch = worktree_branches(dir)
    local_branches(dir).reject { |branch| branch == trunk }.map do |branch|
      classify(dir, trunk, branch, worktree_by_branch[branch])
    end
  end

  def classify(dir, trunk, branch, worktree_path)
    dirty = worktree_path ? dirty?(worktree_path) : false
    count = unmerged_count(dir, trunk, branch)
    kind =
      if dirty then 'rogue'
      elsif count.zero? then 'prunable'
      elsif no_diff?(dir, trunk, branch) then 'squash_merged'
      else 'rogue'
      end
    Result.new(branch:, kind:, unmerged_count: count, dirty:, upstream: upstream_of(dir, branch))
  end

  def ref_exists?(dir, ref)
    _out, status = git(dir, 'rev-parse', '--verify', '-q', ref)
    status.success?
  end

  def local_branches(dir)
    out, status = git(dir, 'for-each-ref', '--format=%(refname:short)', 'refs/heads')
    status.success? ? out.each_line.map(&:strip).reject(&:empty?) : []
  end

  # Maps branch name -> worktree path, for local branches currently checked
  # out somewhere. A detached-HEAD worktree contributes nothing (no branch
  # name to key on), so it never masks a branch's dirty state.
  def worktree_branches(dir)
    out, status = git(dir, 'worktree', 'list', '--porcelain')
    return {} unless status.success?

    path = nil
    out.each_line.with_object({}) do |line, map|
      case line
      when /^worktree (.+)$/ then path = Regexp.last_match(1).strip
      when /^branch refs\/heads\/(.+)$/ then map[Regexp.last_match(1).strip] = path
      end
    end
  end

  def dirty?(worktree_path)
    out, status = git(worktree_path, 'status', '--porcelain')
    !status.success? || !out.strip.empty?
  end

  def unmerged_count(dir, trunk, branch)
    out, status = git(dir, 'rev-list', '--count', "origin/#{trunk}..#{branch}")
    status.success? ? out.strip.to_i : Float::INFINITY
  end

  # Tip-to-tip diff, not three-dot: three-dot diffs from the merge-base and
  # ignores what trunk did since, so it can't tell a squash merge landed. A
  # direct diff of the two tips is empty exactly when trunk's tree already
  # matches the branch's, whatever the merge shape.
  def no_diff?(dir, trunk, branch)
    _out, status = git(dir, 'diff', '--quiet', "origin/#{trunk}", branch)
    status.success?
  end

  def upstream_of(dir, branch)
    out, status = git(dir, 'for-each-ref', '--format=%(upstream:short)', "refs/heads/#{branch}")
    return nil unless status.success?

    out.strip.empty? ? nil : out.strip
  end

  def git(dir, *args) = Open3.capture2e('git', '-C', dir, *args)

  class CLI
    def self.run(argv, out: $stdout)
      trunk = argv.first
      return out.puts('usage: branch_classify.rb <trunk>') if trunk.to_s.empty?

      results = BranchClassify.run(trunk)
      out.puts(JSON.generate(results.map { |r| r.to_h.merge(unmerged_count: finite(r.unmerged_count)) }))
    rescue BranchClassify::TrunkUnresolved => e
      out.puts(JSON.generate(error: 'trunk_unresolved', trunk: e.message))
    end

    def self.finite(count)
      count.infinite? ? -1 : count
    end
  end
end

BranchClassify::CLI.run(ARGV) if __FILE__ == $PROGRAM_NAME
