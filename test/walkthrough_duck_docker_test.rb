# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../scripts/change_docker"
require_relative "../scripts/walkthrough_duck"

# The duck expression through the pinned FFmpeg image on a steady tone: the
# RMS envelope in 10 ms windows must reach the duck depth inside the span and
# never move more than STEP_DB between windows, where the old hard step jumped
# the whole depth at once.
class WalkthroughDuckDockerTest < Minitest::Test
  STEP_DB = 0.6
  SPANS = [ { start_ms: 1000, end_ms: 2000, db: -8 }, { start_ms: 2400, end_ms: 3000, db: -8 } ].freeze

  def setup
    skip "docker not available" unless ChangeDocker.available?
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def envelope(expr)
    filter = "asetnsamples=n=480,volume='#{expr}':eval=frame,astats=metadata=1:reset=1," \
             "ametadata=print:key=lavfi.astats.Overall.RMS_level:file=/work/rms.txt"
    args = [ "-hide_banner", "-v", "error", "-f", "lavfi", "-i", "sine=f=440:r=48000:d=4", "-af", filter, "-f", "null", "-" ]
    argv = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, args: args,
                                    mounts: { @dir => "/work" }, workdir: "/work")
    out, status = Open3.capture2e("timeout", "120", *argv)
    assert status.success?, out
    File.read(File.join(@dir, "rms.txt")).scan(/RMS_level=(-?[\d.]+)/).flatten.map(&:to_f)
  end

  def max_step(levels) = levels.each_cons(2).map { |a, b| (a - b).abs }.max

  def test_ramped_envelope_has_no_step
    levels = envelope(WalkthroughDuck.expression(SPANS, total_ms: 4000))
    top = levels[10..50].max
    assert_in_delta(-8.0, levels[150] - top, 0.2) # 1.5 s, inside the first span
    assert_in_delta(-8.0, levels[220] - top, 0.2) # 2.2 s, the merged gap stays down
    assert_operator max_step(levels), :<=, STEP_DB
  end

  def test_old_hard_step_would_fail
    hard = "if(between(t,1.000,2.000),0.3981,1)"
    assert_operator max_step(envelope(hard)), :>, 7.0
  end
end
