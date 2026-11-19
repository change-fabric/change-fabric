#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'model_roles'

# PreToolUse hook (advisory): a skill that spawns an agent as prose declares its
# role with a leading `[role:<role>]` tag. When the spawn's model differs from
# that role's model in the install snapshot, or the spawn names no model at all
# (it then inherits the orchestrator tier), warn in additionalContext. It never
# denies and never exits nonzero. It reads the snapshot only, never live env or
# user files, so it agrees with the skills install.rb rendered. Workflow
# agent() calls are linted statically instead (test/model_roles_lint_test.rb).
# Disabled with CF_MODEL_ROLE_GUARD=0.
class ModelRoleGuard
  EVENT = 'PreToolUse'
  TOOLS = %w[Agent Task].freeze
  HOST = 'claude'
  TAG = /\A\s*\[role:(?<role>[a-z]+)\]/

  def initialize(event, snapshot_path: ModelRoles.default_snapshot_path, env: ENV)
    @event = event
    @snapshot_path = snapshot_path
    @env = env
  end

  def emit(io = $stdout)
    text = warning
    io.puts(JSON.generate(hookSpecificOutput: { hookEventName: EVENT, additionalContext: text })) if text
  rescue StandardError
    nil
  end

  # The warning text, or nil when the spawn is fine or cannot be judged.
  def warning
    return nil if @env['CF_MODEL_ROLE_GUARD'] == '0'
    return nil unless TOOLS.include?(@event['tool_name'])

    input = @event['tool_input']
    return nil unless input.is_a?(Hash)

    role = role_of(input)
    return nil unless role

    expected = ModelRoles.snapshot_roles(HOST, path: @snapshot_path)&.dig(role)
    return nil unless expected

    actual = input['model'].to_s
    return nil if actual == expected

    detail = actual.empty? ? 'no model (it inherits the orchestrator tier)' : "model #{actual}"
    "[cf model roles] This spawn is tagged [role:#{role}], whose model is #{expected}, but it has #{detail}. " \
      'Pass the role model, or drop the tag if the override is deliberate. Advisory only; ' \
      'CF_MODEL_ROLE_GUARD=0 silences this.'
  end

  private

  def role_of(input)
    description = input['description'].to_s
    tag = description.match(TAG) || input['prompt'].to_s.match(TAG)
    role = tag && tag[:role]
    ModelRoles::ROLES.include?(role) ? role : nil
  end
end

ModelRoleGuard.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
