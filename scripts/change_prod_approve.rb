#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require_relative 'approval_console'
require_relative 'change_prod_envelope'
require_relative 'change_prod_gate'
require_relative 'change_prod_store'

# Human-run approval of one bounded prod op request, bound to its digest.
#
#   change_prod_approve.rb REQUEST_ID [--repo PATH] [--no-push]
#
# Terminal path: the runner never accepts a terminal-only proof (no passkey, no
# console receipt), so this release records nothing and says why. Approval
# works once the console issues receipts (console phases 5 and 6); staging
# waits for the same phase. `--remote` is refused until then.
#
# Refuses without a real TTY and inside an agent harness.
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
    ChangeProdEnvelope.validate(load(store, opts))
    refuse(stderr, ChangeProdGate::LOCAL_REFUSAL)
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
    store.read('requests', opts[:request_id])
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
