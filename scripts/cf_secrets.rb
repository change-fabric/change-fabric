# frozen_string_literal: true

require 'json'
require 'yaml'
require_relative 'contributors_team'
require_relative 'ctx_paths'

# The cf key store. ~/.claude/cf/secrets.yml records, per project, where a paid
# skill's API key comes from: an env file path, or the literal `env` (process
# env only). Only pointers are stored, never key values. A project with no
# recorded choice raises NeedsEnrollment so the agent can ask the user once.
module CfSecrets
  ENV_ONLY = 'env'
  PINNED_VAR = 'CF_SECRETS_ENV'
  NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

  # A recorded choice whose key is absent. Hard error, never a re-ask.
  class MissingKey < StandardError
    attr_reader :provider, :env_var, :source

    def initialize(provider, env_var, source = nil)
      @provider = provider
      @env_var = env_var
      @source = source
      where = source && source != ENV_ONLY ? " in #{source}" : ' in the process env'
      super("#{env_var} for #{provider} not found#{where}")
    end
  end

  # No recorded choice for this project. Carries everything the agent needs to
  # ask, and never a key value.
  class NeedsEnrollment < StandardError
    attr_reader :provider, :env_var, :project_key, :candidates

    def initialize(provider:, env_var:, project_key:, candidates:)
      @provider = provider
      @env_var = env_var
      @project_key = project_key
      @candidates = candidates
      super("no key source recorded for #{project_key} (#{provider})")
    end

    def to_h = { provider:, env_var:, project_key:, candidates: }
  end

  module_function

  def store_path(home = Dir.home) = File.join(home, '.claude', 'cf', 'secrets.yml')

  def project_key(cwd = Dir.pwd)
    ContributorsTeam.new(cwd).repo_id || CtxPaths.dashed(File.expand_path(cwd))
  end

  def load(path = store_path)
    data = File.file?(path) ? YAML.safe_load_file(path) : nil
    data.is_a?(Hash) ? data : {}
  rescue Psych::Exception, SystemCallError
    {}
  end

  # Returns [value, source] or raises NeedsEnrollment / MissingKey. Precedence:
  # process env, CF_SECRETS_ENV, project provider override, project env_file.
  # The global default is a candidate to ask about, never a silent fallback.
  def resolve(provider:, env_vars:, cwd: Dir.pwd, env: ENV, store: load)
    env_vars.each { |v| return [ env[v], :process ] if present?(env[v]) }
    pinned = env[PINNED_VAR]
    if present?(pinned) && (hit = read_var(pinned, env_vars))
      return [ hit, :cf_secrets_env ]
    end

    key = project_key(cwd)
    entry = store.dig('projects', key)
    raise NeedsEnrollment.new(provider:, env_var: env_vars.join(','), project_key: key, candidates: candidates(store)) unless entry.is_a?(Hash)

    src = entry.dig('providers', provider) || entry['env_file']
    hit = src && src != ENV_ONLY ? read_var(src, env_vars) : nil
    return [ hit, :project ] if hit

    raise MissingKey.new(provider, env_vars.first, src)
  end

  # Default first, then other recorded env files, then `env`.
  def candidates(store)
    projects = store['projects'].is_a?(Hash) ? store['projects'].values : []
    files = projects.map { |e| e['env_file'] if e.is_a?(Hash) }
    ([ store['default'] ] + files + [ ENV_ONLY ]).compact.uniq
  end

  def enrollment_line(err) = JSON.generate(cf_enroll: err.to_h)

  # The first non-empty value of env_vars in a KEY=VALUE file, or nil. Never
  # mutates ENV.
  def read_var(path, env_vars)
    vars = read_file(path)
    env_vars.each { |v| return vars[v] if present?(vars[v]) }
    nil
  end

  def read_file(path)
    full = File.expand_path(path)
    return {} unless File.file?(full)

    File.foreach(full).each_with_object({}) do |line, acc|
      name, value = parse_line(line)
      acc[name] ||= value if name
    end
  rescue SystemCallError
    {}
  end

  def parse_line(line)
    text = line.strip
    return if text.empty? || text.start_with?('#')

    name, value = text.delete_prefix('export ').lstrip.split('=', 2)
    return unless value && name.match?(NAME)

    [ name, unquote(value.strip) ]
  end

  def unquote(value)
    quoted = value.length >= 2 && [ '"', "'" ].include?(value[0]) && value[-1] == value[0]
    quoted ? value[1..-2] : value
  end

  def present?(value) = !value.nil? && !value.empty?
end
