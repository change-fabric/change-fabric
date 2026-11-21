#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'change_prod_claim'

# Validates the bounded prod runner blocks spec 0.29.0 adds:
# change_config.runners, backups, maintenance and operations, and
# change_policy.prod_guard. The blocks are read from the base branch.
#
# The floors are fixed by design and the schema rejects anything looser: both
# approval factors (passkey with user verification and TOTP) with a remote
# proof, PITR of at least 72 hours, a restore probe no older than 7 days, a
# maintenance exit whenever there is an enter, every op naming a window or
# carrying a reasoned online_safe opt-out, a backup on every op, typed params
# with no free-form shell, and argv placeholders only from declared params.
#
# Pure validation over parsed YAML. Every method returns messages naming the
# field; empty is valid. A config with none of the blocks is valid.
module ChangeProdSchema
  RUNNER_KINDS = %w[github_actions fixture].freeze
  RUNNER_KEYS = %w[kind workflow environments oidc_roles region claim_role claim_table reconcile_role].freeze
  BACKUP_KINDS = %w[rds_snapshot aurora_snapshot pg_dump_s3 command fixture].freeze
  PITR_KINDS = %w[rds_snapshot aurora_snapshot].freeze
  BACKUP_KEYS = %w[kind target targets provider snapshot verify pitr pitr_source restore_probe].freeze
  # Kinds with no provider API to snapshot through: the config names the command.
  SNAPSHOT_COMMAND_KINDS = %w[pg_dump_s3 command].freeze
  PROBE_KEYS = %w[schedule argv timeout_s max_age_days oidc_roles].freeze
  MAINTENANCE_KEYS = %w[windows enter verify exit].freeze
  WINDOW_KEYS = %w[cron duration_minutes tz].freeze
  OPERATION_KEYS = %w[class runner argv cwd params backup maintenance online_safe verify timeout_s estimate staging_first].freeze
  CLASSES = %w[destructive_data contracts_and_auth money_and_sends gate_config routine].freeze
  # The request envelope validator carries string params only.
  PARAM_TYPES = %w[string].freeze
  PARAM_KEYS = %w[type pattern per_environment].freeze
  ESTIMATE_KEYS = %w[minutes cost_usd].freeze
  GUARD_KEYS = %w[approval dispatch_gate require_staging_first refuse_without_pitr max_concurrent_ops].freeze
  APPROVAL_KEYS = %w[via factors proof ttl_minutes].freeze
  FACTORS = %w[passkey_uv totp].freeze

  # Schema-fixed floors and ceilings.
  MIN_PITR_HOURS = 72
  MAX_PROBE_AGE_DAYS = 7
  MAX_TIMEOUT_S = 86_400
  MAX_TTL_MINUTES = 60
  SHELLS = %w[sh bash zsh dash ksh fish csh tcsh ash].freeze
  NAME = /\A[a-z][a-z0-9_-]{0,62}\z/
  OP = /\A[a-z][a-z0-9_]{0,62}\z/
  ROLE = %r{\Aarn:aws:iam::\d{12}:role/[A-Za-z0-9+=,.@_/-]{1,128}\z}
  PLACEHOLDER = /\{([^{}]*)\}/
  CRON_FIELD = %r{\A(\*|\d+(-\d+)?)(/\d+)?(,(\*|\d+(-\d+)?)(/\d+)?)*\z}

  ZONEINFO_DIRS = %w[/usr/share/zoneinfo /usr/share/lib/zoneinfo /usr/lib/zoneinfo].freeze

  module_function

  # True for UTC or an Area/City name present in the system zoneinfo. An unknown
  # name must never reach ENV['TZ'], which falls back to UTC without a word.
  def known_zone?(name)
    return true if name == 'UTC'
    return false unless name.to_s.match?(%r{\A[A-Za-z]+(/[A-Za-z_+-]+)+\z})

    ZONEINFO_DIRS.any? { |dir| File.file?(File.join(dir, name)) }
  end

  # Every problem with the five blocks together. `config` is the parsed
  # frontmatter (or its change_config); `policy` defaults to the sibling key.
  def errors(config, policy = nil)
    if policy.nil? && config.is_a?(Hash) && config.key?('change_config')
      policy = config['change_policy']
      config = config['change_config']
    end
    Validator.new(config.is_a?(Hash) ? config : {}, policy.is_a?(Hash) ? policy : {}).errors
  end

  # Ops with an online_safe opt-out, [{op:, reason:}], for doctor.
  def online_safe_ops(config)
    ops = config.is_a?(Hash) ? config.dig('change_config', 'operations') : nil
    return [] unless ops.is_a?(Hash)

    ops.filter_map do |name, definition|
      opt = definition.is_a?(Hash) ? definition['online_safe'] : nil
      { op: name.to_s, reason: opt['reason'].to_s } if opt.is_a?(Hash)
    end
  end

  # Backup names with no restore_probe, for doctor.
  def missing_probes(config)
    backups = config.is_a?(Hash) ? config.dig('change_config', 'backups') : nil
    return [] unless backups.is_a?(Hash)

    backups.filter_map { |name, backup| name.to_s unless backup.is_a?(Hash) && backup['restore_probe'].is_a?(Hash) }
  end

  def present?(value) = value.is_a?(String) && !value.strip.empty?
  def int_in?(value, range) = value.is_a?(Integer) && range.cover?(value)
  def string_list?(value) = value.is_a?(Array) && !value.empty? && value.all? { |item| item.is_a?(String) && !item.empty? }

  def unknown(hash, allowed, field)
    extra = hash.keys.map(&:to_s) - allowed
    extra.empty? ? [] : [ "#{field} sets unknown key(s): #{extra.join(', ')}" ]
  end

  # Walks the blocks once, collecting messages.
  class Validator
    def initialize(config, policy)
      @config = config
      @policy = policy
      @errors = []
    end

    def errors
      %w[runners backups maintenance operations].each do |key|
        check_block(key) if @config.key?(key)
      end
      check_guard if @policy.key?('prod_guard')
      check_joins
      @errors
    end

    private

    def add(message) = @errors << message
    def mapping(value) = value.is_a?(Hash) ? value : {}
    def section(key) = mapping(@config[key])
    def fail_unknown(hash, allowed, field) = @errors.concat(ChangeProdSchema.unknown(hash, allowed, field))

    def check_block(key)
      value = @config[key]
      return add("change_config.#{key} must be a mapping") unless value.is_a?(Hash)

      case key
      when 'runners' then each_named(value, key, NAME) { |name, entry, where| check_runner(name, entry, where) }
      when 'backups' then each_named(value, key, NAME) { |name, entry, where| check_backup(name, entry, where) }
      when 'operations' then each_named(value, key, OP) { |name, entry, where| check_operation(name, entry, where) }
      else check_maintenance(value)
      end
    end

    def each_named(map, key, pattern)
      map.each do |name, entry|
        where = "change_config.#{key}.#{name}"
        next add("#{where} is not a valid name") unless name.to_s.match?(pattern)
        next add("#{where} must be a mapping") unless entry.is_a?(Hash)

        yield name.to_s, entry, where
      end
    end

    # --- runners ----------------------------------------------------------

    def check_runner(_name, runner, where)
      fail_unknown(runner, RUNNER_KEYS, where)
      add("#{where}.kind must be one of #{RUNNER_KINDS.join(', ')}") unless RUNNER_KINDS.include?(runner['kind'])
      check_claim(runner, where) if runner['kind'] == 'github_actions'
      add("#{where}.workflow must be a .github/workflows/*.yml path") unless runner['workflow'].to_s.match?(%r{\A\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml\z})
      environments = runner['environments']
      roles = runner['oidc_roles']
      return add("#{where}.environments and #{where}.oidc_roles must be mappings") unless environments.is_a?(Hash) && roles.is_a?(Hash)

      add("#{where}.environments must name at least one profile") if environments.empty?
      environments.each do |profile, env|
        add("#{where}.environments.#{profile} must be a plain environment name") unless env.to_s.match?(NAME)
        add("#{where}.oidc_roles.#{profile} must be an IAM role ARN") unless roles[profile].to_s.match?(ROLE)
      end
      (roles.keys - environments.keys).each { |profile| add("#{where}.oidc_roles.#{profile} has no environment") }
      shared = environments.values.tally.select { |_, count| count > 1 }.keys
      add("#{where}.environments maps two profiles to #{shared.join(', ')}; one approval must select one role") unless shared.empty?
    end

    # The generated claim job reads these through ChangeProdClaim.settings, so
    # a config missing them cannot generate even the staging workflow.
    def check_claim(runner, where)
      add("#{where}.claim_role must be an IAM role ARN") unless runner['claim_role'].to_s.match?(ChangeProdClaim::ROLE)
      add("#{where}.claim_table must be a table name") unless runner['claim_table'].to_s.match?(ChangeProdClaim::TABLE)
      add("#{where}.reconcile_role must be an IAM role ARN") unless runner['reconcile_role'].nil? || runner['reconcile_role'].to_s.match?(ROLE)
      add("#{where}.region must be an AWS region") unless runner['region'].nil? || runner['region'].to_s.match?(ChangeProdClaim::REGION)
    end

    # --- backups ----------------------------------------------------------

    def check_backup(_name, backup, where)
      fail_unknown(backup, BACKUP_KEYS, where)
      kind = backup['kind']
      add("#{where}.kind must be one of #{BACKUP_KINDS.join(', ')}") unless BACKUP_KINDS.include?(kind)
      check_target(backup, where)
      add("#{where}.provider must be a non-empty string") unless ChangeProdSchema.present?(backup['provider'])
      check_snapshot(backup, where)
      check_command(backup['verify'], "#{where}.verify", required: true)
      check_pitr(backup, where)
      check_probe(backup['restore_probe'], "#{where}.restore_probe") if backup.key?('restore_probe')
    end

    # pg_dump_s3 and command have no API to snapshot through, so they name the
    # command that does; the other kinds snapshot through the provider.
    def check_snapshot(backup, where)
      needed = SNAPSHOT_COMMAND_KINDS.include?(backup['kind'])
      return add("#{where}.snapshot is required for #{backup['kind']} (it has no provider API to snapshot through)") if needed && backup['snapshot'].nil?

      check_command(backup['snapshot'], "#{where}.snapshot") unless backup['snapshot'].nil?
    end

    def check_target(backup, where)
      targets = backup['targets']
      if targets
        add("#{where}.targets must map each environment to a resource id") unless targets.is_a?(Hash) && !targets.empty? &&
                                                                                          targets.all? { |env, id| env.to_s.match?(NAME) && ChangeProdSchema.present?(id) }
      elsif !ChangeProdSchema.present?(backup['target'])
        add("#{where} needs target or targets")
      end
    end

    # PITR floor: 72 hours or more. pg_dump_s3 and command cannot prove PITR,
    # so they are valid only with a pitr_source naming a backup that can.
    def check_pitr(backup, where)
      pitr = backup['pitr']
      hours = pitr.is_a?(Hash) ? pitr['required_hours'] : nil
      if pitr.nil? || (pitr.is_a?(Hash) && !pitr.key?('required_hours'))
        hours = MIN_PITR_HOURS
      elsif !pitr.is_a?(Hash) || !hours.is_a?(Integer)
        return add("#{where}.pitr.required_hours must be an integer")
      end
      add("#{where}.pitr.required_hours must be at least #{MIN_PITR_HOURS}") if hours < MIN_PITR_HOURS
      return if PITR_KINDS.include?(backup['kind']) || backup['kind'] == 'fixture'

      source = backup['pitr_source']
      add("#{where}.pitr_source must name a rds_snapshot or aurora_snapshot backup (#{backup['kind']} cannot prove PITR)") unless pitr_source?(source)
    end

    def pitr_source?(name)
      source = section('backups')[name.to_s]
      source.is_a?(Hash) && PITR_KINDS.include?(source['kind'])
    end

    def check_probe(probe, where)
      return add("#{where} must be a mapping") unless probe.is_a?(Hash)

      fail_unknown(probe, PROBE_KEYS, where)
      add("#{where}.schedule must be weekly") unless probe['schedule'] == 'weekly'
      check_command(probe, where, required: true)
      check_probe_roles(probe['oidc_roles'], "#{where}.oidc_roles", where)
      age = probe['max_age_days']
      add("#{where}.max_age_days must be an integer from 1 to #{MAX_PROBE_AGE_DAYS}") unless age.nil? || ChangeProdSchema.int_in?(age, 1..MAX_PROBE_AGE_DAYS)
    end

    # The generated restore-probe workflow assumes one role per profile it
    # probes. Optional: with none, the backup has a probe but no workflow job.
    def check_probe_roles(roles, field, probe_where)
      return if roles.nil?
      return add("#{field} must map a profile to an IAM role ARN") unless roles.is_a?(Hash) && !roles.empty?

      backup = section('backups')[probe_where.split('.')[-2]]
      targets = backup.is_a?(Hash) ? backup['targets'] : nil
      roles.each do |profile, role|
        add("#{field}.#{profile} must be an IAM role ARN") unless role.to_s.match?(ROLE)
        add("#{field}.#{profile} is not a profile of the backup targets") if targets.is_a?(Hash) && !targets.key?(profile)
      end
    end

    # argv plus timeout_s, the shape every command has here.
    def check_command(command, where, required: false)
      return (required ? add("#{where} is required") : nil) if command.nil?
      return add("#{where} must be a mapping") unless command.is_a?(Hash)

      add("#{where}.argv must be a non-empty list of strings") unless ChangeProdSchema.string_list?(command['argv'])
      add("#{where}.argv must not start a shell") if shell?(command['argv'])
      add("#{where}.timeout_s must be an integer from 1 to #{MAX_TIMEOUT_S}") unless ChangeProdSchema.int_in?(command['timeout_s'], 1..MAX_TIMEOUT_S)
    end

    def shell?(argv)
      argv.is_a?(Array) && argv.first.is_a?(String) && SHELLS.include?(File.basename(argv.first))
    end

    # --- maintenance ------------------------------------------------------

    def check_maintenance(block)
      where = 'change_config.maintenance'
      fail_unknown(block, MAINTENANCE_KEYS, where)
      check_windows(block['windows'], "#{where}.windows")
      %w[enter verify exit].each { |step| check_command(block[step], "#{where}.#{step}") if block.key?(step) }
      add("#{where}.exit is required whenever #{where}.enter is set") if block.key?('enter') && !block['exit']
      add("#{where}.verify is required whenever #{where}.enter is set") if block.key?('enter') && !block['verify']
    end

    def check_windows(windows, where)
      return if windows.nil?
      return add("#{where} must be a mapping") unless windows.is_a?(Hash)

      windows.each do |name, window|
        field = "#{where}.#{name}"
        next add("#{field} must be a mapping") unless window.is_a?(Hash) && name.to_s.match?(NAME)

        fail_unknown(window, WINDOW_KEYS, field)
        add("#{field}.cron must be five cron fields") unless cron?(window['cron'])
        add("#{field}.duration_minutes must be an integer from 1 to 1440") unless ChangeProdSchema.int_in?(window['duration_minutes'], 1..1440)
        add("#{field}.tz must be a known time zone name") unless ChangeProdSchema.known_zone?(window['tz'].to_s)
      end
    end

    def cron?(text)
      fields = text.to_s.split
      fields.size == 5 && fields.all? { |field| field.match?(CRON_FIELD) }
    end

    # --- operations -------------------------------------------------------

    def check_operation(name, op, where)
      fail_unknown(op, OPERATION_KEYS, where)
      add("#{where}.class must be one of #{CLASSES.join(', ')}") unless CLASSES.include?(op['class'])
      add("#{where}.runner must name a declared runner") unless section('runners')[op['runner'].to_s].is_a?(Hash)
      add("#{where}.backup must name a declared backup (every op needs one, whatever its class)") unless section('backups')[op['backup'].to_s].is_a?(Hash)
      params = check_params(op['params'], "#{where}.params")
      check_argv(op['argv'], params, "#{where}.argv")
      check_command(op['verify'], "#{where}.verify", required: true)
      check_placeholders(op.dig('verify', 'argv'), params, "#{where}.verify.argv") if op['verify'].is_a?(Hash)
      add("#{where}.timeout_s must be an integer from 1 to #{MAX_TIMEOUT_S}") unless ChangeProdSchema.int_in?(op['timeout_s'], 1..MAX_TIMEOUT_S)
      add("#{where}.cwd must be repo") unless op['cwd'].nil? || op['cwd'] == 'repo'
      check_window_choice(op, where)
      check_estimate(op['estimate'], "#{where}.estimate") if op.key?('estimate')
      add("#{where}.staging_first must be true or false") unless op['staging_first'].nil? || [ true, false ].include?(op['staging_first'])
      add("#{where} is not a valid op name") unless name.match?(OP)
    end

    def check_window_choice(op, where)
      window = op['maintenance']
      opt = op['online_safe']
      return add("#{where} must name a maintenance window or carry online_safe.reason, not both") if window && opt
      return add("#{where} needs a maintenance window or an online_safe.reason") unless window || opt
      return add("#{where}.maintenance must name a window under change_config.maintenance.windows") if window && !mapping(section('maintenance')['windows'])[window.to_s].is_a?(Hash)

      add("#{where}.online_safe.reason must be a non-empty string") if opt && !(opt.is_a?(Hash) && ChangeProdSchema.present?(opt['reason']))
      fail_unknown(opt, %w[reason], "#{where}.online_safe") if opt.is_a?(Hash)
    end

    def check_estimate(estimate, where)
      return add("#{where} must be a mapping") unless estimate.is_a?(Hash)

      fail_unknown(estimate, ESTIMATE_KEYS, where)
      estimate.each_value { |value| add("#{where} values must be non-negative numbers") unless value.is_a?(Numeric) && value >= 0 }
    end

    # Typed, closed params: every param is a string with an anchored pattern, so
    # no free-form text reaches argv. Returns the declared names.
    def check_params(params, where)
      return [] if params.nil?
      return add("#{where} must be a mapping") && [] unless params.is_a?(Hash)

      params.each do |name, spec|
        field = "#{where}.#{name}"
        next add("#{field} must be a mapping") unless spec.is_a?(Hash) && name.to_s.match?(OP)

        fail_unknown(spec, PARAM_KEYS, field)
        check_param(spec, field)
      end
      params.keys.map(&:to_s)
    end

    def check_param(spec, field)
      return add("#{field}.type must be string (the request envelope carries string params only)") unless PARAM_TYPES.include?(spec['type'])

      check_pattern(spec['pattern'], field)
    end

    def check_pattern(pattern, field)
      return add("#{field}.pattern is required (a string param is never free-form)") unless ChangeProdSchema.present?(pattern)

      add("#{field}.pattern must be anchored with ^ and $ (or \\A and \\z)") unless pattern.match?(/\A(\^|\\A).*(\$|\\z)\z/m)
      Regexp.new(pattern)
    rescue RegexpError
      add("#{field}.pattern is not a valid regular expression")
    end

    def check_argv(argv, params, where)
      return add("#{where} must be a non-empty list of strings") unless ChangeProdSchema.string_list?(argv)

      add("#{where} must not start a shell; list the program and its arguments") if shell?(argv)
      check_placeholders(argv, params, where)
    end

    # Placeholders may stand alone only as whole `{param}` tokens inside an
    # argument, and only for declared params.
    def check_placeholders(argv, params, where)
      return unless argv.is_a?(Array)

      used = argv.grep(String).flat_map { |arg| arg.scan(PLACEHOLDER).flatten }
      unknown = used.uniq - params
      add("#{where} uses undeclared params: #{unknown.join(', ')}") unless unknown.empty?
    end

    # --- change_policy.prod_guard -----------------------------------------

    def check_guard
      guard = @policy['prod_guard']
      where = 'change_policy.prod_guard'
      return add("#{where} must be a mapping") unless guard.is_a?(Hash)

      fail_unknown(guard, GUARD_KEYS, where)
      check_approval(guard['approval'], "#{where}.approval")
      add("#{where}.dispatch_gate must be github_environment") unless guard['dispatch_gate'].nil? || guard['dispatch_gate'] == 'github_environment'
      add("#{where}.refuse_without_pitr cannot be set to false (floor)") if guard['refuse_without_pitr'] == false
      add("#{where}.refuse_without_pitr must be true") unless guard['refuse_without_pitr'].nil? || guard['refuse_without_pitr'] == true
      add("#{where}.max_concurrent_ops cannot exceed 1 (floor)") unless guard['max_concurrent_ops'].nil? || guard['max_concurrent_ops'] == 1
      add("#{where}.require_staging_first must be true or false") unless guard['require_staging_first'].nil? || [ true, false ].include?(guard['require_staging_first'])
    end

    def check_approval(approval, where)
      return add("#{where} must be a mapping") unless approval.is_a?(Hash)

      fail_unknown(approval, APPROVAL_KEYS, where)
      add("#{where}.via must be approval_console") unless approval['via'] == 'approval_console'
      factors = approval['factors']
      add("#{where}.factors must be exactly passkey_uv and totp (floor: both factors)") unless factors.is_a?(Array) && factors.map(&:to_s).sort == FACTORS.sort
      add("#{where}.proof must be remote (floor)") unless approval['proof'] == 'remote'
      ttl = approval['ttl_minutes']
      add("#{where}.ttl_minutes must be an integer from 1 to #{MAX_TTL_MINUTES}") unless ttl.nil? || ChangeProdSchema.int_in?(ttl, 1..MAX_TTL_MINUTES)
    end

    # --- joins ------------------------------------------------------------

    # Operations without a prod_guard run with no approval policy; the guard
    # is required as soon as any op is declared.
    def check_joins
      return unless @config['operations'].is_a?(Hash) && !@config['operations'].empty?

      add('change_policy.prod_guard is required when change_config.operations declares an op') unless @policy['prod_guard'].is_a?(Hash)
    end
  end
end
