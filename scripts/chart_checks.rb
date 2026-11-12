# frozen_string_literal: true

require_relative "svg_checks"
require_relative "chart_render"

# The cf:chart lint rules. Every shared SVG check comes from SvgChecks; the
# checks here read the data attributes chart_render.rb writes (data-axis,
# data-scale, data-series, data-key, data-value) and, for value-fidelity,
# re-render the chart.json spec and compare every mark.
module ChartChecks
  Base = SvgChecks::Base
  TYPES = ChartRender::TYPES
  SERIES_TYPES = ChartRender::SERIES_TYPES
  MEASURED_SCALES = %w[linear time].freeze
  TICKS = (3..8)
  RAMP_MIN = 3.0
  GEOMETRY = %w[x y width height cx cy r d data-value].freeze

  # What every check may consult: the SvgChecks context fields plus the spec.
  Context = Data.define(:type, :widths, :measured, :palette, :spec) do
    def text_box(text)
      x, y, w, h = widths.fetch(text.key) { [ text.x, text.y - (0.8 * text.font_size), 0.0, text.font_size ] }
      DiagramSvg::Box.new(x: x, y: y, w: w, h: h)
    end
  end

  module_function

  def match(doc, xpath) = REXML::XPath.match(doc.root, xpath)
  def classes(el) = el.attributes["class"].to_s.split
  def axes(doc) = match(doc, "//g").select { |g| classes(g).include?("axis") }
  def marks(doc) = doc.elements.select { |el| (classes(el) & %w[mark mark-line]).any? }
  def text_of(el) = el.texts.map(&:value).join.strip

  # The root declares one of the seven types.
  class TypeDeclared < Base
    ID = "type-declared"

    def call(_doc, context)
      return [] if TYPES.include?(context.type)

      [ finding("svg", "data-chart-type #{context.type.inspect} is not one of #{TYPES.join(', ')}", "declare a supported type") ]
    end
  end

  # Every axis is titled; a numeric or time axis also names its unit.
  class AxisLabel < Base
    ID = "axis-label"

    def call(doc, context)
      return [] if context.type == "table" || !TYPES.include?(context.type)

      axes = ChartChecks.axes(doc)
      return [ finding("svg", "no <g class=\"axis\"> found", "title each axis with a label and unit") ] if axes.empty?

      axes.flat_map do |g|
        name = g.attributes["data-axis"] || "axis"
        title = g.elements.find { |el| ChartChecks.classes(el).include?("axis-title") }
        out = []
        if g.attributes["data-label"].to_s.strip.empty? || title.nil? || ChartChecks.text_of(title).empty?
          out << finding(name, "axis #{name} has no title", "set #{name}.label in chart.json")
        end
        if MEASURED_SCALES.include?(g.attributes["data-scale"]) && g.attributes["data-unit"].to_s.strip.empty?
          out << finding(name, "#{g.attributes['data-scale']} axis #{name} carries no unit", "set #{name}.unit in chart.json")
        end
        out
      end
    end
  end

  # A bar's length is read from zero, so the value axis must include it.
  class ScaleZero < Base
    ID = "scale-zero"

    def call(doc, context)
      return [] unless %w[bar stacked-bar].include?(context.type)

      axis = ChartChecks.axes(doc).find { |g| g.attributes["data-role"].to_s.start_with?("value") }
      return [ finding("svg", "no value axis", "render the chart with chart_render.rb") ] unless axis

      lo = axis.attributes["data-min"].to_f
      hi = axis.attributes["data-max"].to_f
      base = ChartChecks.match(doc, "//line").any? { |l| ChartChecks.classes(l).include?("baseline") && l.attributes["data-value"] == "0" }
      return [] if lo <= 0 && hi >= 0 && base

      [ finding(axis.attributes["data-axis"] || "axis", "bar baseline is not 0 (domain #{lo} to #{hi})", "start the value axis at 0") ]
    end
  end

  # A numeric axis carries 3 to 8 ticks.
  class TickCount < Base
    ID = "tick-count"

    def call(doc, _context)
      ChartChecks.axes(doc).select { |g| MEASURED_SCALES.include?(g.attributes["data-scale"]) }.filter_map do |g|
        n = g.elements.count { |el| el.name == "line" && ChartChecks.classes(el).include?("tick") }
        finding(g.attributes["data-axis"] || "axis", "#{n} ticks, outside #{TICKS.min} to #{TICKS.max}", "pick a step giving 3 to 8 ticks") unless TICKS.cover?(n)
      end
    end
  end

  # At most six series, each in one of the six categorical colors.
  class SeriesCap < Base
    ID = "series-cap"
    COLOR_CLASS = /\A(?:line-)?s[1-6]\z/

    def call(doc, context)
      return [] unless SERIES_TYPES.include?(context.type)

      marks = ChartChecks.marks(doc)
      names = marks.map { |m| m.attributes["data-series"] }.compact.uniq
      out = []
      out << finding("svg", "#{names.size} series exceed 6", "split the chart or group the small series") if names.size > ChartPalette::SERIES_MAX
      marks.reject { |m| ChartChecks.classes(m).any? { |c| c.match?(COLOR_CLASS) } }.each do |m|
        out << finding(m.attributes["data-series"] || m.name, "mark lacks a categorical color class s1 to s6", "color it with a series class")
      end
      out.uniq
    end
  end

  # Every series is named by a legend entry or a direct label.
  class LegendOrDirectLabel < Base
    ID = "legend-or-direct-label"

    def call(doc, context)
      return [] unless SERIES_TYPES.include?(context.type)

      labelled = ChartChecks.match(doc, "//text").select do |t|
        ChartChecks.classes(t).include?("direct-label") || ChartChecks.classes(t.parent).include?("legend")
      end
      named = labelled.map { |t| t.attributes["data-series"] || ChartChecks.text_of(t) }
      ChartChecks.marks(doc).filter_map { |m| m.attributes["data-series"] }.uniq.reject { |s| named.include?(s) }.map do |s|
        finding(s, "series #{s} has no legend entry or direct label", "add it to the legend")
      end
    end
  end

  # A text alternative carries every value.
  class DataTable < Base
    ID = "data-table"

    def call(doc, _context)
      table = ChartChecks.match(doc, "//g").find { |g| g.attributes["data-role"] == "data-table" }
      return [ finding("svg", "no <g data-role=\"data-table\">", "render with chart_render.rb, which writes one") ] unless table

      text = ChartChecks.match(table, ".//desc").map { |d| ChartChecks.text_of(d) }.join("\n")
      ChartChecks.marks(doc).filter_map { |m| m.attributes["data-value"] }.uniq.filter_map do |v|
        parts = v.split(/,|\.\./)
        finding("data-table", "value #{v} is missing from the data table", "re-render from chart.json") unless parts.all? { |p| text.include?(p) }
      end
    end
  end

  # Mark geometry matches what the spec renders to.
  class ValueFidelity < Base
    ID = "value-fidelity"

    def call(doc, context)
      unless context.spec
        return [ finding("svg", "no --spec given, mark geometry was not checked", "pass --spec chart.json", severity: "notice") ]
      end

      expected = index(DiagramSvg::Document.new(ChartRender.render(context.spec)))
      actual = index(doc)
      missing = (expected.keys - actual.keys).map { |k| finding(k, "mark #{k} from the spec is not drawn", "re-render from chart.json") }
      extra = (actual.keys - expected.keys).map { |k| finding(k, "mark #{k} is not in the spec", "re-render from chart.json") }
      drift = (expected.keys & actual.keys).flat_map do |k|
        (GEOMETRY + [ "text" ]).filter_map do |attr|
          want = expected[k][attr]
          got = actual[k][attr]
          finding(k, "#{attr} is #{got.inspect}, the spec gives #{want.inspect}", "re-render from chart.json") unless want == got
        end
      end
      missing + extra + drift
    rescue ChartRender::Error => e
      [ finding("spec", "spec does not render: #{e.message}", "fix chart.json") ]
    end

    private

    def index(doc)
      ChartChecks.marks(doc).to_h do |m|
        a = m.attributes
        [ "#{a['data-series']}|#{a['data-key']}", GEOMETRY.to_h { |g| [ g, a[g] ] }.merge("text" => ChartChecks.text_of(m)) ]
      end
    end
  end

  # A heatmap shows its color scale.
  class HeatmapLegend < Base
    ID = "heatmap-legend"

    def call(doc, context)
      return [] unless context.type == "heatmap"

      legend = ChartChecks.match(doc, "//g").find { |g| ChartChecks.classes(g).include?("scale-legend") }
      swatches = legend ? legend.elements.count { |el| el.name == "rect" && ChartChecks.classes(el).include?("swatch") } : 0
      return [] if swatches >= 2

      [ finding("svg", "heatmap has no color-scale legend", "add a <g class=\"scale-legend\"> with its swatches") ]
    end
  end

  # The heatmap ramp comes from the palette, grows in contrast step by step,
  # and its top step clears 3:1 against the background in both themes.
  class SequentialContrast < Base
    ID = "sequential-contrast"

    def call(doc, context)
      return [] unless context.type == "heatmap"

      css = DiagramPalette.strip_comments(doc.style_text)
      top = css.gsub(/@media[^{]*\{(?:[^{}]*\{[^{}]*\})*[^{}]*\}/m, "")
      light = DiagramPalette.declarations(DiagramPalette.rules(top).select { |s, _| s == "svg" }.map(&:last).join(";"))
      dark = light.merge(DiagramPalette.declarations(DiagramPalette.dark_block(css)))
      { "light" => light, "dark" => dark }.flat_map { |theme, vars| judge(theme, vars, context) }
    end

    private

    def judge(theme, vars, context)
      ramp = (1..ChartPalette::RAMP_SHARES.size).map { |i| vars["--ramp-#{i}"] }
      bg = vars["--bg"]
      return [ finding("style", "#{theme} theme lacks --bg or a --ramp-1 to --ramp-5 step", "render with chart_render.rb") ] if bg.nil? || ramp.any?(&:nil?)

      off = ramp.reject { |h| context.palette.map(&:upcase).include?(h.upcase) }
      return [ finding("style", "#{theme} ramp #{off.join(' ')} is not derived from the palette roles", "derive the ramp from --accent and --bg") ] if off.any?

      ratios = ramp.map { |h| DiagramPalette.contrast(h, bg) }
      out = []
      out << finding("style", "#{theme} ramp contrast does not rise step by step", "order the ramp from --bg toward --accent") unless ratios.each_cons(2).all? { |a, b| b > a }
      out << finding("style", "#{theme} top ramp step is #{ratios.last.round(2)}:1 on --bg, under #{RAMP_MIN}", "use an accent with more contrast") if ratios.last < RAMP_MIN
      out
    end
  end

  SHARED = [ SvgChecks::A11y, SvgChecks::XmlSafety, SvgChecks::ViewboxClip, SvgChecks::TextOverflow, SvgChecks::Palette,
             SvgChecks::FontStack, SvgChecks::ThemeFallback, SvgChecks::Transform, SvgChecks::TextBaseline,
             SvgChecks::FontUnit, SvgChecks::TextGeometrySource, SvgChecks::DisplayScale ].freeze
  CHART = [ TypeDeclared, AxisLabel, ScaleZero, TickCount, SeriesCap, LegendOrDirectLabel, DataTable, ValueFidelity,
            HeatmapLegend, SequentialContrast ].freeze
  ALL = (SHARED + CHART).freeze

  def self.all = ALL.map(&:new)
end
