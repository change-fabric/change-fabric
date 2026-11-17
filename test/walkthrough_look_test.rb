# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/walkthrough_look"
require_relative "../scripts/walkthrough_ffmpeg"
require_relative "../scripts/walkthrough_storyboard"

# The board `look` (opt-in grain and vignette) and the default-on depth
# tokens (shadows and a background gradient in both themes).
class WalkthroughLookTest < Minitest::Test
  MEASURED = { "input_i" => "-23.10", "input_tp" => "-4.20", "input_lra" => "6.30",
               "input_thresh" => "-33.40", "target_offset" => "0.15" }.freeze

  def plan
    { fps: 30, width: 1920, height: 1080, total_ms: 2000, cursor_png: "/work/r/cursor.png", srt: "/work/r/captions.srt",
      output: "/work/r/walkthrough.mp4", music: nil, duck_spans: [],
      scenes: [ { id: "one", frames_dir: "/work/f/a", frames: 60, start_frame: 0, transition: { "type" => "cut", "ms" => 0 },
                  cursor: [], hero_still: false, audio: nil, offset_ms: 0 } ] }
  end

  def vout(argv) = argv[argv.index("-filter_complex") + 1].split(";").find { |part| part.end_with?("[vout]") }

  def test_absent_and_off_look_plan_nothing
    assert_nil WalkthroughLook.plan({})
    assert_nil WalkthroughLook.plan({ "look" => { "grain" => 0, "vignette" => false } })
    assert_nil WalkthroughLook.plan({ "look" => {} })
  end

  def test_errors
    assert_empty WalkthroughLook.errors(nil)
    assert_empty WalkthroughLook.errors({ "grain" => 6, "vignette" => true })
    assert_empty WalkthroughLook.errors({ "vignette" => 0.5 })
    assert_includes WalkthroughLook.errors("grainy"), "look must be an object"
    assert_includes WalkthroughLook.errors({ "grain" => 40 }), "look.grain must be an integer from 0 to 30"
    assert_includes WalkthroughLook.errors({ "grain" => 2.5 }), "look.grain must be an integer from 0 to 30"
    assert_includes WalkthroughLook.errors({ "vignette" => 3 }), "look.vignette must be true, false, or an angle in radians above 0 and at most 1.5708"
    assert_includes WalkthroughLook.errors({ "blur" => 1 }), "look.blur is not a known field (grain, vignette)"
  end

  def test_storyboard_validate_reports_look_errors
    assert_includes WalkthroughStoryboard.validate({ "look" => { "grain" => -1 } }), "look.grain must be an integer from 0 to 30"
    refute(WalkthroughStoryboard.validate({ "look" => { "grain" => 6 } }).any? { |e| e.start_with?("look") })
  end

  def test_invalid_look_plans_nothing
    assert_nil WalkthroughLook.plan({ "look" => { "grain" => 99 } })
  end

  def test_filter_has_fixed_seed_and_default_angle
    look = WalkthroughLook.plan({ "look" => { "grain" => 6, "vignette" => true } })
    assert_equal({ grain: 6, vignette: WalkthroughLook::DEFAULT_ANGLE }, look)
    assert_equal "noise=alls=6:allf=t:all_seed=#{WalkthroughLook::SEED},vignette=angle=0.6283:eval=init",
                 WalkthroughLook.filter(look)
    assert_equal "vignette=angle=0.5000:eval=init", WalkthroughLook.filter(WalkthroughLook.plan({ "look" => { "vignette" => 0.5 } }))
    assert_equal "noise=alls=4:allf=t:all_seed=#{WalkthroughLook::SEED}", WalkthroughLook.filter({ grain: 4 })
  end

  def test_argv_without_look_is_unchanged
    base = WalkthroughFfmpeg.pass2(plan, MEASURED)
    assert_equal "[v0]format=yuv420p[vout]", vout(base)
    assert_equal base, WalkthroughFfmpeg.pass2(plan.merge(look: nil), MEASURED)
  end

  def test_argv_with_look_adds_grain_and_vignette_before_captions
    look = { grain: 6, vignette: WalkthroughLook::DEFAULT_ANGLE }
    argv = WalkthroughFfmpeg.pass2(plan.merge(look: look, burn_captions: true), MEASURED)
    assert_equal "[v0]#{WalkthroughLook.filter(look)},subtitles=filename='/work/r/captions.srt',format=yuv420p[vout]", vout(argv)
  end

  def test_depth_tokens_in_both_themes
    %i[light dark].each do |theme|
      css = WalkthroughDiagram.depth_css(WalkthroughDiagram.palette(nil, theme), theme)
      %w[--shadow-1 --shadow-2 --bg-from --bg-to --bg-gradient].each { |t| assert_includes css, "#{t}:", "#{theme} #{t}" }
      assert_match(/--bg-gradient: linear-gradient\(180deg, var\(--bg-from\), var\(--bg-to\)\)/, css)
    end
    dark = WalkthroughDiagram.depth_css(WalkthroughDiagram::PALETTE_DARK, :dark)
    light = WalkthroughDiagram.depth_css(WalkthroughDiagram::PALETTE, :light)
    refute_equal dark, light
    assert_includes dark, "--bg-to: #{WalkthroughDiagram::PALETTE_DARK['surface']}"
  end

  def test_pages_consume_depth_tokens
    html = WalkthroughDiagram.screen({ "id" => "d", "diagram" => { "nodes" => [], "edges" => [] } })
    assert_includes html, "--bg-gradient:"
    runtime = File.read(File.join(__dir__, "..", "scripts", "walkthrough_element.js"))
    assert_includes runtime, "var(--bg-gradient"
    assert_includes runtime, "var(--shadow-2"
  end
end
