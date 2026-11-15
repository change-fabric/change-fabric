# frozen_string_literal: true

require 'json'
require_relative 'cf_key_expiry'
require_relative 'cf_keys'
require_relative 'cf_project_identity'
require_relative 'cf_provider_registry'
require_relative 'cf_secret_store'

# Resolves a paid provider key for the project the current directory belongs
# to, from the per-project store only (CfSecretStore). Order:
#
#   1. the project's own enrolled key
#   2. the nearest enrolled ancestor level (deepest first), only when this
#      project's meta records a confirmation for that exact ancestor, or that
#      ancestor enrolled its key with scope tree
#
# Anything else raises Unenrolled, which carries the enrollment snippet and,
# when an ancestor key exists, where it could be inherited from. The chosen
# key's owning level decides expiry: within 24h (UTC) one stderr warning, once
# passed Expired, before the key is read and before any paid call. Process env
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
      { provider: provider, project_root: root, project_id: project_id, reason: 'missing', snippet: snippet,
        inheritable_from: inheritable_from }.compact
    end
  end

  # The resolved key's recorded expiry has passed. Raised before the key file
  # is read, so no paid request is made. Never carries a key value.
  class Expired < StandardError
    attr_reader :provider, :root, :project_id, :owner_root, :label, :expires_at, :snippet, :correct

    def initialize(provider:, root:, project_id:, owner_root:, expires_at:, label: nil)
      @provider = provider
      @root = root
      @project_id = project_id
      @owner_root = owner_root
      @label = label
      @expires_at = expires_at
      @snippet = CfKeys.snippet(provider, owner_root)
      @correct = CfKeys.expires_snippet(provider, owner_root)
      super("#{provider} key#{" \"#{label}\"" if label} enrolled at #{owner_root} expired at #{expires_at}")
    end

    def to_h
      { provider: provider, project_root: root, project_id: project_id, reason: 'expired', owner_root: owner_root,
        label: label, expires_at: expires_at, snippet: snippet, correct: correct }.compact
    end
  end

  @warned = {}

  module_function

  def resolve(provider, cwd: Dir.pwd, env: ENV, err: $stderr, now: Time.now)
    project = CfProjectIdentity.for(cwd)
    warn_ignored_env(provider, project.root, env, err)
    owner = owning_level(project, provider)
    if owner
      check_expiry(provider, project, owner, err, now)
      key = CfSecretStore.read_key(owner[:slug], provider)
      return key if key && !key.empty?
    end

    ancestor = CfSecretStore.inheritable(project.root, provider).first
    raise Unenrolled.new(provider: provider, root: project.root, project_id: project.id,
                         inheritable_from: ancestor&.first&.delete_prefix('dir:'))
  end

  # The level whose key this project uses, or nil: its own, else the nearest
  # ancestor when confirmed for this project or enrolled with scope tree.
  def owning_level(project, provider)
    return { slug: project.slug, root: project.root } if CfSecretStore.key?(project.slug, provider)

    id, slug = CfSecretStore.inheritable(project.root, provider).first
    return nil unless id

    confirmed = CfSecretStore.meta(project.slug).dig('confirmed_inherits', provider) == id
    tree = CfSecretStore.enrollment(slug, provider)['scope'] == 'tree'
    { slug: slug, root: id.delete_prefix('dir:') } if confirmed || tree
  end

  def check_expiry(provider, project, owner, err, now)
    entry = CfSecretStore.enrollment(owner[:slug], provider)
    case CfKeyExpiry.state(entry['expires_at'], now: now)
    when :expired
      raise Expired.new(provider: provider, root: project.root, project_id: project.id, owner_root: owner[:root],
                        expires_at: entry['expires_at'], label: entry['label'])
    when :warn
      warn_once("expiry:#{owner[:slug]}:#{provider}", err,
                "cf: #{provider} key#{" \"#{entry['label']}\"" if entry['label']} enrolled at #{owner[:root]} " \
                "expires at #{entry['expires_at']} (within 24h); renew: #{snippet(provider, owner[:root])}")
    end
  end

  def warn_once(id, err, line)
    return if @warned[id]

    @warned[id] = true
    err.puts(line)
  end

  def snippet(provider, root) = CfKeys.snippet(provider, root)

  # One line per variable per process, naming the variable and never its value.
  def warn_ignored_env(provider, root, env, err)
    names = CfProviderRegistry.fetch(provider).ignored_env + CfProviderRegistry.global_ignored_env
    names.each do |name|
      next if env[name].nil? || env[name].empty?

      warn_once(name, err, "cf: ignoring #{name} from the environment; keys are per project, see #{snippet(provider, root)}")
    end
  end

  def enrollment_line(err) = JSON.generate(cf_enroll: err.to_h)

  def reset_warnings! = @warned.clear
end
