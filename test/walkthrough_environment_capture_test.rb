# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "tmpdir"
require_relative "../scripts/change_docker"
require_relative "../scripts/prototype_capture"
require_relative "../scripts/walkthrough_storyboard"

# The desktop fixture renders deterministically: two captures of the same
# environment scene in the pinned browserless container produce identical
# frames, and the scripted motion (extract progress, elevation, terminal
# pacing) actually changes the picture.
class WalkthroughEnvironmentCaptureTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/walkthrough/desktop", __dir__)

  def test_two_captures_produce_identical_frames
    skip "docker not available" unless ChangeDocker.available?

    Dir.mktmpdir do |root|
      FileUtils.cp_r("#{FIXTURE}/.", root)
      board = WalkthroughStoryboard.load(File.join(root, "storyboard.json"))
      ChangeDocker.with_browserless(network: nil) do |session|
        %w[extract install].each do |id|
          scene = board["scenes"].find { |s| s["id"] == id }
          a, b = 2.times.map { |n| hashes(session, board, scene, root, File.join(root, "run-#{id}-#{n}")) }
          refute_empty a
          assert_equal a, b, "#{id}: frames differ between captures"
          refute_equal a.first, a.last, "#{id}: the scripted motion changes the picture"
        end
      end
    end
  end

  private

  def hashes(session, board, scene, root, out)
    prep = PrototypeCapture.prepare(board, scene, root, {})
    PrototypeCapture.capture(session: session, html: PrototypeCapture.inline_screen(prep[:html_path], root: root),
                             interactions: scene["interactions"], duration_ms: PrototypeCapture.scene_duration(scene), out_dir: out,
                             state: prep[:state], prng_seed: prep[:prng_seed], viewport: board["viewport"], fps: board["fps"], label: scene["id"])
    Dir[File.join(out, "*.png")].sort.map { |f| Digest::SHA256.file(f).hexdigest }
  end
end
