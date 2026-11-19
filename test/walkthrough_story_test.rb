# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../scripts/walkthrough_story"

class WalkthroughStoryTest < Minitest::Test
  S = WalkthroughStory

  def board
    { "scenes" => %w[a b c d e].map { |id| { "id" => id } },
      "story" => story }
  end

  def story
    { "hero" => "the platform admin", "guide" => "change-fabric", "perspective" => "third", "audience" => "platform team",
      "before" => { "state" => "deploys wait", "scenes" => [ "a" ] },
      "turn" => { "moment" => "opens the console", "scenes" => [ "b" ] },
      "after" => { "outcomes" => [ "ships in ten minutes" ], "scenes" => [ "e" ] },
      "beats" => [ { "label" => "first try", "scenes" => [ "c" ] } ],
      "length_s" => 90,
      "highlights" => { "ui_before_after" => false, "scope" => "built_only", "secondary_artifacts" => [], "requests" => [] },
      "assumptions" => [ "/story/beats", "/story/length_s" ] }
  end

  def story_only
    s = story
    %w[before turn after].each { |k| s[k].delete("scenes") }
    s["beats"].each { |b| b.delete("scenes") }
    s
  end

  def sb(&mutate)
    b = board
    mutate&.call(b["story"])
    S.errors(b["story"], mode: :storyboard, board: b)
  end

  def so(&mutate)
    s = story_only
    mutate&.call(s)
    S.errors(s, mode: :story)
  end

  def assert_error(errs, fragment) = assert(errs.any? { |e| e.include?(fragment) }, "expected #{fragment.inspect} in #{errs.inspect}")

  def test_valid_in_both_modes
    assert_empty sb
    assert_empty so
    assert S.preflight!(board)
  end

  def test_first_person_we_hero_passes
    assert_empty sb { |s| s.merge!("hero" => "we, the platform team", "perspective" => "first") }
  end

  def test_story_missing_or_wrong_type
    assert_error S.errors(nil, mode: :story), "story is missing"
    assert_error S.errors([], mode: :storyboard, board: board), "story must be an object"
  end

  def test_hero_and_audience_required_in_both_modes
    [ nil, "", "  ", 3 ].each do |bad|
      assert_error sb { |s| s["hero"] = bad }, "story.hero"
      assert_error so { |s| s["hero"] = bad }, "story.hero"
      assert_error sb { |s| s["audience"] = bad }, "story.audience"
      assert_error so { |s| s["audience"] = bad }, "story.audience"
    end
    assert_error sb { |s| s.delete("hero") }, "story.hero"
  end

  def test_guide_null_is_valid_and_blank_is_not
    assert_empty sb { |s| s["guide"] = nil }
    assert_empty sb { |s| s.delete("guide") }
    assert_error sb { |s| s["guide"] = " " }, "story.guide"
    assert_error so { |s| s["guide"] = 4 }, "story.guide"
  end

  def test_perspective
    %w[first second third].each { |p| assert_empty sb { |s| s["perspective"] = p } }
    assert_error sb { |s| s["perspective"] = "fourth" }, "story.perspective"
  end

  def test_spine_text_fields
    { "before" => "state", "turn" => "moment" }.each do |part, field|
      [ nil, "", "  ", 1 ].each do |bad|
        assert_error sb { |s| s[part][field] = bad }, "story.#{part}.#{field}"
        assert_error so { |s| s[part][field] = bad }, "story.#{part}.#{field}"
      end
    end
    [ nil, [], [ "" ], [ " " ], "text", [ 1 ] ].each do |bad|
      assert_error sb { |s| s["after"]["outcomes"] = bad }, "story.after.outcomes"
      assert_error so { |s| s["after"]["outcomes"] = bad }, "story.after.outcomes"
    end
  end

  def test_spine_parts_must_be_objects
    %w[before turn after].each do |part|
      assert_error sb { |s| s.delete(part) }, "story.#{part} must be an object"
      assert_error so { |s| s[part] = "x" }, "story.#{part} must be an object"
    end
  end

  def test_spine_scenes_required_in_storyboard_and_absent_in_story_only
    %w[before turn after].each do |part|
      assert_error sb { |s| s[part].delete("scenes") }, "story.#{part}.scenes must be a non-empty"
      assert_error sb { |s| s[part]["scenes"] = [] }, "story.#{part}.scenes must be a non-empty"
      assert_error sb { |s| s[part]["scenes"] = "a" }, "story.#{part}.scenes must be a non-empty"
      assert_error sb { |s| s[part]["scenes"] = [ "nope" ] }, "unknown scene ids"
      assert_error so { |s| s[part]["scenes"] = [ "a" ] }, "story.#{part}.scenes must be absent"
    end
  end

  def test_spine_order
    assert_error sb { |s| s["before"]["scenes"] = [ "c" ] }, "before story.turn"
    assert_error sb { |s| s["turn"]["scenes"] = [ "e" ] }, "before story.after"
    assert_empty sb { |s| s["before"]["scenes"] = %w[a b]; s["turn"]["scenes"] = [ "c" ]; s["after"]["scenes"] = %w[d e] }
  end

  def test_beats
    assert_empty sb { |s| s.delete("beats"); s["assumptions"] = [] }
    assert_empty sb { |s| s["beats"] = [] }
    assert_error sb { |s| s["beats"] = {} }, "story.beats must be an array"
    assert_error sb { |s| s["beats"] = [ "x" ] }, "story.beats[0] must be an object"
    assert_error sb { |s| s["beats"] = [ { "scenes" => [ "c" ] } ] }, "story.beats[0].label"
    assert_error sb { |s| s["beats"] = [ { "label" => "x", "scenes" => [ "zz" ] } ] }, "unknown scene ids"
    assert_error so { |s| s["beats"] = [ { "label" => "x", "scenes" => [ "c" ] } ] }, "story.beats[0].scenes must be absent"
    assert_empty so { |s| s["beats"] = [ { "label" => "x" } ] }
  end

  def test_length_s_range_and_type
    [ 15, 600, 90 ].each { |n| assert_empty sb { |s| s["length_s"] = n } }
    [ 14, 601, "90", 90.5, true, nil ].each { |n| assert_error sb { |s| s["length_s"] = n }, "story.length_s" }
  end

  def test_highlights_shapes
    assert_empty sb { |s| s.delete("highlights") }
    assert_empty sb { |s| s["highlights"] = {} }
    assert_error sb { |s| s["highlights"] = [] }, "story.highlights must be an object"
    assert_error sb { |s| s["highlights"]["ui_before_after"] = "yes" }, "ui_before_after must be true or false"
    assert_error sb { |s| s["highlights"]["scope"] = "all" }, "story.highlights.scope"
    assert_error sb { |s| s["highlights"]["secondary_artifacts"] = "a" }, "secondary_artifacts"
    assert_error sb { |s| s["highlights"]["requests"] = [ "" ] }, "story.highlights.requests"
    assert_empty sb { |s| s["highlights"]["scope"] = "wider" }
  end

  def test_ui_before_after_needs_a_pair_in_storyboard_only
    b = board
    b["story"]["highlights"]["ui_before_after"] = true
    assert_error S.errors(b["story"], mode: :storyboard, board: b), "no pair exists"
    s = story_only
    s["highlights"]["ui_before_after"] = true
    assert_empty S.errors(s, mode: :story)
    b["scenes"][0].merge!("footage" => "before", "pair" => "p")
    b["scenes"][3].merge!("footage" => "after", "pair" => "p")
    assert_empty S.errors(b["story"], mode: :storyboard, board: b)
    b["scenes"][0]["footage"] = "after"
    b["scenes"][3]["footage"] = "before"
    assert_error S.errors(b["story"], mode: :storyboard, board: b), "no pair exists"
  end

  def test_assumption_pointers
    assert_empty sb { |s| s["assumptions"] = [ "/story/before/state", "/story/beats/0/label", "/story/highlights" ] }
    assert_error sb { |s| s["assumptions"] = [ "/story/nope" ] }, "does not resolve"
    assert_error sb { |s| s["assumptions"] = [ "/other/hero" ] }, "does not resolve"
    assert_error sb { |s| s["assumptions"] = [ "/story/beats/9" ] }, "does not resolve"
    assert_error sb { |s| s["assumptions"] = "/story/hero" }, "array of JSON pointers"
  end

  def test_preflight_raises_with_the_errors
    b = board
    b.delete("story")
    err = assert_raises(S::MissingStoryError) { S.preflight!(b) }
    assert_includes err.message, "story is missing"
    out = StringIO.new
    assert_equal 2, S.report(err, out: out)
    assert_includes out.string, "run the story round"
  end

  # --- seeding ---

  def seedling
    story_only.merge("assumptions" => [ "/story/length_s", "/story/before/state", "/story/guide" ])
  end

  def test_seed_copies_whole_into_an_absent_story
    out = S.seed(seedling, { "scenes" => [] })
    assert_equal seedling, out["story"]
  end

  def test_seed_fills_only_absent_or_empty_and_never_overwrites
    dest = { "story" => { "hero" => "my hero", "audience" => "", "before" => { "state" => "mine", "scenes" => [ "a" ] },
                          "assumptions" => [ "/story/hero" ] } }
    out = S.seed(seedling, dest)["story"]
    assert_equal "my hero", out["hero"]
    assert_equal "platform team", out["audience"]
    assert_equal "mine", out["before"]["state"]
    assert_equal [ "a" ], out["before"]["scenes"], "scene arrays are never seeded or dropped"
    assert_equal "opens the console", out["turn"]["moment"]
    refute out["turn"].key?("scenes")
    assert_equal 90, out["length_s"]
  end

  def test_seed_carries_pointers_only_for_copied_fields
    dest = { "story" => { "before" => { "state" => "mine" }, "assumptions" => [ "/story/hero" ] } }
    out = S.seed(seedling, dest)["story"]
    assert_includes out["assumptions"], "/story/hero"
    assert_includes out["assumptions"], "/story/length_s"
    assert_includes out["assumptions"], "/story/guide"
    refute_includes out["assumptions"], "/story/before/state", "the user's own value is not an assumption"
  end

  def test_seed_does_not_mutate_inputs_or_seed_scenes
    src = story_only.merge("before" => { "state" => "x", "scenes" => [ "a" ] })
    dest = { "story" => {} }
    out = S.seed(src, dest)
    assert_equal({ "story" => {} }, dest)
    refute out["story"]["before"].key?("scenes")
  end

  # --- unanswered ---

  def test_unanswered_on_empty_story_lists_every_question
    assert_equal S::QUESTIONS.map { |q| q[:key] }, S.unanswered({})
    assert_equal S::QUESTIONS.map { |q| q[:key] }, S.unanswered(nil)
  end

  def test_unanswered_counts_empty_optional_values_as_answered
    s = story_only
    s["beats"] = []
    s["guide"] = nil
    s["highlights"] = { "ui_before_after" => false, "scope" => "wider", "secondary_artifacts" => [], "requests" => [] }
    assert_equal [], S.unanswered(s.except("assumptions"))
  end

  def test_unanswered_required_blank_and_assumed
    s = story_only.merge("assumptions" => [ "/story/before/state" ])
    s["hero"] = " "
    s["after"]["outcomes"] = [ "" ]
    assert_equal %w[hero before after], S.unanswered(s)
    assert_equal %w[hero after], S.unanswered(s, assumed: false)
  end

  def test_unanswered_ignores_absent_optional_keys_as_unanswered
    s = story_only.except("length_s", "perspective")
    assert_equal %w[perspective length], S.unanswered(s.merge("assumptions" => []))
  end

  def test_story_of_reads_either_file
    assert_equal({ "hero" => "x" }, S.story_of({ "story" => { "hero" => "x" } }))
    assert_equal({ "hero" => "x" }, S.story_of({ "hero" => "x" }))
  end

  def test_shipped_storyboards_are_valid
    %w[site-self site-hero-journey].each do |slug|
      board = JSON.parse(File.read(File.join(__dir__, "..", "walkthrough", slug, "storyboard.json")))
      assert_empty S.warnings(board), slug
    end
  end

  def test_validate_warns_with_a_story_prefix_and_never_fails
    require_relative "../scripts/walkthrough_storyboard"
    assert_empty WalkthroughStoryboard.story_warnings(board)
    assert_includes WalkthroughStoryboard.story_warnings(board.except("story")).first, "story: story is missing"
    assert_includes WalkthroughStoryboard.warnings(board.except("story")).join("\n"), "story is missing"
  end
end
