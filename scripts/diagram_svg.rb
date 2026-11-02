# frozen_string_literal: true

require "rexml/document"

# Read-only model of one cf:diagram SVG for the linter. Parses the file with
# REXML (stdlib) and exposes what the checks need as small value objects:
# the viewBox, node boxes (`<g class="node">`), text runs, connector paths
# (`<path class="edge">`), and the raw style text. It knows nothing about the
# rules; DiagramChecks decides what is wrong.
module DiagramSvg
  class ParseError < StandardError; end

  SHAPES = %w[rect circle ellipse polygon].freeze
  DEFAULT_FONT_SIZE = 14.0

  # Axis-aligned box in user units.
  Box = Data.define(:x, :y, :w, :h) do
    def right = x + w
    def bottom = y + h
    def center_x = x + (w / 2.0)
    def center_y = y + (h / 2.0)

    def intersect?(other)
      x < other.right && other.x < right && y < other.bottom && other.y < bottom
    end

    # Chebyshev separation; zero or less when the boxes touch or overlap.
    def gap(other)
      [ other.x - right, x - other.right, other.y - bottom, y - other.bottom ].max
    end

    def inset(by) = Box.new(x: x + by, y: y + by, w: w - (2 * by), h: h - (2 * by))

    def contains_point?(px, py) = px > x && px < right && py > y && py < bottom

    # Distance from a point to the box outline, inside or out.
    def boundary_distance(px, py)
      dx = [ x - px, 0, px - right ].max
      dy = [ y - py, 0, py - bottom ].max
      return Math.hypot(dx, dy) unless dx.zero? && dy.zero?

      [ px - x, right - px, py - y, bottom - py ].min
    end

    # Closed containment of other inside self.inset(inset).
    def contains_box?(other, inset: 0)
      inner = inset(inset)
      other.x >= inner.x && other.right <= inner.right && other.y >= inner.y && other.bottom <= inner.bottom
    end

    # Smallest box covering both.
    def union(other)
      left = [ x, other.x ].min
      top = [ y, other.y ].min
      Box.new(x: left, y: top, w: [ right, other.right ].max - left, h: [ bottom, other.bottom ].max - top)
    end

    # Euclidean gap; zero when the boxes overlap or touch.
    def distance_to_box(other)
      dx = [ other.x - right, x - other.right, 0 ].max
      dy = [ other.y - bottom, y - other.bottom, 0 ].max
      Math.hypot(dx, dy)
    end

    # Euclidean distance from a point to the closed box; zero inside.
    def distance_to_point(px, py)
      Math.hypot([ x - px, 0, px - right ].max, [ y - py, 0, py - bottom ].max)
    end

    def edges
      [ [ x, y, right, y ], [ right, y, right, bottom ], [ right, bottom, x, bottom ], [ x, bottom, x, y ] ]
        .map { |a, b, c, d| Segment.new(x1: a, y1: b, x2: c, y2: d, command: "L") }
    end
  end

  # A node: `box` is the shape's bounding box, `label_box` the box its label
  # must fit (the bbox for a rect, the inscribed box for a round or polygon).
  Node = Data.define(:id, :box, :label_box, :element)
  # One rendered line of a text element: its own content and start point.
  Line = Data.define(:text, :x, :y)
  # A <text> element. `content` is every descendant character run, one line
  # per row joined by newline; `lines` places each row with tspan x/y/dy.
  Text = Data.define(:key, :x, :y, :font_size, :anchor, :content, :lines, :node_id, :element)
  # One straight chord of a connector, tagged with its path command letter.
  Segment = Data.define(:x1, :y1, :x2, :y2, :command) do
    def dx = x2 - x1
    def dy = y2 - y1

    # Liang-Barsky clip against the open box: true only when a positive-length
    # part of the segment lies strictly inside. A point segment is a point test.
    def intersects_box?(box)
      return box.contains_point?(x1, y1) if dx.zero? && dy.zero?

      lo = 0.0
      hi = 1.0
      [ [ -dx, x1 - box.x ], [ dx, box.right - x1 ], [ -dy, y1 - box.y ], [ dy, box.bottom - y1 ] ].each do |p, q|
        if p.zero?
          return false if q <= 0

          next
        end
        t = q.to_f / p
        p.negative? ? lo = [ lo, t ].max : hi = [ hi, t ].min
        return false if lo >= hi
      end
      true
    end

    # Zero when the segment meets the closed box, else the shortest distance.
    def distance_to_box(box)
      return 0.0 if box.distance_to_point(x1, y1).zero? || box.distance_to_point(x2, y2).zero?
      return 0.0 if intersects_box?(box)

      box.edges.map { |e| distance_to_segment(e) }.min
    end

    def distance_to_point(px, py)
      len2 = (dx * dx) + (dy * dy)
      t = len2.zero? ? 0.0 : (((px - x1) * dx) + ((py - y1) * dy)) / len2.to_f
      t = t.clamp(0.0, 1.0)
      Math.hypot(px - (x1 + (t * dx)), py - (y1 + (t * dy)))
    end

    def crosses?(other)
      d1 = orient(other.x1, other.y1)
      d2 = orient(other.x2, other.y2)
      d3 = other.orient(x1, y1)
      d4 = other.orient(x2, y2)
      ((d1.positive? && d2.negative?) || (d1.negative? && d2.positive?)) &&
        ((d3.positive? && d4.negative?) || (d3.negative? && d4.positive?))
    end

    def orient(px, py) = (dx * (py - y1)) - (dy * (px - x1))

    def distance_to_segment(other)
      return 0.0 if crosses?(other)

      [ distance_to_point(other.x1, other.y1), distance_to_point(other.x2, other.y2),
        other.distance_to_point(x1, y1), other.distance_to_point(x2, y2) ].min
    end
  end
  Edge = Data.define(:id, :from, :to, :d, :marker_end, :segments, :element)

  # The parsed diagram.
  class Document
    attr_reader :source, :xml

    def initialize(source)
      @source = source
      @xml = REXML::Document.new(source)
      raise ParseError, "no <svg> root element" unless root&.name == "svg"
    rescue REXML::ParseException => e
      raise ParseError, e.message.lines.first.to_s.strip
    end

    def root = @xml.root
    def attr(name) = root.attributes[name]

    def view_box
      nums = attr("viewBox").to_s.split(/[\s,]+/).map { |v| Float(v, exception: false) }
      return nil unless nums.size == 4 && nums.all?

      Box.new(x: nums[0], y: nums[1], w: nums[2], h: nums[3])
    end

    def elements = REXML::XPath.match(root, "//*")
    def style_text = REXML::XPath.match(root, "//style").map(&:text).compact.join("\n")
    def element_ids = elements.filter_map { |el| el.attributes["id"] }

    def nodes
      @nodes ||= elements.select { |el| el.name == "g" && classes(el).include?("node") }.filter_map do |g|
        shape = g.elements.find { |el| SHAPES.include?(el.name) }
        next unless shape

        Node.new(id: g.attributes["data-id"] || g.attributes["id"], box: Geometry.box(shape),
                 label_box: Geometry.label_box(shape), element: g)
      end.select(&:box)
    end

    def texts
      @texts ||= REXML::XPath.match(root, "//text").each_with_index.map { |el, i| build_text(el, i) }
    end

    def edges
      @edges ||= REXML::XPath.match(root, "//path").select { |el| classes(el).include?("edge") }.map do |el|
        a = el.attributes
        Edge.new(id: a["id"] || "#{a['data-from']}->#{a['data-to']}", from: a["data-from"], to: a["data-to"],
                 d: a["d"].to_s, marker_end: a["marker-end"], segments: PathData.segments(a["d"].to_s), element: el)
      end
    end

    def node(id) = nodes.find { |n| n.id == id }
    def classes(el) = el.attributes["class"].to_s.split

    private

    def build_text(el, index)
      a = el.attributes
      x = a["x"].to_f
      y = a["y"].to_f
      size = font_size(el)
      lines = text_lines(el, x, y, size)
      node = el.parent
      node = node.parent while node.is_a?(REXML::Element) && !(node.name == "g" && classes(node).include?("node"))
      node = nil unless node.is_a?(REXML::Element)
      Text.new(key: a["id"] || "t#{index}", x: x, y: y, font_size: size,
               anchor: inherited(el, "text-anchor") || "start", content: lines.map(&:text).join("\n"), lines: lines,
               node_id: node && (node.attributes["data-id"] || node.attributes["id"]), element: el)
    end

    # Rows of a text element. A tspan carrying x, y, or dy starts a new row; a
    # tspan without x keeps the row start x; dy accumulates in px (em is
    # scaled by font size). Unpositioned content joins the current row.
    def text_lines(el, x, y, size)
      rows = [ { text: +"", x: x, y: y } ]
      walk = lambda do |node|
        node.children.each do |c|
          if c.is_a?(REXML::Text)
            rows.last[:text] << c.value
          elsif c.is_a?(REXML::Element) && c.name == "tspan"
            ta = c.attributes
            if ta["x"] || ta["y"] || ta["dy"]
              cur = rows.last
              ny = ta["y"] ? ta["y"].to_f : cur[:y]
              ny += length(ta["dy"], size) if ta["dy"]
              nx = ta["x"] ? ta["x"].to_f : x
              rows << { text: +"", x: nx, y: ny }
            end
            walk.call(c)
          end
        end
      end
      walk.call(el)
      rows = rows.reject { |r| r[:text].strip.empty? }
      rows = [ { text: "", x: x, y: y } ] if rows.empty?
      rows.map { |r| Line.new(text: r[:text].strip, x: r[:x], y: r[:y]) }
    end

    def length(raw, size)
      v = raw.to_s.split(/[\s,]+/).first.to_s
      v.end_with?("em") ? v.to_f * size : v.to_f
    end

    def font_size(el)
      raw = inherited(el, "font-size").to_s.strip[/\A(\d+(?:\.\d+)?)(?:px)?\z/, 1]
      raw ? raw.to_f : DEFAULT_FONT_SIZE
    end

    # Presentation property as SVG resolves it: the element's own attribute or
    # inline style, else the nearest ancestor's (both properties inherit).
    def inherited(el, prop)
      while el.is_a?(REXML::Element)
        own = el.attributes["style"].to_s[/(?:\A|;)\s*#{Regexp.escape(prop)}\s*:\s*([^;]+)/, 1]&.strip
        own ||= el.attributes[prop]
        return own if own
        el = el.parent
      end
      nil
    end
  end

  # Bounding boxes of the basic shapes.
  module Geometry
    module_function

    def box(el)
      a = el.attributes
      case el.name
      when "rect" then Box.new(x: a["x"].to_f, y: a["y"].to_f, w: a["width"].to_f, h: a["height"].to_f)
      when "circle" then radial(a["cx"], a["cy"], a["r"], a["r"])
      when "ellipse" then radial(a["cx"], a["cy"], a["rx"], a["ry"])
      when "polygon" then polygon(a["points"].to_s)
      end
    end

    # Largest axis-aligned box a label may use inside the shape.
    def label_box(el)
      a = el.attributes
      case el.name
      when "rect" then box(el)
      when "circle" then inscribed(a["cx"].to_f, a["cy"].to_f, a["r"].to_f, a["r"].to_f)
      when "ellipse" then inscribed(a["cx"].to_f, a["cy"].to_f, a["rx"].to_f, a["ry"].to_f)
      when "polygon" then polygon_inscribed(a["points"].to_s)
      end
    end

    # Box inscribed in an ellipse: half sides r / sqrt 2.
    def inscribed(cx, cy, rx, ry)
      hx = rx / Math.sqrt(2)
      hy = ry / Math.sqrt(2)
      Box.new(x: cx - hx, y: cy - hy, w: 2 * hx, h: 2 * hy)
    end

    # The polygon's bbox shrunk about the vertex centroid, by bisection on the
    # scale, until all four corners sit inside the polygon.
    def polygon_inscribed(points)
      pts = points.split(/[\s,]+/).map(&:to_f).each_slice(2).to_a
      outer = polygon(points)
      return nil unless outer && pts.size >= 3

      cx = pts.sum(&:first) / pts.size
      cy = pts.sum(&:last) / pts.size
      half_w = [ cx - outer.x, outer.right - cx ].min
      half_h = [ cy - outer.y, outer.bottom - cy ].min
      fits = ->(k) { [ [ -1, -1 ], [ 1, -1 ], [ 1, 1 ], [ -1, 1 ] ].all? { |sx, sy| inside?(pts, cx + (sx * k * half_w), cy + (sy * k * half_h)) } }
      lo = 0.0
      hi = 1.0
      if fits.call(hi)
        lo = hi
      else
        40.times do
          mid = (lo + hi) / 2
          fits.call(mid) ? lo = mid : hi = mid
        end
      end
      Box.new(x: cx - (lo * half_w), y: cy - (lo * half_h), w: 2 * lo * half_w, h: 2 * lo * half_h)
    end

    # Closed point-in-polygon: on the outline counts as inside.
    def inside?(pts, px, py)
      ring = pts.each_with_index.map { |p, i| [ p, pts[(i + 1) % pts.size] ] }
      on_edge = ring.any? do |(ax, ay), (bx, by)|
        Segment.new(x1: ax, y1: ay, x2: bx, y2: by, command: "L").distance_to_point(px, py) < 1e-9
      end
      return true if on_edge

      ring.count { |(ax, ay), (bx, by)| ((ay > py) != (by > py)) && px < ax + ((py - ay) * (bx - ax) / (by - ay)) }.odd?
    end

    def radial(cx, cy, rx, ry)
      Box.new(x: cx.to_f - rx.to_f, y: cy.to_f - ry.to_f, w: 2 * rx.to_f, h: 2 * ry.to_f)
    end

    def polygon(points)
      pts = points.split(/[\s,]+/).map(&:to_f).each_slice(2).to_a
      return nil if pts.empty?

      xs, ys = pts.transpose
      Box.new(x: xs.min, y: ys.min, w: xs.max - xs.min, h: ys.max - ys.min)
    end
  end

  # Turns path data into absolute straight segments. A curve (C, S, Q, T, A)
  # is flattened into short chords along its real geometry, each tagged with
  # the curve's command letter, so route checks see the rendered shape.
  module PathData
    ARITY = { "M" => 2, "L" => 2, "H" => 1, "V" => 1, "C" => 6, "S" => 4, "Q" => 4, "T" => 2, "A" => 7, "Z" => 0 }.freeze
    STEPS = 16

    module_function

    def commands(d) = d.scan(/[A-Za-z]/).map(&:upcase)

    def segments(d)
      state = { pos: [ 0.0, 0.0 ], start: [ 0.0, 0.0 ], ctrl: nil, prev: nil }
      d.scan(/([A-Za-z])([^A-Za-z]*)/).flat_map do |letter, args|
        nums = args.scan(/-?\d*\.?\d+(?:e-?\d+)?/i).map(&:to_f)
        arity = ARITY.fetch(letter.upcase, 0)
        groups = arity.zero? ? [ [] ] : nums.each_slice(arity).to_a
        groups.flat_map { |g| step(letter, g, state) }
      end
    end

    def step(letter, g, state)
      cmd = letter.upcase
      from = state[:pos]
      pts = points(cmd, absolute(letter, g, from, state[:start]), from, state)
      state[:prev] = cmd
      state[:pos] = pts.last
      if cmd == "M"
        state[:start] = state[:pos]
        return []
      end
      [ from, *pts ].each_cons(2).map { |(a, b)| Segment.new(x1: a[0], y1: a[1], x2: b[0], y2: b[1], command: cmd) }
    end

    # Absolute coordinates for every point argument of one command.
    def absolute(letter, g, pos, start)
      rel = letter == letter.downcase
      case letter.upcase
      when "H" then [ (rel ? pos[0] : 0) + g[0], pos[1] ]
      when "V" then [ pos[0], (rel ? pos[1] : 0) + g[0] ]
      when "Z" then start
      when "A" then g[0, 5] + [ (rel ? pos[0] : 0) + g[5], (rel ? pos[1] : 0) + g[6] ]
      else g.each_slice(2).flat_map { |x, y| rel ? [ pos[0] + x, pos[1] + y ] : [ x, y ] }
      end
    end

    def points(cmd, a, from, state)
      case cmd
      when "C" then cubic(from, a[0, 2], a[2, 2], a[4, 2], state)
      when "S" then cubic(from, reflect(from, state, %w[C S]), a[0, 2], a[2, 2], state)
      when "Q" then quad(from, a[0, 2], a[2, 2], state)
      when "T" then quad(from, reflect(from, state, %w[Q T]), a[0, 2], state)
      else
        state[:ctrl] = nil
        cmd == "A" ? arc(from, *a) : [ a[0, 2] ]
      end
    end

    def reflect(from, state, kinds)
      return from unless state[:ctrl] && kinds.include?(state[:prev])

      [ 2 * from[0] - state[:ctrl][0], 2 * from[1] - state[:ctrl][1] ]
    end

    def cubic(p0, p1, p2, p3, state)
      state[:ctrl] = p2
      (1..STEPS).map do |i|
        t = i.to_f / STEPS
        u = 1 - t
        (0..1).map { |k| u**3 * p0[k] + 3 * u * u * t * p1[k] + 3 * u * t * t * p2[k] + t**3 * p3[k] }
      end
    end

    def quad(p0, p1, p2, state)
      state[:ctrl] = p1
      (1..STEPS).map do |i|
        t = i.to_f / STEPS
        u = 1 - t
        (0..1).map { |k| u * u * p0[k] + 2 * u * t * p1[k] + t * t * p2[k] }
      end
    end

    # SVG endpoint arc to center parameterization (SVG 1.1 F.6.5), sampled.
    def arc(from, rx, ry, phi_deg, large, sweep, x, y)
      rx = rx.abs
      ry = ry.abs
      return [ [ x, y ] ] if rx.zero? || ry.zero? || from == [ x, y ]

      phi = phi_deg * Math::PI / 180
      cos = Math.cos(phi)
      sin = Math.sin(phi)
      dx = (from[0] - x) / 2
      dy = (from[1] - y) / 2
      x1 = cos * dx + sin * dy
      y1 = -sin * dx + cos * dy
      scale = (x1**2) / (rx**2) + (y1**2) / (ry**2)
      if scale > 1
        rx *= Math.sqrt(scale)
        ry *= Math.sqrt(scale)
      end
      num = (rx**2 * ry**2) - (rx**2 * y1**2) - (ry**2 * x1**2)
      den = (rx**2 * y1**2) + (ry**2 * x1**2)
      coef = Math.sqrt([ num / den, 0 ].max) * ((large != 0) == (sweep != 0) ? -1 : 1)
      cx1 = coef * rx * y1 / ry
      cy1 = -coef * ry * x1 / rx
      cx = cos * cx1 - sin * cy1 + (from[0] + x) / 2
      cy = sin * cx1 + cos * cy1 + (from[1] + y) / 2
      theta = Math.atan2((y1 - cy1) / ry, (x1 - cx1) / rx)
      delta = Math.atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx) - theta
      delta -= 2 * Math::PI if sweep.zero? && delta.positive?
      delta += 2 * Math::PI if sweep != 0 && delta.negative?
      (1..STEPS).map do |i|
        a = theta + delta * i / STEPS
        ex = rx * Math.cos(a)
        ey = ry * Math.sin(a)
        i == STEPS ? [ x, y ] : [ cos * ex - sin * ey + cx, sin * ex + cos * ey + cy ]
      end
    end
  end
end
