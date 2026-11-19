#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'shellwords'
require_relative 'hook_event'

# PreToolUse (Bash): denies the agent every route to approving, or tampering
# with the state of, a bounded prod op. Production credentials never reach the
# agent, so the remaining risk is the agent granting itself the approval:
#
#   change_prod_approve.rb                      the human-only approval tool
#   gh api .../actions/runs/N/pending_deployments   approving a deployment review
#   gh api .../environments/... (a write)        protection rules, reviewers, branch policy
#   git push or gh api writes to refs/cf-prod/{approvals,claims,lock,journal}
#
# The console verbs (enroll, totp-enroll, unlock, revoke, verify --write) are
# already denied by secrets_read_guard.rb. There is no escape hatch for the
# agent: a human runs the command in a real terminal. The limit, stated in
# PRINCIPLES.md, is that the agent's admin token can still call these APIs from
# anywhere a hook does not see. Friction, not a sandbox. Fails silent on error.
class ProdApprovalGuard
  EVENT = 'PreToolUse'
  APPROVE_CLI = 'change_prod_approve.rb'
  MARKERS = [ APPROVE_CLI, 'pending_deployments', '/environments', 'refs/cf-prod/' ].freeze
  PENDING = %r{repos/[^/\s]+/[^/\s]+/actions/runs/[^/\s]+/pending_deployments}
  ENVIRONMENTS = %r{repos/[^/\s]+/[^/\s]+/environments(?:/|\z|\?)}
  GUARDED_REFS = %r{refs/cf-prod/(?:approvals|claims|lock|journal)\b}
  WRITE_METHODS = %w[PUT POST PATCH DELETE].freeze
  FIELD_FLAGS = %w[-f -F --field --raw-field --input].freeze

  def initialize(event) = @event = event

  def emit(io = $stdout)
    reason = denial
    io.puts(JSON.generate(deny(reason))) if reason
  rescue StandardError
    nil
  end

  def denial
    return unless @event['tool_name'] == 'Bash'

    input = @event['tool_input']
    command = input.is_a?(Hash) ? input['command'].to_s : ''
    return unless MARKERS.any? { |marker| command.include?(marker) }

    inspect_words(words(command))
  rescue ArgumentError
    'an unparseable shell command naming a prod approval path'
  end

  private

  # Shell words, plus the words inside any quoted argument (`bash -c '...'`).
  def words(command)
    Shellwords.split(command).flat_map do |word|
      word.match?(/\s/) ? [ word, *words(word) ] : [ word ]
    rescue ArgumentError
      [ word ]
    end
  end

  def inspect_words(list)
    return "a shell command running #{APPROVE_CLI}" if list.any? { |word| File.basename(word) == APPROVE_CLI }

    api = api_calls(list)
    api.each do |args|
      return 'a gh api call to pending_deployments' if args.any? { |arg| arg.match?(PENDING) }
      return 'a gh api write to a repository environment' if env_write?(args)
      return 'a gh api write to a guarded refs/cf-prod ref' if guarded_ref?(args) && write?(args)
    end
    return 'a git write to a guarded refs/cf-prod ref' if git_write?(list)

    nil
  end

  # The argument run after each `gh api`.
  def api_calls(list)
    list.each_index.filter_map { |i| list[(i + 2)..] if list[i] == 'gh' && list[i + 1] == 'api' }
  end

  def env_write?(args) = args.any? { |arg| arg.match?(ENVIRONMENTS) } && write?(args)

  def guarded_ref?(args) = args.any? { |arg| arg.match?(GUARDED_REFS) }

  # An explicit non-GET method, or any field flag (gh defaults those to POST).
  def write?(args)
    method = method_of(args)
    return WRITE_METHODS.include?(method) if method
    return false if method_given?(args)

    args.any? { |arg| FIELD_FLAGS.include?(arg) || arg.start_with?('--field=', '--raw-field=', '--input=') || arg.match?(/\A-[fF]./) }
  end

  def method_given?(args) = !method_of(args).nil?

  def method_of(args)
    args.each_with_index do |arg, i|
      return args[i + 1].to_s.upcase if %w[-X --method].include?(arg)
      return arg.sub(/\A--method=/, '').upcase if arg.start_with?('--method=')
      return arg.sub(/\A-X/, '').upcase if arg.match?(/\A-X.+/)
    end
    nil
  end

  # git push or update-ref naming a guarded ref, or a mirror/all push that
  # would carry one.
  def git_write?(list)
    list.each_index.any? do |i|
      next false unless list[i] == 'git'

      verb = list[(i + 1)..].find { |word| !word.start_with?('-') }
      %w[push update-ref].include?(verb) && list[(i + 1)..].any? { |word| word.match?(GUARDED_REFS) }
    end
  end

  def deny(reason)
    {
      hookSpecificOutput: {
        hookEventName: EVENT,
        permissionDecision: 'deny',
        permissionDecisionReason: "[cf:prod] #{reason}. Production approvals are human-only: run it yourself in a real terminal. " \
                                  'The agent never approves its own prod op.'
      }
    }
  end
end

ProdApprovalGuard.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
