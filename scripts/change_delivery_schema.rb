#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'json'
require 'yaml'

# Validates the progressive-delivery blocks spec 0.24.0 adds:
# change_config.delivery (wiring: flag adapters, metric sources, cohorts,
# verdict sources, rollouts) and change_policy.delivery (governance: guards,
# pacing, checkpoints, the breach response). The two are joined by rollout
# name, the trackers precedent, and both are read from the base branch.
#
# A rollout's stages, revision and pacing may live in a per-flag file
# (`source: delivery/<flag>.yml`). That file then owns those keys, and
# CHANGE.md setting any of them for the same rollout is an error.
#
# The floors are fixed by design and the schema rejects anything looser:
# flag-off is always the first breach response, `everyone` is always a human
# checkpoint, a money-affecting rollout never advances automatically, the
# triage roast gate never drops below 9, at most 2 fix attempts in at most 60
# minutes, re-enable only on the first (internal) cohort, every page trigger
# stays on, telemetry older than 180s is never fresh, and a heartbeat gap over
# 10 minutes always alerts.
#
# Pure validation over parsed YAML (plus reading the per-flag files under the
# repo root). Every method returns messages naming the field; empty is valid.
module ChangeDeliverySchema
  CONFIG_KEYS = %w[flags metrics cohorts rollouts verdict_sources].freeze
  POLICY_KEYS = %w[require_rollout verdicts notify one_way_door_paths rollouts].freeze

  FLAGS_KINDS = %w[command fixture].freeze
  FLAGS_KEYS = %w[kind argv cwd timeout_s environments path intents discover].freeze
  QUEUE_KINDS = %w[file_drop command fixture].freeze
  QUEUE_KEYS = %w[kind path argv cwd timeout_s].freeze
  COMMAND_KEYS = %w[argv cwd timeout_s].freeze
  METRICS_KINDS = %w[signoz prometheus command fixture].freeze
  METRICS_KEYS = %w[kind url provider service flag_attribute cohort_attribute error_source argv cwd timeout_s path].freeze
  ERROR_SOURCES = %w[unsampled sampled].freeze
  COHORT_KINDS = %w[adapter_selector hash all].freeze
  COHORT_KEYS = {
    'adapter_selector' => %w[kind ids segment],
    'hash' => %w[kind percent hash_key],
    'all' => %w[kind]
  }.freeze
  ROLLOUT_KEYS = %w[owner flag flags metrics profile source revision stages].freeze
  # The keys a per-flag file owns once `source:` is set.
  SOURCED_KEYS = %w[revision stages].freeze
  FLAG_FILE_KEYS = %w[rollout revision stages pacing].freeze
  STAGE_KEYS = %w[cohort dwell_minutes min_requests advance].freeze
  ADVANCE = %w[auto manual].freeze

  VERDICTS_KEYS = %w[max_telemetry_age_s heartbeat_max_gap_minutes].freeze
  NOTIFY_KEYS = %w[dm page].freeze
  POLICY_ROLLOUT_KEYS = %w[guards pacing human_checkpoints on_breach].freeze
  GUARDS = {
    'new_5xx_on_flagged_spans' => %w[max],
    'new_exceptions_on_flagged_spans' => %w[max],
    'p95_ms_vs_baseline' => %w[max_ratio baseline]
  }.freeze
  BASELINES = %w[flag_off_last_7d].freeze
  PACING_KEYS = %w[advance money_affecting].freeze
  ON_BREACH_KEYS = %w[immediate then triage].freeze
  THEN = %w[triage human].freeze
  TRIAGE_KEYS = %w[fix_budget_minutes fix_attempts gate notify page_human_when
                   dispatch_timeout_minutes ack_timeout_minutes reenable].freeze
  PAGE_TRIGGERS = %w[gate_failed budget_exhausted one_way_door rebreach_after_fix].freeze
  REENABLE_AFTER = %w[fix_merged_and_staging_green].freeze

  # Schema-fixed ceilings and floors.
  MAX_TELEMETRY_AGE_S = 180
  MAX_HEARTBEAT_GAP_MINUTES = 10
  MIN_ROAST_SCORE = 9
  MAX_FIX_ATTEMPTS = 2
  MAX_FIX_BUDGET_MINUTES = 60
  MAX_DISPATCH_TIMEOUT_MINUTES = 10
  MAX_ACK_TIMEOUT_MINUTES = 20
  MAX_TIMEOUT_S = 3600
  EVERYONE = 'everyone'

  NAME = /\A[a-z0-9][a-z0-9_-]{0,62}\z/
  FLAG_KEY = /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/
  FLAG_FILE = %r{\Adelivery/[A-Za-z0-9][A-Za-z0-9_.-]*\.ya?ml\z}

  # One rollout after the per-flag file is merged in: the config wiring plus
  # the policy block of the same name.
  Rollout = Struct.new(:name, :config, :policy, keyword_init: true) do
    def owner = config['owner']
    def flag = config['flag']
    # An omitted inline revision is the documented default, 1.
    def revision = config['revision'].nil? ? 1 : config['revision']
    def stages = Array(config['stages'])
    def source = config['source']
    # A pacing block of the wrong shape reads as empty: check_pacing reports
    # it, and the cross-block floors must not crash on it.
    def pacing = [ config['pacing'], policy['pacing'] ].find { |block| block.is_a?(Hash) } || {}
    def money_affecting? = pacing['money_affecting'] == true
    def advance = pacing['advance'] || 'manual'

    # The stage advance modes in effect: a stage's own, else the rollout's.
    def stage_advances = stages.map { |stage| (stage.is_a?(Hash) && stage['advance']) || advance }

    # sha256 of the merged rollout: what the controller stamps on a verdict.
    def digest = ChangeDeliverySchema.digest(config.except('pacing').merge('pacing' => pacing, 'revision' => revision),
                                            policy.except('pacing'))
  end

  # Every problem with change_config.delivery and change_policy.delivery
  # together. root is the repo root that `source:` paths resolve against.
  def self.errors(config, policy, root: nil)
    Validator.new(config, policy, root).errors
  end

  # The merged rollouts, for doctor and the later phases. Malformed entries
  # are skipped; errors() names them.
  def self.rollouts(config, policy, root: nil)
    Validator.new(config, policy, root).rollouts
  end

  # A changed rollout whose revision did not increase against base. Both
  # arguments are the rollouts() of each side.
  def self.revision_errors(base_rollouts, head_rollouts)
    base = base_rollouts.to_h { |rollout| [ rollout.name, rollout ] }
    head_rollouts.filter_map do |rollout|
      before = base[rollout.name]
      next unless before && content_digest(before) != content_digest(rollout)
      next if rollout.revision.is_a?(Integer) && before.revision.is_a?(Integer) && rollout.revision > before.revision

      "delivery rollout '#{rollout.name}' changed without raising its revision " \
        "(base #{before.revision.inspect}, head #{rollout.revision.inspect})"
    end
  end

  def self.content_digest(rollout)
    digest(rollout.config.except('revision', 'pacing').merge('pacing' => rollout.pacing), rollout.policy.except('pacing'))
  end

  def self.digest(*parts) = Digest::SHA256.hexdigest(JSON.generate(canonical(parts)))

  def self.canonical(value)
    case value
    when Hash then value.keys.map(&:to_s).sort.map { |key| [ key, canonical(value[key] || value[key.to_sym]) ] }
    when Array then value.map { |item| canonical(item) }
    else value
    end
  end

  def self.unknown(hash, allowed, field)
    extra = hash.keys.map(&:to_s) - allowed
    extra.empty? ? [] : [ "#{field} sets unknown key(s): #{extra.join(', ')}" ]
  end

  def self.int_in?(value, range) = value.is_a?(Integer) && range.cover?(value)
  def self.present?(value) = value.is_a?(String) && !value.strip.empty?
  def self.string_list?(value) = value.is_a?(Array) && value.all? { |item| present?(item) }

  # Walks both blocks once, collecting messages.
  class Validator
    def initialize(config, policy, root)
      @config = (config.is_a?(Hash) ? config['delivery'] : nil)
      @policy = (policy.is_a?(Hash) ? policy['delivery'] : nil)
      @root = root
      @errors = []
      @files = {}
    end

    def errors
      return [] if @config.nil? && @policy.nil?

      check_config if @config
      check_policy if @policy
      check_join
      @errors
    end

    def rollouts
      return [] unless @config.is_a?(Hash) && @config['rollouts'].is_a?(Hash)

      @config['rollouts'].filter_map do |name, rollout|
        next unless rollout.is_a?(Hash)

        Rollout.new(name: name.to_s, config: merged(name.to_s, rollout), policy: policy_rollout(name.to_s))
      end
    end

    private

    def add(message) = @errors << message
    def mapping(value) = value.is_a?(Hash) ? value : {}
    def cohorts = mapping(@config.is_a?(Hash) ? @config['cohorts'] : nil)
    def policy_rollout(name) = mapping(mapping(mapping(@policy)['rollouts'])[name])

    # --- change_config.delivery -------------------------------------------

    def check_config
      field = 'change_config.delivery'
      return add("#{field} must be a mapping") unless @config.is_a?(Hash)

      @errors.concat(ChangeDeliverySchema.unknown(@config, CONFIG_KEYS, field))
      each_named(@config, 'flags', field) { |name, value, where| check_flags(name, value, where) }
      each_named(@config, 'metrics', field) { |name, value, where| check_metrics(name, value, where) }
      each_named(@config, 'cohorts', field) { |name, value, where| check_cohort(name, value, where) }
      each_named(@config, 'verdict_sources', field) { |_name, value, where| check_queue(value, where) }
      each_named(@config, 'rollouts', field) { |name, value, where| check_rollout(name, value, where) }
    end

    def each_named(block, key, field)
      return unless block.key?(key)

      where = "#{field}.#{key}"
      entries = block[key]
      return add("#{where} must be a non-empty mapping") unless entries.is_a?(Hash) && !entries.empty?

      entries.each do |name, value|
        add("#{where}.#{name}: name must match #{NAME.source}") unless name.to_s.match?(NAME)
        next add("#{where}.#{name} must be a mapping") unless value.is_a?(Hash)

        yield name.to_s, value, "#{where}.#{name}"
      end
    end

    def check_flags(_name, flags, field)
      @errors.concat(ChangeDeliverySchema.unknown(flags, FLAGS_KEYS, field))
      kind = flags['kind']
      add("#{field}.kind must be one of #{FLAGS_KINDS.join(', ')}") unless FLAGS_KINDS.include?(kind)
      check_command(flags, field) if kind == 'command'
      add("#{field}.path is required for kind fixture") if kind == 'fixture' && !ChangeDeliverySchema.present?(flags['path'])
      check_environments(flags['environments'], "#{field}.environments") if flags.key?('environments')
      check_queue(flags['intents'], "#{field}.intents") if flags.key?('intents')
      check_discover(flags['discover'], "#{field}.discover") if flags.key?('discover')
    end

    def check_environments(envs, field)
      valid = envs.is_a?(Hash) && !envs.empty? && envs.values.all? { |env| ChangeDeliverySchema.present?(env) }
      add("#{field} must map each profile to an adapter environment name") unless valid
    end

    def check_discover(discover, field)
      return add("#{field} must be a mapping") unless discover.is_a?(Hash)

      @errors.concat(ChangeDeliverySchema.unknown(discover, COMMAND_KEYS, field))
      check_command(discover, field)
    end

    # An intents queue or a verdict source: a file drop, a command or a fixture.
    def check_queue(queue, field)
      return add("#{field} must be a mapping") unless queue.is_a?(Hash)

      @errors.concat(ChangeDeliverySchema.unknown(queue, QUEUE_KEYS, field))
      kind = queue['kind']
      add("#{field}.kind must be one of #{QUEUE_KINDS.join(', ')}") unless QUEUE_KINDS.include?(kind)
      if kind == 'command'
        check_command(queue, field)
      elsif kind && !ChangeDeliverySchema.present?(queue['path'])
        add("#{field}.path is required for kind #{kind}")
      end
    end

    def check_command(block, field)
      add("#{field}.argv must be a non-empty list of strings") unless ChangeDeliverySchema.string_list?(block['argv']) && !block['argv'].empty?
      add("#{field}.cwd must be 'repo'") unless [ nil, 'repo' ].include?(block['cwd'])
      return if ChangeDeliverySchema.int_in?(block['timeout_s'], 1..MAX_TIMEOUT_S)

      add("#{field}.timeout_s must be an integer from 1 to #{MAX_TIMEOUT_S}")
    end

    def check_metrics(_name, metrics, field)
      @errors.concat(ChangeDeliverySchema.unknown(metrics, METRICS_KEYS, field))
      kind = metrics['kind']
      add("#{field}.kind must be one of #{METRICS_KINDS.join(', ')}") unless METRICS_KINDS.include?(kind)
      case kind
      when 'signoz', 'prometheus'
        %w[url provider service flag_attribute].each do |key|
          add("#{field}.#{key} is required for kind #{kind}") unless ChangeDeliverySchema.present?(metrics[key])
        end
        add("#{field}.provider must be an enrolled provider name") if metrics['provider'].is_a?(String) && !metrics['provider'].match?(NAME)
      when 'command' then check_command(metrics, field)
      when 'fixture'
        add("#{field}.path is required for kind fixture") unless ChangeDeliverySchema.present?(metrics['path'])
      end
      return if metrics['error_source'].nil? || ERROR_SOURCES.include?(metrics['error_source'])

      add("#{field}.error_source must be one of #{ERROR_SOURCES.join(', ')}")
    end

    def check_cohort(_name, cohort, field)
      kind = cohort['kind']
      return add("#{field}.kind must be one of #{COHORT_KINDS.join(', ')}") unless COHORT_KINDS.include?(kind)

      @errors.concat(ChangeDeliverySchema.unknown(cohort, COHORT_KEYS.fetch(kind), field))
      case kind
      when 'adapter_selector'
        set = %w[ids segment].count { |key| cohort.key?(key) }
        add("#{field} must set exactly one of ids or segment") unless set == 1
        add("#{field}.ids must be a non-empty list of strings") if cohort.key?('ids') && !(ChangeDeliverySchema.string_list?(cohort['ids']) && cohort['ids'].any?)
        add("#{field}.segment must be a string") if cohort.key?('segment') && !ChangeDeliverySchema.present?(cohort['segment'])
      when 'hash'
        add("#{field}.percent must be an integer from 1 to 99") unless ChangeDeliverySchema.int_in?(cohort['percent'], 1..99)
        add("#{field}.hash_key is required") unless ChangeDeliverySchema.present?(cohort['hash_key'])
      end
    end

    def check_rollout(name, rollout, field)
      @errors.concat(ChangeDeliverySchema.unknown(rollout, ROLLOUT_KEYS, field))
      add("#{field}.owner is required") unless ChangeDeliverySchema.present?(rollout['owner'])
      add("#{field}.flag must be a flag key") unless rollout['flag'].is_a?(String) && rollout['flag'].match?(FLAG_KEY)
      check_reference(rollout, 'flags', field)
      check_reference(rollout, 'metrics', field)
      add("#{field}.profile must be a profile name") unless ChangeDeliverySchema.present?(rollout['profile'])
      check_source(name, rollout, field) if rollout.key?('source')
      merged = merged(name, rollout)
      check_revision(merged['revision'], "#{rollout.key?('source') ? rollout['source'] : field}.revision", required: rollout.key?('source'))
      check_stages(merged['stages'], "#{rollout.key?('source') ? rollout['source'] : field}.stages")
    end

    def check_reference(rollout, key, field)
      names = mapping(@config[key]).keys.map(&:to_s)
      add("#{field}.#{key} names '#{rollout[key]}', which change_config.delivery.#{key} does not define") unless names.include?(rollout[key].to_s)
    end

    def check_revision(revision, field, required:)
      return if revision.nil? && !required
      return if ChangeDeliverySchema.int_in?(revision, 1..)

      add("#{field} must be an integer of at least 1")
    end

    def check_stages(stages, field)
      return add("#{field} must be a non-empty list") unless stages.is_a?(Array) && !stages.empty?

      stages.each_with_index do |stage, index|
        where = "#{field}[#{index}]"
        next add("#{where} must be a mapping") unless stage.is_a?(Hash)

        @errors.concat(ChangeDeliverySchema.unknown(stage, STAGE_KEYS, where))
        add("#{where}.cohort names '#{stage['cohort']}', which change_config.delivery.cohorts does not define") unless cohorts.key?(stage['cohort'].to_s)
        %w[dwell_minutes min_requests].each do |key|
          add("#{where}.#{key} must be an integer of at least 0") if stage.key?(key) && !ChangeDeliverySchema.int_in?(stage[key], 0..)
        end
        add("#{where}.advance must be one of #{ADVANCE.join(', ')}") if stage.key?('advance') && !ADVANCE.include?(stage['advance'])
      end
      last = stages.last
      return if last.is_a?(Hash) && last['cohort'] == EVERYONE && mapping(cohorts[EVERYONE])['kind'] == 'all'

      add("#{field}: the last stage must be cohort '#{EVERYONE}' of kind all")
    end

    # --- per-flag files -----------------------------------------------------

    def check_source(name, rollout, field)
      path = rollout['source']
      return add("#{field}.source must be a path under delivery/ ending in .yml") unless path.is_a?(String) && path.match?(FLAG_FILE) && !path.include?('..')

      (SOURCED_KEYS & rollout.keys.map(&:to_s)).each do |key|
        add("#{field}.#{key} is set in CHANGE.md and the per-flag file #{path} owns it; set it in one place")
      end
      if policy_rollout(name).key?('pacing')
        add("change_policy.delivery.rollouts.#{name}.pacing is set in CHANGE.md and the per-flag file #{path} owns it; set it in one place")
      end
      file = flag_file(path)
      return if file.empty?

      @errors.concat(ChangeDeliverySchema.unknown(file, FLAG_FILE_KEYS, path))
      add("#{path}.rollout must be '#{name}'") unless file['rollout'] == name
      check_pacing(file['pacing'], "#{path}.pacing") if file.key?('pacing')
    end

    def flag_file(path)
      @files[path] ||= begin
        if @root.nil?
          {}
        else
          full = File.join(@root, path)
          if File.file?(full)
            data = YAML.safe_load_file(full)
            data.is_a?(Hash) ? data : (add("#{path} must be a mapping") && {})
          else
            add("#{path} not found (named by a delivery rollout's source)")
            {}
          end
        end
      rescue Psych::Exception => e
        add("#{path} is not valid YAML: #{e.message}")
        {}
      end
    end

    # The rollout's config with the per-flag file's keys merged in.
    def merged(_name, rollout)
      return rollout unless rollout['source'].is_a?(String) && rollout['source'].match?(FLAG_FILE)

      file = flag_file(rollout['source'])
      rollout.except(*SOURCED_KEYS).merge(file.slice(*SOURCED_KEYS, 'pacing'))
    end

    # --- change_policy.delivery -------------------------------------------

    def check_policy
      field = 'change_policy.delivery'
      return add("#{field} must be a mapping") unless @policy.is_a?(Hash)

      @errors.concat(ChangeDeliverySchema.unknown(@policy, POLICY_KEYS, field))
      add("#{field}.require_rollout must be true or false") if @policy.key?('require_rollout') && ![ true, false ].include?(@policy['require_rollout'])
      check_verdicts(@policy['verdicts'], "#{field}.verdicts") if @policy.key?('verdicts')
      check_notify(@policy['notify'], "#{field}.notify") if @policy.key?('notify')
      add("#{field}.one_way_door_paths must be a list of glob strings") if @policy.key?('one_way_door_paths') && !ChangeDeliverySchema.string_list?(@policy['one_way_door_paths'])
      each_named(@policy, 'rollouts', field) { |name, value, where| check_policy_rollout(name, value, where) }
    end

    def check_verdicts(verdicts, field)
      return add("#{field} must be a mapping") unless verdicts.is_a?(Hash)

      @errors.concat(ChangeDeliverySchema.unknown(verdicts, VERDICTS_KEYS, field))
      if verdicts.key?('max_telemetry_age_s') && !ChangeDeliverySchema.int_in?(verdicts['max_telemetry_age_s'], 1..MAX_TELEMETRY_AGE_S)
        add("#{field}.max_telemetry_age_s must be an integer from 1 to #{MAX_TELEMETRY_AGE_S}")
      end
      return unless verdicts.key?('heartbeat_max_gap_minutes')
      return if ChangeDeliverySchema.int_in?(verdicts['heartbeat_max_gap_minutes'], 1..MAX_HEARTBEAT_GAP_MINUTES)

      add("#{field}.heartbeat_max_gap_minutes must be an integer from 1 to #{MAX_HEARTBEAT_GAP_MINUTES}")
    end

    def check_notify(notify, field)
      return add("#{field} must be a mapping") unless notify.is_a?(Hash)

      @errors.concat(ChangeDeliverySchema.unknown(notify, NOTIFY_KEYS, field))
      notify.each do |key, provider|
        add("#{field}.#{key} must be an enrolled provider name") unless provider.is_a?(String) && provider.match?(NAME)
      end
    end

    def check_policy_rollout(name, rollout, field)
      @errors.concat(ChangeDeliverySchema.unknown(rollout, POLICY_ROLLOUT_KEYS, field))
      check_guards(rollout['guards'], "#{field}.guards")
      check_pacing(rollout['pacing'], "#{field}.pacing") if rollout.key?('pacing')
      check_checkpoints(rollout['human_checkpoints'], "#{field}.human_checkpoints") if rollout.key?('human_checkpoints')
      check_on_breach(name, rollout['on_breach'], "#{field}.on_breach") if rollout.key?('on_breach')
      check_first_cohort(name, rollout, field)
    end

    def check_guards(guards, field)
      return add("#{field} must be a non-empty mapping") unless guards.is_a?(Hash) && !guards.empty?

      guards.each do |name, guard|
        allowed = GUARDS[name.to_s]
        next add("#{field}.#{name} is not a known guard (#{GUARDS.keys.join(', ')})") unless allowed
        next add("#{field}.#{name} must be a mapping") unless guard.is_a?(Hash)

        @errors.concat(ChangeDeliverySchema.unknown(guard, allowed, "#{field}.#{name}"))
        if allowed.include?('max')
          add("#{field}.#{name}.max must be an integer of at least 0") unless ChangeDeliverySchema.int_in?(guard['max'], 0..)
        else
          add("#{field}.#{name}.max_ratio must be a number above 1") unless guard['max_ratio'].is_a?(Numeric) && guard['max_ratio'] > 1
          add("#{field}.#{name}.baseline must be one of #{BASELINES.join(', ')}") unless BASELINES.include?(guard['baseline'])
        end
      end
    end

    def check_pacing(pacing, field)
      return add("#{field} must be a mapping") unless pacing.is_a?(Hash)

      @errors.concat(ChangeDeliverySchema.unknown(pacing, PACING_KEYS, field))
      add("#{field}.advance must be one of #{ADVANCE.join(', ')}") if pacing.key?('advance') && !ADVANCE.include?(pacing['advance'])
      add("#{field}.money_affecting must be true or false") if pacing.key?('money_affecting') && ![ true, false ].include?(pacing['money_affecting'])
    end

    def check_checkpoints(checkpoints, field)
      return add("#{field} must be a list of cohort names") unless ChangeDeliverySchema.string_list?(checkpoints)

      add("#{field} must contain '#{EVERYONE}'; that checkpoint cannot be removed") unless checkpoints.include?(EVERYONE)
      (checkpoints - cohorts.keys.map(&:to_s)).each do |name|
        add("#{field} names '#{name}', which change_config.delivery.cohorts does not define")
      end
    end

    def check_on_breach(_name, on_breach, field)
      return add("#{field} must be a mapping") unless on_breach.is_a?(Hash)

      @errors.concat(ChangeDeliverySchema.unknown(on_breach, ON_BREACH_KEYS, field))
      add("#{field}.immediate must be flag_off; flag-off always comes first") if on_breach.key?('immediate') && on_breach['immediate'] != 'flag_off'
      add("#{field}.then must be one of #{THEN.join(', ')}") if on_breach.key?('then') && !THEN.include?(on_breach['then'])
      check_triage(on_breach['triage'], "#{field}.triage") if on_breach.key?('triage')
    end

    def check_triage(triage, field)
      return add("#{field} must be a mapping") unless triage.is_a?(Hash)

      @errors.concat(ChangeDeliverySchema.unknown(triage, TRIAGE_KEYS, field))
      ceiling(triage, 'fix_budget_minutes', MAX_FIX_BUDGET_MINUTES, field)
      ceiling(triage, 'fix_attempts', MAX_FIX_ATTEMPTS, field)
      ceiling(triage, 'dispatch_timeout_minutes', MAX_DISPATCH_TIMEOUT_MINUTES, field)
      ceiling(triage, 'ack_timeout_minutes', MAX_ACK_TIMEOUT_MINUTES, field)
      check_gate(triage['gate'], "#{field}.gate") if triage.key?('gate')
      add("#{field}.notify must be dm") if triage.key?('notify') && triage['notify'] != 'dm'
      check_page_triggers(triage['page_human_when'], "#{field}.page_human_when") if triage.key?('page_human_when')
      check_reenable(triage['reenable'], "#{field}.reenable") if triage.key?('reenable')
    end

    def ceiling(block, key, max, field)
      return if !block.key?(key) || ChangeDeliverySchema.int_in?(block[key], 1..max)

      add("#{field}.#{key} must be an integer from 1 to #{max}")
    end

    def check_gate(gate, field)
      return add("#{field} must be a mapping") unless gate.is_a?(Hash)

      @errors.concat(ChangeDeliverySchema.unknown(gate, %w[kind min_score], field))
      add("#{field}.kind must be roast") unless gate['kind'] == 'roast'
      return if !gate.key?('min_score') || (gate['min_score'].is_a?(Numeric) && gate['min_score'].between?(MIN_ROAST_SCORE, 10))

      add("#{field}.min_score must be from #{MIN_ROAST_SCORE} to 10")
    end

    def check_page_triggers(triggers, field)
      return add("#{field} must be a list") unless triggers.is_a?(Array)

      unknown = triggers - PAGE_TRIGGERS
      add("#{field} names unknown trigger(s): #{unknown.join(', ')}") unless unknown.empty?
      missing = PAGE_TRIGGERS - triggers
      add("#{field} must include every trigger; missing: #{missing.join(', ')}") unless missing.empty?
    end

    def check_reenable(reenable, field)
      return add("#{field} must be a mapping") unless reenable.is_a?(Hash)

      @errors.concat(ChangeDeliverySchema.unknown(reenable, %w[after cohort], field))
      add("#{field}.after must be one of #{REENABLE_AFTER.join(', ')}") if reenable.key?('after') && !REENABLE_AFTER.include?(reenable['after'])
    end

    # Floors that need both sides: a money-affecting rollout never auto
    # advances, and re-enable is only ever the first stage's internal cohort.
    def check_first_cohort(name, rollout, field)
      merged = rollouts.find { |candidate| candidate.name == name }
      return unless merged

      if merged.money_affecting? && merged.stage_advances.push(merged.advance).include?('auto')
        add("#{field}: rollout is money_affecting, so advance: auto is not allowed at the rollout or any stage")
      end
      check_reenable_cohort(merged, rollout, field)
    end

    def check_reenable_cohort(merged, rollout, field)
      on_breach = mapping(rollout['on_breach'])
      return if on_breach['then'] == 'human'

      first = merged.stages.first
      first_cohort = first.is_a?(Hash) ? first['cohort'].to_s : nil
      wanted = mapping(mapping(on_breach['triage'])['reenable'])['cohort']
      if wanted && wanted != first_cohort
        add("#{field}.on_breach.triage.reenable.cohort must be the first stage's cohort ('#{first_cohort}')")
      end
      return if first_cohort.nil? || mapping(cohorts[first_cohort])['kind'] == 'adapter_selector'

      add("#{field}: triage re-enables only the first stage's cohort, so '#{first_cohort}' must be kind adapter_selector")
    end

    # --- the join ----------------------------------------------------------

    def check_join
      config_names = mapping(mapping(@config)['rollouts']).keys.map(&:to_s)
      policy_names = mapping(mapping(@policy)['rollouts']).keys.map(&:to_s)
      (config_names - policy_names).each do |name|
        add("change_config.delivery.rollouts.#{name} has no change_policy.delivery.rollouts.#{name}")
      end
      (policy_names - config_names).each do |name|
        add("change_policy.delivery.rollouts.#{name} has no change_config.delivery.rollouts.#{name}")
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  require_relative 'change_frontmatter'
  path = ARGV.fetch(0, 'CHANGE.md')
  data = ChangeFrontmatter.parse_file(path)
  errors = ChangeDeliverySchema.errors(data['change_config'], data['change_policy'], root: File.dirname(File.expand_path(path)))
  puts(errors.empty? ? "delivery OK: #{path}" : errors.map { |message| "error: #{message}" })
  exit(errors.empty? ? 0 : 1)
end
