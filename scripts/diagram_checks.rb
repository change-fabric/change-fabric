# frozen_string_literal: true

require_relative "diagram_svg"

# The cf:diagram lint rules. Each rule is one small class with a kebab-case
# ID and `#call(doc, context) -> [Finding]`, so DiagramLint can run any list
# of them and a test can run one alone. The check concepts were informed by
# two MIT projects and are credited in the repo-root NOTICE; this is an
# independent Ruby implementation written from cf:diagram's own grammar.
module DiagramChecks
  NOTICE = "Lint check concepts credited in NOTICE (diagram-design, svg-diagram; both MIT)."

  Finding = Data.define(:check, :severity, :element, :message, :fix) do
    def to_h = { check:, severity:, element:, message:, fix: }
  end

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

  DEFAULT_PALETTE = %w[
    #FBFBFA #FFFFFF #1F2328 #5B6470 #8A939E #2F5D8A #8A5A2F
    #16181B #1E2125 #E8EAED #A3ABB5 #6E7781 #7FA8D1 #D1A37F
  ].freeze

  MARGIN = 24
  PADDING = 12
  SIBLING_GAP = 24
  LABEL_GAP = 4
  GRID = 8
  MAX_NODES = 12
  MAX_EDGES = 16

  # What every check may consult beyond the document itself.
  Context = Data.define(:type, :widths, :measured, :palette) do
    def rules = TYPE_RULES.fetch(type, TYPE_RULES["flow"])

    # Measured (or estimated) box of a text run, placed by its anchor.
    def text_box(text)
      w, h = widths.fetch(text.key, [ 0.0, text.font_size ])
      left = { "start" => text.x, "end" => text.x - w }.fetch(text.anchor, text.x - (w / 2.0))
      DiagramSvg::Box.new(x: left, y: text.y - (0.8 * h), w: w, h: h)
    end
  end

  # Shared finding constructor.
  class Base
    def finding(element, message, fix, severity: self.class::SEVERITY)
      Finding.new(check: self.class::ID, severity: severity, element: element, message: message, fix: fix)
    end

    SEVERITY = "error"
  end

  # Root is an accessible image with a title and desc first.
  class A11y < Base
    ID = "a11y"

    def call(doc, _context)
      out = []
      out << finding("svg", "root lacks role=\"img\"", "add role=\"img\" to <svg>") unless doc.attr("role") == "img"
      first = doc.root.elements.to_a.first(2)
      unless first.map(&:name) == %w[title desc] && first.all? { |el| el.text.to_s.strip != "" }
        out << finding("svg", "first children must be a non-empty <title> then <desc>", "add <title id=\"t\"> and <desc id=\"d\">")
      end
      ids = doc.attr("aria-labelledby").to_s.split
      missing = ids.empty? ? [ "(none)" ] : ids - doc.element_ids
      out << finding("svg", "aria-labelledby does not resolve: #{missing.join(' ')}", "set aria-labelledby=\"t d\"") if missing.any?
      out
    end
  end

  # No scripts, foreign content, event handlers, remote hrefs, or raw markup in text.
  class XmlSafety < Base
    ID = "xml-safety"
    BANNED = %w[script foreignObject].freeze

    def call(doc, _context)
      doc.elements.flat_map do |el|
        out = []
        out << finding(el.name, "<#{el.name}> is not allowed", "remove it") if BANNED.include?(el.name)
        el.attributes.each_attribute do |a|
          out << finding(el.name, "event attribute #{a.name}", "remove it") if a.name.start_with?("on")
          out << finding(el.name, "remote href #{a.value}", "inline the asset") if a.name.end_with?("href") && a.value.match?(%r{\A(https?:)?//})
        end
        raw = el.texts.map(&:to_s).join
        out << finding(el.name, "raw > in text", "escape as &gt;") if el.name != "style" && raw.include?(">")
        out
      end
    end
  end

  # Shapes, connectors, and text stay inside the viewBox with a margin.
  class ViewboxClip < Base
    ID = "viewbox-clip"

    def call(doc, context)
      vb = doc.view_box
      return [ finding("svg", "missing or malformed viewBox", "set viewBox=\"0 0 W H\"") ] unless vb

      boxes = doc.nodes.map { |n| [ n.id, n.box ] } + doc.texts.map { |t| [ t.key, context.text_box(t) ] } +
              doc.edges.filter_map { |e| (box = edge_box(e)) && [ e.id, box ] }
      boxes.filter_map { |id, box| judge(id, box, vb) }
    end

    private

    # Bounding box of every vertex the connector's path passes through.
    def edge_box(edge)
      return if edge.segments.empty?

      xs = edge.segments.flat_map { |s| [ s.x1, s.x2 ] }
      ys = edge.segments.flat_map { |s| [ s.y1, s.y2 ] }
      DiagramSvg::Box.new(x: xs.min, y: ys.min, w: xs.max - xs.min, h: ys.max - ys.min)
    end

    def judge(id, box, vb)
      margin = [ box.x - vb.x, box.y - vb.y, vb.right - box.right, vb.bottom - box.bottom ].min
      return finding(id, "clipped by the viewBox", "move it inside or grow the viewBox") if margin.negative?

      finding(id, "margin #{margin.round(1)}px is under #{MARGIN}px", "grow the viewBox", severity: "warn") if margin < MARGIN
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
      crossings = texts.product(doc.edges).select { |(_, box), edge| edge.segments.any? { |s| Overlap.crosses?(s, box) } }
                       .map { |(t, _), edge| finding(t.key, "text crosses edge #{edge.id}", "offset the label at least #{LABEL_GAP}px") }
      nodes + text_pairs + crossings
    end

    # Does an axis-aligned or sampled segment enter the box interior?
    def self.crosses?(seg, box)
      (0..20).any? { |i| box.contains_point?(seg.x1 + ((seg.x2 - seg.x1) * i / 20.0), seg.y1 + ((seg.y2 - seg.y1) * i / 20.0)) }
    end
  end

  # Text plus padding fits its node.
  class TextOverflow < Base
    ID = "text-overflow"

    def call(doc, context)
      severity = context.measured ? "error" : "warn"
      doc.texts.filter_map do |t|
        node = t.node_id && doc.node(t.node_id)
        next unless node

        width = context.text_box(t).w
        inner = node.box.w - (2 * PADDING)
        next if width <= inner

        finding(node.id, "label width #{width.round}px exceeds box inner width #{inner.round}px",
                "widen box to #{(((width + (2 * PADDING)) / GRID).ceil * GRID)} or shorten label", severity: severity)
      end
    end
  end

  # A lone centered label sits on center + 0.35 * font size.
  class Baseline < Base
    ID = "baseline"

    def call(doc, _context)
      doc.texts.group_by(&:node_id).filter_map do |id, texts|
        node = id && texts.size == 1 && doc.node(id)
        next unless node

        want = node.box.center_y + (0.35 * texts.first.font_size)
        next if (texts.first.y - want).abs <= 1

        finding(id, "baseline y=#{texts.first.y} should be #{want.round(1)}", "set y=\"#{want.round}\"")
      end
    end
  end

  # Nodes are at least three font sizes tall.
  class BoxHeight < Base
    ID = "box-height"

    def call(doc, _context)
      doc.nodes.filter_map do |node|
        size = doc.texts.select { |t| t.node_id == node.id }.map(&:font_size).max || DiagramSvg::DEFAULT_FONT_SIZE
        next if node.box.h >= 3 * size

        finding(node.id, "height #{node.box.h.round} is under 3 x #{size.round}", "make it at least #{((3 * size) / GRID).ceil * GRID}")
      end
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
        dist = edge.segments.map { |s| distance(s, box) }.min
        finding(text.key, "label is #{dist.round(1)}px from edge #{edge.id}", "keep at least #{LABEL_GAP}px") if dist&.between?(0.001, LABEL_GAP - 0.001)
      end
    end

    def distance(seg, box)
      (0..20).map do |i|
        px = seg.x1 + ((seg.x2 - seg.x1) * i / 20.0)
        py = seg.y1 + ((seg.y2 - seg.y1) * i / 20.0)
        box.contains_point?(px, py) ? 0.0 : box.boundary_distance(px, py)
      end.min
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

      skew = edge.segments.reject { |s| CURVES.include?(s.command) || axis?(s, rules[:connectors]) }
      skew.any? ? [ finding(edge.id, "segment is not #{rules[:connectors]}", "route at right angles") ] : []
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
        next if node.box.boundary_distance(px, py) <= 2

        finding(edge.id, "endpoint misses #{id} by more than 2px", "end the path on the node outline")
      end
    end

    def passes(doc, edge)
      doc.nodes.reject { |n| [ edge.from, edge.to ].include?(n.id) }.filter_map do |node|
        inner = node.box.inset(1)
        next unless edge.segments.any? { |s| Overlap.crosses?(s, inner) }

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

  # Fill and stroke literals come from the resolved palette.
  class Palette < Base
    ID = "palette"
    SEVERITY = "warn"
    PROPS = %w[fill stroke stop-color].freeze

    def call(doc, context)
      allowed = context.palette.map(&:upcase)
      doc.elements.flat_map do |el|
        literals(el).reject { |v| allowed.include?(v.upcase) }.map do |v|
          finding(el.attributes["data-id"] || el.attributes["id"] || el.name, "color #{v} is not in the palette", "use a palette role")
        end
      end
    end

    private

    def literals(el)
      values = PROPS.filter_map { |p| el.attributes[p] }
      values += el.attributes["style"].to_s.scan(/(?:fill|stroke|stop-color):\s*([^;]+)/).flatten
      values.map(&:strip).grep(/\A(#|rgb|hsl)/i)
    end
  end

  # Every font-family ends generic and carries a CJK fallback.
  class FontStack < Base
    ID = "font-stack"
    GENERIC = %w[sans-serif serif monospace system-ui cursive fantasy].freeze

    def call(doc, _context)
      stacks = doc.style_text.scan(/font-family:\s*([^;}]+)/).flatten
      stacks += doc.elements.filter_map { |el| el.attributes["font-family"] }
      return [ finding("style", "no font-family declared", "declare the grammar's font stack") ] if stacks.empty?

      stacks.filter_map do |stack|
        last = stack.split(",").last.to_s.strip.delete("\"'")
        ok = GENERIC.include?(last) && stack.match?(/CJK/i)
        finding("style", "font stack #{stack.strip[0, 40]} lacks a generic family or CJK fallback", "use the grammar's stack") unless ok
      end
    end
  end

  # A background rect and a dark-scheme block redefining the core roles.
  class ThemeFallback < Base
    ID = "theme-fallback"
    ROLES = %w[--ink --bg --surface].freeze

    def call(doc, _context)
      out = []
      bg = REXML::XPath.match(doc.root, "//rect").any? { |r| doc.classes(r).include?("bg") }
      out << finding("svg", "no <rect class=\"bg\">", "add a full-bleed background rect") unless bg
      block = dark_block(doc.style_text)
      missing = block ? ROLES.reject { |r| block.match?(/#{r}\s*:/) } : ROLES
      out << finding("style", "dark scheme does not redefine #{missing.join(', ')}", "add @media (prefers-color-scheme: dark)") if missing.any?
      out
    end

    private

    def dark_block(css)
      start = css =~ /@media[^{]*prefers-color-scheme:\s*dark[^{]*\{/
      return nil unless start

      depth = 0
      css[start..].each_char.with_index do |c, i|
        depth += 1 if c == "{"
        depth -= 1 if c == "}"
        return css[start, i + 1] if depth.zero? && c == "}"
      end
      css[start..]
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
          ConnectorGeometry, ArrowMarker, Palette, FontStack, ThemeFallback, Caps, TypeDeclared ].freeze

  def self.all = ALL.map(&:new)
end
