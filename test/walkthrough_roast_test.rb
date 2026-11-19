# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../scripts/walkthrough_roast"

class WalkthroughRoastTest < Minitest::Test
  def test_keyframes_take_start_middle_end_and_first_overlay_frames
    entries = [ { "id" => "a", "frames" => 30, "start_frame" => 0 }, { "id" => "b", "frames" => 10, "start_frame" => 30 } ]
    keys = WalkthroughRoast.keyframes(entries, { "a" => { "#toast" => 20, "#late" => 99 } })
    assert_equal [ [ "a", "start", 0 ], [ "a", "middle", 15 ], [ "a", "overlay-toast", 24 ], [ "a", "end", 29 ],
                   [ "b", "start", 30 ], [ "b", "middle", 35 ], [ "b", "end", 39 ] ], keys.map { |k| [ k[:scene], k[:label], k[:frame] ] }
    assert_equal "003-a-overlay-toast.jpg", WalkthroughRoast.keyframe_name(2, keys[2])
  end

  def test_overlay_keyframes_sample_the_hold_midpoint_not_the_fade_in
    entries = [ { "id" => "a", "frames" => 100, "start_frame" => 200 } ]
    keys = WalkthroughRoast.keyframes(entries, { "a" => { "#one" => 10, "#two" => 50 } })
    frames = keys.to_h { |k| [ k[:label], k[:frame] - 200 ] }
    assert_equal 30, frames["overlay-one"]
    assert_equal 74, frames["overlay-two"]
  end

  # A toast visible for frames 30 to 90 of a long scene is still sampled while it shows.
  def test_overlay_sample_stays_near_first_sight_in_a_long_scene
    keys = WalkthroughRoast.keyframes([ { "id" => "a", "frames" => 300, "start_frame" => 0 } ], { "a" => { "#toast" => 30 } })
    assert_equal 54, keys.find { |k| k[:label] == "overlay-toast" }[:frame]
  end

  def test_scene_ids_inside_keyframe_file_names_are_recognized
    assert WalkthroughRoast.scene_named?("003-intro-middle.jpg", %w[intro])
    assert WalkthroughRoast.scene_named?("007-intro-overlay-toast.jpg", %w[intro])
    refute WalkthroughRoast.scene_named?("003-intro-2-middle.jpg", %w[intro])
    assert WalkthroughRoast.scene_named?("003-intro-2-middle.jpg", %w[intro-2])
  end

  def test_extract_args_select_each_frame
    args = WalkthroughRoast.extract_args("/work/v.mp4", [ { frame: 0 }, { frame: 15 } ], "/work/k/%03d.jpg")
    assert_includes args, "select=eq(n\\,0)+eq(n\\,15)"
    assert_equal "/work/k/%03d.jpg", args.last
  end

  def test_brief_carries_the_rubric
    brief = WalkthroughRoast.brief("title" => "Demo")
    %w[Blank Overlays Cursor contradictions safe-area bottom\ 15% aspect\ ratio camera\ zoom cut\ off 1080p cf:fractal cf:usability Pacing jargon Narration\ against\ screen Caption-band].each { |w| assert_includes brief, w }
  end

  def test_review_resolves_storyboard_over_change_md_and_refuses_when_empty
    board = { "review" => { "audience" => "Board audience", "purpose" => [ "Outcome" ] } }
    r = WalkthroughRoast.review(board, { kind: "explainer", audience: "Config audience" })
    assert_equal({ kind: "explainer", audience: "Board audience", purpose: [ "Outcome" ] }, r)
    assert_raises(Roast::ReviewError) { WalkthroughRoast.review({}, { audience: "x" }) }
    assert_raises(Roast::ReviewError) { WalkthroughRoast.review({ "review" => { "purpose" => [ "o" ] } }) }
  end

  def test_settings_carry_change_md_review_defaults
    Dir.mktmpdir do |dir|
      write_change(dir, { "kind" => "demo", "audience" => "Ops" })
      assert_equal({ kind: "demo", audience: "Ops" }, WalkthroughRoast.settings(dir)[:review])
    end
  end

  def round(dir, n, issues, responses = nil, score: 5)
    File.write(File.join(dir, "round-#{n}.json"),
               JSON.generate("score" => score, "summary" => "", "issues" => issues, "thirty_second_test" => { "verdict" => "pass", "reason" => "" }, "purpose_test" => []))
    File.write(File.join(dir, "round-#{n}.response.json"), JSON.generate("responses" => responses)) if responses
  end

  def issue(priority, problem = "Toast hides CTA") = { "priority" => priority, "screen" => "s", "problem" => problem, "fix" => "f" }

  def test_gate_reads_only_the_latest_round
    Dir.mktmpdir do |dir|
      assert_nil WalkthroughRoast.gate!(dir)
      round(dir, 1, [ issue("P0") ])
      assert_raises(WalkthroughRoast::OpenFindingsError) { WalkthroughRoast.gate!(dir) }
      assert_nil WalkthroughRoast.gate!(dir, allow: true)
      round(dir, 2, [ issue("P2") ], score: 9)
      assert_nil WalkthroughRoast.gate!(dir)
    end
  end

  def test_accepted_blocker_stays_open_rebutted_one_closes
    Dir.mktmpdir do |dir|
      round(dir, 1, [ issue("P1"), issue("P1", "Caption hides nav") ],
            [ { "screen" => "s", "problem" => "Toast hides", "verdict" => "accept" }, { "screen" => "s", "problem" => "Caption hides", "verdict" => "rebut" } ])
      open = WalkthroughRoast.open_blockers(Roast.load_history(dir))
      assert_equal [ "Toast hides CTA" ], open.map { |i| i["problem"] }
    end
  end

  # A rebuttal clears only the issue its problem text names, whatever its position.
  def test_rebuttal_matches_by_problem_not_position
    swapped = [ { "screen" => "s", "problem" => "Caption hides", "verdict" => "rebut" },
                { "screen" => "s", "problem" => "Toast hides", "verdict" => "accept" } ]
    cases = {
      "swapped order" => [ swapped, [ "Toast hides CTA" ] ],
      "positional, no problem text" => [ [ { "screen" => "s", "verdict" => "rebut" }, { "screen" => "s", "verdict" => "accept" } ], [ "Caption hides nav" ] ],
      "positional, wrong problem text" => [ [ { "screen" => "s", "problem" => "Something else", "verdict" => "rebut" } ], [ "Toast hides CTA", "Caption hides nav" ] ],
      "wrong screen" => [ [ { "screen" => "t", "problem" => "Toast hides", "verdict" => "rebut" } ], [ "Toast hides CTA", "Caption hides nav" ] ]
    }
    cases.each do |name, (responses, expected)|
      Dir.mktmpdir do |dir|
        round(dir, 1, [ issue("P1"), issue("P1", "Caption hides nav") ], responses)
        assert_equal expected, WalkthroughRoast.open_blockers(Roast.load_history(dir)).map { |i| i["problem"] }, name
      end
    end
  end

  def test_transcript_lists_scene_timing_wpm_and_captions
    board = { "scenes" => [ { "id" => "a", "narration" => { "text" => "One two three four" } }, { "id" => "b" } ] }
    manifest = { "timeline" => { "fps" => 10 },
                 "scenes" => [ { "id" => "a", "start_frame" => 0, "frames" => 20 }, { "id" => "b", "start_frame" => 20, "frames" => 5 } ] }
    text = WalkthroughRoast.transcript(board, manifest, "1\n00:00:00,000 --> 00:00:01,000\nOne two\n")
    assert_includes text, "a [0.0s to 2.0s, 120 wpm]: One two three four"
    refute_includes text, "b ["
    assert_includes text, "Caption cues:"
  end

  def test_decide_converges_only_with_target_and_no_blockers
    Dir.mktmpdir do |dir|
      refute WalkthroughRoast.decide(dir)[:stop]
      round(dir, 1, [ issue("P1") ], score: 9)
      refute WalkthroughRoast.decide(dir)[:stop]
      round(dir, 2, [ issue("P2") ], score: 8.5)
      verdict = WalkthroughRoast.decide(dir)
      assert verdict[:stop] && verdict[:converged]
      round(dir, 3, [ issue("P2") ], score: 8.4)
      refute WalkthroughRoast.decide(dir)[:stop]
    end
  end

  def test_decide_stops_at_spend_cap_and_round_cap_without_converging
    Dir.mktmpdir do |dir|
      round(dir, 1, [ issue("P1") ])
      refute WalkthroughRoast.decide(dir, cap_usd: 1.0)[:stop]
      WalkthroughRoast.record_spend(dir, 1, 1.0)
      verdict = WalkthroughRoast.decide(dir, cap_usd: 1.0)
      assert verdict[:stop]
      refute verdict[:converged]
      assert_includes verdict[:reason], "spend cap"
    end
  end

  def test_decide_stops_at_the_round_cap
    Dir.mktmpdir do |dir|
      round(dir, 4, [ issue("P1") ])
      assert_includes WalkthroughRoast.decide(dir, cap_usd: 99)[:reason], "round cap 4"
    end
  end

  # The reset line names what changed and the rule that tripped, so a fresh
  # round-1 after a rework is never mistaken for a lost round.
  def test_change_summary_names_changed_scenes_and_threshold
    was = { "a" => "k1", "b" => "k2", "c" => "k3", "d" => "k4" }
    line = WalkthroughRoast.change_summary(was, { "a" => "n1", "b" => "n2", "c" => "k3", "d" => "k4" })
    assert_includes line, "2 of 4 scenes re-keyed (a, b)"
    assert_includes line, "threshold: half the scenes"
    line = WalkthroughRoast.change_summary(was, { "a" => "k1", "b" => "k2", "c" => "k3", "e" => "k5" })
    assert_includes line, "added e"
    assert_includes line, "dropped d"
    assert_includes WalkthroughRoast.change_summary(nil, was), "no scene baseline"
  end

  # A reworked film starts a fresh round count: the old loop's cap verdict
  # no longer applies once most scenes re-key, but a one-scene fix keeps it.
  def test_material_scene_change_resets_the_round_cap
    Dir.mktmpdir do |dir|
      film = { "a" => "k1", "b" => "k2", "c" => "k3" }
      WalkthroughRoast.record_scenes(dir, film)
      round(dir, 4, [ issue("P1") ], score: 7)
      assert_includes WalkthroughRoast.decide(dir, cap_usd: 99)[:reason], "round cap 4"
      assert_nil WalkthroughRoast.rescope!(dir, film.merge("a" => "k1-fixed"))
      assert_includes WalkthroughRoast.decide(dir, cap_usd: 99)[:reason], "round cap 4"
      archive = WalkthroughRoast.rescope!(dir, { "a" => "n1", "b" => "n2", "c" => "k3" })
      assert File.file?(File.join(archive, "round-4.json"))
      verdict = WalkthroughRoast.decide(dir, cap_usd: 99)
      refute verdict[:stop]
      assert_equal "no roast round yet", verdict[:reason]
      assert_nil WalkthroughRoast.gate!(dir, require_roast: false)
      WalkthroughRoast.record_scenes(dir, { "x" => "1" })
      assert_equal "2", File.basename(WalkthroughRoast.rescope!(dir, { "y" => "1" }))
    end
  end

  # Re-keyed scenes keep their ids, so earlier issues and rebuttals still reach the critic.
  def test_a_reset_carries_rebuttals_for_surviving_scenes
    Dir.mktmpdir do |dir|
      WalkthroughRoast.record_scenes(dir, { "a" => "k1", "b" => "k2", "c" => "k3" })
      kept = { "priority" => "P1", "screen" => "a", "problem" => "Toast hides CTA", "fix" => "f" }
      gone = { "priority" => "P1", "screen" => "c", "problem" => "Old nitpick", "fix" => "f" }
      round(dir, 2, [ kept, gone ], [ { "screen" => "a", "problem" => "Toast hides CTA", "verdict" => "rebut" }, { "screen" => "c", "problem" => "Old nitpick", "verdict" => "rebut" } ])
      assert WalkthroughRoast.rescope!(dir, { "a" => "n1", "b" => "n2" })
      assert_empty Roast.load_history(dir)
      carried = WalkthroughRoast.history(dir)
      assert_equal 1, carried.size
      assert_equal [ "Toast hides CTA" ], carried.first[:critic]["issues"].map { |i| i["problem"] }
      assert_equal "rebut", carried.first[:response]["responses"].first["verdict"]
      round(dir, 1, [ issue("P2") ])
      assert_equal 2, WalkthroughRoast.history(dir).size
      assert_equal 2, Roast.next_round(dir)
    end
  end

  # A capped loop roasted before scene tracking can still restart.
  def test_a_legacy_ledger_restarts_once_on_changed_content_else_takes_a_baseline
    Dir.mktmpdir do |dir|
      round(dir, 4, [ issue("P1") ], score: 7)
      WalkthroughRoast.record_content(dir, 4, "c1")
      film = { "a" => "k1" }
      assert_nil WalkthroughRoast.rescope!(dir, film, content: "c1")
      assert_equal film, WalkthroughRoast.ledger(dir)["scenes"]
    end
    Dir.mktmpdir do |dir|
      round(dir, 4, [ issue("P1") ], score: 7)
      WalkthroughRoast.record_content(dir, 4, "c1")
      assert WalkthroughRoast.rescope!(dir, { "a" => "k2" }, content: "c2")
      assert_equal "no roast round yet", WalkthroughRoast.decide(dir, cap_usd: 99)[:reason]
    end
  end

  def test_an_unreadable_ledger_is_never_rescoped
    Dir.mktmpdir do |dir|
      round(dir, 1, [ issue("P2") ])
      File.write(File.join(dir, WalkthroughRoast::LEDGER), "{")
      assert_nil WalkthroughRoast.rescope!(dir, { "a" => "k" }, content: "c")
      assert_includes WalkthroughRoast.decide(dir)[:reason], "spend ledger unreadable"
    end
  end

  def test_capped_marker_ends_the_loop
    Dir.mktmpdir do |dir|
      round(dir, 1, [ issue("P2") ])
      WalkthroughRoast.mark_capped(dir)
      assert WalkthroughRoast.decide(dir)[:stop]
    end
  end

  def test_spent_sums_recorded_rounds
    Dir.mktmpdir do |dir|
      assert_in_delta 0, WalkthroughRoast.spent(dir)
      WalkthroughRoast.record_spend(dir, 1, 0.25)
      WalkthroughRoast.record_spend(dir, 2, 0.5)
      assert_in_delta 0.75, WalkthroughRoast.spent(dir)
    end
  end

  def test_unreadable_ledger_fails_closed_as_cap_reached
    Dir.mktmpdir do |dir|
      round(dir, 1, [ issue("P2") ], score: 7)
      ledger = File.join(dir, "spend.json")
      File.write(ledger, "{not json")
      verdict = WalkthroughRoast.decide(dir)
      assert verdict[:stop]
      refute verdict[:converged]
      assert_includes verdict[:reason], "spend ledger unreadable"
      File.write(ledger, "[1, 2]")
      assert_includes WalkthroughRoast.decide(dir)[:reason], "spend ledger unreadable"
      File.write(ledger, '{"rounds": 5}')
      assert WalkthroughRoast.capped?(dir)
    end
  end

  def test_gate_refuses_an_unfinished_loop_but_a_cap_releases_it
    Dir.mktmpdir do |dir|
      round(dir, 1, [ issue("P2") ], score: 7)
      assert_raises(WalkthroughRoast::OpenFindingsError) { WalkthroughRoast.gate!(dir) }
      WalkthroughRoast.mark_capped(dir)
      assert_nil WalkthroughRoast.gate!(dir)
    end
  end

  def write_change(dir, roast)
    File.write(File.join(dir, "CHANGE.md"), "---\n#{JSON.generate({ "change_config" => { "design" => { "roast" => roast } } })}\n---\n")
  end

  def test_settings_default_with_no_change_md
    Dir.mktmpdir do |dir|
      s = WalkthroughRoast.settings(dir)
      assert_equal({ roast: true, max_usd: 2.0, target: 8.5, rounds: 4, model: "gpt-6.1-sol", review: {} }, s)
    end
  end

  def test_settings_read_change_md_and_flags_win
    Dir.mktmpdir do |dir|
      write_change(dir, { "auto" => false, "target" => 7, "rounds" => 2, "max_usd" => 1.25, "model" => "m-cfg" })
      s = WalkthroughRoast.settings(dir)
      assert_equal({ roast: false, max_usd: 1.25, target: 7.0, rounds: 2, model: "m-cfg", review: {} }, s)
      s = WalkthroughRoast.settings(dir, roast: true, max_usd: 3.0, target: 9.0, rounds: 5, model: "m-flag")
      assert_equal({ roast: true, max_usd: 3.0, target: 9.0, rounds: 5, model: "m-flag", review: {} }, s)
      assert_equal "gpt-6.1-terra", WalkthroughRoast.settings(dir, model: "terra")[:model]
      s = WalkthroughRoast.settings(dir, roast: nil, max_usd: nil)
      assert_equal 1.25, s[:max_usd]
      refute s[:roast]
    end
  end

  def test_no_roast_flag_wins_over_auto_true
    Dir.mktmpdir do |dir|
      write_change(dir, { "auto" => true })
      refute WalkthroughRoast.settings(dir, roast: false)[:roast]
    end
  end

  def test_settings_reject_a_malformed_block
    Dir.mktmpdir do |dir|
      write_change(dir, { "rounds" => "many" })
      assert_raises(DesignConfig::Error) { WalkthroughRoast.settings(dir) }
    end
  end

  def test_decide_honors_configured_target_and_rounds
    Dir.mktmpdir do |dir|
      round(dir, 1, [ issue("P2") ], score: 7)
      refute WalkthroughRoast.decide(dir)[:stop]
      assert WalkthroughRoast.decide(dir, target: 7)[:converged]
      round(dir, 2, [ issue("P1") ], score: 6)
      assert_includes WalkthroughRoast.decide(dir, rounds: 2)[:reason], "round cap 2"
    end
  end
end
