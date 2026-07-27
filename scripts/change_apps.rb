#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'change_config'
require_relative 'change_frontmatter'
require_relative 'change_policy'
require_relative 'change_schema'

# Reads a root CHANGE.md's change_config.apps registry (schema 0.4.0), the
# monorepo axis change_config.profiles deliberately does not cover: a profile
# changes *where* one app's audit runs, never *what* it audits, so a second
# app with different routes, a different boot, and no auth at all cannot be
# expressed as a profile.
#
# When change_config.apps is absent, single-app mode returns exactly one
# synthetic entry pointing at the root CHANGE.md itself, named for
# change_config.project. Every downstream reader (change_run, doctor, the
# gate store) then has one shape to handle, not two: a bare sweep, a doctor
# walk, and a gate record all iterate "the registered entries" whether there
# is one of them or several.
class ChangeAppRegistry
  class RegistryError < ChangeConfig::ConfigError; end

  # `root` is always the repo root (the directory holding the root
  # CHANGE.md); `config_path` is either that same root CHANGE.md
  # (`synthetic: true`, single-app mode) or one app's own CHANGE.app.yml.
  Entry = Struct.new(:name, :config_path, :path, :description, :enabled, :root, :synthetic, keyword_init: true) do
    def load(profile: nil, overrides: {})
      if synthetic
        ChangeConfig.load(config_path, profile: profile, overrides: overrides)
      else
        ChangeConfig.load_app(config_path, root: root, profile: profile, overrides: overrides)
      end
    end
  end

  def self.load(change_md_path)
    front = ChangeFrontmatter.parse_file(change_md_path)
    config = front['change_config']
    raise RegistryError, ChangeConfig.missing_config_message(change_md_path) unless config.is_a?(Hash)

    root = File.dirname(change_md_path)
    apps = config['apps']

    project = config['project'].to_s
    project = 'project' if project.empty?

    return new(single_app_entries(change_md_path, root, project), root, project, multi_app: false) if apps.nil?

    new(registry_entries(change_md_path, root, config, apps), root, project, multi_app: true)
  end

  def self.single_app_entries(change_md_path, root, project)
    [ Entry.new(name: project, config_path: change_md_path, path: root, description: nil, enabled: true, root: root, synthetic: true) ]
  end
  private_class_method :single_app_entries

  def self.registry_entries(change_md_path, root, config, apps)
    forbidden = ChangeSchema::ROOT_APP_MODE_FORBIDDEN & config.keys
    unless forbidden.empty?
      raise RegistryError,
            "#{change_md_path}: change_config declares apps: alongside #{forbidden.join(', ')}. A root " \
            'that is both a registry and an app is ambiguous (--app would be meaningless for that one ' \
            "app, and promotion.<branch>.profile would not know whose profile is meant); move " \
            "#{forbidden.join(', ')} into one app's own CHANGE.app.yml instead."
    end
    raise RegistryError, "change_config.apps must be a mapping: #{change_md_path}" unless apps.is_a?(Hash)
    raise RegistryError, "change_config.apps is empty: #{change_md_path}" if apps.empty?

    apps.map { |name, entry| build_entry(change_md_path, root, name.to_s, entry) }
  end
  private_class_method :registry_entries

  def self.build_entry(change_md_path, root, name, entry)
    raise RegistryError, "change_config.apps.#{name} is not a mapping: #{change_md_path}" unless entry.is_a?(Hash)
    raise RegistryError, "change_config.apps.#{name} has no config: #{change_md_path}" if entry['config'].to_s.empty?

    config_path = File.expand_path(entry['config'].to_s, root)
    raise RegistryError, "change_config.apps.#{name}.config not found: #{config_path}" unless File.exist?(config_path)

    Entry.new(
      name: name,
      config_path: config_path,
      path: entry['path'] ? File.expand_path(entry['path'].to_s, root) : File.dirname(config_path),
      description: entry['description']&.to_s,
      enabled: entry.fetch('enabled', true) != false,
      root: root,
      synthetic: false
    )
  end
  private_class_method :build_entry

  def initialize(entries, root, project, multi_app:)
    @entries = entries
    @root = root
    @project = project
    @multi_app = multi_app
  end

  def multi_app? = @multi_app
  def entries = @entries
  def enabled_entries = @entries.select(&:enabled)
  def names = @entries.map(&:name)

  # The repo label from the root change_config.project: what a sweep roll-up
  # and the gate record's aggregate use, never one app file's own project.
  def project = @project

  # Resolves `--app NAME` (repeatable) against the registry, in the order
  # requested. An unknown name raises listing the registered apps, the same
  # shape as the existing unknown-profile error.
  def fetch(requested_names)
    requested_names.map do |name|
      @entries.find { |entry| entry.name == name.to_s } ||
        raise(RegistryError, "unknown app '#{name}'; registered apps: #{names.join(', ')}")
    end
  end

  # A well-formed check across the whole registry: one ChangeConfig.doctor
  # -style block per selected app (every enabled app, or the `--app`-requested
  # subset), preceded, in multi-app mode, by the registry header and the
  # promotion-profile coverage check (a `change_policy.promotion.<branch>.profile`
  # that some required app cannot satisfy is a merge gate that is
  # unsatisfiable by construction, worth catching here rather than at merge
  # time).
  def self.doctor(change_md_path, profile: nil, apps: [], overrides: {})
    registry = load(change_md_path)
    selected = apps.empty? ? registry.enabled_entries : registry.fetch(apps)

    lines = []
    if registry.multi_app?
      described = registry.entries.map { |e| e.description ? "#{e.name} (#{e.description})" : e.name }
      lines << "apps: #{described.join(', ')}"
      lines.concat(promotion_profile_coverage_errors(change_md_path, registry))
    end

    selected.each do |entry|
      lines << '' unless lines.empty?
      lines << "--- app: #{entry.name} (#{entry.config_path}) ---" if registry.multi_app?
      lines.concat(ChangeConfig.doctor_lines(entry.config_path, entry.load(profile: profile, overrides: overrides)))
    end

    lines.join("\n")
  end

  # For every protected branch whose promotion rule names a profile, every app
  # required to gate that branch (the rule's own `apps:` list, or every
  # registered enabled app when omitted) must either define that profile name
  # or have no `profiles:` block at all; otherwise the merge gate can never be
  # satisfied for that app. Also flags an explicitly empty `promotion.<branch>
  # .apps: []`, which change_policy.rb resolves to "every app" (the fail-closed
  # reading a hook must take) rather than the "gate nothing" a bare empty list
  # visually suggests.
  def self.promotion_profile_coverage_errors(change_md_path, registry)
    policy = ChangePolicy.for_repo(File.dirname(change_md_path))
    return [] unless policy

    policy.protected_branches.flat_map do |branch|
      unsatisfiable_profile_errors(policy, registry, branch) + empty_apps_list_error(policy, branch)
    end
  end
  private_class_method :promotion_profile_coverage_errors

  def self.unsatisfiable_profile_errors(policy, registry, branch)
    branch_profile = policy.profile_for(branch)
    return [] unless branch_profile

    required_names = policy.apps_for(branch) || registry.enabled_entries.map(&:name)
    required_names.filter_map do |name|
      entry = registry.entries.find { |candidate| candidate.name == name }
      next unless entry

      begin
        entry.load(profile: branch_profile)
        nil
      rescue ChangeConfig::ConfigError => e
        next unless e.message.include?('unknown profile')

        "error: promotion.#{branch}.profile '#{branch_profile}' is unsatisfiable: app '#{name}' has no such " \
          "profile (#{e.message})"
      end
    end
  end
  private_class_method :unsatisfiable_profile_errors

  def self.empty_apps_list_error(policy, branch)
    raw = policy.promotion[branch.to_s]
    apps_value = raw.is_a?(Hash) ? raw['apps'] : nil
    return [] unless apps_value.is_a?(Array) && apps_value.empty?

    [ "error: change_policy.promotion.#{branch}.apps is explicitly empty; that resolves to every " \
      "registered enabled app, not \"gate nothing\" -- use require_change_pass: false for that." ]
  end
  private_class_method :empty_apps_list_error
end
