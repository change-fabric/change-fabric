#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'

# Content-based completeness check, shared by the pre-merge staleness warning
# and the post-merge drop check. Ancestry (`merge-base --is-ancestor`,
# `git log a..b`) cannot answer either question once a squash merge is in the
# picture: a squash-merged child's commits never appear on trunk, and a
# squashed PR's commits collapse into one trunk commit that carries no
# guarantee it kept every file the PR head had.
#
# The primitive is `git merge-tree`: merge `other_ref` into `base_ref` purely
# in memory. A file `git merge-tree` reports conflicted is one `base_ref`
# already intentionally diverges on -- an ordinary conflict for a human to
# resolve, not something missing. A file the merge folds in cleanly, whose
# merged content differs from what `base_ref` already has, is content
# `other_ref` carries that `base_ref` lacks and does not contest: exactly the
# staleness and drop shapes ancestry cannot see.
module ChangeStaleContentCheck
  Result = Data.define(:missing_files, :conflicted_files)

  module_function

  # `base_ref` is the version being checked for completeness (a PR head
  # pre-merge, the new trunk tip post-merge). `other_ref` is the version it
  # should already reflect (trunk pre-merge, the PR head post-merge).
  #
  # `require_base_changed` narrows the finding to files `base_ref` itself
  # also changed. Without it, any file `other_ref` touched that `base_ref`
  # never went near would be reported "missing" -- true by construction (a
  # branch cut before another merge lacks that content) but never actually at
  # risk: a squash merge applies only `base_ref`'s own diff, so a file it
  # never touches cannot be reverted by merging it. The pre-merge staleness
  # check wants the narrowed form for exactly that reason; the post-merge
  # drop check does not, because there `other_ref` (the merged PR head) is
  # already the only side whose changes matter.
  def missing_from(base_ref, other_ref, dir: Dir.pwd, require_base_changed: false)
    tree_oid, conflicted = merge_tree(base_ref, other_ref, dir)
    return Result.new(missing_files: [], conflicted_files: conflicted) if tree_oid.nil?

    changed = other_ref_changes(base_ref, other_ref, dir)
    changed &= other_ref_changes(other_ref, base_ref, dir) if require_base_changed
    missing = changed.reject { |path| conflicted.include?(path) }
                      .select { |path| differs_from_base?(dir, tree_oid, base_ref, path) }
    Result.new(missing_files: missing, conflicted_files: conflicted)
  end

  # [tree_oid, conflicted_paths]. tree_oid is nil when merge-tree itself
  # could not run at all (bad refs, no repo): the caller then has nothing to
  # compare and reports no findings rather than guessing.
  def merge_tree(base_ref, other_ref, dir)
    out, _err, status = Open3.capture3('git', '-C', dir, 'merge-tree', '--write-tree', '--name-only', '-z',
                                        base_ref, other_ref)
    fields = out.split("\0")
    return [ nil, [] ] if fields.empty?

    tree_oid = fields.first
    return [ tree_oid, [] ] if status.success?

    [ tree_oid, conflicted_paths(fields) ]
  rescue StandardError
    [ nil, [] ]
  end

  # The machine-readable conflict format lists conflicted paths right after
  # the tree oid, terminated by an empty field, before the per-file message
  # sections start.
  def conflicted_paths(fields)
    fields[1..].take_while { |field| !field.to_s.empty? }.uniq
  end

  # Paths `other_ref` itself changed relative to its merge-base with
  # `base_ref` -- the only files that can plausibly be "missing", since a
  # file `other_ref` never touched cannot carry a fix or a drop.
  def other_ref_changes(base_ref, other_ref, dir)
    base_sha, status = Open3.capture2e('git', '-C', dir, 'merge-base', base_ref, other_ref)
    return [] unless status.success?

    out, status = Open3.capture2e('git', '-C', dir, 'diff', '--name-only', base_sha.strip, other_ref)
    status.success? ? out.each_line.map(&:strip).reject(&:empty?) : []
  end

  # True when the merged tree's content for `path` differs from what
  # `base_ref` already has there -- either because `base_ref` still has the
  # pre-fix content, or because `base_ref` never had the file at all.
  def differs_from_base?(dir, tree_oid, base_ref, path)
    merged = blob_at(dir, tree_oid, path)
    current = blob_at(dir, base_ref, path)
    merged != current
  end

  def blob_at(dir, treeish, path)
    out, status = Open3.capture2e('git', '-C', dir, 'show', "#{treeish}:#{path}")
    status.success? ? out : nil
  end
end
