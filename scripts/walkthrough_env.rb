# frozen_string_literal: true

# Secrets loading for the walkthrough skills. Keys come from ENV, optionally
# seeded from a dotenv-style file named by CF_SECRETS_ENV (no default path). A key is
# fetched only when its provider is actually called, and its value never
# appears in an error message, a log line, or a file.
module WalkthroughEnv
  SECRETS_ENV_VAR = 'CF_SECRETS_ENV'

  class MissingKeyError < StandardError; end

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

  def elevenlabs_key!
    present('ELEVEN_LABS_API_KEY') || present('ELEVENLABS_API_KEY') ||
      raise(MissingKeyError,
            'ELEVEN_LABS_API_KEY (or ELEVENLABS_API_KEY) not set; set it or point CF_SECRETS_ENV at an env file')
  end

  def openai_key!
    present('OPENAI_API_KEY') ||
      raise(MissingKeyError, 'OPENAI_API_KEY not set; set it or point CF_SECRETS_ENV at an env file')
  end

  def present(name)
    value = ENV.fetch(name, nil)
    value unless value.nil? || value.empty?
  end
end
