#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'shellwords'
require_relative 'hook_event'
require_relative 'cf_keys'
require_relative 'cf_project_identity'
require_relative 'cf_provider_registry'
require_relative 'cf_secret_store'

# SessionStart: for each paid provider an installed skill requires
# (installation.json `required_providers`) that this project has neither
# enrolled, confirmed inheriting, nor deferred, tells the agent to ask the user
# with AskUserQuestion: enroll now, use an ancestor key (only when one exists),
# or defer for this project. Quiet when nothing is missing. Only checks that
# key files exist; never reads one. Fails silent.
class KeyEnrollmentPrompt
  EVENT = 'SessionStart'
  CLI = 'ruby ~/.claude/cf/bin/cf_keys.rb'

  def initialize(event, home: Dir.home) = (@event, @home = event, home)

  def emit(io = $stdout)
    text = context
    io.puts(JSON.generate(hookSpecificOutput: { hookEventName: EVENT, additionalContext: text })) if text
  rescue StandardError
    nil
  end

  def context
    required = required_providers
    return if required.empty?

    project = CfProjectIdentity.for(@event['cwd'] || Dir.pwd)
    meta = CfSecretStore.meta(project.slug)
    lines = required.filter_map { |provider, skills| line(project, meta, provider, skills) }
    return if lines.empty?

    header = "[cf:keys] Paid API keys missing for #{project.root}. For each provider below, ask the user with " \
             'AskUserQuestion, one question per provider, and act on the answer. Never ask for the key in chat; ' \
             'the user runs the enroll snippet in their own terminal.'
    ([ header ] + lines).join("\n")
  rescue StandardError
    nil
  end

  private

  def line(project, meta, provider, skills)
    return unless CfProviderRegistry.known?(provider)
    return if CfSecretStore.key?(project.slug, provider)
    return if meta.dig('deferred', provider)

    ancestor = CfSecretStore.inheritable(project.root, provider).first
    return if ancestor && meta.dig('confirmed_inherits', provider) == ancestor.first

    dir = Shellwords.escape(project.root)
    options = [ "Enroll now: paste `#{CfKeys.snippet(provider, project.root)}` for the user to run" ]
    if ancestor
      options << "Use the key enrolled at #{ancestor.first.delete_prefix('dir:')}: run " \
                 "`#{CLI} confirm-inherit #{provider} --dir #{dir}`"
    end
    options << "Defer for this project: run `#{CLI} defer #{provider} --dir #{dir}` " \
               '(a skill needing it still stops with the enroll snippet)'
    "- #{CfProviderRegistry.fetch(provider).label} (#{provider}, used by #{skills.join(', ')}). Options: #{options.join('; ')}."
  end

  def required_providers
    path = File.join(@home, '.local', 'share', 'change-fabric', 'installation.json')
    data = File.file?(path) ? JSON.parse(File.read(path)) : {}
    required = data.is_a?(Hash) ? data['required_providers'] : nil
    required.is_a?(Hash) ? required : {}
  end
end

KeyEnrollmentPrompt.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
