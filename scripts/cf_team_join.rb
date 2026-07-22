#!/usr/bin/env ruby
# frozen_string_literal: true

# cf-team-join (plan section 4.2): human-run, once per teammate per team. Caches
# the team's shared Ed25519 PRIVATE key into the macOS login Keychain (where the
# hooks read it) and records this machine's local contributor_id.
#
# The private key is supplied one of three ways (checked in order):
#   1. --stdin        : pipe the base64 key on stdin, e.g.
#                         <op-wrapper> read 'op://<vault>/<item>/password' | \
#                           cf_team_join.rb <team_id> <contributor_id> --stdin
#   2. CF_TEAM_KEY    : an env var holding the base64 key
#   3. (default)      : print a suggested 1Password `op read` command and exit,
#                       so the human can review it and re-run with --stdin.
#
# Not fail-open: this is one-time provisioning, so bad input exits nonzero.

require 'fileutils'
require 'shellwords'

module CfTeamJoin
  KEYCHAIN_SERVICE = 'change-fabric-presence'
  OP_WRAPPER = File.expand_path('~/code/pst/pstaylor-patrick/secrets/bin/op')

  module_function

  def run(argv)
    args = argv.dup
    use_stdin = args.delete('--stdin')
    team_id, contributor_id = args
    if team_id.to_s.empty? || contributor_id.to_s.empty?
      warn 'usage: cf_team_join.rb <team_id> <contributor_id> [--stdin]'
      warn '  key source: --stdin, or CF_TEAM_KEY env var, or run without either for the op-read hint'
      exit 1
    end

    key = resolve_key(team_id, use_stdin)
    cache_in_keychain(team_id, key)
    write_contributor_id(team_id, contributor_id)

    puts "Joined team #{team_id} as contributor '#{contributor_id}'."
    puts "  key cached in Keychain (service '#{KEYCHAIN_SERVICE}', account '#{team_id}')"
    puts "  contributor id written to #{contributor_id_path(team_id)}"
  end

  def resolve_key(team_id, use_stdin)
    key = if use_stdin
            $stdin.read.to_s.strip
    elsif !ENV['CF_TEAM_KEY'].to_s.strip.empty?
            ENV['CF_TEAM_KEY'].strip
    end

    if key.to_s.empty?
      print_op_hint(team_id)
      exit 1
    end
    key
  end

  def print_op_hint(team_id)
    warn 'No key supplied. Read the private key from 1Password and pipe it in, e.g.:'
    warn
    warn "  #{OP_WRAPPER} read 'op://<shared-vault>/change-fabric team key: #{team_id}/password' | \\"
    warn "    ruby #{__FILE__} #{team_id} <your-contributor-id> --stdin"
    warn
    warn 'Or set CF_TEAM_KEY=<base64-key> in the environment and re-run.'
  end

  def cache_in_keychain(team_id, key)
    # -U updates an existing entry instead of erroring on a duplicate.
    ok = system(
      'security', 'add-generic-password',
      '-s', KEYCHAIN_SERVICE,
      '-a', team_id,
      '-w', key,
      '-U'
    )
    raise "failed to write key to Keychain for team #{team_id}" unless ok
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
