# frozen_string_literal: true

require_relative "diagram_svg"

# SVG checks shared by every hand-placed or generated cf SVG (cf:diagram
# today). Each rule is one small class with a kebab-case ID and
# `#call(doc, context) -> [Finding]`. A check reads only the document and
# the context's palette, measured flag, and text_box, never a diagram type.
# The report shape and exit codes here are the contract every lint script
# built on these checks prints and returns.
module SvgChecks
  # Exit codes: no errors, at least one error, usage or parse problem,
  # measurement needed Docker or browserless and neither was available.
  EXIT_OK = 0
  EXIT_FINDINGS = 1
  EXIT_USAGE = 2
  EXIT_UNMEASURED = 3

  Finding = Data.define(:check, :severity, :element, :message, :fix) do
    def to_h = { check:, severity:, element:, message:, fix: }
  end

  DEFAULT_PALETTE = %w[
    #F5F5F5 #FFFFFF #2D3142 #4F5D75 #5A6580 #D9DADD #B5401C #F2E9E6 #2E5AA8
    #BFC0C0 #A3ACC0 #45495A #F08A59 #3D3844 #7FA9E6
  ].freeze

  MARGIN = 24
  PADDING = 12
  GRID = 8

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

  # The full text box sits inside its node's label box, padded on every
  # side: one predicate for width, placement, and vertical fit.
  class TextOverflow < Base
    ID = "text-overflow"

    def call(doc, context)
      severity = context.measured ? "error" : "warn"
      doc.texts.filter_map do |t|
        node = t.node_id && doc.node(t.node_id)
        next unless node&.label_box

        box = context.text_box(t)
        inner = node.label_box.inset(PADDING)
        next if inner.contains_box?(box)

        finding(node.id, "label #{t.key} box #{describe(box)} is outside padded node area #{describe(inner)}",
                fix(box, inner), severity: severity)
      end
    end

    private

    def describe(b) = "#{b.x.round(1)},#{b.y.round(1)} #{b.w.round(1)}x#{b.h.round(1)}"

    def fix(box, inner)
      return "widen box to #{(((box.w + (2 * PADDING)) / GRID).ceil * GRID)} or shorten label" if box.w > inner.w
      return "grow the box height or move the label up" if box.h > inner.h

      "move the label inside the box, #{PADDING}px from each edge"
    end
  end

  # Color literals come from the resolved palette, from every source the
  # shared DeclaredProperty resolver knows: attributes, inline styles, and
  # <style> declarations, custom-property roles consumed through var()
  # included (light and dark scheme alike).
  class Palette < Base
    ID = "palette"
    SEVERITY = "warn"
    PROPS = %w[fill stroke stop-color flood-color lighting-color color].freeze
    COLOR = /#\h{3,8}\b|(?:rgba?|hsla?)\([^)]*\)/i

    def call(doc, context)
      allowed = context.palette.map(&:upcase)
      declarations(doc).flat_map do |prop, decl|
        decl.value.scan(COLOR).uniq.reject { |v| allowed.include?(v.upcase) }.map do |v|
          finding(decl.where, "color #{v} in #{DeclaredProperty.describe(decl, prop)} is not in the palette", "use a palette role")
        end
      end.uniq
    end

    private

    def declarations(doc)
      PROPS.flat_map { |p| DeclaredProperty.all(doc, p).map { |d| [ p, d ] } } +
        DeclaredProperty.custom(doc).map { |name, d| [ name, d ] }
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

  # Every place a presentation property is declared: each element's own
  # attribute and inline style (which also covers values an ancestor passes
  # down by inheritance) and every <style> block declaration, any selector.
  # The guards ask this one resolver so none of them misses a source.
  module DeclaredProperty
    Declaration = Struct.new(:where, :value, :source)

    module_function

    def all(doc, prop)
      css = stylesheet(doc).scan(/(?:\A|[\s;{])#{Regexp.escape(prop)}\s*:\s*([^;}]+)/).flatten
      own(doc, prop) + css.map { |v| Declaration.new("style", v.strip, :stylesheet) }
    end

    # Custom-property definitions (--name: value) in any <style> block, as
    # [name, Declaration] pairs, so a role read through var() is checked
    # where its value is set.
    def custom(doc)
      stylesheet(doc).scan(/(?:\A|[\s;{])(--[\w-]+)\s*:\s*([^;}]+)/).map do |name, v|
        [ name, Declaration.new("style", v.strip, :stylesheet) ]
      end
    end

    def stylesheet(doc) = doc.style_text.gsub(%r{/\*.*?\*/}m, "")

    def own(doc, prop)
      doc.elements.flat_map do |el|
        where = el.attributes["data-id"] || el.attributes["id"] || el.name
        inline = el.attributes["style"].to_s.scan(/(?:\A|;)\s*#{Regexp.escape(prop)}\s*:\s*([^;]+)/).flatten
        attr = el.attributes[prop]
        inline.map { |v| Declaration.new(where, v.strip, :inline) } + (attr ? [ Declaration.new(where, attr.strip, :attribute) ] : [])
      end
    end

    def describe(decl, prop)
      decl.source == :stylesheet ? "#{prop}: #{decl.value} in a style block" : "#{prop}=#{decl.value}"
    end
  end

  # No element carries a transform: the geometry model reads raw coordinates.
  class Transform < Base
    ID = "transform"

    def call(doc, _context)
      DeclaredProperty.all(doc, "transform").map do |d|
        finding(d.where, "#{DeclaredProperty.describe(d, 'transform')} is not allowed", "write the coordinates directly")
      end
    end
  end

  # Text sits on the alphabetic baseline; any other baseline, set on the text,
  # inherited from an ancestor, or declared in a stylesheet, moves glyphs off
  # the measured y.
  class TextBaseline < Base
    ID = "text-baseline"
    PROPS = %w[dominant-baseline alignment-baseline].freeze

    def call(doc, _context)
      PROPS.flat_map do |prop|
        DeclaredProperty.all(doc, prop).reject { |d| d.value == "alphabetic" }.map do |d|
          finding(d.where, "#{DeclaredProperty.describe(d, prop)} is not alphabetic", "remove #{prop} and place y on the baseline")
        end
      end
    end
  end

  # Font sizes are unitless or px, wherever they are declared.
  class FontUnit < Base
    ID = "font-unit"
    OK = /\A\d+(\.\d+)?(px)?\z/

    def call(doc, _context)
      DeclaredProperty.all(doc, "font-size").reject { |d| d.value.match?(OK) }.map do |d|
        finding(d.where, "#{DeclaredProperty.describe(d, 'font-size')} is not unitless or px", "use a px size such as 14")
      end
    end
  end

  # The text model resolves font-size and text-anchor from attributes and
  # inline styles only, so a style block declaring either would render
  # geometry the checks never see. Every text-geometry property must sit on
  # the text or an ancestor. The `font` shorthand sets the size too and is
  # never modeled, wherever it is declared, and neither is a size on a tspan.
  class TextGeometrySource < Base
    ID = "text-geometry-source"
    PROPS = %w[font-size text-anchor].freeze

    def call(doc, _context)
      longhand = PROPS.flat_map do |prop|
        DeclaredProperty.all(doc, prop).select { |d| d.source == :stylesheet }.map do |d|
          finding(d.where, "#{DeclaredProperty.describe(d, prop)} is not modeled", "set #{prop} as an attribute on the text")
        end
      end
      shorthand = DeclaredProperty.all(doc, "font").map do |d|
        finding(d.where, "#{DeclaredProperty.describe(d, 'font')} shorthand is not modeled", "use font-family and a font-size attribute instead")
      end
      longhand + shorthand + tspan_sizes(doc)
    end

    # Every line takes its <text>'s size, so a size set on a tspan is unmodeled.
    def tspan_sizes(doc)
      doc.elements.select { |el| el.name == "tspan" }.filter_map do |el|
        next unless el.attributes["font-size"] || el.attributes["style"].to_s.match?(/(?:\A|;)\s*font-size\s*:/)

        finding(el.attributes["id"] || "tspan", "font-size on a tspan is not modeled", "set font-size on the text, or split it into its own text")
      end
    end
  end

  # Text stays legible at the width the diagram is shown at. A viewBox wider
  # than DISPLAY_WIDTH is scaled down to it (a GitHub PR or README column),
  # so the smallest text is judged at that scale.
  class DisplayScale < Base
    ID = "display-scale"
    SEVERITY = "warn"
    DISPLAY_WIDTH = 880
    MIN_PX = 11

    def call(doc, _context)
      vb = doc.view_box
      return [] unless vb && vb.w > DISPLAY_WIDTH && doc.texts.any?

      scale = DISPLAY_WIDTH / vb.w
      small = doc.texts.min_by(&:font_size)
      shown = small.font_size * scale
      return [] if shown >= MIN_PX

      [ finding(small.key, "#{small.font_size.round}px text renders at #{shown.round(1)}px in a #{DISPLAY_WIDTH}px column",
                "draw at viewBox width #{DISPLAY_WIDTH} or less instead of scaling a wider canvas down") ]
    end
  end

  # The --json report: version 1, the measured flag, each file with its
  # findings as hashes, and an error and warning summary.
  def self.report(files, measured:)
    all = files.flat_map { |f| f[:findings] }
    {
      version: 1,
      measured: measured,
      files: files.map { |f| f.merge(findings: f[:findings].map(&:to_h)) },
      summary: { files: files.size, errors: all.count { |f| f.severity == "error" }, warnings: all.count { |f| f.severity == "warn" } }
    }
  end

  def self.exit_code(report) = report[:summary][:errors].positive? ? EXIT_FINDINGS : EXIT_OK
end
