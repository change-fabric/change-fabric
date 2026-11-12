# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../scripts/prototype_capture"

# Real captures in the pinned browserless image come out at the scene's
# viewport, never the container's 800x600 default window, across several
# fresh connections and at dpr 1 and 2.
class PrototypeCaptureViewportDockerTest < Minitest::Test
  PAGE = "<!doctype html><html><body style='margin:0'><p id='size'>size</p></body></html>"

  def setup
    skip "docker not available" unless ChangeDocker.available?
  end

  def test_every_capture_has_the_viewport_size
    ChangeDocker.with_browserless(network: nil) do |session|
      [ { "w" => 640, "h" => 360, "dpr" => 1 }, { "w" => 1024, "h" => 768, "dpr" => 1 }, { "w" => 640, "h" => 360, "dpr" => 2 } ].each do |vp|
        2.times do
          Dir.mktmpdir do |dir|
            PrototypeCapture.capture(session: session, html: PAGE, interactions: [], duration_ms: 100, out_dir: dir,
                                     state: {}, prng_seed: 7, viewport: vp)
            Dir.glob(File.join(dir, "*.png")).each do |f|
              assert_equal PrototypeCapture.frame_size(vp), PngInfo.file_size(f), "#{vp.inspect}: #{File.basename(f)}"
            end
          end
        end
      end
    end
  end
end
