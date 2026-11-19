# frozen_string_literal: true

require 'digest'
require 'securerandom'
require 'yaml'
require_relative 'approval_console/canonical'
require_relative 'change_frontmatter'

# The cf.prod.request/1 envelope: the one immutable description of a bounded
# production op that an agent requests, a human approves and the runner
# executes. The digest binds op, params, profile, environment, version and the
# base-branch config the op was resolved against, so a change to any of them
# after approval makes the runner refuse.
#
# Pure: no git, no network. Everything a caller must prove is a method here so
# the request tool, the approve tool and the runner gate share one definition.
module ChangeProdEnvelope
  class Invalid < StandardError; end

  PROTOCOL = 'cf.prod.request/1'
  KEYS = %w[protocol request_id op params profile environment version config_digest requested_by digest].freeze
  DIGEST_KEYS = %w[request_id op params profile environment version config_digest].freeze
  UUID = ApprovalConsole::Canonical::UUID
  SHA = ApprovalConsole::Canonical::SHA
  NAME = /\A[a-z][a-z0-9_-]{0,62}\z/
  OP = /\A[a-z][a-z0-9_]{0,62}\z/
  DIGEST = /\Asha256:[0-9a-f]{64}\z/
  REQUESTED_BY = /\A(agent|human):[A-Za-z0-9._:-]{1,80}\z/
  PLACEHOLDER = /\{([^{}]*)\}/
  MAX_VALUE = 256

  module_function

  # The config the digest covers: the change_config and change_policy subtrees
  # as the base branch holds them. A caller passes the frontmatter hash.
  def config_digest(config)
    subtree = { 'change_config' => config['change_config'] || {}, 'change_policy' => config['change_policy'] || {} }
    "sha256:#{Digest::SHA256.hexdigest(ApprovalConsole::Canonical.serialize(subtree))}"
  end

  # YAML frontmatter (a CHANGE.md) or a plain YAML file (a fixture).
  def load_config(path)
    text = File.read(path)
    data = text.match?(ChangeFrontmatter::PATTERN) ? ChangeFrontmatter.parse(text) : YAML.safe_load(text)
    raise Invalid, "#{path} holds no config" unless data.is_a?(Hash) && !data.empty?

    data
  rescue SystemCallError, Psych::Exception => e
    raise Invalid, "cannot read config #{path}: #{e.message}"
  end

  def digest(envelope)
    subset = DIGEST_KEYS.to_h { |key| [ key, envelope[key] ] }
    "sha256:#{Digest::SHA256.hexdigest(ApprovalConsole::Canonical.serialize(subset))}"
  end

  # Builds a valid, digested envelope for a declared op, or raises Invalid.
  def build(config:, op:, params:, profile:, version:, requested_by:, request_id: SecureRandom.uuid)
    change = section(config)
    environment = environment_for(change, op, profile)
    envelope = { 'protocol' => PROTOCOL, 'request_id' => request_id, 'op' => op.to_s, 'params' => stringify(params),
                 'profile' => profile.to_s, 'environment' => environment, 'version' => version.to_s,
                 'config_digest' => config_digest(config), 'requested_by' => requested_by.to_s }
    envelope['digest'] = digest(envelope)
    validate(envelope, config: config)
  end

  # Structure, digest and (when a config is given) the op, params and the
  # profile-to-environment mapping against that config. Returns the envelope.
  def validate(envelope, config: nil)
    raise Invalid, 'envelope is not an object' unless envelope.is_a?(Hash)

    shape(envelope)
    raise Invalid, 'digest does not match the envelope' unless envelope['digest'] == digest(envelope)

    check_against_config(envelope, config) if config
    envelope
  end

  # The context the approval verifier must match: the body is bound to the
  # digest through its summary and argv, to the commit through sha, and to the
  # profile. `repo` and `machine_id` come from the caller's own pinned state.
  def approval_context(envelope, repo:, machine_id:)
    { 'type' => 'prod-op', 'machine_id' => machine_id, 'repo' => repo, 'sha' => envelope['version'],
      'profile' => envelope['profile'], 'summary' => summary(envelope), 'argv' => argv(envelope) }
  end

  def summary(envelope)
    "#{PROTOCOL} #{envelope['op']} on #{envelope['environment']} (#{envelope['profile']}) digest #{envelope['digest']}"
  end

  def argv(envelope) = [ PROTOCOL, envelope['digest'] ]

  # The first 12 hex characters of the digest, what a human types back.
  def prefix(envelope) = envelope['digest'].delete_prefix('sha256:')[0, 12]

  def section(config)
    change = config.is_a?(Hash) ? config['change_config'] : nil
    raise Invalid, 'config has no change_config' unless change.is_a?(Hash)

    change
  end

  def environment_for(change, op, profile)
    definition = operation(change, op)
    runner = runner_for(change, definition)
    mapped = (runner['environments'] || {})[profile.to_s]
    raise Invalid, "profile #{profile.inspect} has no environment on runner #{definition['runner']}" unless mapped.is_a?(String) && mapped.match?(NAME)

    mapped
  end

  def operation(change, op)
    raise Invalid, "op #{op.inspect} is not a valid name" unless op.to_s.match?(OP)

    definition = (change['operations'] || {})[op.to_s]
    raise Invalid, "op #{op} is not declared in operations" unless definition.is_a?(Hash)

    placeholders(definition)
    definition
  end

  def runner_for(change, definition)
    runner = (change['runners'] || {})[definition['runner'].to_s]
    raise Invalid, "runner #{definition['runner'].inspect} is not declared" unless runner.is_a?(Hash)

    runner
  end

  # Every {name} in an argv must be a declared param: no free-form shell.
  def placeholders(definition)
    declared = (definition['params'] || {}).keys.map(&:to_s)
    argvs = [ definition['argv'], definition.dig('verify', 'argv') ].compact
    argvs.each do |list|
      raise Invalid, 'argv must be an array of strings' unless list.is_a?(Array) && list.all?(String)

      used = list.flat_map { |arg| arg.scan(PLACEHOLDER).flatten }
      unknown = used - declared
      raise Invalid, "argv uses undeclared params: #{unknown.join(', ')}" unless unknown.empty?
    end
  end

  def check_against_config(envelope, config)
    change = section(config)
    raise Invalid, 'config_digest does not match the base config' unless envelope['config_digest'] == config_digest(config)

    definition = operation(change, envelope['op'])
    mapped = environment_for(change, envelope['op'], envelope['profile'])
    raise Invalid, "environment #{envelope['environment'].inspect} is not the mapping for profile #{envelope['profile']}" unless envelope['environment'] == mapped

    check_params(definition['params'] || {}, envelope['params'])
  end

  # Each declared param is required, a string, free of control characters, and
  # fully matches its pattern. Undeclared params are refused.
  def check_params(declared, given)
    unknown = given.keys - declared.keys.map(&:to_s)
    raise Invalid, "undeclared params: #{unknown.join(', ')}" unless unknown.empty?

    declared.each do |name, spec|
      raise Invalid, "param #{name} is missing" unless given.key?(name.to_s)

      check_param(name, spec, given[name.to_s])
    end
  end

  def check_param(name, spec, value)
    raise Invalid, "param #{name} must declare type string and a pattern" unless spec.is_a?(Hash) && spec['type'] == 'string' && spec['pattern'].is_a?(String)
    raise Invalid, "param #{name} must be a string" unless value.is_a?(String)
    raise Invalid, "param #{name} is empty or over #{MAX_VALUE} characters" if value.empty? || value.length > MAX_VALUE
    raise Invalid, "param #{name} has control characters" if value.match?(/[[:cntrl:]]/)
    raise Invalid, "param #{name} does not match its pattern" unless value.match?(/\A(?:#{spec['pattern']})\z/)
  rescue RegexpError
    raise Invalid, "param #{name} has an invalid pattern"
  end

  def shape(envelope)
    keys = envelope.keys
    raise Invalid, "unexpected or missing fields: #{((keys - KEYS) | (KEYS - keys)).sort.join(', ')}" unless keys.sort == KEYS.sort
    raise Invalid, "protocol is not #{PROTOCOL}" unless envelope['protocol'] == PROTOCOL

    field(envelope, 'request_id', UUID)
    field(envelope, 'op', OP)
    field(envelope, 'profile', NAME)
    field(envelope, 'environment', NAME)
    field(envelope, 'version', SHA)
    field(envelope, 'config_digest', DIGEST)
    field(envelope, 'requested_by', REQUESTED_BY)
    field(envelope, 'digest', DIGEST)
    params_shape(envelope['params'])
  end

  def field(envelope, key, pattern)
    raise Invalid, "#{key} is malformed" unless envelope[key].is_a?(String) && envelope[key].match?(pattern)
  end

  def params_shape(params)
    ok = params.is_a?(Hash) && params.all? { |key, value| key.is_a?(String) && key.match?(OP) && value.is_a?(String) }
    raise Invalid, 'params must be an object of string values' unless ok
  end

  def stringify(params)
    raise Invalid, 'params must be an object' unless params.is_a?(Hash)

    params.to_h { |key, value| [ key.to_s, value ] }
  end
end
