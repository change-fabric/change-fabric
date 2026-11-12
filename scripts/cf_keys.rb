#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'shellwords'
require_relative 'cf_key_validator'
require_relative 'cf_project_identity'
require_relative 'cf_provider_registry'
require_relative 'cf_secret_store'

# The only way a paid provider key enters cf. The user runs it from a snippet
# the agent pastes in chat; the key is typed at a real terminal with echo off,
# validated against the provider's free endpoint, and stored per project.
#
#   enroll PROVIDER [--dir PATH]           TTY only; validates, then stores
#   confirm-inherit PROVIDER [--dir PATH]  after an AskUserQuestion yes
#   defer PROVIDER [--dir PATH]            after an AskUserQuestion defer
#   status [--dir PATH]                    never prints a value
#   remove PROVIDER [--dir PATH]           TTY only
#
# --dir names the enrollment level. Without it the project is the one the
# current directory belongs to. A repo root (or any checkout of it) is that
# repo; any other directory, such as an org folder or a home dir, is its own
# level that descendant projects may inherit from after confirmation.
#
# Like change_override.rb, the TTY check is friction against an agent piping
# a key in, not a sandbox.
class CfKeys
  USAGE = 'usage: cf_keys.rb enroll|confirm-inherit|defer|remove PROVIDER [--dir PATH] | status [--dir PATH]'
  EXIT_USAGE = 1
  EXIT_NO_TTY = 2
  EXIT_INVALID = 3

  def self.snippet(provider, root)
    "ruby ~/.claude/cf/bin/cf_keys.rb enroll #{provider} --dir #{Shellwords.escape(root.to_s)}"
  end

  def initialize(stdin: $stdin, stdout: $stdout, stderr: $stderr, cwd: Dir.pwd, validator: CfKeyValidator.new)
    @in, @out, @err, @cwd, @validator = stdin, stdout, stderr, cwd, validator
  end

  def run(argv)
    command, provider, dir = parse(argv)
    return usage unless command

    case command
    when 'status' then status(dir)
    when 'enroll', 'confirm-inherit', 'defer', 'remove'
      return usage unless provider && CfProviderRegistry.known?(provider)

      send(command.tr('-', '_'), provider, dir)
    else usage
    end
  rescue OptionParser::ParseError, SystemCallError => e
    @err.puts("cf_keys: #{e.message}")
    EXIT_USAGE
  end

  private

  def parse(argv)
    args = argv.dup
    dir = nil
    OptionParser.new { |o| o.on('--dir PATH') { |v| dir = v } }.parse!(args)
    [ args[0], args[1], dir ]
  end

  def usage
    @err.puts(USAGE)
    EXIT_USAGE
  end

  def identity(dir)
    dir ? CfProjectIdentity.for_explicit_dir(File.expand_path(dir, @cwd)) : CfProjectIdentity.for(@cwd)
  end

  def enroll(provider, dir)
    return refuse_without_tty unless @in.tty?

    project = identity(dir)
    label = CfProviderRegistry.fetch(provider).label
    key = read_secret("#{label} API key for #{project.root} (input hidden): ")
    return fail_with('no key entered; nothing stored', EXIT_USAGE) if key.empty?

    unless CfProviderRegistry.fetch(provider).key_regex.match?(key)
      @err.puts("cf_keys: that does not look like a #{label} key; validating anyway")
    end
    result = @validator.call(provider, key)
    return fail_with("#{result.reason}; nothing stored", EXIT_INVALID) unless result.ok?

    CfSecretStore.describe(project)
    CfSecretStore.write_key(project.slug, provider, key)
    CfSecretStore.update_meta(project.slug) { |m| m['deferred']&.delete(provider) }
    @out.puts("enrolled #{provider} for #{project.root}")
    0
  end

  def confirm_inherit(provider, dir)
    project = identity(dir)
    ancestor = CfSecretStore.inheritable(project.root, provider).first
    return fail_with("no enrolled #{provider} key above #{project.root} to inherit", EXIT_USAGE) unless ancestor

    CfSecretStore.describe(project)
    CfSecretStore.update_meta(project.slug) { |m| (m['confirmed_inherits'] ||= {})[provider] = ancestor.first }
    @out.puts("#{project.root} now uses the #{provider} key enrolled at #{ancestor.first.delete_prefix('dir:')}")
    0
  end

  def defer(provider, dir)
    project = identity(dir)
    CfSecretStore.describe(project)
    CfSecretStore.update_meta(project.slug) { |m| (m['deferred'] ||= {})[provider] = true }
    @out.puts("deferred #{provider} for #{project.root}; a skill that needs it still stops until it is enrolled")
    0
  end

  def remove(provider, dir)
    return refuse_without_tty unless @in.tty?

    project = identity(dir)
    CfSecretStore.remove_key(project.slug, provider)
    @out.puts("removed #{provider} for #{project.root}")
    0
  end

  def status(dir)
    project = identity(dir)
    meta = CfSecretStore.meta(project.slug)
    @out.puts("#{project.root} (#{project.id})")
    CfProviderRegistry.names.each { |provider| @out.puts("  #{provider}: #{state(project, meta, provider)}") }
    0
  end

  def state(project, meta, provider)
    return 'enrolled' if CfSecretStore.key?(project.slug, provider)

    ancestor = CfSecretStore.inheritable(project.root, provider).first
    confirmed = meta.dig('confirmed_inherits', provider)
    return "inherited from #{confirmed.delete_prefix('dir:')}" if ancestor && confirmed == ancestor.first
    return 'deferred' if meta.dig('deferred', provider)
    return "inheritable from #{ancestor.first.delete_prefix('dir:')} (unconfirmed)" if ancestor

    'missing'
  end

  def read_secret(prompt)
    @err.print(prompt)
    value = @in.respond_to?(:noecho) ? @in.noecho(&:gets) : @in.gets
    @err.puts
    value.to_s.strip
  end

  def refuse_without_tty
    fail_with('refusing: run this from a real terminal; keys are never piped or pasted', EXIT_NO_TTY)
  end

  def fail_with(message, code)
    @err.puts("cf_keys: #{message}")
    code
  end
end

exit(CfKeys.new.run(ARGV)) if __FILE__ == $PROGRAM_NAME
