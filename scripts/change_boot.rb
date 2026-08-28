#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'

# The target app's lifecycle: bring it up, wait for its own health signal, tear
# it down. Lifted out of ChangeRun verbatim so cf:screenshot, which boots the
# same app twice at two different git refs, drives it through exactly this code
# rather than a second health poller that can drift from it. A divergent poller
# is the kind of drift ChangeLane already exists to prevent, and here it would
# be worse than cosmetic: a before/after tool that mis-decides "the app is up"
# photographs the wrong ref.
#
# The includer supplies four things: `repo_root` (the default working directory
# for a boot command), `log(message)`, and `abort_and_exit(message)`. Everything
# else is here.
#
# `chdir:` is the one thing this module adds over what ChangeRun had inline. It
# defaults to `repo_root`, which is what every existing caller passes
# implicitly, and exists so a base-ref boot can run inside an ephemeral git
# worktree instead. Booting the base ref from the main working tree would boot
# HEAD's code and produce a same-ref-twice diff presented as a real one.
module ChangeBoot
  # A bounded tail of captured subprocess output, so a noisy build log stays
  # readable while the line that actually explains the failure is still there.
  OUTPUT_TAIL_LINES = 40

  def boot_up(boot, chdir: repo_root)
    return unless boot.up?

    log("[change] booting: #{boot.up}")
    out, status = Open3.capture2e(boot_env(boot), boot.up, chdir: chdir)
    return if status.success?

    abort_and_exit("boot command failed: #{boot.up}\n--- boot output (last #{OUTPUT_TAIL_LINES} lines) ---\n#{tail(out)}")
  end

  # Parses each configured boot.env_file (simple KEY=VALUE lines, no shell
  # `source`, so no secret is ever echoed) and merges them into the inherited
  # process environment, later files winning over earlier ones. This is the
  # shell-level equivalent of `set -a; source .env.local; set +a`: it makes a
  # compose `build.args:` entry's `${VAR}` interpolation resolve without the
  # author having to pre-export anything. Fails fast, by name, when a declared
  # file is missing.
  def boot_env(boot)
    files = boot.env_files
    return {} if files.empty?

    files.each_with_object({}) do |path, merged|
      abort_and_exit("boot.env_file not found: #{path}") unless File.exist?(path)

      merged.merge!(parse_env_file(path))
    end
  end

  def parse_env_file(path)
    File.readlines(path).each_with_object({}) do |line, env|
      stripped = line.strip
      next if stripped.empty? || stripped.start_with?('#')

      key, value = stripped.delete_prefix('export ').split('=', 2)
      next unless key && value

      env[key.strip] = value.strip.gsub(/\A['"]|['"]\z/, '')
    end
  end

  def boot_down(boot, chdir: repo_root)
    return if boot.down.empty?

    log("[change] tearing down: #{boot.down}")
    out, status = Open3.capture2e(boot.down, chdir: chdir)
    log("[change] teardown command failed: #{boot.down}\n--- teardown output (last #{OUTPUT_TAIL_LINES} lines) ---\n#{tail(out)}") unless status.success?
  end

  # Polls the health url from the host until it returns the expected status or
  # the timeout elapses. A run with no health url skips straight through, trusting
  # the boot command to have blocked until ready. Carries the last poll's own
  # curl output into the timeout message, so "never became healthy" names the
  # actual response (a connection refused, a wrong status, a TLS failure)
  # instead of leaving the cause to be re-discovered by hand.
  def wait_healthy(boot)
    return if boot.health_url.empty?

    deadline = Time.now + boot.health_timeout
    last_out = nil
    loop do
      ok, last_out = healthy?(boot)
      return if ok

      if Time.now > deadline
        abort_and_exit("app never became healthy at #{boot.health_url}\n--- last health check output ---\n#{tail(last_out)}")
      end
      sleep 2
    end
  end

  # The health poll goes through curl, not Net::HTTP, on purpose. Local dev
  # stacks are commonly fronted by a local CA (a Caddy dev cert), which the OS
  # keychain trusts but Ruby's OpenSSL does not by default, so Net::HTTP raises
  # "certificate verify failed" against a URL a browser and curl both accept.
  # curl trusts the system trust store (and honors SSL_CERT_FILE/SSL_CERT_DIR
  # when set), so the check works against a local-CA https health url with no
  # extra configuration. A short per-attempt timeout keeps the outer deadline
  # loop responsive.
  # Returns [ok?, output] so a caller giving up on the timeout can carry the
  # last attempt's own diagnostic into its own message.
  def healthy?(boot)
    out, status = Open3.capture2e(
      'curl', '-sS', '-o', '/dev/null', '-w', '%{http_code}', '--max-time', '5', boot.health_url
    )
    [ status.success? && out.strip.to_i == boot.health_status, out ]
  rescue StandardError => e
    [ false, e.message ]
  end

  def tail(out)
    out.to_s.lines.last(OUTPUT_TAIL_LINES).join
  end
end
