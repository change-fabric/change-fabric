#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'optparse'
require_relative 'change_trust'
require_relative 'change_approval_store'

# Human-run approval of host-run step definitions (boot.up, boot.down, command
# lane entries) that differ from the base branch at one exact commit. cf:change
# refuses to execute such a step until it is approved here, and the merge and
# tag guards refuse a gate record that ran one without approval.
#
# Usage: change_approve.rb <sha> [--repo PATH]
#
# It reads the definitions committed at <sha> and on the base branch with
# `git show` (nothing is checked out or executed), prints every step that
# differs in full beside its base version (or "new step"), and asks the
# operator to type the sha's first 12 characters. One confirmation approves
# every listed step for that sha. It never consults who authored the commit:
# the maintainer's own pull requests need the same approval.
#
# Refuses without a real TTY on stdin. As with change_override.rb this is
# friction against a scripted or agent-driven approval, not a cryptographic
# bar: a process that allocates its own pty can still drive the prompt, since
# the confirmation value is not secret. The intended use is a human reading
# the listed commands at their own terminal before typing.
module ChangeApprove
  # One step awaiting approval, with the fields a human needs to judge it.
  Pending = Struct.new(:step, :digest, :fields, :base_fields, :profile, keyword_init: true)

  module_function

  def run(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, fetch: true)
    sha_arg, root = parse_args(argv, stderr)
    return 1 unless sha_arg

    unless stdin.tty?
      stderr.puts '[change] refusing: this must be run from a real terminal, not scripted or piped.'
      return 1
    end

    sha = full_sha(root, sha_arg)
    unless sha
      stderr.puts "[change] #{sha_arg} is not a commit in #{root}"
      return 1
    end

    base = ChangeTrust.resolve_base(root, fetch: fetch)
    stderr.puts "[change] note: #{base.note}" if base.note
    pending = pending_steps(root, sha, base)
    if pending.empty?
      stdout.puts "[change] nothing to approve: every step at #{sha[0, 12]} matches #{base.ref} or is already approved."
      return 0
    end

    describe(pending, sha, base, stdout)
    return 1 unless confirmed?(sha, stdin: stdin, stdout: stdout, stderr: stderr)

    ChangeApprovalStore.new(sha).record(steps: pending.map { |item| [ item.step, item.digest ] }, by: approver(root))
    stdout.puts "[change] approved #{pending.size} step(s) for #{sha[0, 12]}. A new commit or an edited step needs a new approval."
    0
  end

  # Every (step, digest) at `sha` that matches neither the base branch nor an
  # existing approval, across the unprofiled config and every named profile,
  # since a profile may override boot and so define a different step.
  def pending_steps(root, sha, base)
    approvals = ChangeApprovalStore.new(sha).approvals
    profiles_at(root, sha).flat_map do |profile|
      head = ChangeTrust.snapshot_definitions(root, sha, profile: profile)
      base_defs = base.sha ? ChangeTrust.snapshot_definitions(root, base.sha, profile: profile) : {}
      head.filter_map do |step, fields|
        digest = ChangeTrust.digest(fields)
        next if base_defs[step] && ChangeTrust.digest(base_defs[step]) == digest
        next if approvals.include?([ step, digest ])

        Pending.new(step: step, digest: digest, fields: fields, base_fields: base_defs[step], profile: profile)
      end
    end.uniq { |item| [ item.step, item.digest ] }
  end

  def profiles_at(root, sha)
    out, status = Open3.capture2e('git', '-C', root, 'show', "#{sha}:CHANGE.md")
    profiles = status.success? ? ChangeFrontmatter.parse(out).dig('change_config', 'profiles') : nil
    profiles.is_a?(Hash) && !profiles.empty? ? profiles.keys.map(&:to_s) : [ nil ]
  end

  def describe(pending, sha, base, stdout)
    stdout.puts "[change] #{pending.size} step(s) at #{sha[0, 12]} differ from #{base.ref || 'the base branch'}:"
    pending.each do |item|
      stdout.puts ''
      stdout.puts "  #{item.step}#{item.profile ? " (profile: #{item.profile})" : ''}  #{item.digest}"
      stdout.puts "    head: #{JSON.generate(item.fields)}"
      stdout.puts "    base: #{item.base_fields ? JSON.generate(item.base_fields) : 'new step'}"
    end
    stdout.puts ''
  end

  def confirmed?(sha, stdin:, stdout:, stderr:)
    stdout.print "Confirm: type the first 12 characters of #{sha} to approve every step listed above: "
    typed = stdin.gets.to_s.strip
    return true if typed == sha[0, 12]

    stderr.puts '[change] confirmation did not match; nothing recorded.'
    false
  end

  def full_sha(root, ref)
    out, status = Open3.capture2e('git', '-C', root, 'rev-parse', '--verify', '--quiet', "#{ref}^{commit}")
    status.success? && !out.strip.empty? ? out.strip : nil
  end

  def approver(root)
    out, status = Open3.capture2e('git', '-C', root, 'config', 'user.name')
    name = status.success? ? out.strip : ''
    name.empty? ? (ENV['USER'] || 'unknown') : name
  end

  def parse_args(argv, stderr)
    args = argv.dup
    root = nil
    OptionParser.new { |o| o.on('--repo PATH') { |value| root = value } }.parse!(args)
    sha = args.first
    if sha.to_s.empty?
      stderr.puts 'usage: change_approve.rb <sha> [--repo PATH]'
      return [ nil, nil ]
    end
    [ sha, File.expand_path(root || repo_root) ]
  end

  def repo_root
    out, status = Open3.capture2e('git', 'rev-parse', '--show-toplevel')
    status.success? ? out.strip : Dir.pwd
  end
end

exit(ChangeApprove.run(ARGV)) if __FILE__ == $PROGRAM_NAME
