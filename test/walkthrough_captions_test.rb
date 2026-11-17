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

  def test_sentence_end_closes_the_cue
    cues = WalkthroughCaptions.cues(WalkthroughCaptions.word_spans(alignment("Hi there. Next one!")))
    assert_equal [ [ "Hi there." ], [ "Next one!" ] ], cues.map { |c| c[:lines] }
  end

  def test_colon_and_question_mark_also_close_a_cue
    cues = WalkthroughCaptions.cues(WalkthroughCaptions.word_spans(alignment("Why? Note: yes")))
    assert_equal [ [ "Why?" ], [ "Note:" ], [ "yes" ] ], cues.map { |c| c[:lines] }
  end

  def test_overlapping_word_timings_never_overlap_cues
    words = [ { text: "One.", start_ms: 0, end_ms: 900 }, { text: "Two", start_ms: 800, end_ms: 1200 } ]
    cues = WalkthroughCaptions.cues(words)
    assert_equal 2, cues.length
    assert_operator cues[1][:start_ms], :>=, cues[0][:end_ms]
    assert_operator cues[1][:end_ms], :>, cues[1][:start_ms]
  end

  def test_no_overlap_clamps_across_a_scene_boundary
    list = [ { start_ms: 0, end_ms: 2000, lines: [ "a" ] }, { start_ms: 1500, end_ms: 1600, lines: [ "b" ] },
             { start_ms: 1700, end_ms: 3000, lines: [ "c" ] } ]
    out = WalkthroughCaptions.no_overlap(list)
    out.each_cons(2) { |a, b| assert_operator b[:start_ms], :>=, a[:end_ms] }
    assert_equal %w[a b c], out.map { |c| c[:lines].first }
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
    assert_equal [ { start_ms: 0, end_ms: 200, db: -10, attack_ms: 300, release_ms: 500 },
                   { start_ms: 9000, end_ms: 9200, db: -8, attack_ms: 300, release_ms: 500 } ], spans
  end

  def test_cues_split_at_silent_gaps_in_either_line_position
    w = ->(text, a, b) { { text: text, start_ms: a, end_ms: b } }
    # Gap while filling the first line, and gap after a completed first line.
    [
      [ w["Hello", 0, 500], w["there", 600, 1000], w["Later", 10_000, 11_000] ],
      [ w["a" * 40, 0, 1000], w["b" * 10, 1100, 2000], w["Later", 10_000, 11_000] ]
    ].each do |words|
      cues = WalkthroughCaptions.cues(words)
      assert_equal 2, cues.length
      assert_operator cues.first[:end_ms], :<, 10_000
      assert_equal 10_000, cues.last[:start_ms]
      assert_equal [ "Later" ], cues.last[:lines]
    end
    # A short pause stays inside one cue.
    one = WalkthroughCaptions.cues([ w["Hi", 0, 400], w["you", 900, 1200] ])
    assert_equal 1, one.length
  end

  def test_orphan_word_joins_the_previous_cue_of_its_sentence
    w = ->(text, a, b) { { text: text, start_ms: a, end_ms: b } }
    words = [ w["Hello", 0, 400], w["there", 500, 900], w["friend.", 1000, 1500] ]
    # Forced: a two-word cue that closes before the sentence ends.
    groups = [ words.first(2), [ words.last ] ]
    merged = WalkthroughCaptions.merge_orphans(groups)
    assert_equal [ words ], merged
  end

  def test_spilled_sentence_end_is_rebalanced_not_left_alone
    text = "#{Array.new(10) { |i| "word#{i}xx" }.join(' ')} renewal."
    cues = WalkthroughCaptions.cues(WalkthroughCaptions.word_spans(alignment(text, step: 0.05)))
    assert_equal text, cues.flat_map { |c| c[:lines] }.join(" ")
    cues.each do |c|
      assert_operator c[:lines].length, :<=, WalkthroughCaptions::MAX_LINES
      c[:lines].each { |l| assert_operator l.length, :<=, WalkthroughCaptions::MAX_LINE }
      assert_operator c[:lines].join(" ").split.length, :>=, WalkthroughCaptions::MIN_WORDS
      assert_operator c[:end_ms] - c[:start_ms], :>=, WalkthroughCaptions::MIN_CUE_MS
    end
    assert_equal 2, cues.length
    refute_equal [ "renewal." ], cues.last[:lines]
    cues.each_cons(2) { |a, b| assert_operator b[:start_ms], :>=, a[:end_ms] }
  end

  def test_orphan_merges_forward_when_it_opens_a_sentence
    w = ->(text, a, b) { { text: text, start_ms: a, end_ms: b } }
    words = [ w["Done.", 0, 900], w["Then", 2000, 2300], w["we", 2400, 2600], w["go.", 2700, 3200] ]
    merged = WalkthroughCaptions.merge_orphans([ [ words[0] ], [ words[1] ], words[2..] ])
    assert_equal [ [ words[0] ], words[1..] ], merged
  end

  def test_orphans_never_cross_a_long_silence
    w = ->(text, a, b) { { text: text, start_ms: a, end_ms: b } }
    cues = WalkthroughCaptions.cues([ w["Hello", 0, 500], w["there", 600, 1000], w["Later", 10_000, 10_300] ])
    assert_equal [ [ "Hello there" ], [ "Later" ] ], cues.map { |c| c[:lines] }
  end
end
