#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'optparse'
require_relative 'change_prod_envelope'
require_relative 'change_prod_store'

# Agent-callable half of the bounded prod runner. An agent may describe a
# declared op and dispatch the runner once a human has approved; it can do
# neither without a person (change_prod_approve.rb is TTY-only and denied to
# agents by prod_approval_guard.rb) and it never holds a production credential.
#
#   change_prod_request.rb create --op NAME [--param k=v ...] --profile P --config FILE [--version SHA]
#   change_prod_request.rb dispatch REQUEST_ID --config FILE
#
# `create` writes refs/cf-prod/requests/<id> and prints the id and digest;
# nothing dispatches. `dispatch` refuses unless an approval ref for exactly
# this digest exists, then starts the generated workflow. The runner re-verifies
# everything; this check only avoids a dispatch that is certain to refuse.
module ChangeProdRequest
  module_function

  def run(argv, stdout: $stdout, stderr: $stderr, env: ENV, runner: method(:gh_dispatch))
    verb = argv.shift
    opts = parse(argv, env)
    case verb
    when 'create' then create(opts, stdout)
    when 'dispatch' then dispatch(opts, stdout, runner)
    else usage(stderr)
    end
  rescue OptionParser::ParseError, ChangeProdEnvelope::Invalid, ChangeProdStore::Error => e
    stderr.puts "[cf-prod] refused: #{e.message}"
    1
  end

  def parse(argv, env)
    opts = { repo: '.', params: {}, push: true, requested_by: "agent:#{env.fetch('CLAUDE_SESSION_ID', 'cli')}" }
    OptionParser.new do |o|
      o.on('--op NAME') { |v| opts[:op] = v }
      o.on('--param K=V') { |v| opts[:params].store(*v.split('=', 2)) }
      o.on('--profile NAME') { |v| opts[:profile] = v }
      o.on('--config PATH') { |v| opts[:config] = v }
      o.on('--version SHA') { |v| opts[:version] = v }
      o.on('--repo PATH') { |v| opts[:repo] = v }
      o.on('--requested-by ID') { |v| opts[:requested_by] = v }
      o.on('--no-push') { opts[:push] = false }
    end.parse!(argv)
    opts[:request_id] = argv.shift
    opts
  end

  def create(opts, stdout)
    config = ChangeProdEnvelope.load_config(opts[:config].to_s)
    envelope = ChangeProdEnvelope.build(config: config, op: opts[:op], params: opts[:params], profile: opts[:profile],
                                        version: opts[:version] || base_sha(opts[:repo]), requested_by: opts[:requested_by])
    ChangeProdStore.new(opts[:repo]).create('requests', envelope['request_id'], envelope, push: opts[:push])
    stdout.puts "request_id: #{envelope['request_id']}"
    stdout.puts "digest: #{envelope['digest']}"
    stdout.puts "A human must now approve it: ruby ~/.claude/cf/bin/change_prod_approve.rb #{envelope['request_id']}"
    0
  end

  def dispatch(opts, stdout, runner)
    id = opts[:request_id].to_s
    config = ChangeProdEnvelope.load_config(opts[:config].to_s)
    store = ChangeProdStore.new(opts[:repo])
    store.fetch if opts[:push]
    envelope = ChangeProdEnvelope.validate(store.read('requests', id), config: config)
    approval = store.read('approvals', id)
    raise ChangeProdStore::Error, 'the approval does not name this request digest' unless approval.is_a?(Hash) && approval['digest'] == envelope['digest']

    workflow = File.basename(config.dig('change_config', 'runners', operation_runner(config, envelope), 'workflow').to_s)
    raise ChangeProdStore::Error, 'the runner declares no workflow file' if workflow.empty?
    raise ChangeProdStore::Error, 'dispatch failed' unless runner.call(workflow, id, opts[:repo])

    stdout.puts "[cf-prod] dispatched #{workflow} for #{id}"
    0
  rescue ChangeProdStore::Missing => e
    raise ChangeProdStore::Error, "not approved yet: #{e.message}"
  end

  def operation_runner(config, envelope) = config.dig('change_config', 'operations', envelope['op'], 'runner').to_s

  # Always dispatches on the default branch; the runner refuses any other ref.
  # Runs in the verified checkout, so gh resolves that repository's workflow.
  def gh_dispatch(workflow, request_id, repo)
    _out, status = Open3.capture2e('gh', 'workflow', 'run', workflow, '-f', "request_id=#{request_id}", chdir: repo)
    status.success?
  end

  # The tip of the remote's default branch: origin/HEAD when set, else the
  # conventional main, then master. Never a guess that could pick a stale branch
  # when origin/HEAD says otherwise.
  def base_sha(repo)
    head, = Open3.capture2e('git', '-C', repo, 'symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD')
    candidates = head.strip.empty? ? %w[refs/remotes/origin/main refs/remotes/origin/master] : [ head.strip ]
    candidates.each do |ref|
      out, status = Open3.capture2e('git', '-C', repo, 'rev-parse', '--verify', '--quiet', ref)
      return out.strip if status.success?
    end
    raise ChangeProdEnvelope::Invalid, 'cannot resolve the default branch (origin/HEAD, origin/main, origin/master); pass --version'
  end

  def usage(stderr)
    stderr.puts 'usage: change_prod_request.rb create --op NAME --profile P --config FILE [--param k=v] | dispatch REQUEST_ID --config FILE'
    2
  end
end

exit(ChangeProdRequest.run(ARGV)) if __FILE__ == $PROGRAM_NAME
