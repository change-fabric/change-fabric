#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative 'approval_console'
require_relative 'approval_console/terminal_prompt'
require_relative 'cf_project_identity'
require_relative 'change_prod_envelope'
require_relative 'change_prod_gate'
require_relative 'change_prod_store'

# Human-run approval of one bounded prod op request, bound to its digest.
#
#   change_prod_approve.rb REQUEST_ID [--repo PATH] [--no-push]
#
# Terminal path (this release): shows the whole envelope, asks for the digest
# prefix typed back, then requires a TOTP code from this machine's enrolled
# seed. The proof is `totp-terminal` with no console receipt, which the runner
# accepts for the staging profile only. A production request is refused here
# rather than approved into a proof the runner would refuse.
# `--remote` (passkey plus TOTP through the console) needs console phases 5 and
# 6 and is refused until they land.
#
# Refuses without a real TTY, inside an agent harness, and on a degraded host.
# Like the other guards this is friction, not a sandbox.
module ChangeProdApprove
  module_function

  def run(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, env: ENV, parents: ApprovalConsoleCli.method(:parent_names),
          store_factory: ->(opts) { ChangeProdStore.new(opts[:repo]) })
    opts = parse(argv)
    refusal = ApprovalConsoleCli.human_only_refusal(stdin, env, parents)
    return refuse(stderr, refusal) if refusal
    return refuse(stderr, 'remote approval needs the console (phases 5 and 6), which has not landed') if opts[:remote]
    return usage(stderr) unless opts[:request_id]

    store = store_factory.call(opts)
    envelope = load(store, opts)
    return refuse(stderr, "a terminal-only proof is accepted for staging only; #{envelope['profile']} needs the remote console") unless ChangeProdGate::LOCAL_PROFILES.include?(envelope['profile'])

    approve(envelope, store, opts, stdin, stdout, stderr)
  rescue OptionParser::ParseError, ChangeProdEnvelope::Invalid, ChangeProdStore::Error => e
    refuse(stderr, e.message)
  end

  def parse(argv)
    opts = { repo: '.', push: true }
    OptionParser.new do |o|
      o.on('--repo PATH') { |v| opts[:repo] = v }
      o.on('--remote') { opts[:remote] = true }
      o.on('--no-push') { opts[:push] = false }
    end.parse!(argv)
    opts[:request_id] = argv.shift
    opts
  end

  def load(store, opts)
    store.fetch if opts[:push]
    ChangeProdEnvelope.validate(store.read('requests', opts[:request_id]))
  end

  def approve(envelope, store, opts, stdin, stdout, stderr)
    preflight = ApprovalConsole::TerminalPrompt.preflight('prod-op')
    return refuse(stderr, preflight) if preflight

    show(envelope, stdout)
    stdout.print "Type the first 12 characters of the digest (#{ChangeProdEnvelope.prefix(envelope)}) to continue: "
    return refuse(stderr, 'the typed digest prefix did not match') unless stdin.gets.to_s.strip == ChangeProdEnvelope.prefix(envelope)

    result = ApprovalConsole::TerminalPrompt.approve(attrs(envelope, opts[:repo]), stdin: stdin, stdout: stdout)
    return refuse(stderr, "#{result.error}; nothing recorded") unless result.ok?

    record = { 'protocol' => ChangeProdGate::APPROVAL_PROTOCOL, 'request_id' => envelope['request_id'],
               'digest' => envelope['digest'], 'proof' => result.proof }
    store.create('approvals', envelope['request_id'], record, push: opts[:push])
    stdout.puts "[cf-prod] approved #{envelope['request_id']} (staging only; expires in 15 minutes)."
    0
  rescue ApprovalConsole::Canonical::Invalid => e
    refuse(stderr, "cannot bind the approval: #{e.message}")
  end

  def attrs(envelope, repo)
    ChangeProdEnvelope.approval_context(envelope, repo: CfProjectIdentity.for(repo).id, machine_id: nil)
                      .reject { |key, _| key == 'machine_id' }
  end

  def show(envelope, stdout)
    stdout.puts "Bounded prod op request #{envelope['request_id']}"
    stdout.puts JSON.pretty_generate(envelope)
  end

  def refuse(stderr, reason)
    stderr.puts "[cf-prod] refusing: #{reason}."
    1
  end

  def usage(stderr)
    stderr.puts 'usage: change_prod_approve.rb REQUEST_ID [--repo PATH] [--no-push]'
    2
  end
end

exit(ChangeProdApprove.run(ARGV)) if __FILE__ == $PROGRAM_NAME
