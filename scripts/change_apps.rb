#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require_relative 'change_config'
require_relative 'change_delivery_schema'
require_relative 'change_frontmatter'
require_relative 'change_policy'
require_relative 'change_prod_classes'
require_relative 'change_prod_runner_gen'
require_relative 'change_prod_schema'
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
            "app, and promotion.<ref>.profile would not know whose profile is meant); move " \
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
  # promotion-profile coverage check (a `change_policy.promotion.<ref>.profile`
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
    lines.concat(gate_scope_errors(change_md_path))
    lines.concat(tracker_policy_errors(change_md_path))
    lines.concat(delivery_lines(change_md_path))
    lines.concat(prod_class_lines(change_md_path))
    lines.concat(prod_schema_lines(change_md_path))
    lines.concat(promotion_target_lines(change_md_path))
    lines.concat(require_scheduled_lines(change_md_path))

    selected.each do |entry|
      lines << '' unless lines.empty?
      lines << "--- app: #{entry.name} (#{entry.config_path}) ---" if registry.multi_app?
      lines.concat(ChangeConfig.doctor_lines(entry.config_path, entry.load(profile: profile, overrides: overrides)))
    end
    lines.concat(policy_lines(change_md_path))

    lines.join("\n")
  end

  # The resolved merge policy, as the merge gate and cf:sweep read it. A
  # CHANGE.md with no change_policy block resolves to the spec default
  # [staging, production], which a trunk-only repo does not have; the gate
  # then protects nothing that exists and admin bypass stays off, so say so
  # here instead of letting a stack sweep discover it as an escalation.
  def self.policy_lines(change_md_path)
    root = File.dirname(change_md_path)
    policy = ChangePolicy.for_repo(root)
    return [] unless policy

    declared = ChangeFrontmatter.parse_file(change_md_path)['change_policy'].is_a?(Hash)
    branches = policy.protected_branches
    lines = [ "policy: protected_branches: #{branches.join(', ')}#{' (spec default; no change_policy block)' unless declared}" ]
    lines << "policy: admin_bypass: #{policy.admin_bypass_allowed? ? 'allowed' : 'not allowed'}"
    on_origin = origin_branches(root)
    missing = branches - on_origin
    return lines if missing.empty? || on_origin.empty?

    lines << "warning: protected_branches resolve to branches that don't exist on origin: #{missing.join(', ')}. " \
             'Set change_policy.protected_branches to the branches this repo merges into.'
  rescue StandardError
    []
  end
  private_class_method :policy_lines

  # Branch names under refs/remotes/origin, read locally (no fetch). Empty when
  # the directory is not a git repo or has no origin refs, so the check stays
  # silent rather than guessing.
  def self.origin_branches(root)
    out, status = Open3.capture2('git', '-C', root, 'for-each-ref', '--format=%(refname:lstrip=3)', 'refs/remotes/origin',
                                 err: File::NULL)
    status.success? ? out.lines.map(&:strip).reject { |name| name.empty? || name == 'HEAD' } : []
  end
  private_class_method :origin_branches

  # A bad change_policy.gate block never fails a guard (an invalid require_on
  # reads as every_merge, an invalid trunk as main), so doctor is where the
  # author learns of it, before the fallback exempts a branch they did not mean.
  def self.gate_scope_errors(change_md_path)
    policy = ChangePolicy.for_repo(File.dirname(change_md_path))
    return [] unless policy

    policy.gate_errors.map { |message| "error: #{message}" }
  end
  private_class_method :gate_scope_errors

  # change_policy.trackers (0.19.0) is read by no guard, so doctor is where a
  # bad tracker workflow (a person named as a holder, an unknown state) shows.
  def self.tracker_policy_errors(change_md_path)
    policy = ChangePolicy.for_repo(File.dirname(change_md_path))
    return [] unless policy

    config = ChangeFrontmatter.parse_file(change_md_path)['change_config']
    policy.tracker_errors(config: config).map { |message| "error: #{message}" }
  rescue StandardError
    []
  end
  private_class_method :tracker_policy_errors

  # change_config.delivery and change_policy.delivery (0.24.0) are read by the
  # consumer's own controller, not by any guard here, so doctor is where a
  # broken floor shows: one line per rollout, then every error, then a
  # warning for each production rollout still on a fixture adapter. Silent
  # when neither block exists.
  def self.delivery_lines(change_md_path)
    data = ChangeFrontmatter.parse_file(change_md_path)
    config = data['change_config']
    policy = data['change_policy']
    root = File.dirname(change_md_path)
    errors = ChangeDeliverySchema.errors(config, policy, root: root)
    rollouts = ChangeDeliverySchema.rollouts(config, policy, root: root)
    return [] if errors.empty? && rollouts.empty?

    rollouts.map { |rollout| delivery_rollout_line(rollout) } +
      errors.map { |message| "error: #{message}" } +
      delivery_fixture_warnings(config, rollouts)
  rescue StandardError
    []
  end
  private_class_method :delivery_lines

  # Prod op classes and the one-way-door linkage note. Silent with no operations.
  def self.prod_class_lines(change_md_path)
    ChangeProdClasses.report(ChangeFrontmatter.parse_file(change_md_path))
  rescue StandardError
    []
  end
  private_class_method :prod_class_lines

  # Bounded prod runner (0.29.0): schema errors, a notice for every
  # online_safe opt-out (never a failure), a warning for each backup with no
  # restore probe, and an error for a hand-edited cf-prod.yml. Silent when the
  # config declares none of the blocks and no workflow exists.
  def self.prod_schema_lines(change_md_path)
    data = ChangeFrontmatter.parse_file(change_md_path)
    config = data['change_config'].is_a?(Hash) ? data['change_config'] : {}
    declared = %w[runners backups maintenance operations].any? { |key| config.key?(key) }
    workflow = File.join(File.dirname(change_md_path), ChangeProdRunnerGen::WORKFLOW)
    lines = []
    if declared
      lines.concat(ChangeProdSchema.errors(data).map { |message| "error: #{message}" })
      lines.concat(ChangeProdSchema.online_safe_ops(data).map { |op| "notice: prod op #{op[:op]} is online_safe: #{op[:reason]}" })
      lines.concat(ChangeProdSchema.missing_probes(data).map { |name| "warning: prod backup #{name} has no restore_probe" })
    end
    lines << "error: #{ChangeProdRunnerGen::WORKFLOW} was edited by hand; regenerate it with change_prod_runner_gen.rb" if File.exist?(workflow) && ChangeProdRunnerGen.tampered?(File.read(workflow))
    lines
  rescue StandardError
    []
  end
  private_class_method :prod_schema_lines

  def self.delivery_rollout_line(rollout)
    stages = rollout.stages.map { |stage| stage.is_a?(Hash) ? stage['cohort'] : '?' }.join(' > ')
    "delivery: rollout #{rollout.name} flag=#{rollout.flag} owner=#{rollout.owner || '(none)'} " \
      "revision=#{rollout.revision} advance=#{rollout.advance}#{' money_affecting' if rollout.money_affecting?} " \
      "stages=#{stages}#{" source=#{rollout.source}" if rollout.source}"
  end
  private_class_method :delivery_rollout_line

  def self.delivery_fixture_warnings(config, rollouts)
    delivery = config.is_a?(Hash) && config['delivery'].is_a?(Hash) ? config['delivery'] : {}
    rollouts.select { |rollout| rollout.config['profile'] == 'production' }.flat_map do |rollout|
      %w[flags metrics].filter_map do |key|
        adapter = (delivery[key].is_a?(Hash) ? delivery[key] : {})[rollout.config[key].to_s]
        next unless adapter.is_a?(Hash) && adapter['kind'] == 'fixture'

        "warning: delivery rollout #{rollout.name} runs on profile production with " \
          "#{key} '#{rollout.config[key]}' still kind fixture"
      end
    end
  end
  private_class_method :delivery_fixture_warnings

  # promotion.<ref>.require_scheduled (0.20.0): every named
  # schedule must be declared in the root change_config.schedules with a sane
  # max_age_days, and a branch rule gated on a local-runner schedule is
  # warned about. Silent when no rule sets require_scheduled.
  def self.require_scheduled_lines(change_md_path)
    policy = ChangePolicy.for_repo(File.dirname(change_md_path))
    return [] unless policy

    branch_rules = policy.branch_promotion.transform_keys { |branch| "promotion.#{branch}" }
    tag_rules = policy.tag_promotion.transform_keys { |pattern| "promotion.tag:#{pattern}" }
    rules = branch_rules.merge(tag_rules)
    return [] unless rules.values.any? { |rule| rule.is_a?(Hash) && rule.key?('require_scheduled') }

    schedules = ChangeScheduleConfig.new(ChangeFrontmatter.parse_file(change_md_path)['change_config'])
    schedules.require_scheduled_errors(rules).map { |message| "error: #{message}" } +
      schedules.require_scheduled_warnings(branch_rules)
  end
  private_class_method :require_scheduled_lines

  # For every protected branch, and every protected tag pattern, whose
  # promotion rule names a profile, every app required to gate it (the rule's
  # own `apps:` list, or every registered enabled app when omitted) must
  # either define that profile name or have no `profiles:` block at all;
  # otherwise the gate can never be satisfied for that app. Also flags an
  # explicitly empty `promotion.<ref>.apps: []`, which change_policy.rb
  # resolves to "every app" (the fail-closed reading a hook must take) rather
  # than the "gate nothing" a bare empty list visually suggests. A tag rule's
  # `apps:`/`profile:` mean exactly what a branch rule's do, so both are
  # checked identically here.
  def self.promotion_profile_coverage_errors(change_md_path, registry)
    policy = ChangePolicy.for_repo(File.dirname(change_md_path))
    return [] unless policy

    branch_errors = policy.protected_branches.flat_map do |branch|
      rule = policy.branch_promotion[branch.to_s]
      unsatisfiable_profile_errors(policy, registry, "promotion.#{branch}", rule) +
        empty_apps_list_error(rule, "promotion.#{branch}")
    end
    tag_errors = policy.tag_promotion.flat_map do |pattern, rule|
      unsatisfiable_profile_errors(policy, registry, "promotion.tag:#{pattern}", rule) +
        empty_apps_list_error(rule, "promotion.tag:#{pattern}")
    end
    branch_errors + tag_errors
  end
  private_class_method :promotion_profile_coverage_errors

  def self.unsatisfiable_profile_errors(policy, registry, label, rule)
    rule_profile = policy.profile_for_rule(rule)
    return [] unless rule_profile

    required_names = policy.apps_for_rule(rule) || registry.enabled_entries.map(&:name)
    required_names.filter_map do |name|
      entry = registry.entries.find { |candidate| candidate.name == name }
      next unless entry

      begin
        entry.load(profile: rule_profile)
        nil
      rescue ChangeConfig::ConfigError => e
        next unless e.message.include?('unknown profile')

        "error: #{label}.profile '#{rule_profile}' is unsatisfiable: app '#{name}' has no such " \
          "profile (#{e.message})"
      end
    end
  end
  private_class_method :unsatisfiable_profile_errors

  def self.empty_apps_list_error(rule, label)
    apps_value = rule.is_a?(Hash) ? rule['apps'] : nil
    return [] unless apps_value.is_a?(Array) && apps_value.empty?

    [ "error: change_policy.#{label}.apps is explicitly empty; that resolves to every " \
      "registered enabled app, not \"gate nothing\" -- use require_change_pass: false for that." ]
  end
  private_class_method :empty_apps_list_error

  # Independent of app-registry mode (single-app and monorepo alike): a
  # `promotion targets:` roll-up of every branch and tag rule with its
  # resolved profile/app set, plus the tag-specific `doctor` warnings from the
  # trunk + tag releases design: overlapping tag patterns (3.3), a
  # trunk-ancestor/prior-tag field misplaced on a branch rule (where nothing
  # reads it), and a `tag:` pattern with no glob metacharacter and no `/`
  # (probably a literal tag name, which works but was almost certainly meant
  # to be a pattern).
  def self.promotion_target_lines(change_md_path)
    policy = ChangePolicy.for_repo(File.dirname(change_md_path))
    return [] unless policy
    return [] if policy.branch_promotion.empty? && policy.tag_promotion.empty?

    lines = [ 'promotion targets:' ]
    policy.branch_promotion.each do |branch, rule|
      lines << "  branch #{branch}: #{promotion_target_summary(policy, rule)}"
      lines.concat(misplaced_tag_field_warnings(policy, "promotion.#{branch}", rule))
    end
    policy.tag_promotion.each do |pattern, rule|
      environment = policy.environment_for_rule(rule, pattern)
      lines << "  tag:#{pattern} (#{environment}): #{promotion_target_summary(policy, rule)}"
      lines.concat(literal_tag_pattern_warning(pattern))
    end
    lines.concat(overlapping_tag_pattern_warnings(policy))
    lines
  end
  private_class_method :promotion_target_lines

  def self.promotion_target_summary(policy, rule)
    profile = policy.profile_for_rule(rule) || '(none)'
    apps = policy.apps_for_rule(rule) || [ 'every enabled app' ]
    "profile=#{profile} apps=#{apps.join(', ')}"
  end
  private_class_method :promotion_target_summary

  def self.misplaced_tag_field_warnings(policy, label, rule)
    warnings = []
    if policy.require_trunk_ancestor_for_rule(rule)
      warnings << "warning: #{label}.require_trunk_ancestor is set on a branch rule; only tag rules read it"
    end
    if policy.require_prior_tag_for_rule(rule)
      warnings << "warning: #{label}.require_prior_tag is set on a branch rule; only tag rules read it"
    end
    warnings
  end
  private_class_method :misplaced_tag_field_warnings

  def self.literal_tag_pattern_warning(pattern)
    return [] if pattern.match?(/[*?\[\]{}]/) || pattern.include?('/')

    [ "warning: tag:#{pattern} has no glob metacharacter and no '/'; it matches only the literal tag " \
      "'#{pattern}', which works but was probably meant to be a pattern" ]
  end
  private_class_method :literal_tag_pattern_warning

  # A repo-authoring lint, not a hard rule: two tag patterns "can overlap"
  # when concretizing one pattern's wildcards with a filler token yields a tag
  # the other pattern also matches (checked both directions). Heuristic, not
  # exhaustive, but catches the common case (`tag:staging/v*` and
  # `tag:staging/v1.*`) so the author sees the union before it surprises them
  # at push time: every matching rule is required, none silently outranks
  # another.
  def self.overlapping_tag_pattern_warnings(policy)
    patterns = policy.tag_promotion.keys
    patterns.combination(2).select { |a, b| tag_patterns_overlap?(a, b) }.map do |a, b|
      "warning: tag:#{a} and tag:#{b} can both match the same tag; every matching rule is required, " \
        'not just the more specific one'
    end
  end
  private_class_method :overlapping_tag_pattern_warnings

  def self.tag_patterns_overlap?(pattern_a, pattern_b)
    return false if pattern_a == pattern_b

    sample_a = pattern_a.gsub('**', 'x').gsub('*', 'x')
    sample_b = pattern_b.gsub('**', 'x').gsub('*', 'x')
    File.fnmatch(pattern_a, sample_b, File::FNM_PATHNAME) || File.fnmatch(pattern_b, sample_a, File::FNM_PATHNAME)
  end
  private_class_method :tag_patterns_overlap?
end
