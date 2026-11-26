#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'change_autopilot'

# PreToolUse hook: denies a Bash command that stands up a project service as a
# host or system-level daemon. That means Homebrew or a bare daemon binary, the
# action the cf:docker doctrine forbids. The doctrine ships as a file-gated skill, so it
# only surfaced when a Dockerfile/compose/Brewfile was edited; the violation that
# prompted this (a Homebrew Caddy running where a Docker Caddy already won) was a
# `brew` command in a session that touched none of those files, so no skill fired.
# A guard keyed on the COMMAND, not the files, closes that gap: it intercepts at
# the one moment the doctrine is actually broken, regardless of what is open.
#
# Like the other guards here this is a loud guardrail, not a sandbox. It matches
# only the known service daemons (the same set the skill's CI grep names), so
# `brew install jq` or `brew services list` pass untouched, and it is bypassable
# (CF_ALLOW_HOSTDAEMON=1) for the rare genuinely-not-project-work case.
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

  # A launchd or systemd user unit is a host daemon when it keeps a service
  # running. A one-shot scheduler entry (a timer or calendar job that starts,
  # runs and exits, like the triage tick) is not. So the scheduler commands are
  # denied only when they name a project service or the command text declares a
  # long-running unit (KeepAlive, Restart=always or on-failure, a RunAtLoad
  # that is true). A bare `launchctl load` of an unnamed plist passes, since the
  # plist is not in the command.
  SCHEDULER = /#{ANCHOR}((?:launchctl|systemctl\s+--user)\s+(?:load|bootstrap|submit|enable|start|restart|kickstart)\b[^&|;]*)/i
  LONG_RUNNING = /KeepAlive|Restart\s*=\s*(?:always|on-failure|on-success|on-abnormal|on-abort|on-watchdog)|<key>RunAtLoad<\/key>\s*<true\s*\/>/i
  SERVICE_NAME = /\b(?:#{Regexp.union(SERVICES).source})\b/i

  # The offending command in `cmd`, or nil. Public so cf:change can refuse a
  # boot step or command lane entry that would start a host daemon, at config
  # load, with the same pattern list this hook enforces at the Bash tool.
  def self.match(cmd)
    PATTERNS.filter_map { |pattern| cmd.to_s.match(pattern)&.captures&.first }.first&.strip || scheduler_daemon(cmd.to_s)
  end

  # The scheduler command when it stands up a long-running unit or a named
  # project service, nil for a one-shot scheduler entry.
  def self.scheduler_daemon(cmd)
    found = cmd.match(SCHEDULER)&.captures&.first&.strip
    found if found && (found.match?(SERVICE_NAME) || cmd.match?(LONG_RUNNING))
  end

  def initialize(event) = @event = event

  def emit(io = $stdout)
    return if ENV['CF_ALLOW_HOSTDAEMON'] == '1'
    return unless @event['tool_name'] == 'Bash'

    offender = offending_snippet(command)
    return unless offender
    # An autopilot naming host_daemon acts like CF_ALLOW_HOSTDAEMON=1.
    return if autopilot_waives?(offender)

    io.puts(JSON.generate(deny(offender)))
  rescue StandardError
    nil
  end

  private

  def command
    input = @event['tool_input']
    input.is_a?(Hash) ? input['command'].to_s : ''
  end

  def autopilot_waives?(offender)
    !ChangeAutopilot.waive!('host_daemon', guard: 'docker_doctrine_guard', detail: offender, command: command, session: @event['session_id']).nil?
  end

  # The offending command (capture group 1, without the leading separator) of the
  # first matching pattern, so the deny reason names exactly what to containerize.
  def offending_snippet(cmd) = self.class.match(cmd)

  def deny(offender)
    {
      hookSpecificOutput: {
        hookEventName: EVENT,
        permissionDecision: 'deny',
        permissionDecisionReason:
          "[cf:docker] '#{offender.strip}' runs a project service as a host or system daemon. " \
          'Run it in a dedicated Docker container (a Compose service or docker run), not Homebrew or a host daemon. ' \
          'Set CF_ALLOW_HOSTDAEMON=1 only if this is genuinely not project work.'
      }
    }
  end
end

if __FILE__ == $PROGRAM_NAME
  event = HookEvent.read
  HookEvent.instrument('docker_doctrine_guard', event) { DockerDoctrineGuard.new(event).emit }
end
