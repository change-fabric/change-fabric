#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'

# PreToolUse hook: denies a Bash `git push` to a GitHub remote when a commit being
# pushed carries a non-noreply author or committer email, which would publish a
# real address. GitHub's own email-privacy setting rejects this server-side; this
# guard catches it client-side so the push is never attempted with the wrong
# identity. Like the merge-mode guard it is advisory, not a sandbox: it inspects
# the command and the git state, and is trivially bypassable (git -c, env-var
# indirection). It exists to make an accidental identity slip loud.
#
# Only GitHub remotes are guarded. A non-GitHub remote (for example the ctx
# store's sync remote) is left alone, so a deliberately non-GitHub identity (the
# ctx system author) still pushes there.

# Pure decision: given the command text, the resolved remote URL, and the emails
# of the commits to be pushed, return the first offending email or nil.
class NoreplyCheck
  PUSH = /\bgit\s+push\b/
  GITHUB = /github\.com/i
  NOREPLY = /@users\.noreply\.github\.com\z/i

  def initialize(command:, remote_url:, author_emails:)
    @command = command.to_s
    @remote_url = remote_url.to_s
    @author_emails = Array(author_emails)
  end

  def offending_email
    return nil unless @command.match?(PUSH)
    return nil unless @remote_url.match?(GITHUB)

    @author_emails.find { |email| !email.to_s.match?(NOREPLY) }
  end
end

# Resolves the git facts the check needs, by shelling out in the current repo.
# Every call fails open (returns empty) so a non-repo or a git error never blocks
# an unrelated command.
class GitFacts
  def remote_url(remote)
    name = remote.to_s
    return name if name.include?('://') || name.include?('@')

    `git remote get-url #{name} 2>/dev/null`.strip
  end

  # Author and committer emails of the commits this push would publish: those
  # reachable from HEAD but not already on any remote-tracking branch. Excluding
  # everything already pushed (rather than diffing the branch's own upstream)
  # keeps a rebase onto a newer trunk from flagging trunk commits that are
  # already on the remote, and still covers a fresh branch with no upstream.
  def author_emails
    `git log HEAD --not --remotes --format=%ae%n%ce 2>/dev/null`.split("\n").map(&:strip).reject(&:empty?).uniq
  end
end

class NoreplyGuard
  EVENT = 'PreToolUse'

  def initialize(event, git: GitFacts.new)
    @event = event
    @git = git
  end

  def emit(io = $stdout)
    return unless @event['tool_name'] == 'Bash'

    cmd = command
    return unless cmd&.match?(NoreplyCheck::PUSH)

    bad = NoreplyCheck.new(command: cmd, remote_url: @git.remote_url(remote_name(cmd)),
                           author_emails: @git.author_emails).offending_email
    return unless bad

    io.puts(JSON.generate(deny(bad)))
  end

  private

  def command
    input = @event['tool_input']
    input.is_a?(Hash) ? input['command'] : nil
  end

  # The remote the push targets: the first non-flag token after `push`, or origin.
  def remote_name(cmd)
    tokens = cmd.split
    after = tokens[(tokens.index('push') + 1)..] || []
    after.find { |token| !token.start_with?('-') } || 'origin'
  end

  def deny(email)
    {
      hookSpecificOutput: {
        hookEventName: EVENT,
        permissionDecision: 'deny',
        permissionDecisionReason: "[pst] GitHub push blocked: commit author #{email} is not a " \
          '@users.noreply.github.com identity and would expose a real email. Re-author with your ' \
          'GitHub noreply email (git commit --amend --reset-author after setting the global ' \
          'user.email), and never pass a -c user.email override on a GitHub push.'
      }
    }
  end
end

NoreplyGuard.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
