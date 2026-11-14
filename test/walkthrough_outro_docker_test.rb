# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../scripts/change_docker"
require_relative "../scripts/walkthrough_ffmpeg"

# The render-time music outro through the pinned FFmpeg image: a steady tone
# bed run through the music entry filters must sit at least 15 dB below its
# mid-bed level over the last 0.5 s (a linear 2.5 s fade lands near -19 dB).
class WalkthroughOutroDockerTest < Minitest::Test
  TOTAL_MS = 6000

  def setup
    skip "docker not available" unless ChangeDocker.available?
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def rms(from, to)
    entry = WalkthroughFfmpeg.music_entry({}, TOTAL_MS)
    filter = "#{entry}atrim=start=#{from}:end=#{to},astats=metadata=1:reset=0," \
             "ametadata=print:key=lavfi.astats.Overall.RMS_level:file=/work/rms.txt"
    args = [ "-hide_banner", "-v", "error", "-f", "lavfi", "-i", "sine=f=440:r=48000:d=6", "-af", filter, "-f", "null", "-" ]
    argv = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, args: args,
                                    mounts: { @dir => "/work" }, workdir: "/work")
    out, status = Open3.capture2e("timeout", "120", *argv)
    assert status.success?, out
    File.read(File.join(@dir, "rms.txt")).scan(/RMS_level=(-?[\d.]+|-inf)/).flatten.last.to_f
  end

  def test_last_half_second_is_far_below_mid_bed
    mid = rms(1.5, 2.5)
    tail = rms(5.5, 6.0)
    assert_operator mid - tail, :>, 15.0, "mid #{mid} dB, tail #{tail} dB"
  end
end
