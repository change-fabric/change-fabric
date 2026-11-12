# frozen_string_literal: true

require 'yaml'
require_relative 'cf_provider_registry'

# Aggregates the paid providers skills declare in SKILL.md frontmatter
# (`providers: [openai, ...]`) into { provider => [skill names] }, the
# `required_providers` install.rb records for the SessionStart prompt. An
# undeclared provider name fails loudly: a typo would otherwise silently
# skip enrollment prompting for that skill.
module SkillProviders
  class UnknownProvider < StandardError; end

  FRONT = /\A---\n(?<front>.*?)\n---\n/m

  module_function

  def collect(skill_dirs, registry: CfProviderRegistry)
    known = registry.names
    skill_dirs.sort.each_with_object({}) do |dir, acc|
      name, providers = declared(dir)
      providers.each do |provider|
        unless known.include?(provider)
          raise UnknownProvider, "#{name} declares unknown provider #{provider.inspect}; " \
                                 "known: #{known.join(', ')} (config/providers.yml)"
        end

        (acc[provider] ||= []) << name
      end
    end
  end

  def declared(dir)
    path = File.join(dir, 'SKILL.md')
    match = File.file?(path) && File.read(path).match(FRONT)
    front = match ? YAML.safe_load(match[:front]) : {}
    front = {} unless front.is_a?(Hash)
    [ front['name'] || File.basename(dir), Array(front['providers']).map(&:to_s) ]
  end

  def report(required)
    return 'paid providers required: none' if required.empty?

    list = required.map { |provider, skills| "#{provider} (#{skills.join(', ')})" }.join(', ')
    "paid providers required: #{list}. Projects are prompted at SessionStart."
  end
end
