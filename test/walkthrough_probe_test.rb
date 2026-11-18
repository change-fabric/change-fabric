# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require_relative "../scripts/walkthrough_probe"

# walkthrough_probe.rb reports a draft's duration, frame count, and streams
# by running ffprobe inside the already-pinned FFmpeg image.
class WalkthroughProbeTest < Minitest::Test
  P = WalkthroughProbe
  SCRIPT = File.expand_path("../scripts/walkthrough_probe.rb", __dir__)

  PROBE = {
    "streams" => [
      { "index" => 0, "codec_type" => "video", "codec_name" => "h264", "width" => 1920, "height" => 1080,
        "avg_frame_rate" => "30/1", "nb_frames" => "1240", "nb_read_packets" => "1240", "duration" => "41.333333" },
      { "index" => 1, "codec_type" => "audio", "codec_name" => "aac", "sample_rate" => "48000", "channels" => 2,
        "duration" => "41.330000" },
      { "index" => 2, "codec_type" => "subtitle", "codec_name" => "mov_text" }
    ],
    "format" => { "duration" => "41.333333", "format_name" => "mov,mp4,m4a,3gp,3g2,mj2" }
  }.freeze

  def setup
    @root = Dir.mktmpdir
    @mp4 = File.join(@root, "demo draft-01.mp4")
    File.binwrite(@mp4, "x")
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_argv_runs_ffprobe_in_the_pinned_image_offline_and_read_only
    argv = P.command(@mp4)
    assert_includes argv, ChangeDocker::FFMPEG_IMAGE
    assert_equal [ "--entrypoint", "ffprobe" ], argv[argv.index("--entrypoint"), 2]
    assert_equal [ "--network", "none" ], argv[argv.index("--network"), 2]
    mount = argv[argv.index("--mount") + 1]
    assert_includes mount, "source=#{File.realpath(@root)}"
    assert_includes mount, "readonly"
    assert_equal "/probe/demo draft-01.mp4", argv.last
    assert_includes argv, "-count_packets"
  end

  def test_summary_names_duration_frames_and_each_stream
    s = P.summarize(JSON.generate(PROBE))
    assert_in_delta 41.333, s[:duration_s], 0.001
    assert_equal 1240, s[:frames]
    assert_in_delta 30.0, s[:fps]
    assert_equal %w[video audio subtitle], s[:streams].map { |x| x[:type] }
    lines = P.lines(s)
    assert_equal "duration: 41.333s", lines[0]
    assert_equal "frames: 1240 at 30.00 fps", lines[1]
    assert_includes lines, "stream 0: video h264 1920x1080 30.00 fps, 1240 frames, 41.333s"
    assert_includes lines, "stream 1: audio aac 48000 Hz 2 ch, 41.330s"
    assert_includes lines, "stream 2: subtitle mov_text"
  end

  def test_frames_fall_back_to_read_packets
    probe = JSON.parse(JSON.generate(PROBE))
    probe["streams"][0].delete("nb_frames")
    assert_equal 1240, P.summarize(JSON.generate(probe))[:frames]
  end

  def test_probe_uses_the_runner_and_raises_on_failure
    seen = nil
    ok = P.probe(@mp4, runner: ->(argv) { (seen = argv) && [ JSON.generate(PROBE), true ] })
    assert_equal 1240, ok[:frames]
    assert_equal P.command(@mp4), seen
    err = assert_raises(P::ProbeError) { P.probe(@mp4, runner: ->(_) { [ "moov atom not found", false ] }) }
    assert_includes err.message, "moov atom not found"
    assert_raises(P::ProbeError) { P.probe(File.join(@root, "missing.mp4"), runner: ->(_) { flunk }) }
  end

  def test_cli_without_a_file_prints_usage
    out, status = Open3.capture2e("ruby", SCRIPT)
    refute status.success?
    assert_includes out, "usage: walkthrough_probe.rb"
  end
end
