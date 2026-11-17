#!/usr/bin/env ruby
# frozen_string_literal: true

# Validates change_policy.trackers.<tracker> (spec 0.19.0): the per-project
# tracker workflow a plan's external phases follow. States, the transitions
# fired on cf events, the typed evidence a transition needs, which role holds a
# state, and the locks that keep cf away from estimates, board moves and
# renames.
#
# CHANGE.md is committed and shared, so it names roles only. A holder that
# reads like a person (`me`, an email, an account id) is an error: the
# role-to-account map is local and uncommitted (~/.claude/cf/roles/).
#
# Pure validation over parsed YAML. Every method returns a list of messages
# naming the field; an empty list means valid.
class TrackerPolicy
  KEYS = %w[states transitions evidence handoffs locks].freeze
  # The fixed cf event vocabulary a transition may fire on, plus release:<ref>.
  EVENTS = %w[dispatch agent_started asked pr_opened merged staging_passed escalated].freeze
  RELEASE_EVENT = /\Arelease:\S+\z/
  TRANSITION_KEYS = %w[to comment evidence].freeze
  EVIDENCE_TYPES = %w[deploy_run check].freeze
  DEPLOY_RUN_KEYS = %w[workflow].freeze
  CHECK_SOURCES = {
    'command' => { required: %w[argv cwd timeout_s], allowed: %w[source argv cwd timeout_s] },
    'plan' => { required: %w[name], allowed: %w[source name] },
    'manual' => { required: %w[prompt], allowed: %w[source prompt] }
  }.freeze
  CHECK_CWDS = %w[repo].freeze
  # Each lock is schema-fixed false: cf never estimates, never moves a ticket
  # between boards, never renames one.
  LOCKS = %w[estimates move_between_boards rename].freeze
  TEMPLATE = /\A[a-z][a-z0-9_]*@[1-9][0-9]*\z/
  CHECK_NAME = /\A[a-z0-9][a-z0-9_-]{0,62}\z/
  ROLE = /\A[a-z][a-z0-9_-]{0,31}\z/
  # Words that name a person rather than a role.
  PERSONAL = %w[me myself i self you mine].freeze

  def self.errors(trackers, config: nil)
    return [] if trackers.nil?
    return [ 'change_policy.trackers must be a mapping' ] unless trackers.is_a?(Hash)

    trackers.flat_map { |name, policy| new(name.to_s, policy, config: config).errors }
  end

  # A role name, or nil when the value reads as a person or an account.
  def self.role_error(value, field)
    return "#{field} must be a role name string" unless value.is_a?(String)
    if PERSONAL.include?(value.strip.downcase)
      return "#{field} is '#{value}'; name a role, never a person (the role map is local)"
    end
    return "#{field} looks like an email; name a role, never an account" if value.include?('@')
    if value.match?(/\d{4,}|:/) || value.match?(/\A\h{12,}\z/)
      return "#{field} looks like an account id; name a role, never an account"
    end
    return nil if value.match?(ROLE)

    "#{field} must be a role name matching #{ROLE.source}"
  end

  def initialize(name, policy, config: nil)
    @name = name
    @policy = policy
    @config = config.is_a?(Hash) ? config : nil
    @field = "change_policy.trackers.#{name}"
  end

  def errors
    return [ "#{@field} must be a mapping" ] unless @policy.is_a?(Hash)

    errors = unknown(@policy, KEYS, @field)
    errors.concat(states_errors)
    errors.concat(transitions_errors)
    errors.concat(evidence_errors)
    errors.concat(handoffs_errors)
    errors.concat(locks_errors)
    errors.concat(config_link_errors)
  end

  # plan.md external.roles (state -> role), the one per-phase override of
  # handoffs. A state not in `states` is an error, as is a non-role holder.
  def roles_override_errors(roles, field: 'external.roles')
    return [] if roles.nil?
    return [ "#{field} must be a mapping of state to role" ] unless roles.is_a?(Hash)

    roles.flat_map do |state, role|
      errs = []
      errs << "#{field} names state '#{state}', which is not in #{@field}.states" unless states.include?(state.to_s)
      errs << self.class.role_error(role, "#{field}.#{state}")
      errs.compact
    end
  end

  def states = @policy.is_a?(Hash) && @policy['states'].is_a?(Array) ? @policy['states'].map(&:to_s) : []

  private

  def states_errors
    list = @policy['states']
    field = "#{@field}.states"
    unless list.is_a?(Array) && !list.empty? && list.all? { |s| present?(s) }
      return [ "#{field} must be a non-empty list of state names" ]
    end

    dupes = list.tally.select { |_, n| n > 1 }.keys
    dupes.empty? ? [] : [ "#{field} lists #{dupes.join(', ')} more than once" ]
  end

  def transitions_errors
    return [] unless @policy.key?('transitions')

    transitions = @policy['transitions']
    field = "#{@field}.transitions"
    return [ "#{field} must be a mapping of event to transition" ] unless transitions.is_a?(Hash)

    transitions.flat_map { |event, rule| transition_errors(event.to_s, rule, "#{field}.#{event}") }
  end

  def transition_errors(event, rule, field)
    unless EVENTS.include?(event) || event.match?(RELEASE_EVENT)
      return [ "#{field}: '#{event}' is not a cf event (#{EVENTS.join(', ')}, release:<ref>)" ]
    end
    return [ "#{field} must be a mapping" ] unless rule.is_a?(Hash)
    return [ "#{field} must set at least one of #{TRANSITION_KEYS.join(', ')}" ] if rule.empty?

    errors = unknown(rule, TRANSITION_KEYS, field)
    errors.concat(to_errors(rule['to'], "#{field}.to")) if rule.key?('to')
    errors.concat(comment_errors(rule['comment'], "#{field}.comment")) if rule.key?('comment')
    errors.concat(transition_evidence_errors(rule['evidence'], "#{field}.evidence")) if rule.key?('evidence')
    errors
  end

  def to_errors(path, field)
    return [ "#{field} must be a non-empty ordered list of states" ] unless path.is_a?(Array) && !path.empty?

    path.reject { |s| states.include?(s.to_s) }.map { |s| "#{field} names state '#{s}', which is not in #{@field}.states" }
  end

  def comment_errors(template, field)
    return [ "#{field} must be a template name@version" ] unless template.is_a?(String) && template.match?(TEMPLATE)

    # With a config supplied, an absent template list enables nothing; only
    # standalone validation (no config) skips the wiring check.
    return [] if @config.nil?

    enabled = @config.dig('outbound', 'templates')
    return [] if enabled.is_a?(Array) && enabled.include?(template)

    [ "#{field} names template '#{template}', which change_config.outbound.templates does not enable" ]
  end

  def transition_evidence_errors(list, field)
    return [ "#{field} must be a non-empty list of evidence types" ] unless list.is_a?(Array) && !list.empty?

    defined = @policy['evidence'].is_a?(Hash) ? @policy['evidence'].keys.map(&:to_s) : []
    list.filter_map do |type|
      next "#{field}: '#{type}' is not an evidence type (#{EVIDENCE_TYPES.join(', ')})" unless EVIDENCE_TYPES.include?(type.to_s)
      next if defined.include?(type.to_s)

      "#{field} needs '#{type}', which #{@field}.evidence does not define"
    end
  end

  def evidence_errors
    return [] unless @policy.key?('evidence')

    evidence = @policy['evidence']
    field = "#{@field}.evidence"
    return [ "#{field} must be a mapping" ] unless evidence.is_a?(Hash)

    errors = unknown(evidence, EVIDENCE_TYPES, field)
    errors.concat(deploy_run_errors(evidence['deploy_run'], "#{field}.deploy_run")) if evidence.key?('deploy_run')
    errors.concat(check_errors(evidence['check'], "#{field}.check")) if evidence.key?('check')
    errors
  end

  def deploy_run_errors(spec, field)
    return [ "#{field} must be a mapping" ] unless spec.is_a?(Hash)

    errors = unknown(spec, DEPLOY_RUN_KEYS, field)
    errors << "#{field}.workflow must name a deploy workflow" unless present?(spec['workflow'])
    errors
  end

  def check_errors(spec, field)
    return [ "#{field} must be a mapping" ] unless spec.is_a?(Hash)

    shape = CHECK_SOURCES[spec['source']]
    return [ "#{field}.source must be one of #{CHECK_SOURCES.keys.join(', ')}" ] unless shape

    errors = unknown(spec, shape[:allowed], "#{field} (source #{spec['source']})")
    errors.concat((shape[:required] - spec.keys.map(&:to_s)).map { |k| "#{field}.#{k} is required for source #{spec['source']}" })
    errors.concat(check_value_errors(spec, field))
  end

  def check_value_errors(spec, field)
    errors = []
    if spec.key?('argv') && !(spec['argv'].is_a?(Array) && !spec['argv'].empty? && spec['argv'].all? { |a| present?(a) })
      errors << "#{field}.argv must be a non-empty list of strings (an argv array, never a shell string)"
    end
    errors << "#{field}.cwd must be one of #{CHECK_CWDS.join(', ')}" if spec.key?('cwd') && !CHECK_CWDS.include?(spec['cwd'])
    if spec.key?('timeout_s') && !(spec['timeout_s'].is_a?(Integer) && spec['timeout_s'].positive?)
      errors << "#{field}.timeout_s must be a positive integer"
    end
    errors << "#{field}.name must match #{CHECK_NAME.source}" if spec.key?('name') && !(spec['name'].is_a?(String) && spec['name'].match?(CHECK_NAME))
    errors << "#{field}.prompt must be a non-empty string" if spec.key?('prompt') && !present?(spec['prompt'])
    errors
  end

  def handoffs_errors
    return [] unless @policy.key?('handoffs')

    handoffs = @policy['handoffs']
    field = "#{@field}.handoffs"
    return [ "#{field} must be a mapping of state to role" ] unless handoffs.is_a?(Hash)

    handoffs.flat_map do |state, role|
      errs = []
      errs << "#{field} names state '#{state}', which is not in #{@field}.states" unless states.include?(state.to_s)
      errs << self.class.role_error(role, "#{field}.#{state}")
      errs.compact
    end
  end

  def locks_errors
    return [] unless @policy.key?('locks')

    locks = @policy['locks']
    field = "#{@field}.locks"
    return [ "#{field} must be a mapping" ] unless locks.is_a?(Hash)

    errors = unknown(locks, LOCKS, field)
    locks.each do |key, value|
      next unless LOCKS.include?(key.to_s)

      errors << "#{field}.#{key} is schema-fixed false; cf never #{lock_verb(key.to_s)}" unless value == false
    end
    errors
  end

  def lock_verb(key)
    { 'estimates' => 'writes estimates', 'move_between_boards' => 'moves tickets between boards',
      'rename' => 'renames boards or tickets' }.fetch(key)
  end

  # A tracker policy needs the matching wiring in change_config.trackers.
  def config_link_errors
    return [] unless @config

    wired = @config['trackers']
    return [] if wired.is_a?(Hash) && wired.key?(@name)

    [ "#{@field} has no matching change_config.trackers.#{@name}" ]
  end

  def unknown(hash, allowed, field)
    extra = hash.keys.map(&:to_s) - allowed
    extra.empty? ? [] : [ "#{field} sets unknown key(s): #{extra.join(', ')}" ]
  end

  def present?(value) = value.is_a?(String) && !value.strip.empty?
end
