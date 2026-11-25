# frozen_string_literal: true

require 'shellwords'
require_relative '../change_frontmatter'
require_relative '../change_schema'

module ScheduledLane
  class ConfigError < StandardError; end

  ENV_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/
  FLAG_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/

  # One validated scheduled_lanes entry with the matrix defaults applied.
  class Lane
    MATRIX_DEFAULTS = { 'max_flags' => 5, 'settle_seconds' => 90, 'revert_headroom_seconds' => 300 }.freeze

    attr_reader :raw

    def initialize(raw)
      @raw = raw
    end

    def id = raw['id']
    def run = raw['run']
    def result_file = raw['result_file']
    def deployed_sha_cmd = raw['deployed_sha_cmd']
    def timeout_seconds = raw['timeout_minutes'] * 60
    def timeout_minutes = raw['timeout_minutes']
    def sinks = raw['sinks'] || []
    def matrix = MATRIX_DEFAULTS.merge(raw['matrix'] || {})
    def matrix_declared? = raw.key?('matrix')
    def matrix_touched? = matrix['mode'] == 'touched-one-at-a-time'

    # Every adapter the nightly detection pass needs.
    def detection_ready?
      %w[list_on_cmd ledger_cmd].all? { |key| matrix[key] }
    end

    def forbidden_envs
      (ChangeSchema::PROTECTED_ENVS + (matrix['forbid_envs'] || [])).map { |name| name.to_s.downcase }.uniq
    end

    # Path of one iteration's own result file: <stem>.<iteration>.json beside
    # the declared one, so no iteration can read another's file.
    def result_path(iteration)
      ext = File.extname(result_file)
      "#{result_file.delete_suffix(ext)}.#{iteration}#{ext.empty? ? '.json' : ext}"
    end
  end

  # Loads scheduled_lanes from a CHANGE file's frontmatter and validates them
  # with ChangeSchema, the one rule set shared with the spec doc.
  module LaneConfig
    module_function

    def load(path)
      raise ConfigError, "config not found: #{path}" unless File.file?(path)

      lanes = ChangeFrontmatter.parse_file(path)['scheduled_lanes']
      raise ConfigError, "#{path} declares no scheduled_lanes" if lanes.nil?

      errors = ChangeSchema.scheduled_lanes_errors(lanes)
      raise ConfigError, errors.join('; ') unless errors.empty?

      lanes.map { |raw| Lane.new(raw) }
    end

    def find(path, id)
      lanes = self.load(path)
      lanes.find { |lane| lane.id == id } || raise(ConfigError, "no scheduled lane '#{id}' (declared: #{lanes.map(&:id).join(', ')})")
    end

    # Fills {flag} and {env} in an adapter command, shell-escaped. A flag key or
    # env name outside the safe alphabet is refused rather than escaped, since
    # the values come from dispatch inputs.
    def fill(template, flag: nil, env: nil)
      raise ConfigError, "unsafe flag key: #{flag.inspect}" if flag && !flag.match?(FLAG_PATTERN)
      raise ConfigError, "unsafe env name: #{env.inspect}" if env && !env.match?(ENV_PATTERN)

      template.gsub(/\{(flag|env)\}/) do
        value = Regexp.last_match(1) == 'flag' ? flag : env
        raise ConfigError, "command uses {#{Regexp.last_match(1)}} but no value was given" if value.nil?

        Shellwords.escape(value)
      end
    end
  end
end
