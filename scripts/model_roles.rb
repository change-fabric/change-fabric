# frozen_string_literal: true

require 'json'
require 'yaml'
require 'fileutils'
require_relative 'cf_state'

# One host-keyed role -> model map. Skills name a role, never a tier; the skill
# compiler renders the model at install time. A model string is opaque here:
# nothing assumes it is a Claude tier name, so another host adds its own entry.
#
# Overrides have one lifetime, install time. `install.rb` resolves the map once
# (env > user file > repo), validates it, compiles skills from it, and writes the
# resolved snapshot last. The advisory hook and the grader read only the
# snapshot, never live env or user files.
module ModelRoles
  ROLES = %w[orchestrator worker author critic classifier].freeze
  SAFE_MODEL = /\A[A-Za-z0-9._:\[\]-]{1,64}\z/
  SNAPSHOT_NAME = 'model_roles.resolved.json'
  USER_FILE_NAME = 'model_roles.yml'
  SNAPSHOT_VERSION = 1

  class InvalidModel < ArgumentError; end

  module_function

  def repo_file = File.expand_path('../config/model_roles.yml', __dir__)
  def default_user_file(root = CfState.root) = File.join(root, USER_FILE_NAME)
  def default_snapshot_path(root = CfState.root) = File.join(root, SNAPSHOT_NAME)

  # The model for one role on a host, or nil when the host is not in the map.
  def model_for(role, host:, env: ENV, user_file: default_user_file, repo_file: self.repo_file)
    check_role!(role)
    resolve(role, host, env, user_file, repo_file)&.first
  end

  # {role => model} for a host, or nil when the host is not in the map.
  def table(host:, env: ENV, user_file: default_user_file, repo_file: self.repo_file)
    entries(host: host, env: env, user_file: user_file, repo_file: repo_file)&.transform_values(&:first)
  end

  # {role => source} (env, user file or repo) for the same resolution.
  def sources(host:, env: ENV, user_file: default_user_file, repo_file: self.repo_file)
    entries(host: host, env: env, user_file: user_file, repo_file: repo_file)&.transform_values(&:last)
  end

  # The roles a model string maps to under a host's resolved table: what the
  # advisory hook compares a spawn's model against.
  def role_of(model, host:, roles: snapshot_roles(host))
    return [] unless roles

    ROLES.select { |role| roles[role] == model.to_s }
  end

  # The resolved snapshot hash, or nil when it is missing, unreadable or foreign.
  def snapshot(path: default_snapshot_path)
    data = JSON.parse(File.read(path))
    data.is_a?(Hash) && data['version'] == SNAPSHOT_VERSION && data['roles'].is_a?(Hash) ? data : nil
  rescue StandardError
    nil
  end

  # The snapshot's role table for a host. Callers that must not break on a
  # fresh checkout fall back to the repo map; the hook and grader do not.
  def snapshot_roles(host, path: default_snapshot_path)
    data = snapshot(path: path)
    data && data['host'] == host ? data['roles'] : nil
  end

  # Snapshot, else the repo map alone (no env, no user file): for runtime text
  # that must still name a model before the first install.
  def installed_or_repo_roles(host, path: default_snapshot_path, repo_file: self.repo_file)
    snapshot_roles(host, path: path) || table(host: host, env: {}, user_file: nil, repo_file: repo_file)
  rescue StandardError
    nil
  end

  # Atomic: a temp file beside the target, then rename, so a reader or a failed
  # install never sees a partial snapshot.
  def write_snapshot(host:, roles:, sources:, path: default_snapshot_path)
    FileUtils.mkdir_p(File.dirname(path))
    temp = "#{path}.tmp.#{Process.pid}"
    body = JSON.generate('version' => SNAPSHOT_VERSION, 'host' => host, 'roles' => roles, 'sources' => sources)
    File.write(temp, "#{body}\n")
    File.rename(temp, path)
  ensure
    FileUtils.rm_f(temp) if temp
  end

  # {role => [snapshot model, live model]} for every role whose live resolution
  # (env, user file, repo) differs from the snapshot. Empty with no snapshot.
  def drift(host:, env: ENV, user_file: default_user_file, repo_file: self.repo_file, path: default_snapshot_path)
    installed = snapshot_roles(host, path: path)
    live = table(host: host, env: env, user_file: user_file, repo_file: repo_file)
    return {} unless installed && live

    ROLES.each_with_object({}) do |role, found|
      found[role] = [ installed[role], live[role] ] if installed[role] != live[role]
    end
  rescue InvalidModel
    {}
  end

  def drift_message(changes, applying: false)
    return nil if changes.empty?

    detail = changes.map { |role, (old, live)| "#{role} #{old || 'unset'} -> #{live || 'unset'}" }.join(', ')
    tail = applying ? 'applying them now' : 're-run ruby install.rb to apply'
    "cf model roles changed since the last install (#{detail}); #{tail}."
  end

  def check_role!(role)
    raise ArgumentError, "unknown model role: #{role.inspect} (known: #{ROLES.join(', ')})" unless ROLES.include?(role)
  end

  def entries(host:, env:, user_file:, repo_file:)
    ROLES.to_h { |role| [ role, resolve(role, host, env, user_file, repo_file) ] }.then do |found|
      found.values.all?(&:nil?) ? nil : found.compact
    end
  end

  # [model, source] or nil. An override applies only to a host the map knows,
  # so a host with no entry keeps its host-neutral phrasing.
  def resolve(role, host, env, user_file, repo_file)
    repo = host_table(read_map(repo_file, warn: false), host)
    user = host_table(read_map(user_file, warn: true), host)
    return nil if repo.nil? && user.nil?

    override = env["CF_MODEL_#{role.upcase}"].to_s
    candidates = [ [ override, 'env' ], [ user&.[](role), 'user file' ], [ repo&.[](role), 'repo' ] ]
    value, source = candidates.find { |candidate, _| !candidate.nil? && candidate != '' }
    return nil if value.nil?

    [ validate!(role, source, value), source ]
  end

  def validate!(role, source, value)
    return value if value.is_a?(String) && value.match?(SAFE_MODEL)

    raise InvalidModel, "invalid model for role #{role} from #{source}: #{value.inspect}"
  end

  def host_table(map, host)
    table = map && map.dig('hosts', host)
    table.is_a?(Hash) ? table : nil
  end

  # A missing file is empty. A malformed user file warns once and is ignored,
  # never a crash (hooks fail silent); a malformed repo file is a real error.
  def read_map(path, warn:)
    return nil if path.nil? || !File.file?(path)

    data = YAML.safe_load_file(path)
    raise Psych::SyntaxError.new(path, 0, 0, 0, 'not a mapping', '') unless data.is_a?(Hash) && data['hosts'].is_a?(Hash)

    data
  rescue Psych::Exception, SystemCallError
    raise unless warn

    @warned ||= {}
    unless @warned[path]
      @warned[path] = true
      Kernel.warn "cf: ignoring malformed model roles file #{path}"
    end
    nil
  end
end
