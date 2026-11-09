# frozen_string_literal: true

require "minitest/autorun"
require "rbconfig"
require_relative "../scripts/ffmpeg_watchdog"

class FfmpegWatchdogTest < Minitest::Test
  RUBY = RbConfig.ruby

  # A stand-in for ffmpeg -progress: prints out_time_us every few ms.
  def progress(step_s, stop_after: nil)
    [ RUBY, "-e", <<~RUBY ]
      $stdout.sync = true
      t = 0.0
      loop do
        t += #{step_s}
        puts "frame=1", "out_time_us=\#{(t * 1_000_000).to_i}", "progress=continue"
        exit 0 if #{stop_after.inspect} && t >= #{stop_after.inspect}
        sleep 0.005
      end
    RUBY
  end

  def test_out_time_parses_progress_lines
    assert_in_delta 1.5, FfmpegWatchdog.out_time("out_time_us=1500000\n")
    assert_in_delta 2.0, FfmpegWatchdog.out_time("out_time_ms=2000000")
    assert_nil FfmpegWatchdog.out_time("out_time=00:00:01.500000")
    assert_nil FfmpegWatchdog.out_time("frame=12")
  end

  def test_a_bounded_run_returns_output_and_status
    out, status = FfmpegWatchdog.run(progress(1.0, stop_after: 5), limit_s: 10)
    assert status.success?
    assert_includes out, "out_time_us=5000000"
  end

  def test_a_runaway_is_killed_with_a_clear_error
    killed = false
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    err = assert_raises(FfmpegWatchdog::RunawayError) do
      FfmpegWatchdog.run(progress(1.0), limit_s: 10, kill: -> { killed = true }, label: "pass 2")
    end
    assert killed, "the kill hook (docker kill) runs"
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, :<, 5
    assert_match(/pass 2 ran away: output time 11\.0s passed the 10\.0s limit/, err.message)
  end
end
