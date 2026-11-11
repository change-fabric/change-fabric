#!/usr/bin/env ruby
# frozen_string_literal: true

# The environment a host-run step (boot.up, boot.down, a command lane entry)
# executes with. It does not inherit the shell: a step sees a small fixed base
# (BASE_NAMES, only those set), the CF_CHANGE_* values the run itself provides,
# and exactly the names it declares. A secret sitting in the maintainer's shell
# never reaches a step that did not ask for it by name, so a pull request that
# edits a step cannot read the whole environment just by printing it.
#
# Declared values are looked up in ENV first, then in the parsed boot.env_file
# values, and every value that resolved is masked in captured output before it
# is logged, reported or published.
module ChangeEnv
  BASE_NAMES = %w[PATH HOME DOCKER_HOST TERM].freeze
  RUN_NAMES = %w[CF_CHANGE_RUN_ID CF_CHANGE_TARGET_URL CF_CHANGE_HEALTH_URL].freeze

  # Values shorter than this are not masked: replacing every "1" or "on" in a
  # transcript would shred the output without protecting anything real.
  MIN_MASK_LENGTH = 4

  # Raised when a declared name resolves to nothing. `names` lists every
  # missing name at once, so one run reports the whole gap instead of one
  # variable per attempt.
  class MissingVariables < StandardError
    attr_reader :names

    def initialize(names)
      @names = names
      super("declared variables are not set: #{names.join(', ')}")
    end
  end

  # `env` is the complete environment to spawn with (pass it with
  # `unsetenv_others: true`); `declared` holds only the declared name/value
  # pairs, the set the masker hides.
  Resolved = Struct.new(:env, :declared, keyword_init: true) do
    def masker = ChangeEnv.masker(declared)
  end

  module_function

  def build(declared:, env_file_values: {}, extra: {}, source: ENV)
    resolved = {}
    missing = []
    Array(declared).each do |name|
      value = lookup(name.to_s, env_file_values, source)
      value.nil? ? missing << name.to_s : resolved[name.to_s] = value
    end
    raise MissingVariables, missing unless missing.empty?

    env = BASE_NAMES.each_with_object({}) do |name, base|
      value = source[name]
      base[name] = value unless value.nil? || value.empty?
    end
    extra.each { |name, value| env[name.to_s] = value.to_s unless value.nil? }
    Resolved.new(env: env.merge(resolved), declared: resolved)
  end

  def lookup(name, env_file_values, source)
    value = source[name]
    return value unless value.nil? || value.empty?

    value = env_file_values[name]
    value.nil? || value.to_s.empty? ? nil : value.to_s
  end

  # A callable that replaces each declared value with ***NAME***, longest value
  # first so a value that contains another is hidden whole rather than leaving
  # a recognisable remainder.
  # Captured output arrives as raw bytes (ASCII-8BIT); a non-ASCII value would
  # make gsub raise on the encoding mismatch and abort the run. Everything is
  # compared as UTF-8, with invalid bytes replaced rather than raised on.
  def utf8(text) = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub

  def masker(declared)
    pairs = declared.to_h.reject { |_name, value| value.to_s.length < MIN_MASK_LENGTH }
                    .sort_by { |_name, value| -value.to_s.length }
    lambda do |text|
      pairs.reduce(utf8(text)) { |out, (name, value)| out.gsub(utf8(value), "***#{name}***") }
    end
  end
end
