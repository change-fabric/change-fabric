#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'shellwords'
require_relative 'hook_event'
require_relative 'path_canon'

# PreToolUse: keeps secrets out of the model's view. Denies any file tool
# whose path lands under ~/.claude/cf/secrets or on a .env or .env.<suffix>
# file, and any shell command that names either. Template env files
# (.example, .sample, .template) stay readable. The shell exceptions are a
# plain run of cf_keys.rb or secret_intake.rb, which never print a value.
# Like the other guards this is a loud guardrail, not a sandbox. Fails
# silent on any error.
class SecretsReadGuard
  EVENT = 'PreToolUse'
  FILE_TOOLS = %w[Read Edit Write MultiEdit NotebookEdit Grep Glob].freeze
  SEARCH_TOOLS = %w[Grep Glob].freeze
  PATH_KEYS = %w[file_path notebook_path path filePath].freeze
  SHELL_MARKERS = [ '.claude/cf/secrets', 'cf/secrets/' ].freeze
  CHAINING = /[;&|<>`\n]|\$\(/
  SAFE_CLIS = %w[cf_keys.rb secret_intake.rb].freeze
  ENV_NAME = %r{\A\.env(?:\.[^/]+)?\z}
  TEMPLATE_SUFFIX = /\.(?:example|sample|template)\z/
  SHELL_WORD = /[^\s'"=:<>|;&()`]+/

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

    paths = file_paths(input)
    hit = paths.find { |path| under_secrets?(path) }
    hit ||= input['pattern'] if tool == 'Glob' && SHELL_MARKERS.any? { |m| input['pattern'].to_s.include?(m) }
    return "#{tool} of #{hit}" if hit

    env_denial(tool, input, paths)
  end

  private

  def env_denial(tool, input, paths)
    hit = paths.find { |path| env_path?(path) }
    hit ||= input['glob'] if tool == 'Grep' && env_name?(File.basename(input['glob'].to_s))
    return unless hit

    @env = true
    "#{tool} of #{hit}"
  end

  def shell_denial(command)
    return if safe_cli_only?(command)
    return 'a shell command naming the secrets directory' if SHELL_MARKERS.any? { |marker| command.include?(marker) }
    return unless command.scan(SHELL_WORD).any? { |word| env_name?(File.basename(word)) }

    @env = true
    'a shell command naming a .env file'
  end

  def safe_cli_only?(command)
    return false if command.match?(CHAINING)

    words = Shellwords.split(command)
    words.first.to_s.end_with?('ruby') && SAFE_CLIS.include?(File.basename(words[1].to_s))
  rescue ArgumentError
    false
  end

  def env_name?(name) = name.match?(ENV_NAME) && !name.match?(TEMPLATE_SUFFIX)

  # Checks the named file and, through a symlink, the file it points at.
  def env_path?(path) = env_name?(File.basename(path)) || env_name?(File.basename(resolve(path)))

  # Grep and Glob search the session cwd when no path is given.
  def file_paths(input)
    paths = PATH_KEYS.filter_map { |key| input[key] if input[key].is_a?(String) && !input[key].empty? }
    paths << '.' if paths.empty? && SEARCH_TOOLS.include?(@event['tool_name'])
    paths
  end

  def under_secrets?(path)
    PathCanon.within?(resolve(path), root)
  end

  def root = File.join(@home, '.claude', 'cf', 'secrets')

  def resolve(path)
    base = @event['cwd'].is_a?(String) ? @event['cwd'] : Dir.pwd
    full = File.expand_path(path.sub(/\A~(?=\/|\z)/, @home), base)
    # Follows symlinks on the longest existing prefix, so a link into the
    # secrets dir is caught too.
    PathCanon.real(full)
  end

  def deny(reason)
    message = @env ? env_message(reason) : keys_message(reason)
    { hookSpecificOutput: { hookEventName: EVENT, permissionDecision: 'deny', permissionDecisionReason: message } }
  end

  def env_message(reason)
    "[cf:secret-intake] Denied #{reason}: .env files hold secrets and stay out of the session. " \
      'Ask the user to edit the file, or stage the value with cf:secret-intake and run ' \
      '`ruby ~/.claude/cf/bin/secret_intake.rb push NAME --to env:<path>`. ' \
      '.env.example, .env.sample and .env.template stay readable.'
  end

  def keys_message(reason)
    "[cf:keys] Denied #{reason}: ~/.claude/cf/secrets holds paid API keys and stays out of the session. " \
      'Use `ruby ~/.claude/cf/bin/cf_keys.rb status` to see what is enrolled; it never prints a value.'
  end
end

SecretsReadGuard.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
