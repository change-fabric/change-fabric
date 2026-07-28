#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'skill_store'

# SessionStart hook: injects the handful of cf tenets that hold for an ENTIRE
# session regardless of which files are open, distilled to one line each. The
# heavyweight rubrics (cf:typescript, cf:ruby, ...) stay file-gated because they
# only matter when you touch a matching file; these few are surface-anywhere, so a
# file-edit trigger surfaces them too late or not at all. This is the proactive
# complement to the guards: glyph_guard and docker_doctrine_guard deny a violation
# after the fact, the digest states the rule up front so the work avoids it.
#
# Kept deliberately short. The whole point of the ctx-surfacing budget work is
# that standing SessionStart context is scarce, so this is a few lines, not a
# rehearsal of every rubric. Announced once per session, mirroring skill_detect.
class DoctrineDigest
  EVENT = 'SessionStart'
  MARKER = 'doctrine-digest'

  TENETS = [
    'Containerize project services (datastores, reverse proxies like Caddy/nginx, runtimes) ' \
    'in dedicated per-use-case Docker containers. Never a host or system-level daemon ' \
    '(no brew install/services for them) and never a global install.',
    'Author every outbound surface (code, prose, commits, PRs, comments) without AI-slop ' \
    'glyphs (no em-dash, bullet, ellipsis, or smart quotes) or agent attribution footers.',
    'PR titles <= 60 chars. PR descriptions <= 640 chars, unless a bona fide reason needs ' \
    'more (a code snippet, a test-plan checklist); the core description should still stay ' \
    'inside 640 chars even then.'
  ].freeze

  # Only relevant while working on this toolkit itself: a client's own repo
  # mentioning its own name is normal, so this tenet would be noise (and
  # misleading, citing a file convention scoped to this repo) anywhere else.
  CF_REPO_TENET =
    'This toolkit is shared across projects: keep authored output generic, no specific ' \
    'client, customer, or downstream-project name or domain. Maintain your own flagged-term ' \
    'list at ~/.claude/cf/sensitive_terms.txt.'

  CF_REPO_REMOTE = %r{[/:]pstaylor-patrick/change-fabric(?:\.git)?\b}i

  POINTER = 'File-type rubrics (TypeScript, Ruby, Rails, React, ...) auto-apply as you edit matching files.'

  def initialize(event, remote_v: -> { `git remote -v 2>/dev/null` })
    @event = event
    @remote_v = remote_v
  end

  def emit(io = $stdout)
    return unless announce?

    io.puts(JSON.generate(context))
  rescue StandardError
    nil
  end

  private

  def tenets
    cf_toolkit_repo? ? TENETS + [ CF_REPO_TENET ] : TENETS
  end

  def cf_toolkit_repo?
    @remote_v.call.to_s.lines.any? { |line| line.match?(CF_REPO_REMOTE) }
  end

  # Once per session: SessionStart also fires on resume and clear, and the tenets
  # do not change within a session, so a second injection would be pure noise.
  def announce?
    store = SkillStore.new(@event['session_id'], MARKER)
    fresh = store.fresh([ MARKER ]) == [ MARKER ]
    store.mark([ MARKER ]) if fresh
    fresh
  end

  def context
    body = tenets.map { |tenet| "- #{tenet}" }.join("\n")
    text = "[cf] Session doctrine (applies all session, not just on matching edits):\n#{body}\n#{POINTER}"
    { hookSpecificOutput: { hookEventName: EVENT, additionalContext: text } }
  end
end

DoctrineDigest.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
