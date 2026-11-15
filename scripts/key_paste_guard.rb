#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'cf_keys'
require_relative 'cf_project_identity'
require_relative 'cf_provider_registry'

# UserPromptSubmit: blocks a chat prompt that carries something shaped like a
# paid provider key (config/providers.yml key_shape), before the model sees
# it, and points the user at the enrollment CLI instead. Keys are typed only
# into cf_keys.rb at a real terminal. Fails silent on any error.
class KeyPasteGuard
  def initialize(event, registry: CfProviderRegistry) = (@event, @registry = event, registry)

  def emit(io = $stdout)
    prompt = @event['prompt']
    return unless prompt.is_a?(String) && !prompt.empty?

    provider = @registry.key_shape_regexes.find { |_p, regex| regex.match?(prompt) }&.first
    return unless provider

    io.puts(JSON.generate(decision: 'block', reason: reason(provider)))
  rescue StandardError
    nil
  end

  private

  def reason(provider)
    "That looks like a #{provider.label} API key. Keys are never pasted in chat. " \
      "Run this in your own terminal: #{CfKeys.snippet(provider.name, root)}. " \
      'Rotate the key if it was already sent anywhere else.'
  end

  def root
    CfProjectIdentity.for(@event['cwd'] || Dir.pwd).root
  rescue StandardError
    '<project root>'
  end
end

KeyPasteGuard.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
