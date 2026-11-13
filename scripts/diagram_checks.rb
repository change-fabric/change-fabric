# frozen_string_literal: true

require_relative "svg_checks"

# The cf:diagram lint rules. The type-aware checks (connectors, markers,
# node spacing and grid, caps) live here; the SVG checks every cf SVG shares
# live in SvgChecks and are re-exported below under their old names. The
# check concepts were informed by two MIT projects and are credited in the
# repo-root NOTICE; this is an independent Ruby implementation written from
# cf:diagram's own grammar.
module DiagramChecks
  NOTICE = "Lint check concepts credited in NOTICE (diagram-design, svg-diagram; both MIT)."

  # Shared checks and constants, re-exported so every existing reference
  # to DiagramChecks::<Name> still resolves.
  Finding = SvgChecks::Finding
  DEFAULT_PALETTE = SvgChecks::DEFAULT_PALETTE
  MARGIN = SvgChecks::MARGIN
  PADDING = SvgChecks::PADDING
  GRID = SvgChecks::GRID
  Base = SvgChecks::Base
  A11y = SvgChecks::A11y
  XmlSafety = SvgChecks::XmlSafety
  ViewboxClip = SvgChecks::ViewboxClip
  TextOverflow = SvgChecks::TextOverflow
  Palette = SvgChecks::Palette
  FontStack = SvgChecks::FontStack
  ThemeFallback = SvgChecks::ThemeFallback
  DeclaredProperty = SvgChecks::DeclaredProperty
  Transform = SvgChecks::Transform
  TextBaseline = SvgChecks::TextBaseline
  FontUnit = SvgChecks::FontUnit
  TextGeometrySource = SvgChecks::TextGeometrySource
  DisplayScale = SvgChecks::DisplayScale

  TYPES = %w[architecture flow sequence state er timeline swimlane layers].freeze
  TYPE_RULES = {
    "architecture" => { connectors: :orthogonal, curves: false, markers: :required, endpoints: true },
    "flow" => { connectors: :orthogonal, curves: false, markers: :required, endpoints: true },
    "sequence" => { connectors: :horizontal, curves: false, markers: :required, endpoints: false },
    "state" => { connectors: :orthogonal, curves: true, markers: :required, endpoints: true },
    "er" => { connectors: :orthogonal, curves: false, markers: :none, endpoints: true },
    "timeline" => { connectors: :horizontal, curves: false, markers: :none, endpoints: false },
    "swimlane" => { connectors: :orthogonal, curves: false, markers: :required, endpoints: true },
    "layers" => { connectors: :orthogonal, curves: false, markers: :optional, endpoints: true }
  }.freeze

  SIBLING_GAP = 24
  LABEL_GAP = 4
  MAX_NODES = 12
  MAX_EDGES = 16

  # What every check may consult beyond the document itself.
  Context = Data.define(:type, :widths, :measured, :palette) do
    def rules = TYPE_RULES.fetch(type, TYPE_RULES["flow"])

    # The single text bounds resolver: the measurer's full box [x, y, w, h]
    # (anchor, baseline, and lines already resolved). A text the measurer
    # did not report gets an empty box at its own position.
    def text_box(text)
      x, y, w, h = widths.fetch(text.key) { [ text.x, text.y - (0.8 * text.font_size), 0.0, text.font_size ] }
      DiagramSvg::Box.new(x: x, y: y, w: w, h: h)
    end
  end

  # Nodes never intersect; text never overlaps text or crosses an edge.
  class Overlap < Base
    ID = "overlap"

    def call(doc, context)
      nodes = doc.nodes.combination(2).select { |a, b| a.box.intersect?(b.box) }
                 .map { |a, b| finding(a.id, "node overlaps #{b.id}", "move one of them apart") }
      texts = doc.texts.map { |t| [ t, context.text_box(t) ] }
      text_pairs = texts.combination(2).select { |(_, a), (_, b)| a.intersect?(b) }
                        .map { |(a, _), (b, _)| finding(a.key, "text overlaps #{b.key}", "move one label") }
      crossings = texts.product(doc.edges).select { |(_, box), edge| edge.segments.any? { |s| s.intersects_box?(box) } }
                       .map { |(t, _), edge| finding(t.key, "text crosses edge #{edge.id}", "offset the label at least #{LABEL_GAP}px") }
      nodes + text_pairs + crossings
    end
  end

  # A lone centered label sits on center + 0.35 * font size. A multi-line
  # label centers its block: the midpoint of its first and last baselines.
  class Baseline < Base
    ID = "baseline"

    def call(doc, _context)
      doc.texts.group_by(&:node_id).filter_map do |id, texts|
        node = id && texts.size == 1 && doc.node(id)
        next unless node

        text = texts.first
        first = text.lines.first.y
        span = text.lines.last.y - first
        want = node.box.center_y + (0.35 * text.font_size) - (span / 2.0)
        next if (first - want).abs <= 1

        finding(id, "first baseline y=#{first.round(1)} should be #{want.round(1)}", "set y=\"#{want.round(1)}\"")
      end
    end
  end

  # Nodes are at least three font sizes tall, plus one line height for each
  # extra label line, and never shorter than the measured text plus padding.
  class BoxHeight < Base
    ID = "box-height"
    LINE_HEIGHT = 1.2

    def call(doc, context)
      doc.nodes.filter_map do |node|
        texts = doc.texts.select { |t| t.node_id == node.id }
        need = required(texts, context)
        next if node.box.h >= need

        finding(node.id, "height #{node.box.h.round} is under the #{need.round(1)} its label needs", "make it at least #{(need / GRID).ceil * GRID}")
      end
    end

    private

    def required(texts, context)
      return 3 * DiagramSvg::DEFAULT_FONT_SIZE if texts.empty?

      texts.map do |t|
        lines = (3 * t.font_size) + (LINE_HEIGHT * t.font_size * (t.lines.size - 1))
        context.measured ? [ lines, context.text_box(t).h + (2 * PADDING) ].max : lines
      end.max
    end
  end

  # Sibling nodes keep a gap; free labels keep off their edges.
  class Spacing < Base
    ID = "spacing"

    def call(doc, context)
      tight = doc.nodes.combination(2).select { |a, b| a.box.gap(b.box).between?(0, SIBLING_GAP - 0.001) }
                 .map { |a, b| finding(a.id, "gap to #{b.id} is #{a.box.gap(b.box).round}px", "keep at least #{SIBLING_GAP}px") }
      tight + labels(doc, context)
    end

    private

    def labels(doc, context)
      doc.texts.reject(&:node_id).product(doc.edges).filter_map do |text, edge|
        box = context.text_box(text)
        dist = edge.segments.map { |s| s.distance_to_box(box) }.min
        finding(text.key, "label is #{dist.round(1)}px from edge #{edge.id}", "keep at least #{LABEL_GAP}px") if dist&.between?(0.001, LABEL_GAP - 0.001)
      end
    end
  end

  # Node geometry sits on the 8px grid.
  class Grid < Base
    ID = "grid"
    SEVERITY = "warn"

    def call(doc, _context)
      doc.nodes.filter_map do |node|
        off = %i[x y w h].reject { |k| (node.box.public_send(k) % GRID).zero? }
        finding(node.id, "#{off.join(', ')} off the #{GRID}px grid", "snap to multiples of #{GRID}") if off.any?
      end
    end
  end

  # Paths follow the type's connector rule and land on their nodes.
  class ConnectorGeometry < Base
    ID = "connector-geometry"
    STRAIGHT = %w[M H V L].freeze
    CURVES = %w[C Q].freeze

    def call(doc, context)
      rules = context.rules
      doc.edges.flat_map { |edge| shape(edge, rules) + ends(doc, edge, rules) + passes(doc, edge) }
    end

    private

    def shape(edge, rules)
      allowed = STRAIGHT + (rules[:curves] ? CURVES : [])
      bad = DiagramSvg::PathData.commands(edge.d) - allowed
      return [ finding(edge.id, "path uses #{bad.uniq.join(', ')}", "use only #{allowed.join(', ')}") ] if bad.any?
      return [ stroke_count(edge) ] unless edge.subpaths.size == 1

      skew = edge.segments.reject { |s| CURVES.include?(s.command) || axis?(s, rules[:connectors]) }
      skew.any? ? [ finding(edge.id, "segment is not #{rules[:connectors]}", "route at right angles") ] : []
    end

    # A connector is exactly one visible stroke: none means nothing joins the
    # nodes, more than one leaves a gap the endpoint checks cannot see.
    def stroke_count(edge)
      if edge.subpaths.empty?
        finding(edge.id, "path draws no segment", "draw the connector from #{edge.from} to #{edge.to}")
      else
        finding(edge.id, "path is split into #{edge.subpaths.size} disconnected pieces", "draw the connector as one continuous subpath")
      end
    end

    def axis?(seg, mode)
      flat = (seg.y1 - seg.y2).abs < 0.01
      mode == :horizontal ? flat : flat || (seg.x1 - seg.x2).abs < 0.01
    end

    def ends(doc, edge, rules)
      return [] unless rules[:endpoints] && edge.segments.any?

      first = edge.segments.first
      last = edge.segments.last
      [ [ edge.from, first.x1, first.y1 ], [ edge.to, last.x2, last.y2 ] ].filter_map do |id, px, py|
        node = doc.node(id)
        next finding(edge.id, "endpoint node #{id.inspect} not found", "set data-from and data-to to node ids") unless node
        next if node.outline_distance(px, py) <= 2

        finding(edge.id, "endpoint misses #{id} by more than 2px", "end the path on the node outline")
      end
    end

    def passes(doc, edge)
      doc.nodes.reject { |n| [ edge.from, edge.to ].include?(n.id) }.filter_map do |node|
        inner = node.box.inset(1)
        next unless edge.segments.any? { |s| s.intersects_box?(inner) }

        finding(edge.id, "passes through #{node.id}", "route around it")
      end
    end
  end

  # Directed edges end in a marker defined in <defs>.
  class ArrowMarker < Base
    ID = "arrow-marker"

    def call(doc, context)
      return [] unless context.rules[:markers] == :required

      markers = REXML::XPath.match(doc.root, "//defs/marker").map { |m| m.attributes["id"] }
      doc.edges.filter_map do |edge|
        ref = edge.marker_end.to_s[/\Aurl\(#([^)]+)\)\z/, 1]
        next if ref && markers.include?(ref)

        finding(edge.id, "edge lacks a marker-end resolving to <defs>", "add marker-end=\"url(#arrow)\"")
      end
    end
  end

  # Diagrams stay small enough to read.
  class Caps < Base
    ID = "caps"
    SEVERITY = "warn"

    def call(doc, _context)
      nodes = doc.nodes.size
      edges = doc.edges.size
      return [] if nodes <= MAX_NODES && edges <= MAX_EDGES

      [ finding("svg", "#{nodes} nodes and #{edges} edges exceed #{MAX_NODES} and #{MAX_EDGES}", "split into diagrams/<slug>/") ]
    end
  end

  # The root declares one of the eight types.
  class TypeDeclared < Base
    ID = "type-declared"

    def call(_doc, context)
      return [] if TYPES.include?(context.type)

      [ finding("svg", "data-diagram-type #{context.type.inspect} is not one of #{TYPES.join(', ')}", "declare a supported type") ]
    end
  end

  ALL = [ A11y, XmlSafety, ViewboxClip, Overlap, TextOverflow, Baseline, BoxHeight, Spacing, Grid,
          ConnectorGeometry, ArrowMarker, Palette, FontStack, ThemeFallback, Caps, TypeDeclared,
          Transform, TextBaseline, FontUnit, TextGeometrySource, DisplayScale ].freeze

  def self.all = ALL.map(&:new)
end
