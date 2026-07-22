#!/usr/bin/env ruby
# frozen_string_literal: true

# cf-team-init (plan section 4.2): human-run, once per new contributors team.
# Generates the team's Ed25519 keypair, prints a ready-to-paste
# `contributors_team:` block for CHANGE.md, PutItems the team's PUBLIC key into
# the cf-teams DynamoDB table, and prints a suggested 1Password command for
# storing the PRIVATE key in a shared vault.
#
# Unlike the hooks, this is NOT fail-open: it is a one-time provisioning tool, so
# a missing gem, missing AWS credentials, or a failed PutItem SHOULD raise a real
# exception and exit nonzero. That is why aws-sdk-dynamodb is hard-required here
# (the one script in this set allowed to) and nothing is wrapped in a rescue.

require 'ed25519'
require 'aws-sdk-dynamodb'
require 'base64'
require 'time'

module CfTeamInit
  TEAMS_TABLE = 'cf-teams'
  REGION = 'us-east-1'
  DEFAULT_PROFILE = 'personal'
  OP_WRAPPER = File.expand_path('~/code/pst/pstaylor-patrick/secrets/bin/op')
  KEYCHAIN_SERVICE = 'change-fabric-presence'

  module_function

  def run(argv)
    team_id, label = argv
    if team_id.to_s.empty? || label.to_s.empty?
      warn 'usage: cf_team_init.rb <team_id> <label>'
      exit 1
    end

    signing_key = Ed25519::SigningKey.generate
    private_b64 = Base64.strict_encode64(signing_key.to_bytes)
    public_b64  = Base64.strict_encode64(signing_key.verify_key.to_bytes)
    created_at  = Time.now.utc.iso8601

    put_team(team_id, public_b64, label, created_at)
    print_change_md_block(team_id, public_b64)
    print_private_key_instructions(team_id, private_b64)
  end

  def put_team(team_id, public_b64, label, created_at)
    client = Aws::DynamoDB::Client.new(region: REGION, profile: ENV.fetch('AWS_PROFILE', DEFAULT_PROFILE))
    client.put_item(
      table_name: TEAMS_TABLE,
      item: {
        'pk' => "TEAM##{team_id}",
        'team_id' => team_id,
        'public_key_ed25519' => public_b64,
        'label' => label,
        'created_at' => created_at
      }
    )
    puts "Wrote team #{team_id} to #{TEAMS_TABLE}."
    puts
  end

  def print_change_md_block(team_id, public_b64)
    puts 'Paste this block into the CHANGE.md frontmatter and fill in the contributors:'
    puts '---8<--- CHANGE.md frontmatter ---8<---'
    puts 'contributors_team:'
    puts "  team_id: #{team_id}"
    puts "  public_key_ed25519: #{public_b64}"
    puts '  contributors: []          # add - {id: <stable-id>, name: <Full Name>}'
    puts '---8<--------------------------------8<---'
    puts
  end

  def print_private_key_instructions(team_id, private_b64)
    puts 'Store the PRIVATE key (base64 Ed25519 seed) in a shared 1Password vault item.'
    puts 'Suggested command (review, then run yourself; nothing is executed for you):'
    puts
    puts "  #{OP_WRAPPER} item create \\"
    puts '    --category=password \\'
    puts '    --vault=<shared-vault> \\'
    puts "    --title='change-fabric team key: #{team_id}' \\"
    puts "    'team_id=#{team_id}' \\"
    puts "    'password=#{private_b64}'"
    puts
    puts "Each teammate then runs:  cf_team_join.rb #{team_id} <their-contributor-id>"
    puts "(cf_team_join caches this key in the Keychain under service '#{KEYCHAIN_SERVICE}', account '#{team_id}')."
  end
end

CfTeamInit.run(ARGV) if __FILE__ == $PROGRAM_NAME
