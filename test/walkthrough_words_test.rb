# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "tmpdir"
require_relative "../scripts/walkthrough_storyboard"
require_relative "../scripts/walkthrough_words"

# Word anchors: alignment JSON to word times, and resolve_anchors against
# the checked-in acceptance board (two scenes that both say "change"). No
# paid call: the alignments are fixtures copied into a temp cache.
class WalkthroughWordsTest < Minitest::Test
  ACCEPTANCE = File.join(__dir__, "fixtures", "walkthrough", "acceptance")

  def alignment(text, step: 0.1)
    chars = text.chars
    { "characters" => chars,
      "character_start_times_seconds" => chars.each_index.map { |i| (i * step).round(3) },
      "character_end_times_seconds" => chars.each_index.map { |i| ((i + 1) * step).round(3) } }
  end

  def test_words_are_lowercased_stripped_and_counted
    words = WalkthroughWords.from_alignment(alignment("Ship it. SHIP it, again!"))
    assert_equal(%w[ship it ship it again], words.map { |w| w[:word] })
    assert_equal [ 1, 1, 2, 2, 1 ], words.map { |w| w[:nth] }
    assert_equal({ word: "ship", nth: 2, start_ms: 900, end_ms: 1300 }, words[2])
  end

  def test_punctuation_only_tokens_are_dropped
    words = WalkthroughWords.from_alignment(alignment("Plan - then ship"))
    assert_equal(%w[plan then ship], words.map { |w| w[:word] })
  end

  def test_at_finds_the_nth_occurrence
    words = WalkthroughWords.from_alignment(alignment("go now, go"))
    assert_equal 0, WalkthroughWords.at(words, "Go")
    assert_equal 800, WalkthroughWords.at(words, "go,", 2)
  end

  def test_missing_word_names_the_nearest_candidates
    words = WalkthroughWords.from_alignment(alignment("the gate is green"))
    err = assert_raises(WalkthroughWords::Missing) { WalkthroughWords.at(words, "gates") }
    assert_includes err.message, '"gates" is not in the narration'
    assert_includes err.message, "gate"
    err = assert_raises(WalkthroughWords::Missing) { WalkthroughWords.at(words, "gate", 2) }
    assert_includes err.message, "said 1 time(s)"
  end

  def test_spoken_numbers_need_the_spoken_form
    words = WalkthroughWords.from_alignment(alignment("three steps"))
    err = assert_raises(WalkthroughWords::Missing) { WalkthroughWords.at(words, "3") }
    assert_includes err.message, "three"
  end

  # -- acceptance board ----------------------------------------------------

  def setup
    @cache = Dir.mktmpdir
    @board = WalkthroughStoryboard.load(File.join(ACCEPTANCE, "board.json"))
    seed_alignments(@board)
  end

  def teardown = FileUtils.rm_rf(@cache)

  def seed_alignments(board)
    WalkthroughStoryboard.scenes(board).each do |scene|
      next unless scene["narration"]

      dest = WalkthroughCache.path(@cache, :audio, WalkthroughStoryboard.audio_key(board, scene), "alignment.json")
      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.cp(File.join(ACCEPTANCE, "alignments", "#{scene['id']}.json"), dest)
    end
  end

  def times(board, id) = board["scenes"].find { |s| s["id"] == id }["interactions"].map { |op| op["t_ms"] }

  def test_acceptance_board_validates_with_anchors_unresolved
    assert_equal [], WalkthroughStoryboard.validate(@board, root: ACCEPTANCE)
  end

  # Each anchor resolves against its own scene, nth counts within the
  # scene, the narration start leads the scene's words, and every time
  # snaps to a frame at 30 fps.
  def test_anchors_resolve_per_scene_and_snap_to_frames
    assert_equal [], WalkthroughStoryboard.resolve_anchors(@board, @cache)
    assert_equal [ 300, 2434, 4100 ], times(@board, "plan")
    assert_equal [ 967, 2334 ], times(@board, "record")
    fps = WalkthroughStoryboard.fps(@board)
    (times(@board, "plan") + times(@board, "record")).each do |t|
      assert_in_delta 0, (t * fps / 1000.0) - PrototypeCapture.frame_at(t, fps), 0.05
    end
  end

  def test_negative_offset_clamps_to_zero_with_a_warning
    @board["scenes"][0]["interactions"][0]["at"]["offset_ms"] = -2000
    warnings = WalkthroughStoryboard.resolve_anchors(@board, @cache)
    assert_equal 0, times(@board, "plan").first
    assert_equal 1, warnings.size
    assert_match(/scene "plan": interaction 0 .*clamped to 0/, warnings.first)
  end

  def test_resolved_ops_out_of_order_fail_naming_both
    @board["scenes"][0]["interactions"][1]["at"] = { "word" => "every" }
    err = assert_raises(WalkthroughStoryboard::ValidationError) { WalkthroughStoryboard.resolve_anchors(@board, @cache) }
    assert_includes err.message, "interaction 1 at 267 ms is before interaction 0 at 300 ms"
  end

  def test_time_past_the_scene_end_fails_and_never_stretches
    @board["scenes"][0]["interactions"][2]["at"]["offset_ms"] = 5000
    err = assert_raises(WalkthroughStoryboard::ValidationError) { WalkthroughStoryboard.resolve_anchors(@board, @cache) }
    assert_match(/interaction 2 .* past the last frame of the scene's 5000 ms/, err.message)
  end

  # 4110 + 890 snaps to 5000 ms, frame 150, one past the last captured
  # frame (0..149) of a 5000 ms scene at 30 fps.
  def test_time_on_the_frame_after_the_last_fails
    @board["scenes"][0]["interactions"][2]["at"]["offset_ms"] = 890
    err = assert_raises(WalkthroughStoryboard::ValidationError) { WalkthroughStoryboard.resolve_anchors(@board, @cache) }
    assert_match(/interaction 2 .* resolves to 5000 ms, past the last frame/, err.message)
    @board["scenes"][0]["interactions"][2]["at"]["offset_ms"] = 850
    assert_equal [], WalkthroughStoryboard.resolve_anchors(@board, @cache)
    assert_equal 4967, times(@board, "plan").last
  end

  def test_missing_word_and_missing_alignment_fail
    @board["scenes"][1]["interactions"][0]["at"]["word"] = "records"
    err = assert_raises(WalkthroughStoryboard::ValidationError) { WalkthroughStoryboard.resolve_anchors(@board, @cache) }
    assert_includes err.message, 'scene "record": "records" is not in the narration; nearest: record'
    FileUtils.rm_rf(@cache)
    err = assert_raises(WalkthroughStoryboard::ValidationError) { WalkthroughStoryboard.resolve_anchors(@board, @cache) }
    assert_includes err.message, "no narration alignment"
  end

  def test_authored_copy_drops_resolved_times
    WalkthroughStoryboard.resolve_anchors(@board, @cache)
    authored = WalkthroughStoryboard.authored(@board)
    assert(authored["scenes"].flat_map { |s| Array(s["interactions"]) }.none? { |op| op.key?("t_ms") })
    assert_equal [], WalkthroughStoryboard.validate(authored, root: ACCEPTANCE)
    refute_nil times(@board, "plan").first
  end
end
