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
# approval_console.rb is exempt per verb, not as a whole: status, request and
# wait are open to agents, while enroll, totp-enroll, unlock, revoke and
# verify --write are denied to them (they also refuse without a real TTY).
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
  APPROVAL_CLI = 'approval_console.rb'
  APPROVAL_AGENT_VERBS = %w[status request wait record].freeze
  APPROVAL_HUMAN_VERBS = %w[enroll totp-enroll unlock revoke].freeze
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
    return approval_denial(command) if approval_denial(command)
    return if safe_cli_only?(command) || approval_cli_only?(command)
    return 'a shell command naming the secrets directory' if SHELL_MARKERS.any? { |marker| command.include?(marker) }
    return unless command.scan(SHELL_WORD).any? { |word| env_name?(File.basename(word)) }

    @env = true
    'a shell command naming a .env file'
  end

  # The human-only approval_console.rb verb a command runs, if any. Scans every
  # word, so a chained or wrapped run is caught too, and an unparseable command
  # that mentions the script is denied rather than guessed at.
  def approval_denial(command)
    return unless command.include?(APPROVAL_CLI)

    words = nested_words(command)
    words.each_with_index do |word, index|
      next unless File.basename(word) == APPROVAL_CLI

      verb = words[(index + 1)..].find { |arg| !arg.start_with?('-') }
      write = verb == 'verify' && words[(index + 1)..].include?('--write')
      next unless APPROVAL_HUMAN_VERBS.include?(verb) || write

      @approval = true
      return "a shell command running approval_console.rb #{verb}"
    end
    nil
  rescue ArgumentError
    @approval = true
    'an unparseable shell command naming approval_console.rb'
  end

  # Shell words, plus the words inside any quoted argument (`bash -c '...'`).
  def nested_words(command)
    Shellwords.split(command).flat_map do |word|
      word.match?(/\s/) ? [ word, *nested_words(word) ] : [ word ]
    rescue ArgumentError
      [ word ]
    end
  end

  def approval_cli_only?(command)
    return false if command.match?(CHAINING)

    words = Shellwords.split(command)
    words.first.to_s.end_with?('ruby') && File.basename(words[1].to_s) == APPROVAL_CLI &&
      (words[2].nil? || APPROVAL_AGENT_VERBS.include?(words[2]))
  rescue ArgumentError
    false
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
    message = if @approval then approval_message(reason)
    elsif @env then env_message(reason)
    else keys_message(reason)
    end
    { hookSpecificOutput: { hookEventName: EVENT, permissionDecision: 'deny', permissionDecisionReason: message } }
  end

  def env_message(reason)
    "[cf:secret-intake] Denied #{reason}: .env files hold secrets and stay out of the session. " \
      'Ask the user to edit the file, or stage the value with cf:secret-intake and run ' \
      '`ruby ~/.claude/cf/bin/secret_intake.rb push NAME --to env:<path>`. ' \
      '.env.example, .env.sample and .env.template stay readable.'
  end

  def approval_message(reason)
    "[cf:approval] Denied #{reason}: TOTP enrollment, unlock, revoke and record writes are human-only. " \
      'Ask the user to run it from their own terminal. `approval_console.rb status`, `request` and `wait` stay open.'
  end

  def keys_message(reason)
    "[cf:keys] Denied #{reason}: ~/.claude/cf/secrets holds paid API keys and stays out of the session. " \
      'Use `ruby ~/.claude/cf/bin/cf_keys.rb status` to see what is enrolled; it never prints a value.'
  end
end

SecretsReadGuard.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
