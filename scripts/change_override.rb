#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'open3'
require_relative 'change_override_store'
require_relative 'cf_project_identity'
require_relative 'approval_console/terminal_prompt'

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
module ChangeOverride
  module_function

  def run(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr)
    sha, reason, profile = parse_args(argv, stderr)
    return 1 unless sha
    return 1 unless real_terminal?(stdin, stderr)

    sha = full_sha(sha)
    unless sha
      stderr.puts '[change] the override must name a full 40-character commit sha (or a ref git can resolve here).'
      return 1
    end
    return 1 unless enrolled?(stderr)
    return 1 unless confirmed?(sha, stdin: stdin, stdout: stdout, stderr: stderr)

    proof = prove(sha, reason, profile, stdin: stdin, stdout: stdout, stderr: stderr)
    return 1 unless proof

    ChangeOverrideStore.new(sha, profile: profile).record(
      reason: reason, recorded_by: ENV['USER'] || ENV['USERNAME'] || 'unknown', proof: proof
    )
    stdout.puts "[change] override recorded for #{sha[0, 12]}#{profile ? " (profile: #{profile})" : ''}. " \
                'Scoped to this exact commit; a new commit needs a new override.'
    0
  end

  # The TOTP second factor over this exact (sha, profile, reason). Nil, with
  # the reason on stderr, when refused; nothing is recorded then.
  def prove(sha, reason, profile, stdin:, stdout:, stderr:)
    result = ApprovalConsole::TerminalPrompt.approve(
      { 'type' => 'override', 'repo' => CfProjectIdentity.for(Dir.pwd).id, 'sha' => sha, 'profile' => profile,
        'reason' => reason }, stdin: stdin, stdout: stdout
    )
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
    OptionParser.new do |o|
      o.on('--reason REASON') { |value| reason = value }
      o.on('--profile NAME') { |value| profile = value }
    end.parse!(args)
    sha = args.first

    if sha.to_s.empty? || reason.to_s.empty?
      stderr.puts 'usage: change_override.rb <sha> --reason "<why>" [--profile NAME]'
      return [ nil, nil, nil ]
    end
    [ sha, reason, profile ]
  end
end

exit(ChangeOverride.run(ARGV)) if __FILE__ == $PROGRAM_NAME
