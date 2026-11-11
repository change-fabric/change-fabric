#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs one host-side step (boot.up, boot.down, a command lane entry) through
# /bin/sh -c in its own process group, with exactly the environment it is
# given (`unsetenv_others`), stdout and stderr merged into one captured
# transcript. A timeout kills the whole group: TERM first, then KILL after a
# grace period, so a step that started children does not leave them running
# past the deadline. A grandchild that called setsid has left the group and is
# out of reach; that is documented, not handled.
#
# A step that exits normally is never killed: boot.up legitimately leaves a
# server running in the background. If such a background child still holds the
# output pipe, reading stops shortly after the step itself exits instead of
# waiting for the server to close it.
module ChangeProcess
  Result = Struct.new(:status, :exit_code, :output, :timed_out, :duration, keyword_init: true) do
    def success? = status == :pass
  end

  KILL_GRACE_SECONDS = 10
  READ_DRAIN_SECONDS = 2

  module_function

  def run(cmd, env:, chdir:, timeout: nil, grace: KILL_GRACE_SECONDS)
    reader, writer = IO.pipe
    started = now
    pid = Process.spawn(env, '/bin/sh', '-c', cmd.to_s, unsetenv_others: true, chdir: chdir, pgroup: true,
                                                         in: File::NULL, out: writer, err: writer)
    writer.close
    output = +''
    drain = Thread.new { copy(reader, output) }
    status, timed_out = wait(pid, timeout, grace)
    drain.join(READ_DRAIN_SECONDS)
    drain.kill if drain.alive?
    reader.close unless reader.closed?
    build_result(status, timed_out, output, now - started)
  end

  def build_result(status, timed_out, output, duration)
    code = status&.exitstatus
    passed = !timed_out && status&.success?
    Result.new(status: passed ? :pass : :fail, exit_code: code, output: output, timed_out: timed_out,
               duration: duration.round(1))
  end

  def copy(reader, output)
    while (chunk = reader.readpartial(65_536))
      output << chunk
    end
  rescue EOFError, IOError
    nil
  end

  def wait(pid, timeout, grace)
    return [ Process.wait2(pid).last, false ] unless timeout

    deadline = now + timeout
    loop do
      _done, status = Process.wait2(pid, Process::WNOHANG)
      return [ status, false ] if status
      break if now >= deadline

      sleep 0.1
    end
    [ kill_group(pid, grace), true ]
  end

  def kill_group(pid, grace)
    signal_group('TERM', pid)
    deadline = now + grace
    while now < deadline
      _done, status = Process.wait2(pid, Process::WNOHANG)
      if status
        signal_group('KILL', pid)
        return status
      end
      sleep 0.1
    end
    signal_group('KILL', pid)
    Process.wait2(pid).last
  rescue Errno::ECHILD
    nil
  end

  def signal_group(signal, pid)
    Process.kill(signal, -pid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
