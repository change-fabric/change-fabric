# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/diagram_svg"

# Text alignment and size resolve as SVG does: own attribute or inline style,
# else the nearest ancestor's, else the SVG initial value.
class DiagramSvgTest < Minitest::Test
  def text(inner, group: "")
    svg = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><g #{group}>#{inner}</g></svg>)
    DiagramSvg::Document.new(svg).texts.first
  end

  def test_text_anchor_variants
    assert_equal "start", text(%(<text x="1" y="1">a</text>)).anchor
    assert_equal "end", text(%(<text x="1" y="1" text-anchor="end">a</text>)).anchor
    assert_equal "middle", text(%(<text x="1" y="1" style="fill:red; text-anchor: middle">a</text>)).anchor
    assert_equal "middle", text(%(<text x="1" y="1">a</text>), group: %(text-anchor="middle")).anchor
    assert_equal "end", text(%(<text x="1" y="1">a</text>), group: %(style="text-anchor:end")).anchor
    assert_equal "start", text(%(<text x="1" y="1" text-anchor="start">a</text>), group: %(text-anchor="middle")).anchor
  end

  def test_font_size_variants
    assert_equal DiagramSvg::DEFAULT_FONT_SIZE, text(%(<text x="1" y="1">a</text>)).font_size
    assert_equal 12.0, text(%(<text x="1" y="1" font-size="12">a</text>)).font_size
    assert_equal 11.0, text(%(<text x="1" y="1" style="font-size:11px">a</text>)).font_size
    assert_equal 18.0, text(%(<text x="1" y="1">a</text>), group: %(font-size="18")).font_size
  end

  def box(x, y, w, h) = DiagramSvg::Box.new(x: x, y: y, w: w, h: h)
  def seg(x1, y1, x2, y2) = DiagramSvg::Segment.new(x1: x1, y1: y1, x2: x2, y2: y2, command: "L")

  def rand_box(rng) = box(rng.rand(-50.0..50.0), rng.rand(-50.0..50.0), rng.rand(1.0..40.0), rng.rand(1.0..40.0))
  def rand_seg(rng) = seg(*Array.new(4) { rng.rand(-80.0..80.0) })

  # Dense sample points along a segment, the brute-force oracle.
  def samples(s, steps = 1000) = (0..steps).map { |i| t = i.to_f / steps; [ s.x1 + (t * s.dx), s.y1 + (t * s.dy) ] }

  def test_segment_intersects_box_hand_cases
    b = box(0, 0, 10, 10)
    assert seg(-5, 5, 15, 5).intersects_box?(b), "through the middle"
    refute seg(-5, 0, 15, 0).intersects_box?(b), "along the top edge"
    refute seg(-5, -5, 5, 5 - 20).intersects_box?(b), "misses"
    refute seg(-5, 5, 0, 5).intersects_box?(b), "ends on the edge"
    refute seg(10, -5, 10, 15).intersects_box?(b), "along the right edge"
    assert seg(5, 5, 20, 20).intersects_box?(b), "endpoint inside"
    assert seg(5, 5, 5, 5).intersects_box?(b), "point inside"
    refute seg(0, 5, 0, 5).intersects_box?(b), "point on edge"
    assert seg(48, 104, 624, 104).intersects_box?(box(346.8, 97.4, 354 - 346.8, 109.4 - 97.4)), "timeline repro"
  end

  def test_segment_intersects_box_matches_oracle
    rng = Random.new(288)
    500.times do
      b = rand_box(rng)
      s = rand_seg(rng)
      inside = samples(s).map { |px, py| b.distance_to_point(px, py).zero? ? -b.boundary_distance(px, py) : b.distance_to_point(px, py) }
      depth = -inside.min
      next if depth.abs < 0.5 # near the outline, sampling cannot decide

      assert_equal depth.positive?, s.intersects_box?(b), "#{s.inspect} vs #{b.inspect}"
    end
  end

  def test_segment_distance_to_box_matches_oracle
    rng = Random.new(288)
    assert_equal 0.0, seg(5, 5, 6, 6).distance_to_box(box(0, 0, 10, 10))
    assert_equal 0.0, seg(-5, 0, 15, 0).distance_to_box(box(0, 0, 10, 10))
    assert_in_delta 3.0, seg(-5, 13, 15, 13).distance_to_box(box(0, 0, 10, 10)), 1e-9
    assert_in_delta Math.hypot(3, 4), seg(13, 14, 30, 30).distance_to_box(box(0, 0, 10, 10)), 1e-9
    500.times do
      b = rand_box(rng)
      s = rand_seg(rng)
      oracle = samples(s).map { |px, py| b.distance_to_point(px, py) }.min
      tol = Math.hypot(s.dx, s.dy) / 1000.0 + 1e-9
      exact = s.distance_to_box(b)
      assert_operator exact, :<=, oracle + 1e-9
      assert_in_delta oracle, exact, tol
    end
  end

  def test_box_distance_and_union_match_oracle
    rng = Random.new(288)
    assert_equal 0.0, box(0, 0, 10, 10).distance_to_box(box(10, 0, 5, 5)), "touching"
    assert_in_delta 5.0, box(0, 0, 10, 10).distance_to_box(box(13, 14, 5, 5)), 1e-9
    assert_equal box(0, 0, 20, 15), box(0, 0, 10, 10).union(box(15, 5, 5, 10))
    200.times do
      a = rand_box(rng)
      b = rand_box(rng)
      corners = [ [ b.x, b.y ], [ b.right, b.y ], [ b.x, b.bottom ], [ b.right, b.bottom ] ]
      edge_pts = b.edges.flat_map { |e| samples(e, 200) }
      oracle = a.intersect?(b) ? 0.0 : edge_pts.map { |px, py| a.distance_to_point(px, py) }.min
      assert_in_delta oracle, a.distance_to_box(b), (([ b.w, b.h ].max / 200.0) + 1e-9)
      u = a.union(b)
      assert u.contains_box?(a, inset: -1e-9) && u.contains_box?(b, inset: -1e-9)
      assert corners.all? { |px, py| u.distance_to_point(px, py) < 1e-9 }
    end
  end

  def test_box_contains_box_and_point_distance
    outer = box(0, 0, 10, 10)
    assert outer.contains_box?(box(0, 0, 10, 10)), "closed containment"
    assert outer.contains_box?(box(2, 2, 6, 6), inset: 2)
    refute outer.contains_box?(box(1, 2, 6, 6), inset: 2)
    refute outer.contains_box?(box(5, 5, 6, 1))
    assert_equal 0.0, outer.distance_to_point(5, 5)
    assert_equal 0.0, outer.distance_to_point(10, 3)
    assert_in_delta 5.0, outer.distance_to_point(13, 14), 1e-9
    rng = Random.new(288)
    200.times do
      b = rand_box(rng)
      px = rng.rand(-100.0..100.0)
      py = rng.rand(-100.0..100.0)
      oracle = b.edges.flat_map { |e| samples(e) }.map { |qx, qy| Math.hypot(px - qx, py - qy) }.min
      oracle = 0.0 if px.between?(b.x, b.right) && py.between?(b.y, b.bottom)
      assert_in_delta oracle, b.distance_to_point(px, py), (([ b.w, b.h ].max / 1000.0) + 1e-9)
    end
  end

  def test_path_data_exposes_segments
    segs = DiagramSvg::PathData.segments("M0 0 L10 0 C10 5 15 10 20 10")
    assert_equal 1 + DiagramSvg::PathData::STEPS, segs.size
    assert(segs.all? { |s| s.is_a?(DiagramSvg::Segment) })
    assert_equal [ 20.0, 10.0 ], [ segs.last.x2, segs.last.y2 ]
  end
end
