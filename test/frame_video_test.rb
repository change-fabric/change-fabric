# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "tmpdir"
require_relative "../scripts/frame_video"

# FrameVideo: the JPEG sequence a sampler's ticks resolve to, and the pinned,
# network-less FFmpeg encode that turns it into an mp4.
class FrameVideoTest < Minitest::Test
  Status = Struct.new(:ok) do
    def success? = ok
  end

  FRAMES = %w[a b c].map { |s| Base64.strict_encode64(s) }.freeze

  def test_write_jpgs_numbers_one_file_per_tick_and_resolves_indices
    Dir.mktmpdir do |dir|
      assert_equal 4, FrameVideo.write_jpgs(dir, FRAMES, [ 0, 2, 2, 1 ])
      assert_equal %w[000001.jpg 000002.jpg 000003.jpg 000004.jpg], Dir.children(dir).sort
      assert_equal %w[a c c b], (1..4).map { |i| File.binread(File.join(dir, format("%06d.jpg", i))) }
    end
  end

  def test_write_jpgs_reads_frame_zero_for_a_tick_before_the_first_frame
    Dir.mktmpdir do |dir|
      FrameVideo.write_jpgs(dir, FRAMES, [ -1 ])
      assert_equal "a", File.binread(File.join(dir, "000001.jpg"))
    end
  end

  def test_write_jpgs_with_empty_ticks_writes_nothing
    Dir.mktmpdir do |dir|
      assert_equal 0, FrameVideo.write_jpgs(dir, [], [])
      assert_equal 0, FrameVideo.write_jpgs(dir, nil, nil)
      assert_empty Dir.children(dir)
    end
  end

  def test_encode_argv_runs_the_pinned_image_with_no_network
    argv = FrameVideo.encode_argv("/tmp/frames", fps: 6, crf: 23)
    assert_equal %w[docker run --rm], argv.first(3)
    assert_equal "none", argv[argv.index("--network") + 1]
    assert_includes argv, "type=bind,\"source=/tmp/frames\",target=/work"
    image = argv.index(ChangeDocker::FFMPEG_IMAGE)
    assert image, "pinned FFmpeg image"
    args = argv[(image + 1)..]
    assert_equal "6", args[args.index("-framerate") + 1]
    assert_equal "6", args[args.index("-r") + 1]
    assert_equal "23", args[args.index("-crf") + 1]
    assert_equal "libx264", args[args.index("-c:v") + 1]
    assert_equal "yuv420p", args[args.index("-pix_fmt") + 1]
    assert_equal "+faststart", args[args.index("-movflags") + 1]
    assert_equal "/work/out.mp4", args.last
  end

  def test_encode_defaults_crf_to_18
    args = FrameVideo.encode_argv("/tmp/frames", fps: 30)
    assert_equal "18", args[args.index("-crf") + 1]
  end

  def test_encode_moves_the_output_into_place
    Dir.mktmpdir do |dir|
      frames = File.join(dir, "jpg")
      FrameVideo.write_jpgs(frames, FRAMES, [ 0 ])
      seen = nil
      runner = lambda do |argv|
        seen = argv
        File.write(File.join(frames, "out.mp4"), "mp4")
        [ "", Status.new(true) ]
      end
      out = File.join(dir, "video", "mobile.mp4")
      assert_equal out, FrameVideo.encode(frames, fps: 6, out: out, runner: runner)
      assert_equal "mp4", File.read(out)
      assert_equal "docker", seen.first
    end
  end

  def test_encode_raises_on_empty_dir_without_running_docker
    Dir.mktmpdir do |dir|
      runner = ->(_argv) { flunk "docker must not run" }
      assert_raises(FrameVideo::EncodeError) { FrameVideo.encode(dir, fps: 6, out: File.join(dir, "x.mp4"), runner: runner) }
    end
  end

  def test_encode_raises_when_ffmpeg_fails
    Dir.mktmpdir do |dir|
      FrameVideo.write_jpgs(dir, FRAMES, [ 0 ])
      runner = ->(_argv) { [ "boom", Status.new(false) ] }
      err = assert_raises(FrameVideo::EncodeError) { FrameVideo.encode(dir, fps: 6, out: File.join(dir, "x.mp4"), runner: runner) }
      assert_match(/boom/, err.message)
    end
  end

  def test_encode_argv_fits_frames_to_an_even_size_only_when_given_one
    refute_includes FrameVideo.encode_argv("/tmp/frames", fps: 6), "-vf"
    args = FrameVideo.encode_argv("/tmp/frames", fps: 6, size: [ 390, 293 ])
    assert_match(/\Ascale=390:292:force_original_aspect_ratio=decrease,pad=390:292:/, args[args.index("-vf") + 1])
  end

  # A stray frame of another size (one Chromium painted before setViewport
  # took effect) used to set the whole video's size: the encode used the
  # first frame's. The dominant size wins, and an odd stray height no longer
  # fails libx264.
  def test_real_encode_with_a_stray_odd_sized_first_frame_keeps_the_walk_size
    skip "docker not available" unless ChangeDocker.available?

    Dir.mktmpdir do |dir|
      src = File.join(dir, "src")
      FileUtils.mkdir_p(src)
      frames = { "a.jpg" => "390x293", "b.jpg" => "390x844" }.map do |name, size|
        make = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, mounts: { src => "/work" },
                                        args: [ "-v", "error", "-f", "lavfi", "-i", "color=c=red:s=#{size}:d=1", "-frames:v", "1",
                                                "/work/#{name}" ])
        _out, status = Open3.capture2e(*make)
        skip "could not make sample frames" unless status.success?
        Base64.strict_encode64(File.binread(File.join(src, name)))
      end
      jpg = File.join(dir, "jpg")
      FrameVideo.write_jpgs(jpg, frames, [ 0, 1, 1, 1 ])
      assert_equal [ 390, 844 ], FrameVideo.dominant_size(jpg)
      out = File.join(dir, "v.mp4")
      FrameVideo.encode(jpg, fps: 6, out: out)
      probe = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, mounts: { dir => "/w" },
                                       args: [ "-v", "error", "-i", "/w/v.mp4", "-f", "null", "-" ])
      _o, ok = Open3.capture2e(*probe)
      assert ok.success?
      assert_equal [ 390, 844 ], mp4_size(dir)
    end
  end

  # Real encode in the pinned image: a few solid JPEGs made by FFmpeg itself.
  def test_real_encode_in_pinned_image
    skip "docker not available" unless ChangeDocker.available?

    Dir.mktmpdir do |dir|
      src = File.join(dir, "src")
      FileUtils.mkdir_p(src)
      make = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, mounts: { src => "/work" },
                                      args: [ "-v", "error", "-f", "lavfi", "-i", "color=c=red:s=64x48:d=1", "-frames:v", "2",
                                              "/work/f%d.jpg" ])
      _out, status = Open3.capture2e(*make)
      skip "could not make sample frames" unless status.success?
      frames = %w[f1.jpg f2.jpg].map { |f| Base64.strict_encode64(File.binread(File.join(src, f))) }
      jpg = File.join(dir, "jpg")
      FrameVideo.write_jpgs(jpg, frames, [ 0, 1, 1, 0, 1, 0 ])
      out = File.join(dir, "v.mp4")
      FrameVideo.encode(jpg, fps: 6, out: out)
      assert File.size(out).positive?
      check = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, mounts: { dir => "/w" },
                                       args: [ "-v", "error", "-i", "/w/v.mp4", "-f", "null", "-" ])
      _o, ok = Open3.capture2e(*check)
      assert ok.success?
    end
  end
  private

  def mp4_size(dir)
    grab = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, mounts: { dir => "/w" },
                                    args: [ "-v", "error", "-i", "/w/v.mp4", "-frames:v", "1", "/w/first.jpg" ])
    Open3.capture2e(*grab)
    FrameVideo.jpeg_size(File.join(dir, "first.jpg"))
  end
end
