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
    %w[Blank Overlays Cursor contradictions safe-area 1080p cf:fractal cf:usability].each { |w| assert_includes brief, w }
  end

  def round(dir, n, issues, responses = nil)
    File.write(File.join(dir, "round-#{n}.json"),
               JSON.generate("score" => 5, "summary" => "", "issues" => issues, "thirty_second_test" => { "verdict" => "pass", "reason" => "" }))
    File.write(File.join(dir, "round-#{n}.response.json"), JSON.generate("responses" => responses)) if responses
  end

  def issue(priority, problem = "Toast hides CTA") = { "priority" => priority, "screen" => "s", "problem" => problem, "fix" => "f" }

  def test_gate_reads_only_the_latest_round
    Dir.mktmpdir do |dir|
      assert_nil WalkthroughRoast.gate!(dir)
      round(dir, 1, [ issue("P0") ])
      assert_raises(WalkthroughRoast::OpenFindingsError) { WalkthroughRoast.gate!(dir) }
      assert_nil WalkthroughRoast.gate!(dir, allow: true)
      round(dir, 2, [ issue("P2") ])
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
end
