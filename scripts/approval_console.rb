#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require_relative 'approval_console/host_health'
require_relative 'approval_console/local_store'
require_relative 'approval_console/totp'

# The approval console CLI. This phase carries the terminal TOTP path:
#
#   totp-enroll  generate this machine's seed and show it once on /dev/tty
#   status       enrollment, fence, lockout, sync queue and host health
#   unlock       refused: a terminal-only install has no manual unlock
#
# `totp-enroll` and `unlock` refuse without a real TTY and inside an agent
# harness. `status` is read-only and never prints the seed, so agents may run
# it. As elsewhere in this repo the guards are friction, not a sandbox.
module ApprovalConsoleCli
  AGENT_ENV = %w[CLAUDECODE CLAUDE_CODE_ENTRYPOINT CODEX_SANDBOX OPENCODE PI_AGENT].freeze
  AGENT_PROCESS = /claude|codex|opencode|pi-agent/i
  ALT_ON = "\e[?1049h"
  ALT_OFF = "\e[?1049l"

  module_function

  def run(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, env: ENV, store: nil, tty_open: method(:open_tty),
          parents: method(:parent_names), now: Time.now)
    store ||= ApprovalConsole::LocalStore.new
    case argv.first
    when 'totp-enroll' then totp_enroll(store, stdin, stderr, env, tty_open, parents)
    when 'status' then status(store, stdout, now)
    when 'unlock' then unlock(store, stdin, stderr, env, parents)
    else usage(stderr)
    end
  end

  def usage(stderr)
    stderr.puts 'usage: approval_console.rb totp-enroll | status | unlock'
    1
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
    stdout.puts "console: #{info[:console_configured] ? 'configured' : 'not configured (terminal only)'}"
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

exit(ApprovalConsoleCli.run(ARGV)) if __FILE__ == $PROGRAM_NAME
