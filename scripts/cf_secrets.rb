# frozen_string_literal: true

require 'json'
require_relative 'cf_keys'
require_relative 'cf_project_identity'
require_relative 'cf_provider_registry'
require_relative 'cf_secret_store'

# Resolves a paid provider key for the project the current directory belongs
# to, from the per-project store only (CfSecretStore). Order:
#
#   1. the project's own enrolled key
#   2. the nearest enrolled ancestor level (deepest first), only when this
#      project's meta records a confirmation for that exact ancestor
#
# Anything else raises Unenrolled, which carries the enrollment snippet and,
# when an ancestor key exists, where it could be inherited from. Process env
# vars and the old per-project pointer file are never read as a key source: a set
# variable earns one stderr warning naming it, never its value.
module CfSecrets
  # No usable key for this project. Never carries a key value.
  class Unenrolled < StandardError
    attr_reader :provider, :root, :project_id, :snippet, :inheritable_from

    def initialize(provider:, root:, project_id:, inheritable_from: nil)
      @provider = provider
      @root = root
      @project_id = project_id
      @inheritable_from = inheritable_from
      @snippet = CfKeys.snippet(provider, root)
      super("no #{provider} key enrolled for #{root}")
    end

    def to_h
      { provider: provider, project_root: root, project_id: project_id, snippet: snippet,
        inheritable_from: inheritable_from }.compact
    end
  end

  @warned = {}

  module_function

  def resolve(provider, cwd: Dir.pwd, env: ENV, err: $stderr)
    project = CfProjectIdentity.for(cwd)
    warn_ignored_env(provider, project.root, env, err)
    own = CfSecretStore.read_key(project.slug, provider)
    return own if own && !own.empty?

    ancestor = CfSecretStore.inheritable(project.root, provider).first
    confirmed = CfSecretStore.meta(project.slug).dig('confirmed_inherits', provider)
    if ancestor && confirmed == ancestor.first
      inherited = CfSecretStore.read_key(ancestor.last, provider)
      return inherited if inherited && !inherited.empty?
    end

    raise Unenrolled.new(provider: provider, root: project.root, project_id: project.id,
                         inheritable_from: ancestor&.first&.delete_prefix('dir:'))
  end

  def snippet(provider, root) = CfKeys.snippet(provider, root)

  # One line per variable per process, naming the variable and never its value.
  def warn_ignored_env(provider, root, env, err)
    names = CfProviderRegistry.fetch(provider).ignored_env + CfProviderRegistry.global_ignored_env
    names.each do |name|
      next if env[name].nil? || env[name].empty? || @warned[name]

      @warned[name] = true
      err.puts("cf: ignoring #{name} from the environment; keys are per project, see #{snippet(provider, root)}")
    end
  end

  def enrollment_line(err) = JSON.generate(cf_enroll: err.to_h)

  def reset_warnings! = @warned.clear
end
