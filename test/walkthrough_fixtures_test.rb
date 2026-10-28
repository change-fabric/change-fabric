# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "json"
require_relative "../scripts/design_tokens"
require_relative "../scripts/prototype_capture"
require_relative "../scripts/walkthrough_cache"
require_relative "../scripts/walkthrough_ffmpeg"
require_relative "../scripts/walkthrough_storyboard"

# The two cf:walkthrough fixtures are static input: a greenfield PRD with no
# design system, and an existing product with DESIGN.md, tokens.css, and a
# brand mark. Both must validate, render-md must match the committed
# storyboard.md, and the FFmpeg pass 2 argv built from each timeline must
# match the committed ffmpeg_argv.json. No docker and no network here.
#
# Regenerate a golden only after a deliberate change:
#   WRITE_GOLDEN=1 bundle exec rake test TEST=test/walkthrough_fixtures_test.rb
class WalkthroughFixturesTest < Minitest::Test
  ROOT = File.join(__dir__, "fixtures", "walkthrough")
  FIXTURES = %w[greenfield existing].freeze
  MEASURED = { "input_i" => "-20.00", "input_tp" => "-3.00", "input_lra" => "5.00",
               "input_thresh" => "-30.00", "target_offset" => "0.00" }.freeze

  CACHE = "/work/.cache"

  def dir(name) = File.join(ROOT, name)

  def path(name, *parts) = File.join(dir(name), *parts)

  def board(name) = WalkthroughStoryboard.load(path(name, "storyboard.json"))

  # A render plan built from the storyboard alone, with container paths
  # derived from the authored deps, so the argv depends only on committed
  # input. The cursor path is empty because no frames are captured in CI.
  def plan(name)
    b = board(name)
    line = WalkthroughStoryboard.timeline(b)
    by_id = WalkthroughStoryboard.scenes(b).to_h { |s| [ s["id"], s ] }
    render = "#{CACHE}/render/fixture"
    { fps: line["fps"], width: b.dig("viewport", "w"), height: b.dig("viewport", "h"), total_ms: line["total_ms"],
      cursor_png: "#{render}/cursor.png", srt: "#{render}/captions.srt", output: "#{render}/walkthrough.mp4",
      music: b["music"] && { path: "#{CACHE}/music/fixture.mp3", gain_db: b.dig("music", "gain_db") },
      duck_spans: [],
      scenes: line["scenes"].map do |entry|
        scene = by_id.fetch(entry["id"])
        { id: entry["id"], frames_dir: "#{CACHE}/frames/#{scene.dig('deps', 'frames_key') || entry['id']}",
          frames: entry["frames"], start_frame: entry["start_frame"], transition: entry["transition"], cursor: [],
          hero_still: scene["hero_still"] == true, audio: "#{CACHE}/audio/#{scene.dig('deps', 'audio_key')}.mp3",
          offset_ms: (entry["start_frame"] * 1000.0 / line["fps"]).round }
      end }
  end

  FIXTURES.each do |name|
    define_method("test_#{name}_validates") do
      assert_empty WalkthroughStoryboard.validate(board(name), root: dir(name))
    end

    define_method("test_#{name}_render_md_matches_committed") do
      assert_equal File.read(path(name, "storyboard.md")), WalkthroughStoryboard.render_md(board(name))
    end

    define_method("test_#{name}_ffmpeg_argv_golden") do
      golden = path(name, "ffmpeg_argv.json")
      argv = WalkthroughFfmpeg.pass2(plan(name), MEASURED)
      File.write(golden, "#{JSON.pretty_generate(argv)}\n") if ENV["WRITE_GOLDEN"]
      assert_equal JSON.parse(File.read(golden)), argv
    end

    define_method("test_#{name}_digests_match_sources") do
      b = board(name)
      b["source_docs"].each do |doc|
        assert_equal Digest::SHA256.file(path(name, doc["path"])).hexdigest, doc["sha256"], doc["path"]
      end
      assert_equal Digest::SHA256.file(path(name, "screens", "tokens.css")).hexdigest, b["tokens_css_sha256"]
    end

    define_method("test_#{name}_screens_are_capturable") do
      WalkthroughStoryboard.scenes(board(name)).each do |scene|
        html = PrototypeCapture.inline_screen(path(name, scene.dig("screen", "html")))
        refute_match(%r{https?://}, html.gsub("http://www.w3.org/2000/svg", ""), scene["id"])
      end
    end
  end

  def test_greenfield_has_cross_scene_state
    later = WalkthroughStoryboard.scenes(board("greenfield")).find { |s| s.dig("store", "from_scene") }
    refute_nil later
    form = File.read(path("greenfield", "screens", "lend-book.html"))
    list = File.read(path("greenfield", later.dig("screen", "html")))
    assert_match(/data-cf-submit="loans"/, form)
    assert_match(/data-cf-list="loans"/, list)
  end

  def test_greenfield_has_no_design_system
    refute File.exist?(path("greenfield", "DESIGN.md"))
  end

  def test_existing_design_md_lints_clean
    design = File.read(path("existing", "DESIGN.md"))
    tokens = File.read(path("existing", "tokens.css"))
    assert_empty DesignTokens.lint(design, tokens).map(&:to_s)
    assert_equal tokens, File.read(path("existing", "screens", "tokens.css"))
    assert_equal Digest::SHA256.hexdigest(design), board("existing")["design_md_sha256"]
  end

  def test_existing_ships_brand_mark_and_conventions
    assert File.file?(path("existing", "screens", "assets", "harborline.svg"))
    assert File.file?(path("existing", "conventions.md"))
  end
end
