#!/usr/bin/env ruby
# frozen_string_literal: true

require 'io/console'
require 'optparse'
require 'shellwords'
require_relative 'cf_key_expiry'
require_relative 'cf_key_validator'
require_relative 'cf_project_identity'
require_relative 'cf_provider_registry'
require_relative 'cf_secret_store'

# The only way a paid provider key enters cf. The user runs it from a snippet
# the agent pastes in chat; the key is typed at a real terminal with echo off,
# validated against the provider's free endpoint, and stored per project.
#
#   enroll PROVIDER [--dir PATH] [--expires DATE] [--label TEXT] [--scope tree|project]
#                                          TTY only; validates, then stores
#   expires PROVIDER DATE [--dir PATH]     records or corrects the expiry
#   confirm-inherit PROVIDER [--dir PATH]  after an AskUserQuestion yes
#   defer PROVIDER [--dir PATH] [--days 1|7] skip it here for 1 or 7 days (default 7)
#   status [--dir PATH]                    never prints a value
#   remove PROVIDER [--dir PATH]           TTY only
#
# --dir names the enrollment level. Without it the project is the one the
# current directory belongs to. A repo root (or any checkout of it) is that
# repo; any other directory, such as an org folder or a home dir, is its own
# level that descendant projects may inherit from after confirmation, or
# without one when that level enrolled with --scope tree.
#
# --expires takes a date (00:00 UTC) or full ISO8601. Providers do not expose
# expiry, so it is recorded by the user; status and resolve read it.
#
# Like change_override.rb, the TTY check is friction against an agent piping
# a key in, not a sandbox.
class CfKeys
  USAGE = 'usage: cf_keys.rb enroll PROVIDER [--dir PATH] [--expires DATE] [--label TEXT] [--scope tree|project] | ' \
          'expires PROVIDER DATE [--dir PATH] | defer PROVIDER [--dir PATH] [--days 1|7] | ' \
          'confirm-inherit|remove PROVIDER [--dir PATH] | status [--dir PATH]'
  SCOPES = %w[project tree].freeze
  EXIT_USAGE = 1
  EXIT_NO_TTY = 2
  EXIT_INVALID = 3

  def self.snippet(provider, root)
    "ruby ~/.claude/cf/bin/cf_keys.rb enroll #{provider} --dir #{Shellwords.escape(root.to_s)}"
  end

  def self.expires_snippet(provider, root)
    "ruby ~/.claude/cf/bin/cf_keys.rb expires #{provider} YYYY-MM-DD --dir #{Shellwords.escape(root.to_s)}"
  end

  def initialize(stdin: $stdin, stdout: $stdout, stderr: $stderr, cwd: Dir.pwd, validator: CfKeyValidator.new)
    @in, @out, @err, @cwd, @validator = stdin, stdout, stderr, cwd, validator
  end

  def run(argv)
    command, provider, rest, opts = parse(argv)
    return usage unless command

    case command
    when 'status' then status(opts[:dir])
    when 'enroll'
      return usage unless known?(provider) && valid_enroll_opts?(opts)

      enroll(provider, opts)
    when 'expires'
      return usage unless known?(provider) && rest.first

      expires(provider, rest.first, opts[:dir])
    when 'defer'
      return usage unless known?(provider)

      defer(provider, opts[:dir], opts.fetch(:days, CfSecretStore::DEFER_DEFAULT_DAYS))
    when 'confirm-inherit', 'remove'
      return usage unless known?(provider)

      send(command.tr('-', '_'), provider, opts[:dir])
    else usage
    end
  rescue OptionParser::ParseError, ArgumentError, SystemCallError => e
    @err.puts("cf_keys: #{e.message}")
    EXIT_USAGE
  end

  private

  def parse(argv)
    args = argv.dup
    opts = {}
    OptionParser.new do |o|
      o.on('--dir PATH') { |v| opts[:dir] = v }
      o.on('--expires DATE') { |v| opts[:expires] = v }
      o.on('--label TEXT') { |v| opts[:label] = v }
      o.on('--scope SCOPE') { |v| opts[:scope] = v }
      o.on('--days N', Integer) { |v| opts[:days] = v }
    end.parse!(args)
    [ args[0], args[1], args.drop(2), opts ]
  end

  def known?(provider) = provider && CfProviderRegistry.known?(provider)

  # Checked before any key is read, so a typo costs nothing.
  def valid_enroll_opts?(opts)
    CfKeyExpiry.parse(opts[:expires]) if opts[:expires]
    opts[:scope].nil? || SCOPES.include?(opts[:scope])
  rescue ArgumentError => e
    @err.puts("cf_keys: #{e.message}")
    false
  end

  def usage
    @err.puts(USAGE)
    EXIT_USAGE
  end

  def identity(dir)
    dir ? CfProjectIdentity.for_explicit_dir(File.expand_path(dir, @cwd)) : CfProjectIdentity.for(@cwd)
  end

  def enroll(provider, opts)
    return refuse_without_tty unless @in.tty?

    project = identity(opts[:dir])
    label = CfProviderRegistry.fetch(provider).label
    return refuse_without_tty unless @in.respond_to?(:noecho)

    key = read_secret("#{label} API key for #{project.root} (input hidden): ")
    return fail_with('no key entered; nothing stored', EXIT_USAGE) if key.empty?

    unless CfProviderRegistry.fetch(provider).key_regex.match?(key)
      @err.puts("cf_keys: that does not look like a #{label} key; validating anyway")
    end
    result = @validator.call(provider, key)
    return fail_with("#{result.reason}; nothing stored", EXIT_INVALID) unless result.ok?

    CfSecretStore.describe(project)
    CfSecretStore.write_key(project.slug, provider, key)
    CfSecretStore.update_enrollment(project.slug, provider, enrollment_fields(opts))
    CfSecretStore.clear_deferral(project.slug, provider)
    @out.puts("enrolled #{provider} for #{project.root}#{details(CfSecretStore.enrollment(project.slug, provider))}")
    0
  end

  def enrollment_fields(opts)
    label = opts[:label].to_s.strip
    { 'expires_at' => opts[:expires] && CfKeyExpiry.parse(opts[:expires]).iso8601,
      'label' => label.empty? ? nil : label,
      'scope' => opts[:scope] == 'tree' ? 'tree' : nil }
  end

  # Sets or corrects the date without touching the key. Exit 3 when this
  # level has no key for provider: there is nothing to date.
  def expires(provider, date, dir)
    expires_at = CfKeyExpiry.parse(date).iso8601
    project = identity(dir)
    unless CfSecretStore.key?(project.slug, provider)
      return fail_with("no #{provider} key enrolled at #{project.root}; nothing to date", EXIT_INVALID)
    end

    CfSecretStore.update_enrollment(project.slug, provider, 'expires_at' => expires_at)
    @out.puts("#{provider} at #{project.root} now expires #{expires_at}")
    0
  end

  def confirm_inherit(provider, dir)
    project = identity(dir)
    ancestor = CfSecretStore.inheritable(project.root, provider).first
    return fail_with("no enrolled #{provider} key above #{project.root} to inherit", EXIT_USAGE) unless ancestor

    CfSecretStore.describe(project)
    CfSecretStore.update_meta(project.slug) { |m| (m['confirmed_inherits'] ||= {})[provider] = ancestor.first }
    CfSecretStore.clear_deferral(project.slug, provider)
    @out.puts("#{project.root} now uses the #{provider} key enrolled at #{ancestor.first.delete_prefix('dir:')}")
    0
  end

  # A paid step needing provider here skips with a one-line note (exit 5)
  # until the deferral lapses; the next paid run after that asks again.
  def defer(provider, dir, days)
    project = identity(dir)
    CfSecretStore.describe(project)
    until_at = CfSecretStore.defer(project.slug, provider, days: days)
    @out.puts("deferred #{provider} for #{project.root} until #{until_at}; paid steps needing it skip until then")
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

  # An active deferral comes first, matching WalkthroughEnv.key!: it is why
  # paid calls skip even when a key is enrolled or inherited.
  def state(project, meta, provider)
    if CfSecretStore.deferral_active?(project.slug, provider)
      return "deferred until #{CfSecretStore.deferred_until(project.slug, provider).iso8601}"
    end
    if CfSecretStore.key?(project.slug, provider)
      return "enrolled#{details(CfSecretStore.enrollment(project.slug, provider))}"
    end

    ancestor = CfSecretStore.inheritable(project.root, provider).first
    confirmed = meta.dig('confirmed_inherits', provider)
    if ancestor
      entry = CfSecretStore.enrollment(ancestor.last, provider)
      from = ancestor.first.delete_prefix('dir:')
      return "inherited from #{from}#{details(entry)}" if confirmed == ancestor.first || entry['scope'] == 'tree'
    end
    return "inheritable from #{ancestor.first.delete_prefix('dir:')} (unconfirmed)" if ancestor

    'missing'
  end

  # Label, scope and expiry of an enrolled entry, never a value.
  def details(entry, now: Time.now)
    parts = []
    parts << "label \"#{entry['label']}\"" if entry['label']
    parts << 'scope tree' if entry['scope'] == 'tree'
    if (days = CfKeyExpiry.days_remaining(entry['expires_at'], now: now))
      left = CfKeyExpiry.state(entry['expires_at'], now: now) == :expired ? 'expired' : "#{days} days left"
      parts << "expires #{entry['expires_at']} (#{left})"
    end
    parts.empty? ? '' : " (#{parts.join(', ')})"
  end

  # Callers check noecho first: a terminal that cannot hide input never gets
  # a plain gets fallback, so the key is never echoed.
  def read_secret(prompt)
    @err.print(prompt)
    value = @in.noecho(&:gets)
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
