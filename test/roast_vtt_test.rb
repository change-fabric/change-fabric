# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/roast_vtt"

class RoastVttTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/roast_audio/continuous.vtt", __dir__)

  def test_parses_header_metadata_identifiers_settings_and_short_stamps
    text = "﻿WEBVTT - narration\r\nKind: captions\r\n\r\nNOTE a comment\r\nspanning lines\r\n\r\nSTYLE\r\n::cue { color: red }\r\n\r\n" \
           "intro\r\n00:01.500 --> 00:03.250 align:start position:10%\r\nFirst line\r\n  second line  \r\n\r\n" \
           "01:00:02.000 --> 01:00:04.000\r\nAn hour in\r\n"
    cues = RoastVtt.parse(text)
    assert_equal [ 1, 2 ], cues.map(&:index)
    assert_equal [ 1500, 3250 ], [ cues[0].start_ms, cues[0].end_ms ]
    assert_equal "First line second line", cues[0].text
    assert_equal 3_602_000, cues[1].start_ms
  end

  def test_rejects_a_missing_header_and_a_bad_timing_line
    assert_raises(RoastVtt::ParseError) { RoastVtt.parse("00:01.000 --> 00:02.000\nhi\n") }
    assert_raises(RoastVtt::ParseError) { RoastVtt.parse("WEBVTT\n\n00:01 --> 00:02.000\nhi\n") }
  end

  def test_mmss_rounds_to_tenths
    assert_equal "0:00.0", RoastVtt.mmss(0)
    assert_equal "0:12.3", RoastVtt.mmss(12_340)
    assert_equal "2:03.4", RoastVtt.mmss(123_400)
    assert_equal "1:00.0", RoastVtt.mmss(59_990)
  end

  def test_shift_and_render_round_trip
    cues = RoastVtt.shift(RoastVtt.parse_file(FIXTURE), 300)
    again = RoastVtt.parse(RoastVtt.render(cues))
    assert_equal [ 550, 2300, 4300 ], again.map(&:start_ms)
    assert_equal cues.map(&:text), again.map(&:text)
  end

  def test_three_cues_inside_continuous_speech_pass
    cues = RoastVtt.parse_file(FIXTURE)
    assert_empty RoastVtt.structure(cues, duration_ms: 6000, speech: [ [ 250, 5750 ] ])
  end

  def test_order_overlap_span_negative_and_past_end
    cues = [ cue(1, 1000, 2000), cue(2, 1500, 2500), cue(3, 900, 950), cue(4, 3000, 3000), cue(5, 5000, 7000) ]
    rules = RoastVtt.structure(cues, duration_ms: 6000, speech: [ [ 0, 6000 ] ]).map { |f| f["rule"] }
    assert_includes rules, "cue_overlap"
    assert_includes rules, "cue_order"
    assert_includes rules, "cue_span"
    assert_includes rules, "cue_past_end"
    negative = RoastVtt.structure([ cue(1, -200, 1000) ], duration_ms: 6000, speech: [ [ 0, 1000 ] ])
    assert_equal [ "cue_negative" ], negative.map { |f| f["rule"] }
  end

  def test_a_cue_with_too_little_speech_under_it_is_outside_speech
    failures = RoastVtt.structure([ cue(1, 0, 1000), cue(2, 1000, 2000) ], duration_ms: 2000, speech: [ [ 0, 1050 ] ])
    assert_equal [ [ "cue_outside_speech", 2, "0:01.0" ] ], failures.map { |f| f.values_at("rule", "cue", "at") }
  end

  def test_speech_beyond_the_cues_is_uncaptioned
    failures = RoastVtt.structure([ cue(1, 1000, 2000) ], duration_ms: 4000, speech: [ [ 500, 3000 ] ])
    assert_equal %w[uncaptioned_speech uncaptioned_speech], failures.map { |f| f["rule"] }
    assert_empty RoastVtt.structure([ cue(1, 1000, 2000) ], duration_ms: 4000, speech: [ [ 800, 2200 ] ])
  end

  def test_speech_between_cues_with_no_cue_is_uncaptioned
    failures = RoastVtt.structure([ cue(1, 0, 1000), cue(2, 5000, 6000) ], duration_ms: 6000, speech: [ [ 0, 6000 ] ])
    assert_equal [ [ "uncaptioned_speech", "0:01.0" ] ], failures.map { |f| f.values_at("rule", "at") }
    assert_empty RoastVtt.structure([ cue(1, 0, 1000), cue(2, 1200, 6000) ], duration_ms: 6000, speech: [ [ 0, 6000 ] ])
  end

  def test_no_cues_fails
    assert_equal [ "no_cues" ], RoastVtt.structure([], duration_ms: 1000, speech: []).map { |f| f["rule"] }
  end

  private

  def cue(i, s, e) = RoastVtt::Cue.new(index: i, start_ms: s, end_ms: e, text: "cue #{i}")
end
