# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../scripts/change_docker"
require_relative "../scripts/ffmpeg_square"
require_relative "../scripts/walkthrough_ffmpeg"
require_relative "support/png_fixture"

# Frames that carry pHYs pixel-aspect metadata, run through the pinned
# FFmpeg image. A scale to a slightly different aspect is what writes a
# non-square pHYs into a composited PNG, and a frame carrying one breaks
# the final concat; FfmpegSquare normalizes both ends.
class FfmpegSquareDockerTest < Minitest::Test
  PHYS = [ 7839, 7807 ].freeze

  def setup
    skip "docker not available" unless ChangeDocker.available?
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def ffmpeg(*args)
    argv = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, args: [ "-hide_banner", "-nostdin", "-y", *args ],
                                    mounts: { @dir => "/work" }, workdir: "/work")
    Open3.capture2e(*argv)
  end

  def frames(name, phys: nil)
    FileUtils.mkdir_p(File.join(@dir, name))
    3.times { |i| File.binwrite(File.join(@dir, name, format("%06d.png", i + 1)), PngFixture.png(64, 36, phys: phys)) }
    [ "-framerate", "30", "-i", "/work/#{name}/%06d.png" ]
  end

  def concat(chain_a, chain_b)
    ffmpeg(*frames("a", phys: PHYS), *frames("b"),
           "-filter_complex", "[0:v]#{chain_a}[x];[1:v]#{chain_b}[y];[x][y]concat=n=2:v=1:a=0[out]",
           "-map", "[out]", "-f", "null", "-")
  end

  def test_a_non_square_phys_frame_breaks_concat_unless_normalized
    out, status = concat("scale=64:36:flags=lanczos", "scale=64:36:flags=lanczos")
    refute status.success?, "the pHYs aspect reaches the filter graph as a mismatched SAR"
    assert_match(/do not match|SAR/i, out)

    out, status = concat(FfmpegSquare.scale(64, 36), FfmpegSquare.scale(64, 36))
    assert status.success?, out.lines.last(10).join
  end

  def test_the_assembly_scene_chain_normalizes_the_sample_aspect
    plan = { width: 64, height: 36, fps: 30, scenes: [ { id: "a", cursor: [] }, { id: "b", cursor: [] } ] }
    chain = ->(i) { WalkthroughFfmpeg.scene_chain(plan, plan[:scenes][i], i).first[/\A\[\d:v\](.*)\[s\d\]\z/, 1] }
    out, status = concat(chain.call(0), chain.call(1))
    assert status.success?, out.lines.last(10).join
  end

  def test_a_squared_composite_writes_no_non_square_phys
    frames("in")
    _, status = ffmpeg("-i", "/work/in/000001.png", "-vf", "scale=63:36:flags=lanczos", "/work/raw.png")
    assert status.success?
    raw = PngFixture.phys(File.binread(File.join(@dir, "raw.png")))
    refute_nil raw, "an aspect-changing scale stamps a pHYs"
    refute_equal raw[0], raw[1]

    out, status = ffmpeg("-i", "/work/in/000001.png", "-vf", FfmpegSquare.scale(63, 36), "/work/square.png")
    assert status.success?, out
    square = PngFixture.phys(File.binread(File.join(@dir, "square.png")))
    assert(square.nil? || square[0] == square[1], "pHYs #{square.inspect} is not square")
  end
end
