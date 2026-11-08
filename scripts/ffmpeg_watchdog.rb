# frozen_string_literal: true

require 'open3'

# Runs an ffmpeg command that writes `-progress pipe:1` and stops it once its
# output clock passes a limit. A filter graph with an unbounded branch, or an
# input whose timestamps go backwards, can keep the encoder emitting audio
# long after the video ended until memory runs out; a capture2e-style wait
# would hang on that forever. `kill` stops the real process (for a docker run,
# a `docker kill` of its named container); the client process is killed too.
module FfmpegWatchdog
  class RunawayError < StandardError; end

  module_function

  # Returns [output, status] like Open3.capture2e, or raises RunawayError.
  def run(argv, limit_s:, kill: nil, label: 'ffmpeg')
    out = +''
    Open3.popen2e(*argv) do |stdin, io, thr|
      stdin.close
      io.each_line do |line|
        out << line
        time = out_time(line)
        next unless time && time > limit_s

        stop(thr, kill)
        raise RunawayError, format('%<l>s ran away: output time %<t>.1fs passed the %<m>.1fs limit; killed it. ' \
                                   "Last output:\n%<o>s", l: label, t: time, m: limit_s, o: out.lines.last(20).join)
      end
      [ out, thr.value ]
    end
  end

  # Seconds from a `-progress` line (out_time_us, or out_time_ms which ffmpeg
  # also reports in microseconds); nil for any other line.
  def out_time(line)
    us = line[/\Aout_time_(?:us|ms)=(\d+)/, 1]
    us && (us.to_i / 1_000_000.0)
  end

  def stop(thr, kill)
    kill&.call
    Process.kill('KILL', thr.pid)
  rescue Errno::ESRCH
    nil
  ensure
    thr.join(10)
  end
end
