# frozen_string_literal: true

require 'open3'

module Triage
  # Runs one external command with a hard timeout and kills it on expiry. The
  # only place triage shells out, so every caller can inject a stub with the
  # same call shape: `runner.call(argv, timeout)` returning a Result.
  module Command
    Result = Struct.new(:out, :err, :ok, :timed_out, keyword_init: true)

    def self.run(argv, timeout)
      Open3.popen3(*argv) do |stdin, stdout, stderr, thread|
        stdin.close
        readers = [ Thread.new { stdout.read }, Thread.new { stderr.read } ]
        if thread.join(timeout)
          Result.new(out: readers[0].value, err: readers[1].value, ok: thread.value.success?, timed_out: false)
        else
          kill(thread.pid)
          readers.each(&:kill)
          Result.new(out: '', err: "timed out after #{timeout}s", ok: false, timed_out: true)
        end
      end
    rescue SystemCallError => e
      Result.new(out: '', err: e.message, ok: false, timed_out: false)
    end

    def self.kill(pid)
      Process.kill('KILL', pid)
    rescue SystemCallError
      nil
    end
  end
end
