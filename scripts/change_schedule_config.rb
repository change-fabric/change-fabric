# frozen_string_literal: true

require_relative 'change_schema'

# change_config.schedules (0.19.0, unreleased): named schedules that run some
# lanes on a clock against one profile, separate from the per-PR sweep. This
# file only parses and validates the block into Schedule values; nothing here
# runs a lane or installs a scheduler entry.
#
# An absent block is an empty list, so a CHANGE.md that declares no schedules
# behaves exactly as it did before the block existed.
class ChangeScheduleConfig
  Schedule = Data.define(:name, :cron, :profile, :runner, :lanes, :overrides) do
    # The lane's override for this schedule, or an empty hash.
    def override(lane) = overrides.fetch(lane, {})

    def zap_mode = override('zap').fetch('mode', ChangeScheduleConfig::ZAP_DEFAULT_MODE)
    def active_scan? = lanes.include?('zap') && zap_mode == 'full'
  end

  NAME = /\A[a-z0-9][a-z0-9-]{0,40}\z/
  RUNNERS = %w[actions local].freeze
  KEYS = %w[cron profile runner lanes].freeze
  # The command lane has no scheduled execution: it is host-run and
  # base-trusted per sweep, not a clock-driven job.
  SCHEDULABLE_LANES = (ChangeSchema::LANES - %w[command]).freeze
  ZAP_MODES = %w[baseline full].freeze
  ZAP_DEFAULT_MODE = 'baseline'
  # Override fields per lane: the fields the lane already reads in
  # change_config.lanes (derived from the schema registry, so a new lane field
  # is overridable without a second list), minus `enabled`, plus zap.mode.
  # k6.script is an existing lane field, so it needs no addition.
  def self.lane_fields(lane)
    prefixes = [ "change_config.lanes.#{lane}.", 'change_config.lanes.<lane>.' ]
    ChangeSchema::FIELDS.filter_map do |path|
      prefix = prefixes.find { |candidate| path.start_with?(candidate) }
      prefix && path.delete_prefix(prefix)[/\A[a-z_]+/]
    end.uniq - %w[enabled]
  end

  OVERRIDE_FIELDS = SCHEDULABLE_LANES.to_h do |lane|
    [ lane, (lane_fields(lane) + (lane == 'zap' ? %w[mode] : [])).uniq.freeze ]
  end.freeze

  # minute, hour, day of month, month, day of week (0 and 7 are both Sunday).
  CRON_RANGES = [ 0..59, 0..23, 1..31, 1..12, 0..7 ].freeze
  CRON_FIELD_NAMES = %w[minute hour day-of-month month day-of-week].freeze
  MAX_AGE_DAYS = 1..90

  # `config` is the raw change_config mapping (before any profile merge).
  def initialize(config)
    @config = config.is_a?(Hash) ? config : {}
    @block = @config['schedules']
  end

  def declared? = @config.key?('schedules')

  # Every problem with the block, as messages naming the field. Empty when the
  # block is absent or valid.
  def errors
    errors = allow_active_scan_errors
    return errors unless declared?
    return errors + [ 'change_config.schedules must be a mapping of schedule name to settings' ] unless @block.is_a?(Hash)

    errors + @block.flat_map { |name, entry| schedule_errors(name.to_s, entry) }
  end

  # The parsed schedules, in declaration order. Only meaningful when #errors
  # is empty.
  def schedules
    return [] unless @block.is_a?(Hash)

    @block.map do |name, entry|
      entry = {} unless entry.is_a?(Hash)
      Schedule.new(name: name.to_s, cron: entry['cron'].to_s, profile: entry['profile'].to_s,
                   runner: entry['runner'].to_s, lanes: Array(entry['lanes']).map(&:to_s),
                   overrides: overrides_of(entry))
    end
  end

  def names = schedules.map(&:name)
  def fetch(name) = schedules.find { |schedule| schedule.name == name.to_s }

  # True when the profile has opted in to active scanning.
  def allow_active_scan?(profile)
    @config.dig('profiles', profile.to_s, 'allow_active_scan') == true
  end

  # Errors for change_policy promotion rules' require_scheduled blocks, given
  # the policy's branch and tag rules ({label => rule}).
  def require_scheduled_errors(rules)
    rules.flat_map do |label, rule|
      next [] unless rule.is_a?(Hash) && rule.key?('require_scheduled')

      required_errors("change_policy.#{label}.require_scheduled", rule['require_scheduled'])
    end
  end

  # Warnings for a branch rule gated on a local-runner schedule: the merge
  # guard may run on a machine that never ran that schedule.
  def require_scheduled_warnings(branch_rules)
    branch_rules.flat_map do |label, rule|
      next [] unless rule.is_a?(Hash) && rule['require_scheduled'].is_a?(Hash)

      rule['require_scheduled'].keys.filter_map do |name|
        schedule = fetch(name)
        next unless schedule&.runner == 'local'

        "warning: change_policy.#{label}.require_scheduled names '#{name}', a runner: local schedule; " \
          'a branch merge can be checked on a machine that never ran it'
      end
    end
  end

  # A cron expression's problems, or an empty list. Five fields; each field is
  # `*`, a number, a range, a step, or a comma list of those, all in range.
  def self.cron_errors(cron, field)
    return [ "#{field} must be a five-field cron string; got #{cron.inspect}" ] unless cron.is_a?(String)

    parts = cron.strip.split(/\s+/)
    unless parts.size == 5
      return [ "#{field} must have exactly five fields (minute hour day-of-month month day-of-week); got #{cron.inspect}" ]
    end

    parts.each_with_index.filter_map do |part, index|
      next if cron_field_valid?(part, CRON_RANGES[index])

      "#{field} #{CRON_FIELD_NAMES[index]} field '#{part}' is not valid (allowed #{CRON_RANGES[index]})"
    end
  end

  def self.cron_field_valid?(part, range)
    part.split(',', -1).all? { |item| cron_item_valid?(item, range) }
  end

  def self.cron_item_valid?(item, range)
    return false if item.empty?

    base, step = item.split('/', 2)
    return false if item.count('/') > 1
    return false if step && !(step.match?(/\A\d+\z/) && step.to_i.positive?)
    return true if base == '*'

    low, high = base.split('-', 2)
    return false unless low.to_s.match?(/\A\d+\z/) && (high.nil? || high.match?(/\A\d+\z/))
    return range.cover?(low.to_i) if high.nil?

    range.cover?(low.to_i) && range.cover?(high.to_i) && low.to_i <= high.to_i
  end
  private_class_method :cron_item_valid?

  private

  def allow_active_scan_errors
    return [] unless @config['profiles'].is_a?(Hash)

    @config['profiles'].filter_map do |name, profile|
      next unless profile.is_a?(Hash) && profile.key?('allow_active_scan')
      next if [ true, false ].include?(profile['allow_active_scan'])

      "change_config.profiles.#{name}.allow_active_scan must be true or false; got #{profile['allow_active_scan'].inspect}"
    end
  end

  def profile_names = @config['profiles'].is_a?(Hash) ? @config['profiles'].keys.map(&:to_s) : []

  def overrides_of(entry)
    SCHEDULABLE_LANES.each_with_object({}) do |lane, out|
      out[lane] = entry[lane] if entry[lane].is_a?(Hash)
    end
  end

  def schedule_errors(name, entry)
    field = "change_config.schedules.#{name}"
    return [ "#{field}: schedule name must match #{NAME.source}" ] unless name.match?(NAME)
    return [ "#{field} must be a mapping" ] unless entry.is_a?(Hash)

    errors = unknown_key_errors(entry, field)
    errors.concat(self.class.cron_errors(entry['cron'], "#{field}.cron"))
    errors.concat(profile_errors(entry['profile'], "#{field}.profile"))
    errors.concat(runner_errors(entry['runner'], "#{field}.runner"))
    errors.concat(lane_errors(entry['lanes'], "#{field}.lanes"))
    errors.concat(override_errors(entry, field))
  end

  def unknown_key_errors(entry, field)
    unknown = entry.keys.map(&:to_s) - KEYS - ChangeSchema::LANES
    return [] if unknown.empty?

    [ "#{field} sets unknown key(s): #{unknown.join(', ')}. A schedule takes #{KEYS.join(', ')} " \
      'plus per-lane overrides keyed by lane name' ]
  end

  def profile_errors(profile, field)
    return [ "#{field} is required" ] if profile.nil? || profile.to_s.empty?
    return [] if profile_names.include?(profile.to_s)

    defined = profile_names.empty? ? 'none (no change_config.profiles block)' : profile_names.join(', ')
    [ "#{field} '#{profile}' is not a defined profile; defined profiles: #{defined}" ]
  end

  def runner_errors(runner, field)
    return [] if RUNNERS.include?(runner)

    [ "#{field} is required and must be one of #{RUNNERS.join(', ')}; got #{runner.inspect}" ]
  end

  def lane_errors(lanes, field)
    unless lanes.is_a?(Array) && !lanes.empty? && lanes.all?(String)
      return [ "#{field} must be a non-empty list of lane names" ]
    end

    errors = []
    errors << "#{field} may not include command; the command lane has no scheduled execution" if lanes.include?('command')
    unknown = lanes - ChangeSchema::LANES
    errors << "#{field} names unknown lane(s): #{unknown.join(', ')}" unless unknown.empty?
    errors
  end

  def override_errors(entry, field)
    lanes = Array(entry['lanes']).map(&:to_s)
    (entry.keys.map(&:to_s) & ChangeSchema::LANES).flat_map do |lane|
      lane_override_errors(lane, entry[lane], lanes, "#{field}.#{lane}", entry['profile'].to_s)
    end
  end

  def lane_override_errors(lane, override, lanes, field, profile)
    return [ "#{field} overrides a lane this schedule does not run; add #{lane} to lanes or drop it" ] unless lanes.include?(lane)
    return [ "#{field} may not be overridden; the command lane has no scheduled execution" ] if lane == 'command'
    return [ "#{field} must be a mapping" ] unless override.is_a?(Hash)

    unknown = override.keys.map(&:to_s) - OVERRIDE_FIELDS.fetch(lane)
    errors = unknown.empty? ? [] : [ "#{field} sets unknown key(s): #{unknown.join(', ')}" ]
    errors.concat(zap_mode_errors(override['mode'], field, profile)) if lane == 'zap' && override.key?('mode')
    errors
  end

  def zap_mode_errors(mode, field, profile)
    return [ "#{field}.mode must be one of #{ZAP_MODES.join(', ')}; got #{mode.inspect}" ] unless ZAP_MODES.include?(mode)
    return [] if mode == 'baseline' || allow_active_scan?(profile)

    [ "#{field}.mode is full (an active scan), but profile '#{profile}' does not set allow_active_scan: true; " \
      "opt the profile in under change_config.profiles.#{profile}.allow_active_scan before any active scan can target it" ]
  end

  def required_errors(field, required)
    return [ "#{field} must be a mapping of schedule name to { max_age_days: N }" ] unless required.is_a?(Hash)

    required.flat_map do |name, settings|
      entry_field = "#{field}.#{name}"
      next [ "#{entry_field} names no declared schedule; declared: #{names.empty? ? 'none' : names.join(', ')}" ] unless fetch(name)
      next [ "#{entry_field} must be a mapping with max_age_days" ] unless settings.is_a?(Hash)

      unknown = settings.keys.map(&:to_s) - %w[max_age_days]
      errors = unknown.empty? ? [] : [ "#{entry_field} sets unknown key(s): #{unknown.join(', ')}" ]
      age = settings['max_age_days']
      errors << "#{entry_field}.max_age_days must be an integer from 1 to 90; got #{age.inspect}" unless age.is_a?(Integer) && MAX_AGE_DAYS.cover?(age)
      errors
    end
  end
end
