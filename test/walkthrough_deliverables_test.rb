# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../scripts/walkthrough_deliverables"
require_relative "../scripts/walkthrough_draft_board"

class WalkthroughDeliverablesTest < Minitest::Test
  D = WalkthroughDeliverables
  B = WalkthroughDraftBoard

  def setup
    @root = Dir.mktmpdir
    @render = File.join(@root, ".cache", "render", "h")
    FileUtils.mkdir_p(@render)
    @mp4 = File.join(@render, "walkthrough.mp4")
    File.binwrite(@mp4, "one")
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def deliver(kind = "narrated", **kw) = D.deliver(@root, "demo", @mp4, kind: kind, **kw)

  def test_numbering_never_overwrites_an_earlier_draft
    first = deliver("silent", scenes: { "a" => "k1" })
    File.binwrite(@mp4, "two")
    second = deliver(scenes: { "a" => "k1" })
    assert_equal File.join(@root, "demo-draft-01.mp4"), first[:mp4]
    assert_equal File.join(@root, "demo-draft-02.mp4"), second[:mp4]
    assert_equal "one", File.binread(first[:mp4])
    assert_equal "two", File.binread(second[:mp4])
  end

  def test_next_number_follows_the_highest_after_a_gap
    File.binwrite(File.join(@root, "demo-draft-01.mp4"), "x")
    File.binwrite(File.join(@root, "demo-draft-04.mp4"), "x")
    File.binwrite(File.join(@root, "other-draft-09.mp4"), "x")
    assert_equal 5, D.next_number(@root, "demo")
    assert_equal File.join(@root, "demo-draft-05.mp4"), deliver[:mp4]
  end

  def test_the_final_is_unnumbered_and_carries_the_vtt
    File.write(File.join(@render, "walkthrough.vtt"), "WEBVTT\n")
    out = deliver("final")
    assert_equal File.join(@root, "demo-final.mp4"), out[:mp4]
    assert_equal File.join(@root, "demo-final.vtt"), out[:vtt]
    FileUtils.rm_rf(File.join(@root, ".cache"))
    assert_equal "one", File.binread(out[:mp4]), "the deliverable survives a cache delete"
    assert_nil out[:entry]["number"]
  end

  def test_sidecar_records_sha_kind_and_scenes
    deliver("silent", scenes: { "a" => "k1", "b" => "k2" }, provisional: true)
    list = JSON.parse(File.read(D.sidecar(@root, "demo")))["deliveries"]
    assert_equal 1, list.size
    e = list.first
    assert_equal [ 1, "silent", "demo-draft-01.mp4" ], e.values_at("number", "kind", "file")
    assert_equal Digest::SHA256.file(File.join(@root, "demo-draft-01.mp4")).hexdigest, e["sha256"]
    assert_equal({ "a" => "k1", "b" => "k2" }, e["scenes"])
    assert_equal "draft-01: silent; provisional timing (pre-narration); first cut, 2 scenes", e["caption"]
  end

  def test_caption_diffs_against_the_previous_delivery
    deliver("partial", scenes: { "a" => "k1", "b" => "k2", "c" => "p1", "d" => "k4", "e" => "p5" },
                       placeholders: { "c" => "waiting on PR", "e" => "waiting on PR" })
    out = deliver("partial", scenes: { "a" => "k1", "b" => "k2b", "c" => "k3", "d" => "k4b", "e" => "p5" },
                             placeholders: { "e" => "waiting on PR" })
    assert_equal "draft-02: partial; scene c filmed; scenes b and d refilmed; scene e still a placeholder (waiting on PR)",
                 out[:entry]["caption"]
    same = deliver(scenes: { "a" => "k1", "b" => "k2b", "c" => "k3", "d" => "k4b", "e" => "k5" })
    assert_equal "draft-03: narrated; scene e filmed", same[:entry]["caption"]
    again = deliver(scenes: { "a" => "k1", "b" => "k2b", "c" => "k3", "d" => "k4b", "e" => "k5" })
    assert_equal "draft-04: narrated; no picture change", again[:entry]["caption"]
  end

  def test_line_is_absolute_and_fenced_alone
    out = deliver(scenes: { "a" => "k" })
    assert_equal "walkthrough-draft: #{File.join(@root, 'demo-draft-01.mp4')} | draft-01: narrated; first cut, 1 scene", out[:line]
    assert_equal "```\n#{out[:line]}\n```", D.fenced(out[:line])
  end

  def test_unknown_kind_is_refused
    assert_raises(ArgumentError) { deliver("rough") }
  end

  # -- draft boards -----------------------------------------------------------

  def board
    { "fps" => 30, "theme" => "light", "music" => { "prompt" => "calm" },
      "scenes" => [
        { "id" => "a", "order" => 1, "title" => "Sign in", "screen" => { "html" => "screens/a.html" },
          "narration" => { "text" => "one two three four five", "measured_ms" => 0 },
          "interactions" => [ { "op" => "move", "target" => "#a", "t_ms" => 100 },
                              { "op" => "click", "target" => "#b", "at" => { "word" => "three" } },
                              { "op" => "click", "target" => "#c", "at" => { "word" => "five", "fallback_t_ms" => 1500 } } ],
          "timing" => { "min_ms" => 1000, "pad_ms" => 0 } },
        { "id" => "b", "order" => 2, "title" => "Live billing", "pending" => { "reason" => "waiting on PR 12" },
          "screen" => { "url" => "https://example.test" }, "interactions" => [ { "op" => "click", "target" => "#x", "t_ms" => 0 } ],
          "narration" => { "text" => "billing", "measured_ms" => 3000 }, "timing" => { "min_ms" => 1000, "pad_ms" => 200 } }
      ] }
  end

  def test_placeholder_card_names_the_scene_and_reason_for_its_planned_length
    out = B.with_placeholders(board)
    card = out["scenes"][1]
    assert_equal "element", card["kind"]
    beat = card["element"]["beats"].first
    assert_equal [ "card", "Live billing", "Not filmed yet: waiting on PR 12" ], beat.values_at("type", "title", "subtitle")
    assert_equal "light", card["element"]["theme"], "the film's theme"
    assert_equal 3200, card["timing"]["min_ms"]
    refute card.key?("screen")
    refute card.key?("interactions")
    assert_equal "billing", card["narration"]["text"], "the voice line stays"
    assert_equal({ "b" => "waiting on PR 12" }, B.placeholders(out))
    assert_equal "Sign in", board["scenes"][0]["title"], "the source is untouched"
    assert_empty WalkthroughElement.errors(card)
  end

  def test_pending_needs_a_reason
    assert_empty WalkthroughStoryboard.pending_errors({ "pending" => { "reason" => "waiting" } })
    refute_empty WalkthroughStoryboard.pending_errors({ "pending" => {} })
    refute_empty WalkthroughStoryboard.pending_errors({ "pending" => "soon" })
  end

  def test_silent_board_drops_music_and_voice_and_spaces_anchors
    out = B.silent(board)
    refute out.key?("music")
    scene = out["scenes"][0]
    refute scene.key?("narration")
    assert_equal 2000, scene["timing"]["min_ms"], "five words at 2.5 per second"
    ops = scene["interactions"]
    ops.each { |op| refute op.key?("at") }
    assert_equal 667, ops[1]["t_ms"], "evenly spaced: first of two anchors at a third"
    assert_equal 1500, ops[2]["t_ms"], "fallback_t_ms wins"
  end

  def test_silent_element_beats_take_provisional_landings
    scene = { "id" => "e", "order" => 1, "kind" => "element", "narration" => { "text" => "a b c d e f g h i j", "measured_ms" => 4000 },
              "timing" => { "min_ms" => 0 },
              "element" => { "beats" => [ { "id" => "x", "type" => "statement", "lines" => [ "Hi" ], "land_at" => { "word" => "a" },
                                            "exit_at" => { "word" => "c" } },
                                          { "id" => "y", "type" => "statement", "lines" => [ "Yo" ], "land_at" => { "word" => "f" } } ],
                             "steps" => [ { "op" => "count", "id" => "y", "at" => { "word" => "f" }, "from" => 0, "to" => 3 } ] } }
    out = B.silent({ "fps" => 30, "scenes" => [ scene ] })["scenes"][0]
    beats = out["element"]["beats"]
    assert_equal [ 1334, 2667 ], beats.map { |b| b["land_at"] }
    assert_kind_of Integer, beats[0]["exit_at"]
    assert_operator beats[0]["exit_at"], :<, beats[1]["land_at"]
    assert_kind_of Integer, out["element"]["steps"][0]["t_ms"]
  end
end
