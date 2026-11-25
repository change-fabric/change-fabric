# frozen_string_literal: true

require 'open3'

module ScheduledLane
  # Runs one repo-declared command through /bin/sh -c in its own process group,
  # stdout and stderr captured apart (adapters print data on stdout), optional
  # stdin, optional timeout. A timeout kills the whole group, TERM then KILL.
  # Never raises for a failed command: spawn problems come back as `error`, so
  # the caller classifies them as infra rather than crashing mid-matrix.
  #
  # An exception raised into the calling thread while a command runs (the
  # matrix driver's signal handler does this) kills the child group before it
  # propagates, so an interrupted lane does not outlive its parent.
  class CommandRunner
    Outcome = Struct.new(:stdout, :stderr, :exit_code, :timed_out, :error, keyword_init: true) do
      def ok? = error.nil? && !timed_out && exit_code&.zero? == true
      def summary = error || (timed_out ? 'timed out' : "exit #{exit_code.inspect}: #{stderr.to_s.strip[0, 300]}")
    end

    KILL_GRACE_SECONDS = 5

    def initialize(chdir: Dir.pwd, env: {})
      @chdir = chdir
      @base_env = env
    end

    # `env` entries with a nil value are removed from the child environment.
    def call(cmd, env: {}, stdin: nil, timeout: nil)
      merged = ENV.to_h.merge(@base_env.transform_keys(&:to_s)).merge(env.transform_keys(&:to_s))
      Open3.popen3(merged.compact, '/bin/sh', '-c', cmd.to_s, chdir: @chdir, pgroup: true) do |input, out, err, wait|
        run_child(input, out, err, wait, stdin, timeout)
      end
    rescue SystemCallError => e
      Outcome.new(stdout: '', stderr: '', exit_code: nil, timed_out: false, error: "spawn failed: #{e.message}")
    end

    private

    def run_child(input, out, err, wait, stdin, timeout)
      readers = [ Thread.new { out.read }, Thread.new { err.read } ]
      write_stdin(input, stdin)
      finished = wait.join(timeout)
      timed_out = finished.nil?
      kill_group(wait.pid, wait) if timed_out
      Outcome.new(stdout: readers[0].value.to_s, stderr: readers[1].value.to_s,
                  exit_code: timed_out ? nil : wait.value.exitstatus, timed_out: timed_out, error: nil)
    rescue Exception # rubocop:disable Lint/RescueException
      kill_group(wait.pid, wait)
      raise
    end

    def write_stdin(input, stdin)
      input.write(stdin) if stdin
    rescue Errno::EPIPE
      nil
    ensure
      input.close unless input.closed?
    end

    def kill_group(pid, wait)
      signal('TERM', pid)
      return if wait.join(KILL_GRACE_SECONDS)

      signal('KILL', pid)
      wait.join(KILL_GRACE_SECONDS)
    end

    def signal(name, pid)
      Process.kill(name, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
end
