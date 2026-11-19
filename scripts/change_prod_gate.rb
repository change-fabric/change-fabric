#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'optparse'
require 'time'
require_relative 'approval_console/canonical'
require_relative 'approval_console/verifier'
require_relative 'change_prod_envelope'
require_relative 'change_prod_store'

# The runner-side gate: everything the generated cf-prod.yml checks before it
# touches a credential. It trusts nothing in the request or approval refs. The
# envelope is revalidated against the base-branch config, the approval proof is
# verified offline against the pinned credentials (public keys, rpId, receipt
# key, machine ids, repo) committed on base, and the approved body must be bound
# to the recomputed request digest. Any failure is a refusal with one reason.
#
# A proof with neither a passkey assertion nor a console receipt (`totp-terminal`,
# level :local) carries nothing cryptographic, and the machine ids are public,
# so anyone able to write refs/cf-prod/approvals could forge one. The runner
# never accepts it, for any profile: it needs a passkey assertion or a console
# receipt. Staging waits for the console receipt phase.
module ChangeProdGate
  APPROVAL_PROTOCOL = 'cf.prod.approval/2'
  LOCAL_REFUSAL = 'a proof with no passkey assertion or console receipt is never accepted; ' \
                  'staging waits for the console receipt phase'
  DEFAULT_TTL_MINUTES = 30
  MAX_TTL_MINUTES = 60
  CLOCK_SKEW = 300

  Result = Struct.new(:ok, :reason, :envelope, :level, keyword_init: true) do
    def ok? = ok
  end

  class Refuse < StandardError; end

  module_function

  # request_id -> Result. `config` is the base-branch frontmatter hash,
  # `credentials` the pinned credentials hash, `allowed` the environments the
  # generated workflow has jobs for.
  def verify(store:, request_id:, config:, credentials:, allowed:, now: Time.now)
    envelope = load_request(store, request_id, config)
    refuse("environment #{envelope['environment']} has no job in this workflow") unless allowed.include?(envelope['environment'])
    approval = load_approval(store, request_id, envelope)
    pinned = pinned(credentials)
    proof = approval['proof']
    body = parse_body(proof)
    refuse('approver machine is not pinned') unless pinned[:machine_ids].include?(body['machine_id'])
    result = check_proof(proof, envelope, body, pinned)
    refuse(LOCAL_REFUSAL) unless %i[passkey receipt].include?(result.level)
    refuse('the remote approval policy needs a console receipt: a passkey assertion alone does not prove the TOTP factor') if proof_policy(config) == 'remote' && result.level != :receipt
    check_lifetime(body, config, now)
    Result.new(ok: true, envelope: envelope, level: result.level)
  rescue Refuse, ChangeProdEnvelope::Invalid, ChangeProdStore::Error => e
    Result.new(ok: false, reason: e.message)
  end

  def refuse(reason) = raise(Refuse, reason)

  def load_request(store, request_id, config)
    envelope = store.read('requests', request_id)
    ChangeProdEnvelope.validate(envelope, config: config)
    refuse('request_id does not match its ref') unless envelope['request_id'] == request_id
    envelope
  rescue ChangeProdStore::Missing
    refuse('no request ref')
  end

  def load_approval(store, request_id, envelope)
    approval = store.read('approvals', request_id)
    refuse('approval record is not an object') unless approval.is_a?(Hash)
    refuse("approval keys are not #{%w[protocol request_id digest proof].join(', ')}") unless approval.keys.sort == %w[digest proof protocol request_id].sort
    refuse("approval protocol is not #{APPROVAL_PROTOCOL}") unless approval['protocol'] == APPROVAL_PROTOCOL
    refuse('approval request_id does not match') unless approval['request_id'] == request_id
    refuse('approval digest does not match the request digest') unless approval['digest'] == envelope['digest']
    approval
  rescue ChangeProdStore::Missing
    refuse('no approval ref')
  end

  def pinned(credentials)
    refuse('pinned credentials are missing') unless credentials.is_a?(Hash)
    ids = credentials['machine_ids']
    ok = %w[rp_id repo].all? { |key| credentials[key].is_a?(String) && !credentials[key].empty? } &&
         ids.is_a?(Array) && !ids.empty? && ids.all?(String) && credentials['credentials'].is_a?(Hash)
    refuse('pinned credentials need rp_id, repo, machine_ids and credentials') unless ok
    { rp_id: credentials['rp_id'], repo: credentials['repo'], machine_ids: ids, credentials: credentials['credentials'],
      receipt_public_key: credentials['receipt_public_key'] }
  end

  def parse_body(proof)
    refuse('approval proof is not an object') unless proof.is_a?(Hash)
    ApprovalConsole::Canonical.parse(proof['body'])
  rescue ApprovalConsole::Canonical::Invalid => e
    refuse("approval body is invalid: #{e.message}")
  end

  # change_policy.prod_guard.approval.proof: `remote` (the default, and the
  # floor) needs a console receipt, which is the only evidence the TOTP factor
  # was checked; `passkey` accepts a bare passkey assertion.
  def proof_policy(config)
    value = config.dig('change_policy', 'prod_guard', 'approval', 'proof') if config.is_a?(Hash)
    value = 'remote' if value.nil?
    refuse("policy approval proof must be remote or passkey, not #{value.inspect}") unless %w[remote passkey].include?(value)
    value
  end

  def check_proof(proof, envelope, body, pinned)
    verifier = ApprovalConsole::Verifier.new(rp_id: pinned[:rp_id], credentials: pinned[:credentials],
                                             receipt_public_key: pinned[:receipt_public_key])
    expected = ChangeProdEnvelope.approval_context(envelope, repo: pinned[:repo], machine_id: body['machine_id'])
    result = verifier.verify(proof, expected: expected)
    refuse("approval proof refused: #{result.reason}") unless result.ok?

    result
  end

  # The signed body's own lifetime, not the console's online expiry: refused
  # once past expires_at, longer than the policy ttl, or dated in the future.
  def check_lifetime(body, config, now)
    created = ApprovalConsole::Canonical.parse_time(body['created_at'])
    expires = ApprovalConsole::Canonical.parse_time(body['expires_at'])
    ttl = ttl_minutes(config) * 60
    refuse('approval has expired') if now >= expires
    refuse("approval lifetime exceeds the #{ttl / 60} minute policy ttl") if expires - created > ttl
    refuse('approval is dated in the future') if created - now > CLOCK_SKEW
  end

  def ttl_minutes(config)
    raw = config.dig('change_policy', 'prod_guard', 'approval', 'ttl_minutes') if config.is_a?(Hash)
    ttl = raw.nil? ? DEFAULT_TTL_MINUTES : raw
    refuse("policy ttl_minutes must be an integer from 1 to #{MAX_TTL_MINUTES}") unless ttl.is_a?(Integer) && ttl.between?(1, MAX_TTL_MINUTES)
    ttl
  end

  # The workflow runs only from the default branch, and the job checkout must be
  # exactly the approved version, reachable from the base branch.
  def provenance(root:, envelope:, github_ref:, default_branch:, base_ref: "origin/#{default_branch}")
    refuse("dispatch ref #{github_ref.inspect} is not refs/heads/#{default_branch}") unless github_ref == "refs/heads/#{default_branch}"
    head = git(root, 'rev-parse', 'HEAD').strip
    refuse("checkout #{head[0, 12]} is not the approved version #{envelope['version'][0, 12]}") unless head == envelope['version']
    _out, status = Open3.capture2e('git', '-C', root, 'merge-base', '--is-ancestor', envelope['version'], base_ref)
    refuse("version #{envelope['version'][0, 12]} is not reachable from #{base_ref}") unless status.success?
    true
  rescue Refuse => e
    Result.new(ok: false, reason: e.message)
  end

  def git(root, *args)
    out, status = Open3.capture2e('git', '-C', root, *args)
    refuse("git #{args.first} failed") unless status.success?
    out
  end

  # Single use: the claim ref is created before any credential is requested. A
  # create that fails means the approval was already consumed. It records the
  # run id and attempt so credentials can be bound to exactly this attempt.
  def claim(store:, request_id:, run_id:, attempt:, now: Time.now, push: true)
    refuse('GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT are required to claim') if run_id.to_s.empty? || attempt.to_s.empty?
    store.create('claims', request_id, { 'request_id' => request_id, 'run_id' => run_id.to_s, 'run_attempt' => attempt.to_s,
                                         'claimed_at' => now.utc.iso8601 }, push: push)
    Result.new(ok: true)
  rescue ChangeProdStore::Exists => e
    Result.new(ok: false, reason: "approval already consumed: #{e.message}")
  rescue ChangeProdStore::Error, Refuse => e
    Result.new(ok: false, reason: e.message)
  end

  # Gate to the credential step. Read-only: only the run attempt that made the
  # claim may proceed. A rerun of any job carries a higher attempt, and a job
  # runs once per attempt, so a rerun needs a fresh approval.
  def issue(store:, envelope:, run_id:, attempt:)
    claimed = store.read('claims', envelope['request_id'])
    same = !run_id.to_s.empty? && !attempt.to_s.empty? && claimed['run_id'] == run_id.to_s && claimed['run_attempt'] == attempt.to_s
    refuse('this run attempt did not claim the approval; a rerun needs a fresh approval') unless same
    Result.new(ok: true, envelope: envelope)
  rescue ChangeProdStore::Missing
    Result.new(ok: false, reason: 'no claim exists for this approval')
  rescue ChangeProdStore::Error, Refuse => e
    Result.new(ok: false, reason: e.message)
  end

  # CLI used by the generated workflow. Exit 0 only when every check passed.
  def run(argv, env: ENV, stdout: $stdout, stderr: $stderr, now: Time.now)
    verb = argv.shift
    opts = parse(argv)
    case verb
    when 'verify' then cli_verify(opts, env, stdout, stderr, now)
    when 'claim' then cli_claim(opts, env, stdout, stderr, now)
    when 'recheck' then cli_recheck(opts, env, stdout, stderr, now)
    when 'run' then refuse_run(stderr)
    else usage(stderr)
    end
  rescue OptionParser::ParseError, ChangeProdEnvelope::Invalid, ChangeProdStore::Error, SystemCallError, JSON::ParserError => e
    stderr.puts "[cf-prod] refused: #{e.message}"
    1
  end

  def parse(argv)
    opts = { repo: '.', remote: 'origin', allowed: [], default_branch: 'main' }
    OptionParser.new do |o|
      o.on('--request-id ID') { |v| opts[:request_id] = v }
      o.on('--repo PATH') { |v| opts[:repo] = v }
      o.on('--config PATH') { |v| opts[:config] = v }
      o.on('--credentials PATH') { |v| opts[:credentials] = v }
      o.on('--allow-environments LIST') { |v| opts[:allowed] = v.split(',') }
      o.on('--default-branch NAME') { |v| opts[:default_branch] = v }
      o.on('--version-root PATH') { |v| opts[:version_root] = v }
      o.on('--remote NAME') { |v| opts[:remote] = v }
    end.parse!(argv)
    opts
  end

  def verified(opts, env, now)
    store = ChangeProdStore.new(opts[:repo], remote: opts[:remote])
    store.fetch
    config = ChangeProdEnvelope.load_config(opts.fetch(:config))
    credentials = JSON.parse(File.read(opts.fetch(:credentials)))
    result = verify(store: store, request_id: opts.fetch(:request_id), config: config, credentials: credentials, allowed: opts[:allowed], now: now)
    return [ store, result ] unless result.ok? && opts[:version_root]

    prov = provenance(root: opts[:version_root], envelope: result.envelope, github_ref: env['GITHUB_REF'].to_s, default_branch: opts[:default_branch])
    [ store, prov == true ? result : prov ]
  rescue KeyError => e
    raise OptionParser::MissingArgument, e.message
  end

  def cli_verify(opts, env, stdout, stderr, now)
    _store, result = verified(opts, env, now)
    return fail_with(stderr, result) unless result.ok?

    output = env['GITHUB_OUTPUT']
    lines = { 'environment' => result.envelope['environment'], 'version' => result.envelope['version'] }.map { |k, v| "#{k}=#{v}" }
    output ? File.open(output, 'a') { |file| file.puts(lines) } : stdout.puts(lines)
    stdout.puts "[cf-prod] verified #{result.envelope['digest'][0, 19]} (proof level #{result.level})"
    0
  end

  def cli_claim(opts, env, stdout, stderr, now)
    store, result = verified(opts, env, now)
    return fail_with(stderr, result) unless result.ok?

    claim = claim(store: store, request_id: opts.fetch(:request_id), run_id: env['GITHUB_RUN_ID'], attempt: env['GITHUB_RUN_ATTEMPT'], now: now)
    return fail_with(stderr, claim) unless claim.ok?

    stdout.puts '[cf-prod] claimed'
    0
  end

  # Run in the credential job, just before it assumes a role: the approval may
  # have expired while the job waited, and a job rerun must not reuse the claim.
  # Verifies again and checks this is the claiming attempt.
  def cli_recheck(opts, env, stdout, stderr, now)
    store, result = verified(opts, env, now)
    return fail_with(stderr, result) unless result.ok?

    issued = issue(store: store, envelope: result.envelope, run_id: env['GITHUB_RUN_ID'], attempt: env['GITHUB_RUN_ATTEMPT'])
    return fail_with(stderr, issued) unless issued.ok?

    stdout.puts '[cf-prod] approval still valid for this attempt'
    0
  end

  def refuse_run(stderr)
    stderr.puts '[cf-prod] refused: no op executor ships in this release; the runner verifies and claims only'
    1
  end

  def fail_with(stderr, result)
    stderr.puts "[cf-prod] refused: #{result.reason}"
    1
  end

  def usage(stderr)
    stderr.puts 'usage: change_prod_gate.rb verify|claim|recheck|run --request-id ID --repo PATH --config PATH --credentials PATH --allow-environments LIST'
    2
  end
end

exit(ChangeProdGate.run(ARGV)) if __FILE__ == $PROGRAM_NAME
