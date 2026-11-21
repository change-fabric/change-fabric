#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'resource_gate'

# PreToolUse hook (advisory): before an Agent or Task spawn, read RAM and free
# disk with the resource gate's own readers and warn in additionalContext when
# the machine is below the floor. It never denies, never reclaims and never
# exits nonzero. The gate fails closed on a bad reading; this hook is the
# opposite on purpose (hooks fail silent), so a reading that fails produces no
# warning at all. When a workflow did not declare FANOUT, the live linked
# worktrees under the repo stand in for the planned worktree count.
# Disabled with CF_RESOURCE_GUARD=0.
class ResourceFloorGuard
  EVENT = 'PreToolUse'
  TOOLS = %w[Agent Task].freeze
  HOOK_TIMEOUT = 3

  def initialize(event, gate: nil, worktrees: nil, env: ENV)
    @event = event
    @env = env
    @gate = gate
    @worktrees = worktrees
  end

  def emit(io = $stdout)
    text = warning
    io.puts(JSON.generate(hookSpecificOutput: { hookEventName: EVENT, additionalContext: text })) if text
  rescue StandardError
    nil
  end

  # The warning text, or nil when the spawn is fine or cannot be judged.
  def warning
    return nil if @env['CF_RESOURCE_GUARD'] == '0'
    return nil unless TOOLS.include?(@event['tool_name'])

    result = (@gate || build_gate).check(worktrees: live_worktrees, reclaim_safe: false)
    return nil if result.exit_code != 3

    message(result.json)
  rescue StandardError
    nil
  end

  private

  def project = File.realpath(@event['cwd'].to_s.empty? ? Dir.pwd : @event['cwd'])

  def live_worktrees
    @worktrees ||= begin
      listing = ResourceGate::Runner.new(timeout: HOOK_TIMEOUT).call('worktrees', 'git', '-C', project, 'worktree', 'list', '--porcelain')
      [ listing.scan(/^worktree /).length, 1 ].max
    rescue StandardError
      1
    end
  end

  def build_gate
    platform = ResourceGate.platform
    runner = ResourceGate::Runner.new(timeout: HOOK_TIMEOUT)
    floors = ResourceGate::Floors.new(platform: platform, repo_file: ResourceGate.defaults_file,
                                      user_file: ResourceGate::USER_FLOORS_FILE, env: @env)
    ResourceGate::Gate.new(project: project, floors: floors, platform: platform,
                           mem: ResourceGate::MemReader.new(platform: platform, runner: runner),
                           disk: ResourceGate::DiskReader.new(runner: runner),
                           profile: ResourceGate.load_profile(project))
  end

  def message(json)
    need = json[:need] || {}
    "[cf resource floors] Below the resource floor before this spawn: #{json[:ram_available_mb]} MB RAM available, " \
      "#{json[:disk_free_gb]} GB disk free (need about #{need[:ram_mb]} MB RAM, #{need[:disk_gb]} GB disk). " \
      'Run `ruby ~/.claude/cf/bin/resource_gate.rb check --json --reclaim-safe` first, and stop if it still reports ok false. ' \
      'Advisory only; CF_RESOURCE_GUARD=0 silences this.'
  end
end

ResourceFloorGuard.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
