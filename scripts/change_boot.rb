#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require_relative 'change_env'
require_relative 'change_process'

# The target app's lifecycle: bring it up, wait for its own health signal, tear
# it down. Lifted out of ChangeRun verbatim so cf:screenshot, which boots the
# same app twice at two different git refs, drives it through exactly this code
# rather than a second health poller that can drift from it. A divergent poller
# is the kind of drift ChangeLane already exists to prevent, and here it would
# be worse than cosmetic: a before/after tool that mis-decides "the app is up"
# photographs the wrong ref.
#
# The includer supplies `repo_root` (the default working directory for a boot
# command), `log(message)`, `abort_and_exit(message)`, and `boot_run_id` (the
# CF_CHANGE_RUN_ID a boot step sees). It may override `boot_runner` (default
# ChangeProcess) so a test never spawns a real shell. Everything else is here.
#
# 0.17.0: boot.up and boot.down run only when trusted (ChangeTrust: the
# definition equals the base branch's, or a human approved it for this
# commit), with the minimal environment ChangeEnv builds (PATH, HOME,
# DOCKER_HOST, TERM, the CF_CHANGE_* values, and the names boot.env declares),
# under boot.timeout_seconds when set. The caller passes its trust verdict in
# as `trust:`, so cf:change and cf:screenshot decide trust the same way.
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

  # `prefix` names the app in a monorepo ("portal/"), matching the step names
  # ChangeTrust.step_definitions produced.
  def boot_up(boot, trust:, chdir: repo_root, prefix: '')
    return unless boot.up?

    step = "#{prefix}boot.up"
    abort_and_exit(trust.refusal(step)) unless trust.trusted?(step)
    env = boot_step_env(boot, chdir: chdir) { |message| abort_and_exit(message) }
    log("[change] booting: #{boot.up}")
    result = boot_runner.run(boot.up, env: env.env, chdir: chdir, timeout: boot.timeout_seconds)
    return if result.success?

    abort_and_exit("#{failure_reason(result, boot, 'boot command failed')}: #{boot.up}\n" \
                   "--- boot output (last #{OUTPUT_TAIL_LINES} lines) ---\n#{tail(env.masker.call(result.output))}")
  end

  # Teardown is best effort: an untrusted step, a missing variable, or a
  # failure is logged, never raised, so it cannot hide the run's own outcome.
  def boot_down(boot, trust:, chdir: repo_root, prefix: '')
    return if boot.down.empty?

    step = "#{prefix}boot.down"
    return log("[change] #{trust.refusal(step)}") unless trust.trusted?(step)

    env = boot_step_env(boot, chdir: chdir) { |message| return log("[change] teardown skipped: #{message}") }
    log("[change] tearing down: #{boot.down}")
    result = boot_runner.run(boot.down, env: env.env, chdir: chdir, timeout: boot.timeout_seconds)
    return if result.success?

    log("[change] #{failure_reason(result, boot, 'teardown command failed')}: #{boot.down}\n" \
        "--- teardown output (last #{OUTPUT_TAIL_LINES} lines) ---\n#{tail(env.masker.call(result.output))}")
  end

  # The environment a boot step runs with. A missing env file or missing
  # declared variables are yielded to the caller's block as a message, and the
  # caller decides whether that aborts (boot.up) or only logs (boot.down).
  def boot_step_env(boot, chdir:)
    values = boot_env(boot, chdir: chdir) { |message| return yield(message) }
    ChangeEnv.build(declared: boot.env_names, env_file_values: values, extra: boot_extra_env(boot))
  rescue ChangeEnv::MissingVariables => e
    yield("boot.env declares variables that are not set: #{e.names.join(', ')} " \
          '(set them in the environment or in boot.env_file)')
  end

  def boot_extra_env(boot)
    {
      'CF_CHANGE_RUN_ID' => boot_run_id, 'CF_CHANGE_TARGET_URL' => boot.target_url,
      'CF_CHANGE_HEALTH_URL' => boot.health_url
    }
  end

  def failure_reason(result, boot, default)
    result.timed_out ? "timed out after #{boot.timeout_seconds}s; process group killed" : default
  end

  def boot_runner = ChangeProcess

  # Parses each configured boot.env_file (simple KEY=VALUE lines, no shell
  # `source`, so no secret is ever echoed), later files winning over earlier
  # ones. Since 0.17.0 these are value sources only: a key reaches a boot step
  # only when boot.env declares its name. A relative path resolves against
  # `chdir`, so a base-ref boot in a worktree reads the worktree's own file. A
  # missing file is yielded by name to the caller's block.
  def boot_env(boot, chdir: repo_root)
    boot.env_file_entries.each_with_object({}) do |entry, merged|
      path = File.expand_path(entry, chdir)
      return yield("boot.env_file not found: #{path}") unless File.exist?(path)

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
