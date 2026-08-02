#!/usr/bin/env ruby
# frozen_string_literal: true

# cf-team-join (plan section 4.2): human-run, once per teammate per team. Caches
# a team credential into the macOS login Keychain, where the code that needs it
# reads it back.
#
# Two credential types, two modes, one flow:
#
#   (default)    the team's shared Ed25519 PRIVATE key, cached under service
#                `change-fabric-presence`, account `<team_id>`, plus this
#                machine's local contributor_id. This is what the presence and
#                secret-alert hooks sign with.
#
#   --platform   a team API key for the hosted platform, cached under service
#                `change-fabric-platform`, account `<organization>/<team>`.
#                This is what `change_artifact_publish.rb` authenticates its
#                three publish calls with, so the key lives in neither the
#                repo's CHANGE.md nor every shell's environment.
#
# They are deliberately separate Keychain services rather than two accounts on
# one. The two credentials have different blast radii and different rotation
# stories, and one service holding both would make revoking either mean
# re-provisioning the other.
#
# The secret is supplied one of three ways (checked in order):
#   1. --stdin        : pipe the value on stdin, e.g.
#                         <op-wrapper> read 'op://<vault>/<item>/password' | \
#                           cf_team_join.rb <team_id> <contributor_id> --stdin
#   2. an env var     : CF_TEAM_KEY (default mode) or CF_TEAM_API_KEY (--platform)
#   3. (default)      : print a suggested 1Password `op read` command and exit,
#                       so the human can review it and re-run with --stdin.
#
# Not fail-open: this is one-time provisioning, so bad input exits nonzero.

require 'fileutils'
require 'shellwords'

module CfTeamJoin
  KEYCHAIN_SERVICE = 'change-fabric-presence'
  PLATFORM_KEYCHAIN_SERVICE = 'change-fabric-platform'
  OP_WRAPPER = File.expand_path('~/code/pst/pstaylor-patrick/secrets/bin/op')

  module_function

  def run(argv)
    args = argv.dup
    use_stdin = args.delete('--stdin')
    platform = args.delete('--platform')

    platform ? run_platform(args, use_stdin) : run_presence(args, use_stdin)
  end

  # --- the presence key (the original mode) ------------------------------------

  def run_presence(args, use_stdin)
    team_id, contributor_id = args
    if team_id.to_s.empty? || contributor_id.to_s.empty?
      warn 'usage: cf_team_join.rb <team_id> <contributor_id> [--stdin]'
      warn '  key source: --stdin, or CF_TEAM_KEY env var, or run without either for the op-read hint'
      exit 1
    end

    key = resolve_secret(use_stdin, 'CF_TEAM_KEY') { print_presence_hint(team_id) }
    cache_in_keychain(KEYCHAIN_SERVICE, team_id, key)
    write_contributor_id(team_id, contributor_id)

    puts "Joined team #{team_id} as contributor '#{contributor_id}'."
    puts "  key cached in Keychain (service '#{KEYCHAIN_SERVICE}', account '#{team_id}')"
    puts "  contributor id written to #{contributor_id_path(team_id)}"
  end

  # --- the platform team API key (--platform) ----------------------------------

  # Deliberately the same shape as the presence flow, and deliberately not more:
  # this stores one credential under one account and prints where it went. It
  # writes no contributor_id, because a team API key names a team and no person,
  # which is exactly the property that lets CI hold one.
  def run_platform(args, use_stdin)
    organization, team = args
    if organization.to_s.empty? || team.to_s.empty?
      warn 'usage: cf_team_join.rb --platform <organization-slug> <team-slug> [--stdin]'
      warn '  key source: --stdin, or CF_TEAM_API_KEY env var, or run without either for the op-read hint'
      exit 1
    end

    account = platform_account(organization, team)
    key = resolve_secret(use_stdin, 'CF_TEAM_API_KEY') { print_platform_hint(account) }
    cache_in_keychain(PLATFORM_KEYCHAIN_SERVICE, account, key)

    puts "Stored a platform team API key for #{account}."
    puts "  key cached in Keychain (service '#{PLATFORM_KEYCHAIN_SERVICE}', account '#{account}')"
    puts '  cf:change publishes findings artifacts with it; nothing else reads it'
  end

  def platform_account(organization, team) = "#{organization}/#{team}"

  # --- shared -------------------------------------------------------------------

  def resolve_secret(use_stdin, env_var)
    value = if use_stdin
              $stdin.read.to_s.strip
    elsif !ENV[env_var].to_s.strip.empty?
              ENV[env_var].strip
    end

    if value.to_s.empty?
      yield
      exit 1
    end
    value
  end

  def print_presence_hint(team_id)
    warn 'No key supplied. Read the private key from 1Password and pipe it in, e.g.:'
    warn
    warn "  #{OP_WRAPPER} read 'op://<shared-vault>/change-fabric team key: #{team_id}/password' | \\"
    warn "    ruby #{__FILE__} #{team_id} <your-contributor-id> --stdin"
    warn
    warn 'Or set CF_TEAM_KEY=<base64-key> in the environment and re-run.'
  end

  def print_platform_hint(account)
    warn 'No key supplied. Mint a team API key in the platform web app (your team page,'
    warn '"API keys"), store it in 1Password, and pipe it in, e.g.:'
    warn
    warn "  #{OP_WRAPPER} read 'op://<shared-vault>/change-fabric platform key: #{account}/credential' | \\"
    warn "    ruby #{__FILE__} --platform #{account.split('/').join(' ')} --stdin"
    warn
    warn 'Or set CF_TEAM_API_KEY=<key> in the environment and re-run.'
  end

  def cache_in_keychain(service, account, key)
    # -U updates an existing entry instead of erroring on a duplicate.
    ok = system(
      'security', 'add-generic-password',
      '-s', service,
      '-a', account,
      '-w', key,
      '-U'
    )
    raise "failed to write the credential to Keychain for #{account}" unless ok
  end

  def write_contributor_id(team_id, contributor_id)
    path = contributor_id_path(team_id)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{contributor_id}\n")
  end

  def contributor_id_path(team_id)
    File.join(Dir.home, '.claude', 'cf', 'teams', team_id, 'contributor_id')
  end
end

CfTeamJoin.run(ARGV) if __FILE__ == $PROGRAM_NAME
