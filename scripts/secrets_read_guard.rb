#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'shellwords'
require_relative 'hook_event'

# PreToolUse: keeps paid keys out of the model's view by denying any file
# tool whose path lands under ~/.claude/cf/secrets, and any shell command
# that names that directory. The one shell exception is a plain run of
# cf_keys.rb, which never prints a value. Like the other guards this is a
# loud guardrail, not a sandbox. Fails silent on any error.
class SecretsReadGuard
  EVENT = 'PreToolUse'
  FILE_TOOLS = %w[Read Edit Write MultiEdit NotebookEdit Grep Glob].freeze
  PATH_KEYS = %w[file_path notebook_path path filePath].freeze
  SHELL_MARKERS = [ '.claude/cf/secrets', 'cf/secrets/' ].freeze
  CHAINING = /[;&|<>`\n]|\$\(/

  def initialize(event, home: Dir.home) = (@event, @home = event, home)

  def emit(io = $stdout)
    reason = denial
    io.puts(JSON.generate(deny(reason))) if reason
  rescue StandardError
    nil
  end

  def denial
    tool = @event['tool_name']
    input = @event['tool_input']
    return unless input.is_a?(Hash)
    return shell_denial(input['command'].to_s) if tool == 'Bash'
    return unless FILE_TOOLS.include?(tool)

    hit = file_paths(input).find { |path| under_secrets?(path) }
    hit ||= input['pattern'] if tool == 'Glob' && SHELL_MARKERS.any? { |m| input['pattern'].to_s.include?(m) }
    "#{tool} of #{hit}" if hit
  end

  private

  def shell_denial(command)
    return unless SHELL_MARKERS.any? { |marker| command.include?(marker) }
    return if cf_keys_only?(command)

    'a shell command naming the secrets directory'
  end

  def cf_keys_only?(command)
    return false if command.match?(CHAINING)

    words = Shellwords.split(command)
    words.first.to_s.end_with?('ruby') && File.basename(words[1].to_s) == 'cf_keys.rb'
  rescue ArgumentError
    false
  end

  def file_paths(input)
    PATH_KEYS.filter_map { |key| input[key] if input[key].is_a?(String) && !input[key].empty? }
  end

  def under_secrets?(path)
    full = resolve(path)
    [ root, real(root) ].uniq.any? { |dir| full == dir || full.start_with?("#{dir}/") }
  end

  def root = File.join(@home, '.claude', 'cf', 'secrets')

  def resolve(path)
    base = @event['cwd'].is_a?(String) ? @event['cwd'] : Dir.pwd
    full = File.expand_path(path.sub(/\A~(?=\/|\z)/, @home), base)
    real(full)
  end

  # Follows symlinks on the longest existing prefix, so a link into the
  # secrets dir is caught too.
  def real(path)
    return File.realpath(path) if File.exist?(path)

    parent = File.dirname(path)
    parent == path ? path : File.join(real(parent), File.basename(path))
  end

  def deny(reason)
    {
      hookSpecificOutput: {
        hookEventName: EVENT,
        permissionDecision: 'deny',
        permissionDecisionReason:
          "[cf:keys] Denied #{reason}: ~/.claude/cf/secrets holds paid API keys and stays out of the session. " \
          'Use `ruby ~/.claude/cf/bin/cf_keys.rb status` to see what is enrolled; it never prints a value.'
      }
    }
  end
end

SecretsReadGuard.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
