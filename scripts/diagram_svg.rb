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
  end

  Node = Data.define(:id, :box, :element)
  Text = Data.define(:key, :x, :y, :font_size, :anchor, :content, :node_id, :element)
  Segment = Data.define(:x1, :y1, :x2, :y2, :command)
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
        Node.new(id: g.attributes["data-id"] || g.attributes["id"], box: Geometry.box(shape), element: g) if shape
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
      node = el.parent && el.parent.name == "g" && classes(el.parent).include?("node") ? el.parent : nil
      Text.new(key: a["id"] || "t#{index}", x: a["x"].to_f, y: a["y"].to_f, font_size: font_size(el),
               anchor: a["text-anchor"] || "middle", content: el.texts.map(&:value).join,
               node_id: node && (node.attributes["data-id"] || node.attributes["id"]), element: el)
    end

    def font_size(el)
      raw = el.attributes["font-size"] || el.attributes["style"].to_s[/font-size:\s*([\d.]+)/, 1]
      raw ? raw.to_f : DEFAULT_FONT_SIZE
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

  # Turns path data into absolute straight segments; a curve becomes one
  # chord from its start to its end point, tagged with its command letter.
  module PathData
    ARITY = { "M" => 2, "L" => 2, "H" => 1, "V" => 1, "C" => 6, "S" => 4, "Q" => 4, "T" => 2, "A" => 7, "Z" => 0 }.freeze

    module_function

    def commands(d) = d.scan(/[A-Za-z]/).map(&:upcase)

    def segments(d)
      pos = [ 0.0, 0.0 ]
      start = pos
      d.scan(/([A-Za-z])([^A-Za-z]*)/).flat_map do |letter, args|
        nums = args.scan(/-?\d*\.?\d+(?:e-?\d+)?/i).map(&:to_f)
        arity = ARITY.fetch(letter.upcase, 0)
        groups = arity.zero? ? [ [] ] : nums.each_slice(arity).to_a
        groups.filter_map do |g|
          from = pos
          pos = advance(letter, g, pos, start)
          if letter.upcase == "M"
            start = pos
            next
          end
          Segment.new(x1: from[0], y1: from[1], x2: pos[0], y2: pos[1], command: letter.upcase)
        end
      end
    end

    def advance(letter, g, pos, start)
      rel = letter == letter.downcase
      base = rel ? pos : [ 0.0, 0.0 ]
      case letter.upcase
      when "H" then [ (rel ? pos[0] : 0) + g[0], pos[1] ]
      when "V" then [ pos[0], (rel ? pos[1] : 0) + g[0] ]
      when "Z" then start
      else [ base[0] + g[-2], base[1] + g[-1] ]
      end
    end
  end
end
