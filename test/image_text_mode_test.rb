# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/image_text_mode"

class ImageTextModeTest < Minitest::Test
  def classify(prompt, **opts)
    ImageTextMode.classify(prompt: prompt, **opts)
  end

  def test_no_quotes_is_none
    result = classify("a calm ocean at dawn")
    assert_equal :none, result.mode
    assert_empty result.warnings
  end

  def test_one_short_run_is_short
    result = classify('poster saying "Sale"')
    assert_equal :short, result.mode
    assert_equal [ "Sale" ], result.runs
  end

  def test_single_quoted_short_run_is_short
    assert_equal :short, classify("sign reading 'Open now'").mode
  end

  def test_five_words_is_heavy
    assert_equal :heavy, classify('banner "Big summer sale now on"').mode
  end

  def test_two_runs_is_heavy
    assert_equal :heavy, classify('"Sale" and "Today"').mode
  end

  def test_over_25_chars_is_heavy
    assert_equal :heavy, classify('"Extraordinarily wonderfulness"').mode
  end

  def test_apostrophe_is_not_a_run
    assert_equal :none, classify("don't add anything, it's a quiet scene").mode
  end

  def test_spec_forces_heavy
    result = classify("a calm ocean", spec: { "copy" => {} })
    assert_equal [ :heavy, :spec ], [ result.mode, result.reason ]
  end

  def test_explicit_mode_beats_spec
    result = classify('"Big summer sale now on"', spec: { "copy" => {} }, mode: "none")
    assert_equal [ :none, :explicit ], [ result.mode, result.reason ]
  end

  def test_unknown_explicit_mode_raises
    assert_raises(ArgumentError) { classify("x", mode: "loud") }
  end

  def test_banner_word_without_quotes_warns
    result = classify("a hero banner of a mountain")
    assert_equal :none, result.mode
    assert_equal 1, result.warnings.size
  end
end
