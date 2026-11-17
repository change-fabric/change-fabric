# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../scripts/change_docker"
require_relative "../scripts/walkthrough_ffmpeg"
require_relative "../scripts/walkthrough_look"

# Real pass 2 renders in the pinned FFmpeg image. A board with no `look` and
# one with `look: { grain: 0, vignette: false }` decode to identical frames
# (look-off parity), and grain on its fixed seed renders the same frames
# twice while still changing the picture.
class WalkthroughLookDockerTest < Minitest::Test
  FPS = 30
  FRAMES = 15
  MEASURED = { "input_i" => "-23.10", "input_tp" => "-4.20", "input_lra" => "6.30",
               "input_thresh" => "-33.40", "target_offset" => "0.15" }.freeze

  def setup
    skip "docker not available" unless ChangeDocker.available?
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, "f"))
    out, status = ffmpeg([ "-hide_banner", "-v", "error", "-y", "-f", "lavfi", "-i", "color=c=0x334155:s=128x72:r=#{FPS}",
                           "-frames:v", FRAMES.to_s, "-start_number", "1", "f/%06d.png" ])
    skip "could not make fixtures: #{out.lines.last(3).join}" unless status.success?
    FileUtils.cp(File.join(__dir__, "..", "scripts", "vendor", "walkthrough", "cursor.png"), @dir)
    File.write(File.join(@dir, "c.srt"), "1\n00:00:00,000 --> 00:00:00,400\nhi\n")
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def ffmpeg(args, entrypoint: nil)
    argv = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, args: args, entrypoint: entrypoint,
                                    mounts: { @dir => "/work" }, workdir: "/work")
    Open3.capture2e("timeout", "120", *argv)
  end

  def plan(board, name)
    look = WalkthroughLook.plan(board)
    p = { fps: FPS, width: 128, height: 72, total_ms: FRAMES * 1000 / FPS, cursor_png: "/work/cursor.png", srt: "/work/c.srt",
          output: "/work/#{name}.mp4", music: nil, duck_spans: [],
          scenes: [ { id: "s", frames_dir: "/work/f", frames: FRAMES, start_frame: 0, transition: { "type" => "cut", "ms" => 0 },
                      cursor: [], hero_still: false, audio: nil, offset_ms: 0 } ] }
    look ? p.merge(look: look) : p
  end

  # The decoded video frames' md5s, one line per frame.
  def frames(board, name)
    out, status = ffmpeg(WalkthroughFfmpeg.pass2(plan(board, name), MEASURED))
    assert status.success?, out.lines.last(10).join
    out, status = ffmpeg([ "-v", "error", "-i", "#{name}.mp4", "-map", "0:v", "-f", "framemd5", "-" ])
    assert status.success?, out
    out.lines.grep_v(/\A#/)
  end

  def test_look_off_renders_frame_identical_to_no_look
    none = frames({}, "none")
    off = frames({ "look" => { "grain" => 0, "vignette" => false } }, "off")
    refute_empty none
    assert_equal none, off
  end

  def test_grain_is_seeded_and_visible
    look = { "look" => { "grain" => 8, "vignette" => true } }
    one = frames(look, "one")
    assert_equal one, frames(look, "two"), "the same seed renders the same frames"
    refute_equal frames({}, "plain"), one, "the look changes the picture"
  end
end
