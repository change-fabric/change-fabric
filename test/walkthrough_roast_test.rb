# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../scripts/walkthrough_roast"

class WalkthroughRoastTest < Minitest::Test
  def test_keyframes_take_start_middle_end_and_first_overlay_frames
    entries = [ { "id" => "a", "frames" => 30, "start_frame" => 0 }, { "id" => "b", "frames" => 10, "start_frame" => 30 } ]
    keys = WalkthroughRoast.keyframes(entries, { "a" => { "#toast" => 20, "#late" => 99 } })
    assert_equal [ [ "a", "start", 0 ], [ "a", "middle", 15 ], [ "a", "overlay-toast", 20 ], [ "a", "end", 29 ],
                   [ "b", "start", 30 ], [ "b", "middle", 35 ], [ "b", "end", 39 ] ], keys.map { |k| [ k[:scene], k[:label], k[:frame] ] }
    assert_equal "003-a-overlay-toast.jpg", WalkthroughRoast.keyframe_name(2, keys[2])
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
      assert_equal({ roast: true, max_usd: 2.0, target: 8.5, rounds: 4, model: Roast::MODEL, review: {} }, s)
    end
  end

  def test_settings_read_change_md_and_flags_win
    Dir.mktmpdir do |dir|
      write_change(dir, { "auto" => false, "target" => 7, "rounds" => 2, "max_usd" => 1.25, "model" => "m-cfg" })
      s = WalkthroughRoast.settings(dir)
      assert_equal({ roast: false, max_usd: 1.25, target: 7.0, rounds: 2, model: "m-cfg", review: {} }, s)
      s = WalkthroughRoast.settings(dir, roast: true, max_usd: 3.0, target: 9.0, rounds: 5, model: "m-flag")
      assert_equal({ roast: true, max_usd: 3.0, target: 9.0, rounds: 5, model: "m-flag", review: {} }, s)
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
