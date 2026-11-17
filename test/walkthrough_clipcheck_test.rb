# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require_relative "../scripts/walkthrough_clipcheck"

class WalkthroughClipcheckTest < Minitest::Test
  VP = { "w" => 1920, "h" => 1080 }.freeze

  def box(id, x, y, w, h, kind: "text", text: id, font_px: 32, overflow: false)
    { "id" => id, "kind" => kind, "text" => text, "x" => x, "y" => y, "w" => w, "h" => h, "font_px" => font_px, "overflow" => overflow }
  end

  def frame(i, boxes) = { "frame" => i, "t_ms" => (i * 1000.0 / 60).round, "boxes" => boxes }

  def data(frames, viewport: VP) = { "viewport" => viewport, "frames" => frames }

  # A centred group filling a comfortable share of the frame.
  def inside = [ box("api", 600, 400, 300, 84, kind: "node"), box("api-label", 640, 420, 220, 40), box("db", 1000, 400, 400, 300, kind: "node") ]

  def test_tokens_carry_the_video_scale_and_safe_area
    t = WalkthroughClipcheck.tokens
    assert_equal 28, t.dig("type_scale", "label")
    assert_equal 40, t.dig("type_scale", "body")
    assert_equal 96, t.dig("type_scale", "statement")
    assert_in_delta 0.05, t.dig("safe_area", "inset")
  end

  def test_tokens_resolve_from_an_installed_skill_root
    Dir.mktmpdir do |dir|
      installed = File.join(dir, "installed")
      FileUtils.mkdir_p(installed)
      File.write(File.join(installed, WalkthroughClipcheck::TOKENS_FILE), "{}")
      assert_equal File.join(installed, WalkthroughClipcheck::TOKENS_FILE),
                   WalkthroughClipcheck.tokens_path([ File.join(dir, "missing"), installed ])
      assert_raises(ArgumentError) { WalkthroughClipcheck.tokens_path([ File.join(dir, "missing") ]) }
    end
    assert_includes WalkthroughClipcheck.token_roots, File.join(Dir.home, ".claude", "skills", "cf:walkthrough", "reference")
  end

  def test_boxes_inside_the_safe_area_pass
    r = WalkthroughClipcheck.check("s1", data([ frame(0, inside), frame(1, inside) ]))
    assert_empty r[:refusals]
  end

  def test_edge_crossing_refuses_and_names_scene_time_and_element
    clip = inside + [ box("long-label", 1700, 500, 260, 40) ]
    r = WalkthroughClipcheck.check("s1", data([ frame(3, clip) ]))
    assert_equal 1, r[:refusals].size
    msg = r[:refusals].first
    assert_includes msg, "s1"
    assert_includes msg, "50 ms"
    assert_includes msg, "long-label"
    assert_includes msg, "frame edge"
  end

  def test_safe_area_crossing_inside_the_frame_refuses
    r = WalkthroughClipcheck.check("s1", data([ frame(0, inside + [ box("near", 1800, 500, 80, 40) ]) ]))
    assert_match(/near.*safe area/, r[:refusals].join)
  end

  # Roast fix 1: the first and last frames pass, a middle frame (mid scale-in)
  # clips, and the check still refuses because it reads every frame.
  def test_mid_frame_clip_refuses_though_first_and_last_pass
    grown = [ box("hero", 40, 300, 1840, 120) ]
    frames = [ frame(0, inside), frame(1, grown), frame(2, inside) ]
    r = WalkthroughClipcheck.check("scale-in", data(frames))
    assert_equal 1, r[:refusals].size
    assert_includes r[:refusals].first, "frame 1"
  end

  def test_internal_overflow_refuses
    r = WalkthroughClipcheck.check("s1", data([ frame(0, inside + [ box("cut", 700, 600, 200, 40, overflow: true) ]) ]))
    assert_match(/cut.*overflows its box/, r[:refusals].join)
  end

  # Roast fix 5: an oversized diagram fit_view would shrink below 28 px is
  # refused and the content is named for a split, never shrunk.
  def test_oversized_diagram_below_the_label_minimum_refuses_and_names_content
    nodes = (1..12).map { |i| box("n#{i}", 100 + (i * 130), 500, 120, 30, text: "Node #{i}", font_px: 14) }
    r = WalkthroughClipcheck.check("oversized", data([ frame(0, nodes) ]))
    refusal = r[:refusals].find { |m| m.include?("below") }
    refute_nil refusal
    assert_includes refusal, "28 px"
    assert_includes refusal, "Node 1"
    assert_includes refusal, "split"
  end

  def test_size_is_measured_in_output_pixels
    small_vp = { "w" => 1280, "h" => 720 }
    # 24 css px at 720p is 36 output px at 1080p: passes.
    r = WalkthroughClipcheck.check("s", data([ frame(0, [ box("a", 400, 300, 300, 40, font_px: 24), box("b", 400, 100, 400, 300, kind: "node") ]) ], viewport: small_vp))
    assert_empty r[:refusals]
  end

  def test_node_boxes_are_not_held_to_the_type_minimum
    r = WalkthroughClipcheck.check("s", data([ frame(0, inside + [ box("n", 700, 700, 100, 50, kind: "node", font_px: 10) ]) ]))
    assert_empty r[:refusals]
  end

  def test_repeat_findings_report_once_per_element
    clip = [ box("x", 1900, 500, 100, 40) ]
    r = WalkthroughClipcheck.check("s", data([ frame(0, clip), frame(1, clip), frame(2, clip) ]))
    assert_equal 1, r[:refusals].size
  end

  def test_overfill_warns_without_refusing
    full = [ box("panel", 100, 60, 1720, 960, kind: "node") ]
    r = WalkthroughClipcheck.check("s", data([ frame(0, full) ]))
    assert_empty r[:refusals]
    assert_match(/fill .* above 70 percent/, r[:warnings].join)
  end

  def test_underfill_warns
    r = WalkthroughClipcheck.check("s", data([ frame(0, [ box("dot", 900, 500, 100, 40) ]) ]))
    assert_match(/below 20 percent/, r[:warnings].join)
  end

  def test_cli_exits_one_on_refusal_and_zero_when_clean
    Dir.mktmpdir do |dir|
      bad = File.join(dir, "bad")
      good = File.join(dir, "good")
      [ bad, good ].each { |d| Dir.mkdir(d) }
      File.write(File.join(bad, WalkthroughClipcheck::BOXES), JSON.generate(data([ frame(0, [ box("x", 1900, 500, 100, 40) ]) ])))
      File.write(File.join(good, WalkthroughClipcheck::BOXES), JSON.generate(data([ frame(0, inside) ])))
      script = File.expand_path("../scripts/walkthrough_clipcheck.rb", __dir__)
      out, status = Open3.capture2e(RbConfig.ruby, script, good)
      assert status.success?, out
      out, status = Open3.capture2e(RbConfig.ruby, script, bad, good)
      assert_equal 1, status.exitstatus
      assert_includes out, "bad"
    end
  end

  def test_scene_dir_without_boxes_is_skipped
    Dir.mktmpdir do |dir|
      assert_nil WalkthroughClipcheck.check_dir(dir)
    end
  end

  def test_summary_is_pass_or_counts_findings_across_scenes
    clean = { refusals: [], warnings: [] }
    dirty = { refusals: %w[a b], warnings: [] }
    assert_equal "PASS (2 scene(s))", WalkthroughClipcheck.summary([ [ "s1", clean ], [ "s2", clean ] ])
    assert_equal "2 finding(s) across 1 scene(s)", WalkthroughClipcheck.summary([ [ "s1", clean ], [ "s2", dirty ] ])
  end
end
