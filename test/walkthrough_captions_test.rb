# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/walkthrough_captions"

class WalkthroughCaptionsTest < Minitest::Test
  def alignment(text, step: 0.1)
    chars = text.chars
    { "characters" => chars,
      "character_start_times_seconds" => chars.each_index.map { |i| (i * step).round(3) },
      "character_end_times_seconds" => chars.each_index.map { |i| ((i + 1) * step).round(3) } }
  end

  def test_word_spans
    words = WalkthroughCaptions.word_spans(alignment("Hi there"), offset_ms: 1000)
    assert_equal [ { text: "Hi", start_ms: 1000, end_ms: 1200 }, { text: "there", start_ms: 1300, end_ms: 1800 } ], words
  end

  def test_cues_respect_line_and_cue_limits
    text = Array.new(30) { |i| "word#{i}" }.join(" ")
    cues = WalkthroughCaptions.cues(WalkthroughCaptions.word_spans(alignment(text, step: 0.01)))
    cues.each do |c|
      assert_operator c[:lines].length, :<=, 2
      c[:lines].each { |l| assert_operator l.length, :<=, 42 }
    end
    assert_equal text, cues.flat_map { |c| c[:lines] }.join(" ")
    assert_operator cues.length, :>, 1
  end

  def test_srt_golden
    srt = WalkthroughCaptions.srt(WalkthroughCaptions.cues(WalkthroughCaptions.word_spans(alignment("Hi there"))))
    assert_equal "1\n00:00:00,000 --> 00:00:00,800\nHi there\n", srt
  end

  def test_vtt_header_and_dot_timestamps
    srt = "1\n00:00:00,000 --> 00:00:00,800\nHi, there\n\n2\n01:02:03,004 --> 01:02:04,500\nBye\n"
    assert_equal "WEBVTT\n\n1\n00:00:00.000 --> 00:00:00.800\nHi, there\n\n2\n01:02:03.004 --> 01:02:04.500\nBye\n",
                 WalkthroughCaptions.vtt(srt)
  end

  def test_timestamp
    assert_equal "01:02:03,004", WalkthroughCaptions.timestamp(3_723_004)
  end

  def test_duck_spans
    spans = WalkthroughCaptions.duck_spans([
      { offset_ms: 0, alignment: alignment("Hi"), duck_db: -10 },
      { offset_ms: 5000, alignment: alignment(" ") },
      { offset_ms: 9000, alignment: alignment("Ok") }
    ])
    assert_equal [ { start_ms: 0, end_ms: 200, db: -10 }, { start_ms: 9000, end_ms: 9200, db: -12 } ], spans
  end
end
