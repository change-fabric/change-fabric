#!/usr/bin/env ruby
# frozen_string_literal: true

# Advisory guardrail, not airtight enforcement: it inspects the Bash command
# text (plus the current branch, for bare pushes). It catches the obvious cases
# and is trivially bypassable (env-var indirection, `git -c`, non-Bash tools).
# It exists to make an accidental violation of the chosen mode loud, not to
# sandbox.
class GuardedCommand
  PUSH = /\bgit\s+push\b/
  MERGE = /\bgh\s+pr\s+merge\b/
  PR_CREATE = /\bgh\s+pr\s+create\b/
  TRUNK = %w[main master].freeze

  def initialize(command, mode, branch: nil)
    @command = command.to_s
    @mode = mode
    @branch = branch.to_s
  end

  def violation
    case @mode
    when 'Local only'
      return 'git push' if push?
      return 'gh pr merge' if merge?
    when 'Merge ready'
      return 'a direct push to the trunk' if push_to_trunk?
      return 'gh pr merge' if merge?
    when 'Yolo'
      return 'gh pr create' if pr_create?
    end
    nil
  end

  private

  def push?
    @command.match?(PUSH)
  end

  def merge?
    @command.match?(MERGE)
  end

  def pr_create?
    @command.match?(PR_CREATE)
  end

  # Merge ready allows pushing a feature branch but never the trunk, which would
  # land changes without a PR. An explicit `main`/`master` refspec is a trunk
  # push; so is a bare `git push` while the current branch is the trunk.
  def push_to_trunk?
    return false unless push?

    destinations = push_destinations
    return trunk?(@branch) if destinations.empty?

    destinations.any? { |dest| trunk?(dest) }
  end

  # Branch names the push would update on the remote. A bare push (no refspec)
  # returns [] and is resolved against the current branch by the caller.
  def push_destinations
    tokens = @command.split
    push_index = tokens.index('push')
    return [] unless push_index

    positionals = tokens[(push_index + 1)..].reject { |t| t.start_with?('-') }
    refspecs = positionals.drop(1) # first positional is the remote
    refspecs.map { |spec| destination_of(spec) }
  end

  def destination_of(refspec)
    dest = refspec.include?(':') ? refspec.split(':', 2).last : refspec
    dest == 'HEAD' ? @branch : dest
  end

  def trunk?(name)
    TRUNK.include?(name.to_s)
  end
end
