# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/walkthrough_loudness"

# The free master loudness gate, graded from fixture ebur128 output. The real
# FFmpeg normalize-and-remeasure run is in walkthrough_loudness_docker_test.rb.
class WalkthroughLoudnessTest < Minitest::Test
  FIXTURES = File.join(__dir__, "fixtures", "walkthrough", "loudness")
  NARRATED = { "scenes" => [ { "id" => "a", "narration" => { "text" => "Hello there." } } ] }.freeze

  def fixture(name) = File.read(File.join(FIXTURES, "#{name}.txt"))

  def check(name, board = NARRATED)
    calls = []
    status = Struct.new(:ok) { def success? = ok }.new(true)
    result = WalkthroughLoudness.check("/tmp/x/master.mp4", board, docker: ->(argv) { calls << argv; [ fixture(name), status ] })
    [ result, calls ]
  end

  def test_parse_reads_integrated_and_true_peak
    assert_equal({ integrated: -16.2, true_peak: -2.6 }, WalkthroughLoudness.parse(fixture("compliant")))
  end

  def test_compliant_master_passes
    result, calls = check("compliant")
    assert result.pass?, result.reason
    assert_equal 1, calls.size
    assert_includes calls.first.join(" "), "ebur128=peak=true"
    assert_includes calls.first, ChangeDocker::FFMPEG_IMAGE
  end

  def test_over_peak_fails
    result, = check("over_peak")
    assert result.fail?
    assert_match(/true peak -0\.8 dBTP above -2/, result.reason)
  end

  def test_out_of_range_integrated_fails
    result, = check("out_of_range")
    assert result.fail?
    assert_match(/integrated -19\.4 LUFS outside -16/, result.reason)
  end

  def test_narration_with_no_audio_stream_fails
    result, = check("no_stream")
    assert result.fail?
    assert_match(/no audio stream/, result.reason)
  end

  def test_narration_with_unmeasurable_audio_fails
    result, = check("silent_audio")
    assert result.fail?
    assert_match(/no measurable audio/, result.reason)
  end

  def test_declared_silent_board_is_skipped_without_docker
    [ { "audio" => "none", "scenes" => NARRATED["scenes"] }, { "scenes" => [ { "id" => "a" } ] } ].each do |board|
      result, calls = check("no_stream", board)
      assert result.skip?, board.inspect
      assert_empty calls
      assert_match(/declares no audio/, result.line)
    end
  end

  def test_music_only_board_is_not_silent
    refute WalkthroughLoudness.declared_silent?({ "scenes" => [ { "id" => "a" } ], "music" => { "prompt" => "x" } })
  end

  def test_tolerance_edges
    assert WalkthroughLoudness.grade({ integrated: -17.0, true_peak: -2.0 }).pass?
    refute WalkthroughLoudness.grade({ integrated: -14.9, true_peak: -3.0 }).pass?
  end
end
