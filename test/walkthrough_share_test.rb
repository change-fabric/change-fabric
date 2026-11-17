# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/walkthrough_share"

class WalkthroughShareTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    @mp4 = File.join(@root, "demo-draft-01.mp4")
    File.binwrite(@mp4, "full")
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_args_encode_a_chat_sized_copy
    args = WalkthroughShare.args("demo-draft-01.mp4", "demo-draft-01-share.mp4", 1800)
    joined = args.join(" ")
    assert_includes joined, "-i demo-draft-01.mp4 "
    assert_includes joined, "-c:v libx264 -crf 26"
    assert_includes joined, "-maxrate 1800k -bufsize 3600k"
    assert_includes joined, "-c:a aac -b:a 128k"
    assert_includes joined, "-movflags +faststart"
    assert_includes joined, "-map 0:s? -c:s copy", "soft captions survive the share copy"
    assert_equal "demo-draft-01-share.mp4", args.last
  end

  def test_path_and_line
    share = WalkthroughShare.path_for(@mp4)
    assert_equal File.join(@root, "demo-draft-01-share.mp4"), share
    assert_equal "walkthrough-share: #{share}", WalkthroughShare.line(share)
  end

  def test_fits_on_first_rung
    seen = []
    result = WalkthroughShare.make(@root, @mp4, encode: encoder(seen, 10))
    assert_equal 1800, result[:maxrate_k]
    assert_equal [ "1800k" ], seen
  end

  def test_over_cap_steps_bitrate_down
    seen = []
    sizes = { "1800k" => 50, "1200k" => 40, "800k" => 20 }
    result = WalkthroughShare.make(@root, @mp4, limit: 30, encode: lambda { |args|
      rate = args[args.index("-maxrate") + 1]
      seen << rate
      File.binwrite(args.last.sub("/work", @root), "x" * sizes.fetch(rate))
      true
    })
    assert_equal %w[1800k 1200k 800k], seen
    assert_equal 800, result[:maxrate_k]
  end

  def test_reports_when_nothing_fits
    result = WalkthroughShare.make(@root, @mp4, limit: 5, encode: encoder([], 10))
    assert_match(/over 0 MiB even at 500k/, result[:error])
    refute File.exist?(WalkthroughShare.path_for(@mp4))
  end

  def test_reports_a_failed_encode
    result = WalkthroughShare.make(@root, @mp4, encode: ->(_) { false })
    assert_equal "share encode failed at 1800k", result[:error]
  end

  private

  def encoder(seen, bytes)
    lambda do |args|
      seen << args[args.index("-maxrate") + 1]
      File.binwrite(args.last.sub("/work", @root), "x" * bytes)
      true
    end
  end
end
