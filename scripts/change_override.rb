#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require_relative 'change_override_store'

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
module ChangeOverride
  module_function

  def run(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr)
    sha, reason, profile = parse_args(argv, stderr)
    return 1 unless sha
    return 1 unless confirmed?(sha, stdin: stdin, stdout: stdout, stderr: stderr)

    ChangeOverrideStore.new(sha, profile: profile).record(
      reason: reason, recorded_by: ENV['USER'] || ENV['USERNAME'] || 'unknown'
    )
    stdout.puts "[change] override recorded for #{sha[0, 12]}#{profile ? " (profile: #{profile})" : ''}. " \
                'Scoped to this exact commit; a new commit needs a new override.'
    0
  end

  # The TTY check plus the typed-SHA-prefix confirmation, isolated from
  # argument parsing and the record/report steps so each concern in run can
  # be read (and tested) on its own.
  def confirmed?(sha, stdin:, stdout:, stderr:)
    unless stdin.tty?
      stderr.puts '[change] refusing: this must be run from a real terminal, not scripted or piped.'
      return false
    end

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
