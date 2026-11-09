# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/walkthrough_render"

# The capture records a pointer position on every frame, so the drawn track
# must drop it where no step puts the pointer to work.
class WalkthroughRenderCursorTest < Minitest::Test
  TRACK = [ { "frame" => 1, "x" => 640, "y" => 360, "down" => false } ].freeze

  def setup
    @dir = Dir.mktmpdir
    @run = WalkthroughRender::Run.new(@dir, board: { "scenes" => [] }, out: StringIO.new)
  end

  def teardown = FileUtils.rm_rf(@dir)

  def drawn(scene) = @run.drawn_cursor({ scene: scene, cursor: TRACK })

  def test_a_diagram_scene_never_draws_a_cursor
    assert_empty drawn("kind" => "diagram", "interactions" => [ { "t_ms" => 0, "op" => "move", "target" => "#x" } ])
  end

  def test_a_screen_scene_without_steps_draws_no_cursor
    assert_empty drawn("screen" => { "html" => "screens/a.html" })
  end

  def test_key_and_wait_steps_do_not_place_the_pointer
    steps = [ { "t_ms" => 0, "op" => "wait", "duration_ms" => 500 }, { "t_ms" => 600, "op" => "key", "keys" => "Enter" } ]
    assert_empty drawn("screen" => { "html" => "screens/a.html" }, "interactions" => steps)
  end

  def test_a_screen_scene_with_a_pointer_step_keeps_its_track
    steps = [ { "t_ms" => 0, "op" => "click", "target" => "#go" } ]
    assert_equal TRACK, drawn("screen" => { "html" => "screens/a.html" }, "interactions" => steps)
  end

  def test_a_live_scene_keeps_its_recorded_track
    assert_equal TRACK, drawn("screen" => { "url" => "https://app.localhost/" })
  end

  def test_an_empty_track_parks_the_overlay_off_canvas
    assert_equal WalkthroughFfmpeg::OFFSCREEN.to_s, WalkthroughFfmpeg.chain(WalkthroughFfmpeg.runs([], "x"))
  end
end
