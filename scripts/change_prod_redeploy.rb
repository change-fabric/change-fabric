#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'optparse'
require 'yaml'
require_relative 'change_prod_envelope'
require_relative 'change_prod_request'
require_relative 'change_prod_store'

# The built-in `redeploy_previous` op for the bounded prod runner, and the one
# call the progressive-delivery triage flow makes when a fix needs a code
# rollback. Tags stay human-only, so the op redeploys the previous release ref
# and never retags.
#
#   change_prod_redeploy.rb template
#   change_prod_redeploy.rb offer --config FILE --profile P [--repo PATH] [--incident ID] [--version SHA]
#
# `offer` resolves the recorded predecessor of the current successful
# deployment, binds its commit sha into the request params, and writes the
# request ref. It never approves and never dispatches: a person still approves
# the digest with passkey plus TOTP, exactly as for every other op. Deployment
# history and tag resolution are injectable so the logic is testable with no
# GitHub call.
module ChangeProdRedeploy
  class Refused < StandardError; end

  OP = 'redeploy_previous'
  RELEASE = /\Av[0-9.]+\z/
  SHA = /\A[0-9a-f]{40}\z/
  REASON = 'redeploys an already-released build'
  APPROVE = 'ruby ~/.claude/cf/bin/change_prod_approve.rb'

  # Paste under change_config.operations. `previous_sha` is bound into the
  # approved digest next to the release ref, so a ref that moves after approval
  # (or a ref that never pointed at the recorded predecessor) is refused. The
  # argv is the app's own deploy command; adjust it, keep the params.
  TEMPLATE = {
    'class' => 'routine',
    'runner' => 'prod',
    'argv' => [ 'pnpm', 'app', 'deploy', '--ref', '{previous_release}' ],
    'params' => {
      'previous_release' => { 'type' => 'string', 'pattern' => '^v[0-9.]+$' },
      'previous_sha' => { 'type' => 'string', 'pattern' => '^[0-9a-f]{40}$' }
    },
    'backup' => 'main_db',
    'online_safe' => { 'reason' => REASON },
    'verify' => { 'argv' => [ 'pnpm', 'app', 'health' ], 'timeout_s' => 120 },
    'timeout_s' => 1200,
    'staging_first' => true
  }.freeze

  module_function

  def template_yaml = YAML.dump({ 'change_config' => { 'operations' => { OP => TEMPLATE } } })

  # The sha the previous successful deployment ran. `deployments` is newest
  # first: [{ 'sha' =>, 'state' => }]. The current deployment is the newest
  # success; its predecessor is the newest earlier success at a different sha.
  def predecessor(deployments)
    successes = Array(deployments).select { |d| d.is_a?(Hash) && d['state'] == 'success' && d['sha'].to_s.match?(SHA) }
    raise Refused, 'no successful deployment is recorded, so there is nothing to roll back from' if successes.empty?

    current = successes.first['sha']
    previous = successes.find { |d| d['sha'] != current }
    raise Refused, 'no earlier successful deployment at a different commit is recorded' unless previous

    previous['sha']
  end

  # The params for the op: the release tag that points at the predecessor, and
  # the predecessor sha. `tags_at` maps a sha to its tag names.
  def params_for(deployments, tags_at:)
    sha = predecessor(deployments)
    releases = Array(tags_at.call(sha)).grep(RELEASE).sort_by { |tag| tag.delete_prefix('v').split('.').map(&:to_i) }
    raise Refused, "no release tag points at the recorded predecessor #{sha[0, 12]}" if releases.empty?

    { 'previous_release' => releases.last, 'previous_sha' => sha }
  end

  # Runner-side recheck: the approved params must still name the recorded
  # predecessor, and the tag must still resolve to that sha.
  def check(params, deployments:, resolve_tag:)
    sha = predecessor(deployments)
    raise Refused, 'previous_sha is not the recorded predecessor deployment' unless params['previous_sha'] == sha
    raise Refused, 'previous_release does not resolve to the recorded predecessor' unless resolve_tag.call(params['previous_release']) == sha

    true
  end

  # True when the config declares the op in the built-in shape: routine class,
  # a reasoned online-safe opt-out and the bound previous_sha param. Triage
  # offers nothing otherwise.
  def declared?(config)
    op = config.is_a?(Hash) ? config.dig('change_config', 'operations', OP) : nil
    op.is_a?(Hash) && op['class'] == 'routine' && !op.dig('online_safe', 'reason').to_s.strip.empty? &&
      op.dig('params', 'previous_sha').is_a?(Hash)
  end

  # Writes the request ref for a rollback and returns the envelope. This is the
  # entry point the triage flow calls; approval and dispatch stay with people.
  def offer(config:, profile:, version:, requested_by:, deployments:, tags_at:, store: nil, push: true)
    raise Refused, "the config does not declare #{OP} with a previous_sha param (see: change_prod_redeploy.rb template)" unless declared?(config)

    params = params_for(deployments, tags_at: tags_at)
    envelope = ChangeProdEnvelope.build(config: config, op: OP, params: params, profile: profile, version: version, requested_by: requested_by)
    store&.create('requests', envelope['request_id'], envelope, push: push)
    envelope
  end

  def run(argv, stdout: $stdout, stderr: $stderr, env: ENV, history: method(:gh_history), tags: method(:git_tags))
    verb = argv.shift
    case verb
    when 'template' then print_template(stdout)
    when 'offer' then cli_offer(argv, stdout, env, history, tags)
    else
      stderr.puts 'usage: change_prod_redeploy.rb template | offer --config FILE --profile P [--repo PATH] [--incident ID] [--version SHA]'
      2
    end
  rescue OptionParser::ParseError, Refused, ChangeProdEnvelope::Invalid, ChangeProdStore::Error => e
    stderr.puts "[cf-prod] refused: #{e.message}"
    1
  end

  def print_template(stdout)
    stdout.print(template_yaml)
    0
  end

  def cli_offer(argv, stdout, env, history, tags)
    opts = parse(argv, env)
    config = ChangeProdEnvelope.load_config(opts[:config].to_s)
    version = opts[:version] || ChangeProdRequest.base_sha(opts[:repo])
    envelope = offer(config: config, profile: opts[:profile], version: version, requested_by: opts[:requested_by],
                     deployments: history.call(opts[:repo], production_environment(config, opts[:profile])),
                     tags_at: ->(sha) { tags.call(opts[:repo], sha) }, store: ChangeProdStore.new(opts[:repo]), push: opts[:push])
    report(stdout, envelope, opts[:incident])
    0
  end

  def report(stdout, envelope, incident)
    params = envelope['params']
    stdout.puts "request_id: #{envelope['request_id']}"
    stdout.puts "digest: #{envelope['digest']}"
    stdout.puts "redeploys #{params['previous_release']} (#{params['previous_sha'][0, 12]})#{incident ? " for incident #{incident}" : ''}"
    stdout.puts "A human must now approve it: #{APPROVE} #{envelope['request_id']}"
  end

  def parse(argv, env)
    opts = { repo: '.', push: true, requested_by: "agent:#{env.fetch('CLAUDE_SESSION_ID', 'cli')}" }
    OptionParser.new do |o|
      o.on('--config PATH') { |v| opts[:config] = v }
      o.on('--profile NAME') { |v| opts[:profile] = v }
      o.on('--repo PATH') { |v| opts[:repo] = v }
      o.on('--incident ID') { |v| opts[:incident] = v }
      o.on('--version SHA') { |v| opts[:version] = v }
      o.on('--no-push') { opts[:push] = false }
    end.parse!(argv)
    opts
  end

  def production_environment(config, profile)
    ChangeProdEnvelope.environment_for(ChangeProdEnvelope.section(config), OP, profile)
  end

  def git(repo, *args)
    out, status = Open3.capture2e('git', '-C', repo, *args)
    raise Refused, "git #{args.first} failed" unless status.success?

    out.strip
  end

  def git_tags(repo, sha) = git(repo, 'tag', '--points-at', sha).split("\n")

  # Deployment history newest first. A deployment counts as a success when any
  # of its statuses was `success`: GitHub's auto-inactivation adds an `inactive`
  # status after a newer success, so the latest status alone would drop a valid
  # rollback target. Any failed lookup refuses, because skipping a deployment
  # would silently pick the wrong predecessor.
  def gh_history(repo, environment, gh: method(:gh_api))
    deployments = gh.call(repo, "repos/{owner}/{repo}/deployments?environment=#{environment}&per_page=30")
    deployments.map do |d|
      statuses = gh.call(repo, "repos/{owner}/{repo}/deployments/#{Integer(d['id'])}/statuses?per_page=100")
      { 'sha' => d['sha'], 'state' => state_from(statuses) }
    end
  end

  def state_from(statuses)
    return 'success' if Array(statuses).any? { |s| s['state'] == 'success' }

    Array(statuses).first&.fetch('state', nil)
  end

  def gh_api(repo, path)
    out, status = Open3.capture2e('gh', 'api', path, chdir: repo)
    raise Refused, "cannot read #{path.split('?').first}" unless status.success?

    JSON.parse(out)
  rescue JSON::ParserError
    raise Refused, "unreadable response for #{path.split('?').first}"
  end
end

exit(ChangeProdRedeploy.run(ARGV)) if __FILE__ == $PROGRAM_NAME
