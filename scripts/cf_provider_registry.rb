# frozen_string_literal: true

require 'yaml'

# The paid-provider registry, config/providers.yml, as data. Resolved beside
# the scripts: <repo>/config in a checkout, ~/.claude/cf/config once installed
# (the scripts land in ~/.claude/cf/bin).
module CfProviderRegistry
  class UnknownProvider < StandardError; end

  Provider = Struct.new(:name, :label, :key_file, :ignored_env, :key_shape, :validate, keyword_init: true) do
    def key_regex = Regexp.new(key_shape)
  end

  module_function

  def default_path = File.expand_path('../config/providers.yml', __dir__)

  def load(path = default_path)
    data = YAML.safe_load_file(path)
    raise ArgumentError, "invalid provider registry: #{path}" unless data.is_a?(Hash) && data['providers'].is_a?(Hash)

    data
  end

  def all(path = default_path)
    load(path)['providers'].map do |name, entry|
      Provider.new(name: name, label: entry.fetch('label'), key_file: entry.fetch('key_file'),
                   ignored_env: Array(entry['ignored_env']), key_shape: entry.fetch('key_shape'),
                   validate: entry.fetch('validate'))
    end
  end

  def names(path = default_path) = all(path).map(&:name)

  def fetch(name, path = default_path)
    all(path).find { |p| p.name == name.to_s } or raise UnknownProvider, "unknown provider: #{name}"
  end

  def known?(name, path = default_path) = names(path).include?(name.to_s)

  def global_ignored_env(path = default_path) = Array(load(path)['global_ignored_env'])

  # [provider, regex] pairs, for the chat paste guard.
  def key_shape_regexes(path = default_path) = all(path).map { |p| [ p, p.key_regex ] }
end
