#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'securerandom'
require 'uri'
require_relative 'approval_console/aws_operator'
require_relative 'approval_console/client'
require_relative 'approval_console/host_health'
require_relative 'approval_console/local_store'
require_relative 'approval_console/proof_check'
require_relative 'approval_console/remote'
require_relative 'approval_console/sync'
require_relative 'approval_console/totp'
require_relative 'change_approval_store'
require_relative 'change_override_store'
require_relative 'change_policy'
require_relative 'cf_project_identity'

# The approval console CLI.
#
#   totp-enroll  generate this machine's seed and show it once on /dev/tty
#   enroll       register this machine with a deployed console and pin it
#   request      ask the console for a prod-op, carve-out or money approval
#   wait         resume waiting on a request made with --no-wait
#   sync         upload offline terminal approvals for console receipts
#   verify       check the proofs recorded for a sha (read-only)
#   status       enrollment, fence, lockout, sync queue and host health
#   unlock       refused: needs a passkey approval not offered yet
#
# `totp-enroll`, `enroll` and `unlock` refuse without a real TTY and inside an
# agent harness. The others never print a secret, so agents may run them: an
# agent asks for an approval with `request`, and the human answers on the
# phone. As elsewhere in this repo the guards are friction, not a sandbox.
module ApprovalConsoleCli
  AGENT_ENV = %w[CLAUDECODE CLAUDE_CODE_ENTRYPOINT CODEX_SANDBOX OPENCODE PI_AGENT].freeze
  AGENT_PROCESS = /claude|codex|opencode|pi-agent/i
  ALT_ON = "\e[?1049h"
  ALT_OFF = "\e[?1049l"

  module_function

  # `io` carries the injectable collaborators the console verbs use: :client
  # (a Client or nil), :operator (an AwsOperator factory), :sleeper, :clock.
  def run(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, env: ENV, store: nil, tty_open: method(:open_tty),
          parents: method(:parent_names), now: Time.now, io: {})
    store ||= ApprovalConsole::LocalStore.new
    ctx = Context.new(stdin: stdin, stdout: stdout, stderr: stderr, env: env, store: store, tty_open: tty_open,
                      parents: parents, io: io)
    case argv.first
    when 'totp-enroll' then totp_enroll(store, stdin, stderr, env, tty_open, parents)
    when 'enroll' then Enroll.run(argv.drop(1), ctx)
    when 'request' then request(argv.drop(1), ctx)
    when 'wait' then wait(argv.drop(1), ctx)
    when 'sync' then sync(ctx)
    when 'verify' then verify(argv.drop(1), ctx)
    when 'status' then status(store, stdout, now)
    when 'unlock' then unlock(store, stdin, stderr, env, parents)
    else usage(stderr)
    end
  end

  Context = Struct.new(:stdin, :stdout, :stderr, :env, :store, :tty_open, :parents, :io, keyword_init: true) do
    def client = io.key?(:client) ? io[:client] : ApprovalConsole::Client.for(store)
    def sleeper = io[:sleeper] || ->(seconds) { sleep(seconds) }
    def clock = io[:clock] || -> { Time.now }
  end

  def usage(stderr)
    stderr.puts 'usage: approval_console.rb totp-enroll | enroll --url URL --profile NAME | ' \
                'request --type prod-op|carve-out|money --summary TEXT [--pr-url URL] [--no-wait] [-- argv...] | ' \
                'wait <request_id> | sync | verify <sha> [--repo PATH] [--profile NAME] | status | unlock'
    1
  end

  REQUEST_TYPES = %w[prod-op carve-out money].freeze

  # Asks the console to approve one high-risk action, bound to this repo, its
  # HEAD and the exact argv or PR URL. Prints the verified proof as one line of
  # JSON on stdout and exits 0 only when the console approved it.
  def request(args, ctx)
    opts = parse_request(args, ctx.stderr) or return 1
    refusal = request_refusal(opts, ctx)
    return refuse(ctx.stderr, 'request', refusal) if refusal

    attrs = request_attrs(opts)
    client = ctx.client
    body, url = ApprovalConsole::Remote.submit(attrs, store: ctx.store, client: client, now: ctx.clock.call, ttl: opts[:ttl])
    ctx.stderr.puts "[approval_console] approve on your phone: #{url}"
    if opts[:no_wait]
      ctx.store.save_request(ApprovalConsole::Canonical.parse(body)['request_id'], body)
      ctx.stdout.puts JSON.generate('request_id' => ApprovalConsole::Canonical.parse(body)['request_id'], 'url' => url)
      return 0
    end
    finish(ApprovalConsole::Remote.wait(body, expected: ApprovalConsole::Remote.expected(attrs, ctx.store.machine_id),
                                              store: ctx.store, client: client, sleeper: ctx.sleeper, clock: ctx.clock), ctx)
  rescue ApprovalConsole::Client::Unreachable, ApprovalConsole::Client::Refused, ApprovalConsole::Canonical::Invalid => e
    refuse(ctx.stderr, 'request', e.message)
  end

  def parse_request(args, stderr)
    opts = { ttl: ApprovalConsole::Remote::LIFETIME, argv: [] }
    split = args.index('--')
    opts[:argv] = split ? args[(split + 1)..] : []
    OptionParser.new do |o|
      o.on('--type TYPE') { |value| opts[:type] = value }
      o.on('--summary TEXT') { |value| opts[:summary] = value }
      o.on('--pr-url URL') { |value| opts[:pr_url] = value }
      o.on('--sha SHA') { |value| opts[:sha] = value }
      o.on('--repo PATH') { |value| opts[:repo] = value }
      o.on('--ttl SECONDS', Integer) { |value| opts[:ttl] = value.clamp(60, ApprovalConsole::Canonical::MAX_LIFETIME) }
      o.on('--no-wait') { opts[:no_wait] = true }
    end.parse!(split ? args[0...split] : args.dup)
    return opts if REQUEST_TYPES.include?(opts[:type]) && !opts[:summary].to_s.strip.empty?

    usage(stderr)
    nil
  rescue OptionParser::ParseError
    usage(stderr)
    nil
  end

  def request_refusal(opts, ctx)
    return 'this machine has no TOTP seed; run totp-enroll from a real terminal' unless ctx.store.enrolled?
    return 'no console is configured; run enroll from a real terminal first' unless ctx.client

    health = ApprovalConsole::HostHealth.refusal(opts[:type], ApprovalConsole::HostHealth.check(store: ctx.store))
    return health if health
    return 'carve-out needs --pr-url' if opts[:type] == 'carve-out' && opts[:pr_url].to_s.empty?
    return "#{opts[:type]} needs the command after --" if opts[:type] != 'carve-out' && opts[:argv].empty?

    nil
  end

  def request_attrs(opts)
    root = File.expand_path(opts[:repo] || Dir.pwd)
    sha = opts[:sha] || git_head(root)
    attrs = { 'type' => opts[:type], 'repo' => CfProjectIdentity.for(root).id, 'sha' => sha, 'profile' => nil,
              'summary' => opts[:summary] }
    opts[:type] == 'carve-out' ? attrs.merge('pr_url' => opts[:pr_url]) : attrs.merge('argv' => opts[:argv])
  end

  def git_head(root)
    out, status = Open3.capture2e('git', '-C', root, 'rev-parse', 'HEAD')
    status.success? ? out.strip : ''
  end

  def wait(args, ctx)
    body = ctx.store.saved_request(args.first)
    return refuse(ctx.stderr, 'wait', 'no request with that id was made from this machine') unless body
    return refuse(ctx.stderr, 'wait', 'no console is configured') unless ctx.client

    finish(ApprovalConsole::Remote.wait(body, expected: ApprovalConsole::Remote.expected_from_body(body), store: ctx.store,
                                              client: ctx.client, sleeper: ctx.sleeper, clock: ctx.clock), ctx)
  end

  def finish(result, ctx)
    return refuse(ctx.stderr, 'the approval', result.error) unless result.ok?

    ctx.stdout.puts JSON.generate(result.proof)
    0
  end

  def sync(ctx)
    return refuse(ctx.stderr, 'sync', 'no console is configured') unless ctx.client
    return refuse(ctx.stderr, 'sync', 'this machine has no TOTP seed') unless ctx.store.enrolled?

    report = ApprovalConsole::Sync.run(store: ctx.store, client: ctx.client)
    ctx.stdout.puts "synced: #{report.synced}"
    ctx.stdout.puts "conflicts: #{report.conflicts}"
    ctx.stdout.puts 'console unreachable; the rest stay queued' if report.unreachable
    report.unreachable || report.conflicts.positive? ? 1 : 0
  end

  # Checks every proof recorded for a sha at the strictest level each passes,
  # without changing anything. Exit 1 when any proof is refused.
  def verify(args, ctx)
    root = Dir.pwd
    profile = nil
    OptionParser.new do |o|
      o.on('--repo PATH') { |value| root = File.expand_path(value) }
      o.on('--profile NAME') { |value| profile = value }
    end.parse!(args = args.dup)
    sha = args.first.to_s
    sha = git_rev(root, sha) unless sha.match?(/\A[0-9a-f]{40}\z/)
    return usage(ctx.stderr) if sha.to_s.empty?

    report_proofs(sha, root, profile, ctx)
  end

  def git_rev(root, ref)
    out, status = Open3.capture2e('git', '-C', root, 'rev-parse', '--verify', '--quiet', "#{ref}^{commit}")
    status.success? ? out.strip : nil
  end

  # nil when there is no override, a problem for a malformed one.
  def override_report(check, override, **context)
    return nil if override.nil?
    return 'override record is malformed' unless override.is_a?(Hash)

    check.override_problem(override, **context)
  end

  def report_proofs(sha, root, profile, ctx)
    repo = CfProjectIdentity.for(root).id
    entries = ChangeApprovalStore.new(sha).entries
    override = ChangeOverrideStore.new(sha, profile: profile).read
    failed = false
    pins = ChangePolicy.for_repo(root)&.approval_pins
    %w[passkey remote local].each do |level|
      check = ApprovalConsole::ProofCheck.new(level: level, store: ctx.store, pins: pins)
      problems = [ entries.empty? ? nil : check.approvals_problem(entries, repo: repo, sha: sha),
                   override_report(check, override, repo: repo, sha: sha, profile: profile) ].compact
      ctx.stdout.puts "#{level}: #{problems.empty? ? 'pass' : problems.join('; ')}"
      failed = !problems.empty? if level == 'local'
    end
    ctx.stdout.puts "records: #{entries.size} step approval(s), #{override ? 1 : 0} override"
    failed ? 1 : 0
  end

  def totp_enroll(store, stdin, stderr, env, tty_open, parents)
    refusal = human_only_refusal(stdin, env, parents)
    return refuse(stderr, 'totp-enroll', refusal) if refusal
    return refuse(stderr, 'totp-enroll', 'a TOTP seed is already enrolled on this machine') if store.enrolled?

    tty = tty_open.call
    return refuse(stderr, 'totp-enroll', '/dev/tty cannot be opened; enroll from the console instead') unless tty

    reveal(store, tty, stderr)
  ensure
    tty.close if tty.respond_to?(:close)
  end

  # The seed goes to the tty only: never stdout, stderr or a log. On a failed
  # reveal the seed is discarded so an unseen secret is not left enrolled.
  def reveal(store, tty, stderr)
    seed = store.enroll!
    shown = false
    begin
      show(tty, store, seed)
      shown = true
    rescue StandardError, Errno::EIO
      stderr.puts '[approval_console] could not show the secret on the terminal; nothing was enrolled.'
    ensure
      # Also runs on Interrupt and other signals: an unconfirmed seed is never kept.
      store.discard! unless shown
    end
    return 1 unless shown

    stderr.puts '[approval_console] enrolled. Add the secret to any RFC 6238 TOTP app, one entry per machine.'
    0
  end

  def show(tty, store, seed)
    secret = ApprovalConsole::Base32.encode(seed)
    label = store.label.to_s.gsub(/[^A-Za-z0-9._-]/, '-')
    tty.print(ALT_ON)
    tty.puts 'TOTP secret for this machine (any RFC 6238 app: SHA-1, 6 digits, 30 s).'
    tty.puts 'Type it into your app; it is shown once.'
    tty.puts ''
    tty.puts "  secret: #{secret}"
    tty.puts "  uri:    otpauth://totp/cf:#{label}?secret=#{secret}&issuer=cf"
    tty.puts ''
    tty.print 'Press Enter when saved: '
    tty.flush
    tty.gets
  ensure
    tty.print("\e[2J\e[H#{ALT_OFF}")
    tty.flush
  end

  def status(store, stdout, now)
    info = store.status(now: now)
    report = ApprovalConsole::HostHealth.check(store: store)
    stdout.puts "enrolled: #{info[:enrolled] ? 'yes' : 'no (run totp-enroll from a real terminal)'}"
    stdout.puts "machine: #{info[:machine_id]}" if info[:machine_id]
    stdout.puts "last accepted step: #{info[:last_step] || 'none'}"
    stdout.puts "locked until: #{info[:locked_until].iso8601}" if info[:locked_until]
    stdout.puts "console: #{info[:console_configured] ? store.base_url : 'not configured (terminal only)'}"
    stdout.puts "pending sync: #{info[:pending]}"
    stdout.puts "conflicts: #{info[:conflicts]}" if info[:conflicts].positive?
    stdout.puts "host: #{report.degraded? ? "degraded (#{report.reasons.join('; ')}); prod-op, carve-out and money are refused" : 'ok'}"
    0
  end

  def unlock(store, stdin, stderr, env, parents)
    refusal = human_only_refusal(stdin, env, parents)
    return refuse(stderr, 'unlock', refusal) if refusal

    reason = if store.console_configured?
               'unlock needs a passkey approval from the console, which is not available in this release'
    else
               'a terminal-only install has no manual unlock; wait for the lockout to expire (15 minutes, doubling, at most 24 hours)'
    end
    refuse(stderr, 'unlock', reason)
  end

  # Human-only verbs need a real TTY on stdin and no agent harness.
  def human_only_refusal(stdin, env, parents)
    return 'this must be run from a real terminal, not scripted or piped' unless stdin.tty?
    return 'an agent harness is running this command; run it yourself in a terminal' if agent?(env, parents)

    nil
  end

  def agent?(env, parents)
    AGENT_ENV.any? { |name| !env[name].to_s.empty? } || parents.call.any? { |name| name.match?(AGENT_PROCESS) }
  end

  def refuse(stderr, verb, reason)
    stderr.puts "[approval_console] refusing #{verb}: #{reason}."
    2
  end

  def open_tty
    File.open('/dev/tty', 'r+')
  rescue SystemCallError
    nil
  end

  # Command names up the parent process chain, nearest first. Empty when ps
  # is unavailable.
  def parent_names
    names = []
    pid = Process.ppid
    8.times do
      out, status = Open3.capture2('ps', '-o', 'ppid=,comm=', '-p', pid.to_s, err: File::NULL)
      break unless status.success?

      ppid, comm = out.strip.split(' ', 2)
      names << File.basename(comm.to_s)
      break if ppid.to_i <= 1

      pid = ppid.to_i
    end
    names
  rescue SystemCallError
    []
  end
end

require_relative 'approval_console/enroll'

exit(ApprovalConsoleCli.run(ARGV)) if __FILE__ == $PROGRAM_NAME
