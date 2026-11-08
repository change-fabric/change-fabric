# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "base64"
require "tmpdir"
require "fileutils"
require_relative "../scripts/change_config"
require_relative "../scripts/change_media"
require_relative "../scripts/change_lane_browserless"

# The lane hands each viewport's sampled frames to the media sink, which
# encodes them. A recording problem is never a gate signal: no video is a
# warn, and frames trimmed by the budget are one info finding per viewport.
class ChangeLaneBrowserlessRecordingTest < Minitest::Test
  class FakeSession
    def initialize(video) = @video = video

    def run_function(code)
      name = JSON.parse(code[/const viewports = (\[.*?\]);/, 1]).first["name"]
      cell = { "viewport" => name, "width" => 390, "route" => "/", "httpStatus" => 200,
               "scrollWidth" => 10, "overflow" => false, "consoleErrors" => 0 }
      { "cells" => [ cell ], "videos" => [ { "viewport" => name }.merge(@video) ] }
    end
  end

  Ctx = Struct.new(:network, :target_url, :browserless, :media) do
    def log(_message) = nil
  end

  VIEWPORTS = [ { "name" => "mobile", "width" => 390, "height" => 844 } ].freeze
  FRAMES = { "frames" => [ Base64.strict_encode64("a") ], "ticks" => [ 0, 0 ] }.freeze

  def run_lane(video, encoder)
    Dir.mktmpdir do |dir|
      media = ChangeMedia.new(dir, encoder: encoder)
      config = ChangeConfig::LaneConfig.new("browserless", { "routes" => [ "/" ], "viewports" => VIEWPORTS }, "/repo")
      ctx = Ctx.new("net", "https://app.example.org", FakeSession.new(video), media)
      return [ ChangeLaneBrowserless.new(config, ctx).run, media ]
    end
  end

  def ok_encoder
    lambda do |_dir, fps:, out:|
      FileUtils.mkdir_p(File.dirname(out))
      File.binwrite(out, "mp4 at #{fps}")
    end
  end

  def recording_findings(findings) = findings.select { |f| f.check == "mobile recording" }

  def test_a_clean_recording_adds_no_finding
    findings, media = run_lane(FRAMES.merge("dropped" => 0), ok_encoder)
    assert_empty recording_findings(findings)
    assert_equal "video/mobile.mp4", media.videos.first.path
  end

  def test_dropped_frames_produce_one_info_finding
    findings, media = run_lane(FRAMES.merge("dropped" => 7), ok_encoder)
    recording = recording_findings(findings)
    assert_equal 1, recording.size
    assert_equal "pass", recording.first.status
    assert_equal "info", recording.first.severity
    assert_match(/7 sampled frames dropped/, recording.first.detail)
    assert_equal 7, media.videos.first.dropped
    refute findings.any?(&:fail?)
  end

  def test_an_encode_failure_is_a_warn_and_the_lane_still_passes
    failing = ->(_dir, fps:, out:) { raise FrameVideo::EncodeError, "ffmpeg failed: #{fps} #{out}" }
    findings, = run_lane(FRAMES.merge("dropped" => 0), failing)
    recording = recording_findings(findings)
    assert_equal [ "warn" ], recording.map(&:status)
    assert_match(/encode failed/, recording.first.detail)
    refute findings.any?(&:fail?)
  end

  def test_no_frames_is_a_warn
    findings, = run_lane({ "error" => "no screencast frames captured" }, ok_encoder)
    recording = recording_findings(findings)
    assert_equal [ "warn" ], recording.map(&:status)
    assert_match(/no screencast frames captured/, recording.first.detail)
  end
end
