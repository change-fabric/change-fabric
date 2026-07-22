#!/usr/bin/env ruby
# frozen_string_literal: true

require 'shellwords'

# Advisory guardrail, not airtight enforcement: it inspects the Bash command
# text (plus the current branch, for bare pushes). It catches the obvious cases
# and is trivially bypassable (env-var indirection, `git -c`, non-Bash tools).
# It exists to make an accidental violation of the chosen mode loud, not to
# sandbox.
class GuardedCommand
  TRUNK = %w[main master].freeze

  # Tokenizes via Shellwords, so a quoted string (a commit message, a PR body)
  # collapses into one token instead of leaking its words into the surrounding
  # command - "gh pr edit --body 'run gh pr merge later'" never looks like an
  # invocation of `gh pr merge`.
  def self.tokens(command)
    Shellwords.split(command.to_s)
  rescue ArgumentError
    command.to_s.split
  end

  # True when `words` appear as an exact contiguous run of tokens.
  def self.invokes?(command, *words)
    tokens(command).each_cons(words.size).any? { |window| window == words }
  end

  def self.push?(command) = invokes?(command, 'git', 'push')
  def self.merge?(command) = invokes?(command, 'gh', 'pr', 'merge')
  def self.pr_create?(command) = invokes?(command, 'gh', 'pr', 'create')

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
    self.class.push?(@command)
  end

  def merge?
    self.class.merge?(@command)
  end

  def pr_create?
    self.class.pr_create?(@command)
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
