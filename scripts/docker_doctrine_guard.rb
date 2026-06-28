#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'

# PreToolUse hook: denies a Bash command that stands up a project service as a
# host or system-level daemon (Homebrew or a bare daemon binary), the action the
# pst:docker doctrine forbids. The doctrine ships as a file-gated skill, so it
# only surfaced when a Dockerfile/compose/Brewfile was edited; the violation that
# prompted this (a Homebrew Caddy running where a Docker Caddy already won) was a
# `brew` command in a session that touched none of those files, so no skill fired.
# A guard keyed on the COMMAND, not the files, closes that gap: it intercepts at
# the one moment the doctrine is actually broken, regardless of what is open.
#
# Like the other guards here this is a loud guardrail, not a sandbox. It matches
# only the known service daemons (the same set the skill's CI grep names), so
# `brew install jq` or `brew services list` pass untouched, and it is bypassable
# (PST_ALLOW_HOSTDAEMON=1) for the rare genuinely-not-project-work case.
class DockerDoctrineGuard
  EVENT = 'PreToolUse'

  # Service names whose host daemon belongs in a container instead. Kept in sync
  # with the brew-services grep in skills/docker/SKILL.md; that doc is the rubric,
  # this is its enforcement at the point of action.
  SERVICES = %w[
    postgres postgresql redis mysql mariadb mongo mongodb
    caddy nginx httpd apache apache2 rabbitmq memcached elasticsearch
  ].freeze

  # A command RUNS a service daemon (not merely mentions one) only when the
  # program sits at a command position: the start of the line or just after a
  # shell separator, optionally behind sudo. Anchoring keeps the guard off mere
  # mentions (a commit message, `grep redis-server`, a `docker run caddy:2`
  # argument) and on real invocations. Group 1 is the offending command for the
  # deny reason.
  ANCHOR = '(?:\A|[\n;&|])\s*(?:sudo\s+)?'

  # Each pattern is a way to run a project service as a host daemon: `brew
  # install`/`services` for a named service; a bare server binary; `caddy
  # run`/`start`. Stopping at &|; keeps the brew match inside one command so a
  # downstream `| grep caddy` does not pull a service name into the match.
  PATTERNS = [
    /#{ANCHOR}(brew\s+(?:install|services)\b[^&|;]*\b(?:#{Regexp.union(SERVICES).source})\b)/i,
    /#{ANCHOR}((?:initdb|pg_ctl|redis-server|mysqld|mongod|memcached)\b)/,
    /#{ANCHOR}(caddy\s+(?:run|start)\b)/i
  ].freeze

  def initialize(event) = @event = event

  def emit(io = $stdout)
    return if ENV['PST_ALLOW_HOSTDAEMON'] == '1'
    return unless @event['tool_name'] == 'Bash'

    offender = offending_snippet(command)
    return unless offender

    io.puts(JSON.generate(deny(offender)))
  rescue StandardError
    nil
  end

  private

  def command
    input = @event['tool_input']
    input.is_a?(Hash) ? input['command'].to_s : ''
  end

  # The offending command (capture group 1, without the leading separator) of the
  # first matching pattern, so the deny reason names exactly what to containerize.
  def offending_snippet(cmd)
    PATTERNS.filter_map { |pattern| cmd.match(pattern)&.captures&.first }.first
  end

  def deny(offender)
    {
      hookSpecificOutput: {
        hookEventName: EVENT,
        permissionDecision: 'deny',
        permissionDecisionReason:
          "[pst:docker] '#{offender.strip}' runs a project service as a host or system daemon. " \
          'Run it in a dedicated Docker container (a Compose service or docker run), not Homebrew or a host daemon. ' \
          'Set PST_ALLOW_HOSTDAEMON=1 only if this is genuinely not project work.'
      }
    }
  end
end

DockerDoctrineGuard.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
