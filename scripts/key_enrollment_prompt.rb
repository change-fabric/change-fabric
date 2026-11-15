#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'shellwords'
require_relative 'hook_event'
require_relative 'cf_key_expiry'
require_relative 'cf_keys'
require_relative 'cf_project_identity'
require_relative 'cf_provider_registry'
require_relative 'cf_secret_store'

# SessionStart: for each paid provider an installed skill requires
# (installation.json `required_providers`) that this project has neither
# enrolled, confirmed inheriting, nor deferred, tells the agent to ask the user
# with AskUserQuestion: enroll now, use an ancestor key (only when one exists),
# or defer for this project. Quiet when nothing is missing. Only checks that
# key files exist; never reads one. Also scans every project's meta.json in the
# secret store for keys already expired or expiring within 24h, naming the
# provider, label, project root and renew command. Fails silent.
class KeyEnrollmentPrompt
  EVENT = 'SessionStart'
  CLI = 'ruby ~/.claude/cf/bin/cf_keys.rb'

  def initialize(event, home: Dir.home, now: Time.now) = (@event, @home, @now = event, home, now)

  def emit(io = $stdout)
    text = context
    io.puts(JSON.generate(hookSpecificOutput: { hookEventName: EVENT, additionalContext: text })) if text
  rescue StandardError
    nil
  end

  def context
    text = [ missing_context, expiry_context ].compact.join("\n\n")
    text.empty? ? nil : text
  end

  def expiry_context
    lines = CfSecretStore.each_meta.flat_map { |_slug, meta| expiry_lines(meta) }
    return if lines.empty?

    header = '[cf:keys] Enrolled paid API keys expired or expiring within 24h. Tell the user; a skill refuses ' \
             'an expired key locally. The user renews in their own terminal, or corrects a wrong date with ' \
             "`#{CLI} expires PROVIDER DATE --dir ROOT`."
    ([ header ] + lines).join("\n")
  rescue StandardError
    nil
  end

  def missing_context
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

  def expiry_lines(meta)
    root = meta['root']
    enrolled = meta['enrolled']
    return [] unless root.is_a?(String) && !root.empty? && enrolled.is_a?(Hash)

    enrolled.sort.filter_map { |provider, entry| expiry_line(root, provider, entry) }
  rescue StandardError
    []
  end

  def expiry_line(root, provider, entry)
    return unless entry.is_a?(Hash) && CfProviderRegistry.known?(provider)

    state = CfKeyExpiry.state(entry['expires_at'], now: @now)
    return if state == :ok

    status = state == :expired ? 'expired' : 'expires within 24h'
    text = entry['label'].to_s.gsub(/[[:cntrl:]]+/, ' ').strip
    label = text.empty? ? '' : " \"#{text}\""
    "- #{provider}#{label} at #{root}: #{status} (#{entry['expires_at']}). Renew: " \
      "`#{CLI} enroll #{provider} --dir #{Shellwords.escape(root)}`."
  end

  def line(project, meta, provider, skills)
    return unless CfProviderRegistry.known?(provider) && skills.is_a?(Array)
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
