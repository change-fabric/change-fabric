# frozen_string_literal: true

require_relative 'cf_secrets'

# Secrets loading for the walkthrough skills. Keys come from ENV, optionally
# seeded from a dotenv-style file named by CF_SECRETS_ENV (no default path). A key is
# fetched only when its provider is actually called, and its value never
# appears in an error message, a log line, or a file.
module WalkthroughEnv
  SECRETS_ENV_VAR = 'CF_SECRETS_ENV'

  class MissingKeyError < StandardError; end

  # No key source recorded for this project. A MissingKeyError so existing
  # rescues still catch it; callers that can ask the user rescue it first and
  # call enroll_exit!.
  class NeedsEnrollment < MissingKeyError
    def initialize(cause_error)
      @details = cause_error.to_h
      super(cause_error.message)
    end

    def to_h = @details
  end

  module_function

  def load_secrets(path = ENV.fetch(SECRETS_ENV_VAR, nil))
    return if path.nil? || path.empty?

    full = File.expand_path(path)
    return unless File.file?(full)

    File.foreach(full) do |line|
      name, value = parse_line(line)
      next unless name
      next if ENV.key?(name) && !ENV[name].empty?

      ENV[name] = value
    end
    nil
  rescue SystemCallError
    nil
  end

  def parse_line(line)
    text = line.strip
    return if text.empty? || text.start_with?('#')

    text = text.delete_prefix('export ').lstrip
    name, value = text.split('=', 2)
    return unless value && name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

    [ name, unquote(value.strip) ]
  end

  def unquote(value)
    if value.length >= 2 && [ '"', "'" ].include?(value[0]) && value[-1] == value[0]
      value[1..-2]
    else
      value
    end
  end

  def elevenlabs_key! = key!('elevenlabs', %w[ELEVEN_LABS_API_KEY ELEVENLABS_API_KEY])

  def openai_key! = key!('openai', %w[OPENAI_API_KEY])

  def gemini_key! = key!('gemini', %w[GEMINI_API_KEY])

  # The key value from CfSecrets, never echoed. An unenrolled project raises
  # NeedsEnrollment; a recorded source without the key raises MissingKeyError.
  def key!(provider, env_vars)
    CfSecrets.resolve(provider: provider, env_vars: env_vars).first
  rescue CfSecrets::NeedsEnrollment => e
    raise NeedsEnrollment, e
  rescue CfSecrets::MissingKey => e
    raise MissingKeyError, e.message
  end

  ENROLL_EXIT = 4

  # Prints the one cf_enroll JSON line (no values) and returns the exit code,
  # for CLIs whose run returns a status.
  def enroll(err, out: $stdout)
    out.puts(CfSecrets.enrollment_line(err))
    ENROLL_EXIT
  end

  # Prints the one cf_enroll JSON line (no values) and exits 4.
  def enroll_exit!(err, out: $stdout) = exit(enroll(err, out: out))

  def present(name)
    value = ENV.fetch(name, nil)
    value unless value.nil? || value.empty?
  end
end
