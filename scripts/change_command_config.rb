#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'change_env'
require_relative 'docker_doctrine_guard'

# Validation for `change_config.lanes.command` (0.17.0): a project's own
# checks, each a host-run command graded by its exit code. Every message names
# the offending path (`lanes.command.commands[1].run`), so an author can find
# the line without reading this file. Separate from ChangeConfig because the
# lane's entry shape has nothing in common with the browser and load lanes'.
module ChangeCommandConfig
  ENTRY_KEYS = %w[name run env timeout_seconds artifacts profiles retries].freeze
  LANE_KEYS = %w[enabled commands].freeze
  NAME = /\A[a-z0-9][a-z0-9_-]{0,62}\z/
  ENV_NAME = /\A[A-Z_][A-Z0-9_]*\z/
  RESERVED_ENV_NAMES = (ChangeEnv::BASE_NAMES + ChangeEnv::RUN_NAMES).freeze
  MAX_TIMEOUT_SECONDS = 21_600
  MAX_RETRIES = 3
  # Lane-level keys other lanes accept that mean nothing here.
  UNUSED_LANE_KEYS = %w[base_url wait_for basic_auth auth targets].freeze

  module_function

  # `profiles` is the list of profile names the config defines, so an entry's
  # `profiles:` filter can be checked against it.
  def errors(section, profiles: [])
    return [ 'lanes.command must be a mapping' ] unless section.is_a?(Hash)

    errors = lane_key_errors(section)
    return errors unless section.fetch('enabled', true) != false

    commands = section['commands']
    return errors << 'lanes.command.commands must be a non-empty list' unless commands.is_a?(Array) && !commands.empty?

    commands.each_with_index { |entry, index| errors.concat(entry_errors(entry, "lanes.command.commands[#{index}]", profiles)) }
    errors.concat(duplicate_name_errors(commands))
  end

  def lane_key_errors(section)
    section.keys.filter_map do |key|
      if key == 'retries'
        'lanes.command.retries is not supported; set retries per command entry'
      elsif UNUSED_LANE_KEYS.include?(key)
        "lanes.command.#{key} is not used by the command lane"
      elsif !LANE_KEYS.include?(key)
        "lanes.command.#{key} is not a command lane key (allowed: #{LANE_KEYS.join(', ')})"
      end
    end
  end

  def entry_errors(entry, path, profiles)
    return [ "#{path} must be a mapping" ] unless entry.is_a?(Hash)

    unknown = entry.keys - ENTRY_KEYS
    errors = unknown.empty? ? [] : [ "#{path} sets unknown key(s): #{unknown.join(', ')} (allowed: #{ENTRY_KEYS.join(', ')})" ]
    errors << "#{path}.name must match #{NAME.source}" unless entry['name'].is_a?(String) && entry['name'].match?(NAME)
    errors.concat(run_errors(entry['run'], "#{path}.run"))
    errors.concat(timeout_errors(entry['timeout_seconds'], "#{path}.timeout_seconds"))
    errors.concat(env_errors(entry['env'], "#{path}.env")) if entry.key?('env')
    errors.concat(artifact_errors(entry['artifacts'], "#{path}.artifacts")) if entry.key?('artifacts')
    errors.concat(profile_errors(entry['profiles'], "#{path}.profiles", profiles)) if entry.key?('profiles')
    errors.concat(retry_errors(entry['retries'], "#{path}.retries")) if entry.key?('retries')
    errors
  end

  def run_errors(run, path)
    return [ "#{path} must be a non-empty string" ] unless run.is_a?(String) && !run.strip.empty?

    [ doctrine_error(path, run) ].compact
  end

  def doctrine_error(path, cmd)
    return nil if ENV['CF_ALLOW_HOSTDAEMON'] == '1'

    offender = DockerDoctrineGuard.match(cmd)
    return nil unless offender

    "#{path} starts a host daemon (#{offender}); run it in a container (see skills/docker/SKILL.md) " \
      'or set CF_ALLOW_HOSTDAEMON=1'
  end

  def timeout_errors(value, path)
    return [] if value.is_a?(Integer) && value.between?(1, MAX_TIMEOUT_SECONDS)

    [ "#{path} is required: an integer from 1 to #{MAX_TIMEOUT_SECONDS}; got #{value.inspect}" ]
  end

  def env_errors(names, path)
    unless names.is_a?(Array) && names.all? { |name| name.is_a?(String) && name.match?(ENV_NAME) }
      return [ "#{path} must be a list of variable names (A-Z, 0-9, _); got #{names.inspect}" ]
    end

    reserved = names & RESERVED_ENV_NAMES
    reserved.empty? ? [] : [ "#{path} may not declare #{reserved.join(', ')}; the base environment and CF_CHANGE_* values are always provided" ]
  end

  def artifact_errors(globs, path)
    return [ "#{path} must be a list of repo-relative globs" ] unless globs.is_a?(Array) && globs.all?(String)

    globs.filter_map do |glob|
      "#{path} entry #{glob.inspect} must be repo-relative with no '..' segment" if glob.start_with?('/') || glob.split(%r{[/{,}]}).include?('..')
    end
  end

  def profile_errors(names, path, profiles)
    return [ "#{path} must be a non-empty list of profile names" ] unless names.is_a?(Array) && !names.empty? && names.all?(String)

    unknown = names - profiles
    unknown.empty? ? [] : [ "#{path} names undefined profile(s): #{unknown.join(', ')} (defined: #{profiles.empty? ? 'none' : profiles.join(', ')})" ]
  end

  def retry_errors(value, path)
    return [] if value.is_a?(Integer) && value.between?(0, MAX_RETRIES)

    [ "#{path} must be an integer from 0 to #{MAX_RETRIES}; got #{value.inspect}" ]
  end

  def duplicate_name_errors(commands)
    names = commands.filter_map { |entry| entry['name'] if entry.is_a?(Hash) }
    dupes = names.tally.select { |_, count| count > 1 }.keys
    dupes.empty? ? [] : [ "lanes.command.commands names must be unique; repeated: #{dupes.join(', ')}" ]
  end

  # A profile may switch the lane on or off and nothing else: each entry's own
  # `profiles:` is how a command is selected per environment.
  def profile_override_error(profile, section)
    extra = section.keys - [ 'enabled' ]
    return nil if extra.empty?

    "profile '#{profile}' lane 'command' sets #{extra.join(', ')}; a profile may only set enabled on the " \
      "command lane. Select entries per environment with each command's profiles: list."
  end
end
