#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'optparse'
require_relative 'change_trust'
require_relative 'change_approval_store'
require_relative 'cf_project_identity'
require_relative 'approval_console/terminal_prompt'
require_relative 'approval_console/remote'
require_relative 'approval_console/proof_check'
require_relative 'approval_console/recorder'
require_relative 'approval_console/route'
require_relative 'change_policy'

# Human-run approval of host-run step definitions (boot.up, boot.down, command
# lane entries) that differ from the base branch at one exact commit. cf:change
# refuses to execute such a step until it is approved here, and the merge and
# tag guards refuse a gate record that ran one without approval.
#
# Usage: change_approve.rb <sha> [--repo PATH] [--remote]
#
# --remote sends the exact steps to the approval console instead: the phone
# shows every field, takes the TOTP code and the passkey, and the returned
# proof is checked by ApprovalConsole::Recorder (passkey level, authoritative
# pins, freshness) before it is recorded. --remote needs no TTY, so an agent
# can start it and post the link; only the phone approves. Without a console
# configured it falls back to the terminal path below at a real terminal, and
# is refused otherwise.
#
# It reads the definitions committed at <sha> and on the base branch with
# `git show` (nothing is checked out or executed), prints every step that
# differs in full beside its base version (or "new step"), and asks the
# operator to type the sha's first 12 characters. One confirmation approves
# every listed step for that sha. It never consults who authored the commit:
# the maintainer's own pull requests need the same approval.
#
# Without --remote it refuses without a real TTY on stdin, then, after the
# typed confirmation, requires a TOTP code from this machine's enrolled seed (approval_console.rb
# totp-enroll) read with echo off. The code is fenced to one use per 30 second
# step, and the record carries a `totp-terminal` proof bound to the exact
# steps shown. The typed prefix is not secret, so a process that allocates its
# own pty can still drive that part; the TOTP code is the second factor, and
# like the other guards here this is friction, not a sandbox. The intended use
# is a human reading the listed commands at their own terminal.
module ChangeApprove
  # One step awaiting approval, with the fields a human needs to judge it.
  Pending = Struct.new(:step, :digest, :fields, :base_fields, :profile, keyword_init: true)

  module_function

  def run(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, fetch: true, console: :default, authority: :default, io: {})
    sha_arg, root, remote = parse_args(argv, stderr)
    return 1 unless sha_arg

    unless remote || stdin.tty?
      stderr.puts '[change] refusing: this must be run from a real terminal, not scripted or piped (or use --remote).'
      return 1
    end

    sha = full_sha(root, sha_arg)
    unless sha
      stderr.puts "[change] #{sha_arg} is not a commit in #{root}"
      return 1
    end

    base = ChangeTrust.resolve_base(root, fetch: fetch)
    stderr.puts "[change] note: #{base.note}" if base.note
    pending = pending_steps(root, sha, base, stderr: stderr)
    if pending.empty?
      stdout.puts "[change] nothing to approve: every step at #{sha[0, 12]} matches #{base.ref} or is already approved."
      return 0
    end

    refusal = ApprovalConsole::TerminalPrompt.preflight('step')
    if refusal
      stderr.puts "[change] refusing: #{refusal}"
      return 1
    end

    describe(pending, sha, base, stdout)
    store = remote && ApprovalConsole::Route.store(root, authority: authority)
    return unenrolled(store, stderr) if store && store.unenrolled_reason
    client = remote && console_client(console, store, stdin, stderr)
    return 1 if remote && !client && !stdin.tty?
    return approve_remote(pending, root, sha, client, authority, store: store, stdout: stdout, stderr: stderr, **io) if client
    return 1 unless confirmed?(sha, stdin: stdin, stdout: stdout, stderr: stderr)

    proof = prove(pending, root, sha, stdin: stdin, stdout: stdout, stderr: stderr)
    return 1 unless proof

    ChangeApprovalStore.new(sha).record(steps: pending.map { |item| [ item.step, item.digest ] }, by: approver(root), proof: proof)
    approved(pending, sha, stdout)
  end

  def approved(pending, sha, stdout)
    stdout.puts "[change] approved #{pending.size} step(s) for #{sha[0, 12]}. A new commit or an edited step needs a new approval."
    0
  end

  # The phone path, runnable without a TTY: the authoritative policy is
  # resolved first (so a missing pin fails before the phone is asked), then
  # the receipt goes through ApprovalConsole::Recorder, the only writer.
  def approve_remote(pending, root, sha, client, authority, stdout:, stderr:, store: ApprovalConsole::LocalStore.new, **opts)
    authority = ApprovalConsole::Recorder.authority_for(root) if authority == :default
    attrs = attrs(pending, root, sha)
    proof = prove_remote(attrs, client, store, stdout: stdout, stderr: stderr, **opts)
    return 1 unless proof

    recorder = ApprovalConsole::Recorder.new(authority: authority, recorded_by: approver(root), clock: opts[:clock] || -> { Time.now })
    result = recorder.record(proof, expected: ApprovalConsole::Remote.expected(attrs, ApprovalConsole::LocalStore.new.machine_id))
    return approved(pending, sha, stdout) if result.ok?

    stderr.puts "[change] #{result.error}; nothing recorded."
    1
  rescue ChangePolicy::Unreadable => e
    stderr.puts "[change] refusing: cannot read the authoritative approval policy (#{e.message})."
    1
  end

  # The console client, or nil (with a note) when none is configured: a real
  # terminal falls back to the TOTP path, anything else is refused.
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

  def attrs(pending, root, sha)
    items = pending.map { |item| { 'step' => item.step, 'fields' => item.fields, 'base_fields' => item.base_fields } }
    { 'type' => 'step', 'repo' => CfProjectIdentity.for(root).id, 'sha' => sha, 'profile' => nil, 'items' => items }
  end

  # The console path: passkey plus TOTP on the phone, verified here.
  def prove_remote(attrs, client, store, stdout:, stderr:, **opts)
    result = ApprovalConsole::Remote.approve(attrs, store: store, client: client, out: stdout, **opts)
    return result.proof if result.ok?

    stderr.puts "[change] #{result.error}; nothing recorded."
    nil
  end

  # The TOTP second factor over the exact items just shown. Nil (with the
  # reason on stderr) when the code is refused; nothing is recorded then.
  def prove(pending, root, sha, stdin:, stdout:, stderr:)
    result = ApprovalConsole::TerminalPrompt.approve(attrs(pending, root, sha), stdin: stdin, stdout: stdout)
    return result.proof if result.ok?

    stderr.puts "[change] #{result.error}; nothing recorded."
    nil
  rescue ApprovalConsole::Canonical::Invalid => e
    stderr.puts "[change] cannot bind the approval: #{e.message}; nothing recorded."
    nil
  end

  # Every (step, digest) at `sha` that matches neither the base branch nor an
  # existing approval, for every app and every profile that app defines (or
  # its unprofiled config), since a profile may override boot and so define a
  # different step. In a monorepo the profiles live in each app's own config.
  def pending_steps(root, sha, base, stderr: $stderr)
    approvals = standing_approvals(root, sha)
    ChangeTrust.profiles_by_app(root, sha).flat_map do |app, profiles|
      profiles.flat_map do |profile|
        pending_for(root, sha, base, app: app, profile: profile, approvals: approvals, stderr: stderr)
      end
    end.uniq { |item| [ item.step, item.digest ] }
  end

  # The recorded (step, digest) pairs whose proof passes this repo's
  # require_approval_proof. A refused one is offered for approval again.
  def standing_approvals(root, sha)
    policy = ChangePolicy.for_repo(root)
    check = ApprovalConsole::ProofCheck.new(level: policy&.require_approval_proof, pins: policy&.approval_pins)
    repo = CfProjectIdentity.for(root).id
    ChangeApprovalStore.new(sha).entries.group_by { |entry| entry['proof'].is_a?(Hash) ? entry['proof']['body'] : entry.object_id }
                       .values.select { |group| check.approvals_problem(group, repo: repo, sha: sha).nil? }
                       .flatten.map { |entry| [ entry['step'].to_s, entry['digest'].to_s.delete_prefix('sha256:') ] }
  end

  def pending_for(root, sha, base, app:, profile:, approvals:, stderr:)
    apps = app ? [ app ] : nil
    head = ChangeTrust.snapshot_definitions(root, sha, profile: profile, apps: apps)
    unless head
      stderr.puts "[change] could not load #{app || 'CHANGE.md'} at #{sha[0, 12]} (profile: #{profile || 'none'}); fix it first"
      return []
    end
    base_defs = (base.sha && ChangeTrust.snapshot_definitions(root, base.sha, profile: profile, apps: apps)) || {}
    head.filter_map do |step, fields|
      digest = ChangeTrust.digest(fields)
      next if base_defs[step] && ChangeTrust.base_match?(ChangeTrust.digest(base_defs[step]), digest)
      next if approvals.include?([ step, digest ])

      Pending.new(step: step, digest: digest, fields: fields, base_fields: base_defs[step], profile: profile)
    end
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
    prefix = sha[0, 12]
    stdout.puts "To approve every step listed above for #{sha}, type these 12 characters exactly:"
    stdout.puts "type: #{prefix}"
    stdout.print '> '
    typed = stdin.gets.to_s.strip
    return true if typed == prefix

    stderr.puts "[change] confirmation did not match (expected #{prefix}, got #{typed.empty? ? 'nothing' : typed}); nothing recorded."
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
    remote = false
    OptionParser.new do |o|
      o.on('--repo PATH') { |value| root = value }
      o.on('--remote') { remote = true }
    end.parse!(args)
    sha = args.first
    if sha.to_s.empty?
      stderr.puts 'usage: change_approve.rb <sha> [--repo PATH] [--remote]'
      return [ nil, nil, false ]
    end
    [ sha, File.expand_path(root || repo_root), remote ]
  end

  def repo_root
    out, status = Open3.capture2e('git', 'rev-parse', '--show-toplevel')
    status.success? ? out.strip : Dir.pwd
  end
end

exit(ChangeApprove.run(ARGV)) if __FILE__ == $PROGRAM_NAME
