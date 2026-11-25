#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'open3'
require_relative 'change_override_store'
require_relative 'cf_project_identity'
require_relative 'approval_console/terminal_prompt'
require_relative 'approval_console/remote'
require_relative 'approval_console/recorder'
require_relative 'approval_console/route'

# Human-run companion to change_merge_guard.rb's CF_ALLOW_UNGATED_MERGE escape
# hatch, for the case that hatch is documented but unreachable: the guard reads
# that env var from its own PreToolUse hook process, whose environment is fixed
# at harness launch, so nothing an agent exports or prefixes on a command
# mid-session ever reaches it. This script writes a file the guard reads
# instead (ChangeOverrideStore), scoped to the exact (sha[, profile]) so it can
# never leak to a later commit or a different profile.
#
# Refuses to run without a real TTY on stdin, and asks the operator to type
# the SHA's first 12 characters back. Like every other guard in this codebase
# (change_merge_guard.rb's own docstring says it plainly: "a loud guardrail
# rather than a sandbox"), this is a bar raised against casual, accidental, or
# scripted misuse (a bare pipe or heredoc will not satisfy it), not a hard
# cryptographic guarantee against a determined adversarial agent: a process
# willing to allocate its own pty (`script`, Python's `pty.spawn`, `expect`)
# can still drive both checks, since the confirmation value (a SHA prefix) is
# not secret from whatever already wants to override the gate. The intended
# use is still a human typing it themselves at their own terminal; this is not
# a substitute for that intent, only friction against skipping it by accident.
#
# After the typed confirmation it also requires a TOTP code from this
# machine's enrolled seed (approval_console.rb totp-enroll), fenced to one use
# per 30 second step, and stores a `totp-terminal` proof with the override.
# With --remote and a console configured, the phone shows the override and
# takes the TOTP code and the passkey instead, and ApprovalConsole::Recorder
# checks the receipt before it is recorded. --remote needs no TTY (an agent
# starts it and posts the link; only the phone approves) and a --reason of at
# least 20 characters.
module ChangeOverride
  module_function

  def run(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, console: :default, authority: :default, io: {})
    sha, reason, profile, remote, scope = parse_args(argv, stderr)
    return 1 unless sha
    return 1 unless remote ? long_reason?(reason, stderr) : real_terminal?(stdin, stderr)
    return 1 if scope && !remote && !scoped_remote_only(stderr)

    sha = full_sha(sha)
    unless sha
      stderr.puts '[change] the override must name a full 40-character commit sha (or a ref git can resolve here).'
      return 1
    end
    return 1 unless enrolled?(stderr)

    store = remote && ApprovalConsole::Route.store(Dir.pwd, authority: authority)
    return unenrolled(store, stderr) if store && store.unenrolled_reason
    client = remote && console_client(console, store, stdin, stderr)
    return 1 if remote && !client && !stdin.tty?
    return 1 if scope && !client && !scoped_remote_only(stderr)
    return override_remote(attrs(sha, reason, profile, scope), client, authority, store: store, stdout: stdout, stderr: stderr, **io) if client
    return 1 unless confirmed?(sha, stdin: stdin, stdout: stdout, stderr: stderr)

    proof = prove(sha, reason, profile, stdin: stdin, stdout: stdout, stderr: stderr)
    return 1 unless proof

    ChangeOverrideStore.new(sha, profile: profile).record(reason: reason, recorded_by: recorded_by, proof: proof)
    recorded(sha, profile, stdout)
  end

  def recorded_by = ENV['USER'] || ENV['USERNAME'] || 'unknown'

  def recorded(sha, profile, stdout)
    stdout.puts "[change] override recorded for #{sha[0, 12]}#{profile ? " (profile: #{profile})" : ''}. " \
                'Scoped to this exact commit; a new commit needs a new override.'
    0
  end

  # The phone path, runnable without a TTY. The authoritative policy is
  # resolved before the phone is asked; ApprovalConsole::Recorder checks and
  # writes the receipt.
  def override_remote(attrs, client, authority, stdout:, stderr:, store: ApprovalConsole::LocalStore.new, **opts)
    authority = ApprovalConsole::Recorder.authority_for(Dir.pwd) if authority == :default
    proof = prove_remote(attrs, client, store, stdout: stdout, stderr: stderr, **opts)
    return 1 unless proof

    expected = ApprovalConsole::Remote.expected(attrs, ApprovalConsole::LocalStore.new.machine_id)
    result = ApprovalConsole::Recorder.new(authority: authority, recorded_by: recorded_by, clock: opts[:clock] || -> { Time.now }).record(proof, expected: expected)
    return recorded(attrs['sha'], attrs['profile'], stdout) if result.ok?

    stderr.puts "[change] #{result.error}; nothing recorded."
    1
  rescue ChangePolicy::Unreadable => e
    stderr.puts "[change] refusing: cannot read the authoritative approval policy (#{e.message})."
    1
  end

  # A phone override says why in at least MIN_REASON characters.
  def long_reason?(reason, stderr)
    return true if reason.to_s.strip.length >= ApprovalConsole::Recorder::MIN_REASON

    stderr.puts "[change] refusing: --remote needs a --reason of at least #{ApprovalConsole::Recorder::MIN_REASON} characters."
    false
  end

  def attrs(sha, reason, profile, scope = nil)
    base = { 'type' => 'override', 'repo' => CfProjectIdentity.for(Dir.pwd).id, 'sha' => sha, 'profile' => profile, 'reason' => reason }
    scope ? base.merge('scope' => scope) : base
  end

  # A scope is part of the signed phone body; the terminal path signs none.
  def scoped_remote_only(stderr)
    stderr.puts '[change] refusing: --scope needs --remote (only a phone approval carries a scope).'
    false
  end

  # The console client, or nil: a real terminal falls back to the TOTP path,
  # anything else is refused.
  # The repo pins a console this machine is not enrolled on: refused before
  # the phone is asked.
  def unenrolled(store, stderr)
    stderr.puts "[change] refusing: #{store.unenrolled_reason}; nothing recorded."
    1
  end

  def console_client(console, store, stdin, stderr)
    client = console == :default ? ApprovalConsole::Client.for(store) : console
    return client if client

    stderr.puts(stdin.tty? ? '[change] no approval console is configured; using the terminal TOTP path.' : '[change] refusing: no approval console is configured.')
    nil
  end

  def prove_remote(attrs, client, store, stdout:, stderr:, **opts)
    result = ApprovalConsole::Remote.approve(attrs, store: store, client: client, out: stdout, **opts)
    return result.proof if result.ok?

    stderr.puts "[change] #{result.error}; nothing recorded."
    nil
  end

  # The TOTP second factor over this exact (sha, profile, reason). Nil, with
  # the reason on stderr, when refused; nothing is recorded then.
  def prove(sha, reason, profile, stdin:, stdout:, stderr:)
    result = ApprovalConsole::TerminalPrompt.approve(attrs(sha, reason, profile), stdin: stdin, stdout: stdout)
    return result.proof if result.ok?

    stderr.puts "[change] #{result.error}; nothing recorded."
    nil
  rescue ApprovalConsole::Canonical::Invalid => e
    stderr.puts "[change] cannot bind the override: #{e.message}; nothing recorded."
    nil
  end

  # A full lowercase sha as given, else what git resolves it to here.
  def full_sha(ref)
    return ref if ref.match?(/\A[0-9a-f]{40}\z/)

    out, status = Open3.capture2e('git', 'rev-parse', '--verify', '--quiet', "#{ref}^{commit}")
    status.success? && out.strip.match?(/\A[0-9a-f]{40}\z/) ? out.strip : nil
  end

  def enrolled?(stderr)
    refusal = ApprovalConsole::TerminalPrompt.preflight('override')
    stderr.puts "[change] refusing: #{refusal}" if refusal
    refusal.nil?
  end

  def real_terminal?(stdin, stderr)
    return true if stdin.tty?

    stderr.puts '[change] refusing: this must be run from a real terminal, not scripted or piped.'
    false
  end

  # The typed-SHA-prefix confirmation, isolated from
  # argument parsing and the record/report steps so each concern in run can
  # be read (and tested) on its own.
  def confirmed?(sha, stdin:, stdout:, stderr:)
    stdout.print "Confirm: type the first 12 characters of #{sha} to authorize a merge gate override: "
    typed = stdin.gets.to_s.strip
    return true if typed == sha[0, 12]

    stderr.puts '[change] confirmation did not match; nothing recorded.'
    false
  end

  def parse_args(argv, stderr)
    args = argv.dup
    reason = nil
    profile = nil
    remote = false
    scope = nil
    OptionParser.new do |o|
      o.on('--remote') { remote = true }
      o.on('--scope SCOPE', ApprovalConsole::Canonical::SCOPES) { |value| scope = value }
      o.on('--reason REASON') { |value| reason = value }
      o.on('--profile NAME') { |value| profile = value }
    end.parse!(args)
    sha = args.first

    if sha.to_s.empty? || reason.to_s.empty?
      stderr.puts 'usage: change_override.rb <sha> --reason "<why>" [--profile NAME] [--remote [--scope merge|tag]]'
      return [ nil, nil, nil, false, nil ]
    end
    [ sha, reason, profile, remote, scope ]
  end
end

exit(ChangeOverride.run(ARGV)) if __FILE__ == $PROGRAM_NAME
