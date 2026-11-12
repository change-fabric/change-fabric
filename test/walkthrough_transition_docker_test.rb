# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../scripts/change_docker"
require_relative "../scripts/walkthrough_transition"

# The moving transitions rendered for real in the pinned FFmpeg: on two
# solid colours every pixel of every frame comes from exactly one page
# (no blend, no alpha), split by one straight edge that only advances; on
# two ramps the push moves both pages, the old one out left and the new one
# in from the right, rather than wiping over a still page.
class WalkthroughTransitionDockerTest < Minitest::Test
  W = 64
  H = 32
  FPS = 10
  # Sources are generated in RGB, so the planar-RGB transition keeps them exact.
  RED = [ 255, 0, 0 ].freeze
  BLUE = [ 0, 0, 255 ].freeze

  def setup
    skip "docker not available" unless ChangeDocker.available?
  end

  # rgb24 frames of A then B through one xfade, planar RGB so no chroma
  # subsampling blurs the edge.
  def render(type, a_src, b_src, a_post = "", b_post = a_post)
    xfade = WalkthroughTransition.xfade({ "type" => type, "ms" => 1000, "ease" => "linear" }, duration: 1, offset: 1)
    Dir.mktmpdir do |dir|
      graph = "[0]format=gbrp[a];[1]format=gbrp[b];[a][b]#{xfade},format=rgb24"
      args = [ "-v", "error", "-y", "-f", "lavfi", "-i", "#{a_src}:s=#{W}x#{H}:r=#{FPS}:d=3#{a_post}", "-f", "lavfi", "-i", "#{b_src}:s=#{W}x#{H}:r=#{FPS}:d=3#{b_post}",
               "-filter_complex", graph, "-f", "rawvideo", "/w/o.rgb" ]
      out, status = Open3.capture2e(*ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, mounts: { dir => "/w" }, args: args))
      assert status.success?, out
      File.binread(File.join(dir, "o.rgb")).bytes.each_slice(3).each_slice(W * H).map { |f| f.each_slice(W).to_a }
    end
  end

  def test_moving_transitions_take_each_pixel_from_exactly_one_page
    { "push" => :x, "slide-left" => :x, "slide-up" => :y }.each do |type, axis|
      frames = render(type, "color=c=red", "color=c=blue", ",format=gbrp")
      shown = frames.map do |rows|
        assert(rows.flatten(1).all? { |px| px == RED || px == BLUE }, "#{type}: a pixel is neither page")
        lines = axis == :x ? rows : rows.transpose
        b = lines.map { |line| line.count(BLUE) }
        assert_equal 1, b.uniq.size, "#{type}: the edge is straight"
        lines.each { |line| assert_equal line.sort_by { |px| px == RED ? 0 : 1 }, line, "#{type}: one edge, the new page on the far side" }
        b.first
      end
      assert_equal 0, shown.first, type
      assert_equal (axis == :x ? W : H), shown.last, type
      assert_equal shown.sort, shown, "#{type}: the new page only advances"
      span = axis == :x ? W : H
      mid = shown.select { |n| n.positive? && n < span }
      assert_operator mid.size, :>=, 5, "#{type}: the move spans the transition"
      mid.each_cons(2) { |p, q| assert_in_delta span / 10.0, q - p, 1, "#{type}: linear ease steps evenly" }
    end
  end

  # Ramps: the old page's value is 2x and the new page's 255 - 2x at
  # source column x, so a column's value names its page and source column.
  def test_push_slides_both_pages
    frames = render("push", "color=c=black", "color=c=black", ",format=gray,geq=lum='X*2'", ",format=gray,geq=lum='255-X*2'")
    moving = frames.find { |rows| (row = rows[H / 2].map(&:first)).first > 20 && row.max > 200 }
    refute_nil moving
    row = moving[H / 2].map(&:first)
    edge = (1...W).find { |x| row[x] > row[x - 1] + 60 }
    refute_nil edge, row.inspect
    s = W - edge
    assert_in_delta s * 2, row[0], 2, "the old page has moved left by s: its column s is at x 0"
    assert_in_delta 255, row[edge], 2, "the new page's column 0 has entered at W - s"
    assert_in_delta 255 - ((W - 1 - edge) * 2), row[W - 1], 2, "and the new page is not stretched or anchored left"
  end
end
