#!/usr/bin/env ruby
# frozen_string_literal: true

# Validates the wiring blocks spec 0.19.0 adds under change_config:
# `execution` (the adapters that run plan phases outside the harness),
# `outbound` (the one send path every outbound effect goes through) and
# `trackers` (which issue tracker a policy in change_policy.trackers talks to).
#
# The rules that are fixed by design are fixed here too: the roast target
# never drops below 9, roast rounds never exceed 4, roast spend never exceeds
# $2 per plan run, and held messages flush at least every 15 minutes.
#
# Pure validation over parsed YAML; every method returns messages naming the
# field, empty when valid.
module ExecutionConfigSchema
  EXECUTION_KEYS = %w[ledger_dir adapters].freeze
  ADAPTER_KINDS = %w[github_issue fixture].freeze
  ADAPTER_KEYS = %w[kind repo trigger_label label_after_create bot_login design_ref ask_markers failure_markers].freeze
  OUTBOUND_KEYS = %w[spend_usd_cap hold_flush_minutes stale_hold_hours roast_target roast_rounds templates channels].freeze
  CHANNEL_KEYS = {
    'github' => %w[deliver],
    'slack' => %w[deliver provider channel],
    'jira' => %w[deliver tracker]
  }.freeze
  DELIVER = %w[send draft].freeze
  TRACKER_KINDS = %w[jira].freeze
  TRACKER_KEYS = %w[kind site provider project].freeze

  SPEND_CAP_MAX = 2.0
  ROAST_TARGET_MIN = 9
  ROAST_ROUNDS = (1..4)
  HOLD_FLUSH_MINUTES = (1..15)

  NAME = /\A[a-z0-9][a-z0-9_-]{0,62}\z/
  REPO = %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}
  BOT_LOGIN = /\A[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?\z/
  TEMPLATE = /\A[a-z][a-z0-9_]*@[1-9][0-9]*\z/
  HOST = /\A(?=.{1,253}\z)[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/
  PROJECT_KEY = /\A[A-Z][A-Z0-9_]{1,9}\z/
  SLACK_CHANNEL = /\A(#[a-z0-9][a-z0-9_-]{0,79}|[CG][A-Z0-9]{8,})\z/

  # Every problem with change_config.execution, outbound and trackers.
  def self.errors(config)
    return [] unless config.is_a?(Hash)

    execution_errors(config['execution']) +
      outbound_errors(config['outbound'], config['trackers']) +
      trackers_errors(config['trackers'])
  end

  def self.execution_errors(execution)
    return [] if execution.nil?

    field = 'change_config.execution'
    return [ "#{field} must be a mapping" ] unless execution.is_a?(Hash)

    errors = unknown(execution, EXECUTION_KEYS, field)
    if execution.key?('ledger_dir')
      dir = execution['ledger_dir']
      unless dir == 'plan' || (dir.is_a?(String) && dir.match?(%r{\A(~/|/)\S}))
        errors << "#{field}.ledger_dir must be 'plan' or an absolute or ~ path"
      end
    end
    errors.concat(adapters_errors(execution['adapters'], "#{field}.adapters")) if execution.key?('adapters')
    errors
  end

  def self.adapters_errors(adapters, field)
    return [ "#{field} must be a non-empty mapping" ] unless adapters.is_a?(Hash) && !adapters.empty?

    adapters.flat_map { |name, adapter| adapter_errors(name.to_s, adapter, "#{field}.#{name}") }
  end

  def self.adapter_errors(name, adapter, field)
    errors = []
    errors << "#{field}: adapter name must match #{NAME.source}" unless name.match?(NAME)
    return errors << "#{field} must be a mapping" unless adapter.is_a?(Hash)

    errors.concat(unknown(adapter, ADAPTER_KEYS, field))
    errors << "#{field}.kind must be one of #{ADAPTER_KINDS.join(', ')}" unless ADAPTER_KINDS.include?(adapter['kind'])
    errors.concat(github_issue_errors(adapter, field)) if adapter['kind'] == 'github_issue'
    %w[label_after_create design_ref].each do |key|
      errors << "#{field}.#{key} must be a boolean" if adapter.key?(key) && ![ true, false ].include?(adapter[key])
    end
    %w[ask_markers failure_markers].each do |key|
      errors << "#{field}.#{key} must be a non-empty list of strings" if adapter.key?(key) && !string_list?(adapter[key])
    end
    errors
  end

  def self.github_issue_errors(adapter, field)
    errors = []
    errors << "#{field}.repo must be owner/name" unless adapter['repo'].is_a?(String) && adapter['repo'].match?(REPO)
    errors << "#{field}.trigger_label must be a non-empty string" unless present?(adapter['trigger_label'])
    unless adapter['bot_login'].is_a?(String) && adapter['bot_login'].match?(BOT_LOGIN)
      errors << "#{field}.bot_login must be a GitHub login (for example some-bot[bot])"
    end
    errors
  end

  def self.outbound_errors(outbound, trackers)
    return [] if outbound.nil?

    field = 'change_config.outbound'
    return [ "#{field} must be a mapping" ] unless outbound.is_a?(Hash)

    errors = unknown(outbound, OUTBOUND_KEYS, field)
    errors.concat(outbound_limit_errors(outbound, field))
    errors.concat(templates_errors(outbound['templates'], "#{field}.templates")) if outbound.key?('templates')
    errors.concat(channels_errors(outbound['channels'], trackers, "#{field}.channels")) if outbound.key?('channels')
    errors
  end

  def self.outbound_limit_errors(outbound, field)
    errors = []
    cap = outbound['spend_usd_cap']
    if outbound.key?('spend_usd_cap') && !(cap.is_a?(Numeric) && cap.positive? && cap <= SPEND_CAP_MAX)
      errors << "#{field}.spend_usd_cap must be a number above 0 and at most #{SPEND_CAP_MAX}"
    end
    target = outbound['roast_target']
    if outbound.key?('roast_target') && !(target.is_a?(Numeric) && target.between?(ROAST_TARGET_MIN, 10))
      errors << "#{field}.roast_target must be a number from #{ROAST_TARGET_MIN} to 10 (the minimum is schema-fixed)"
    end
    errors << "#{field}.roast_rounds must be an integer from 1 to 4" if outbound.key?('roast_rounds') && !int_in?(outbound['roast_rounds'], ROAST_ROUNDS)
    if outbound.key?('hold_flush_minutes') && !int_in?(outbound['hold_flush_minutes'], HOLD_FLUSH_MINUTES)
      errors << "#{field}.hold_flush_minutes must be an integer from 1 to 15"
    end
    errors << "#{field}.stale_hold_hours must be a positive integer" if outbound.key?('stale_hold_hours') && !int_in?(outbound['stale_hold_hours'], 1..)
    errors
  end

  def self.templates_errors(templates, field)
    return [ "#{field} must be a list of name@version" ] unless templates.is_a?(Array)

    errors = templates.reject { |t| t.is_a?(String) && t.match?(TEMPLATE) }.map { |t| "#{field}: #{t.inspect} is not name@version" }
    dupes = templates.tally.select { |_, n| n > 1 }.keys
    errors << "#{field} lists #{dupes.join(', ')} more than once" unless dupes.empty?
    errors
  end

  def self.channels_errors(channels, trackers, field)
    return [ "#{field} must be a mapping" ] unless channels.is_a?(Hash)

    channels.flat_map do |name, channel|
      sub = "#{field}.#{name}"
      allowed = CHANNEL_KEYS[name.to_s]
      next [ "#{sub}: unknown channel (#{CHANNEL_KEYS.keys.join(', ')})" ] unless allowed
      next [ "#{sub} must be a mapping" ] unless channel.is_a?(Hash)

      channel_errors(channel, allowed, trackers, sub)
    end
  end

  def self.channel_errors(channel, allowed, trackers, field)
    errors = unknown(channel, allowed, field)
    errors << "#{field}.deliver must be one of #{DELIVER.join(', ')}" if channel.key?('deliver') && !DELIVER.include?(channel['deliver'])
    errors << "#{field}.provider must be a non-empty string" if channel.key?('provider') && !present?(channel['provider'])
    if channel.key?('channel') && !(channel['channel'].is_a?(String) && channel['channel'].match?(SLACK_CHANNEL))
      errors << "#{field}.channel must be a #channel name or a channel id"
    end
    if channel.key?('tracker') && !(trackers.is_a?(Hash) && trackers.key?(channel['tracker']))
      errors << "#{field}.tracker names '#{channel['tracker']}', which is not an entry of change_config.trackers"
    end
    errors
  end

  def self.trackers_errors(trackers)
    return [] if trackers.nil?

    field = 'change_config.trackers'
    return [ "#{field} must be a mapping" ] unless trackers.is_a?(Hash)

    trackers.flat_map { |name, tracker| tracker_errors(name.to_s, tracker, "#{field}.#{name}") }
  end

  def self.tracker_errors(name, tracker, field)
    errors = []
    errors << "#{field}: tracker name must match #{NAME.source}" unless name.match?(NAME)
    return errors << "#{field} must be a mapping" unless tracker.is_a?(Hash)

    errors.concat(unknown(tracker, TRACKER_KEYS, field))
    errors << "#{field}.kind must be one of #{TRACKER_KINDS.join(', ')}" unless TRACKER_KINDS.include?(tracker['kind'])
    errors << "#{field}.site must be a bare hostname" unless tracker['site'].is_a?(String) && tracker['site'].match?(HOST)
    errors << "#{field}.provider must be a non-empty string" unless present?(tracker['provider'])
    errors << "#{field}.project must be a project key (#{PROJECT_KEY.source})" unless tracker['project'].is_a?(String) && tracker['project'].match?(PROJECT_KEY)
    errors
  end

  def self.unknown(hash, allowed, field)
    extra = hash.keys.map(&:to_s) - allowed
    extra.empty? ? [] : [ "#{field} sets unknown key(s): #{extra.join(', ')}" ]
  end

  def self.string_list?(value) = value.is_a?(Array) && !value.empty? && value.all? { |v| present?(v) }
  def self.int_in?(value, range) = value.is_a?(Integer) && range.cover?(value)
  def self.present?(value) = value.is_a?(String) && !value.strip.empty?
end
