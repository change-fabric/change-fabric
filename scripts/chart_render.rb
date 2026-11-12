#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "fileutils"
require "json"
require "optparse"
require_relative "diagram_palette"

# cf:chart's palette: cf:diagram's color roles plus the colors a chart
# derives from them (six categorical series colors and a five-step
# sequential ramp), for the light and the dark theme. The default roles are
# the default skin in skills/diagram/reference/grammar.md; a repo with a
# token file gets its own roles through DiagramPalette.
module ChartPalette
  DEFAULT = {
    light: {
      "--bg" => "#F5F5F5", "--surface" => "#FFFFFF", "--ink" => "#2D3142", "--muted" => "#4F5D75",
      "--soft" => "#5A6580", "--line" => "#4F5D75", "--rule" => "#D9DADD", "--accent" => "#B5401C",
      "--accent-tint" => "#F2E9E6", "--link" => "#2E5AA8"
    },
    dark: {
      "--bg" => "#2D3142", "--surface" => "#2D3142", "--ink" => "#F5F5F5", "--muted" => "#BFC0C0",
      "--soft" => "#A3ACC0", "--line" => "#A3ACC0", "--rule" => "#45495A", "--accent" => "#F08A59",
      "--accent-tint" => "#3D3844", "--link" => "#7FA9E6"
    }
  }.freeze
  RAMP_SHARES = [ 0.2, 0.4, 0.6, 0.8, 1.0 ].freeze
  SERIES_MAX = 6

  module_function

  # Roles for both themes: the repo's token file when one resolves, else the default skin.
  def roles(repo: nil, tokens: nil)
    return DEFAULT unless repo || tokens

    path = DiagramPalette.locate(repo: repo || Dir.pwd, tokens: tokens)
    return DEFAULT unless path

    r = DiagramPalette.resolve(path)
    { light: r.light, dark: r.dark }
  end

  # The roles plus the derived series and ramp colors, for one theme.
  def theme(roles)
    mix = ->(a, b, share) { DiagramPalette.hex(DiagramPalette.mix(DiagramPalette.rgb(roles[a]), DiagramPalette.rgb(roles[b]), share)) }
    series = [
      roles["--accent"], roles["--link"], roles["--ink"], mix.("--accent", "--link", 0.5),
      mix.("--accent", "--bg", 0.55), mix.("--link", "--bg", 0.55)
    ]
    derived = series.each_with_index.to_h { |h, i| [ "--s#{i + 1}", h ] }
    RAMP_SHARES.each_with_index { |s, i| derived["--ramp-#{i + 1}"] = mix.("--accent", "--bg", s) }
    roles.merge(derived)
  end

  # Every hex a chart drawn from these roles may use, for the palette check.
  def hexes(all = DEFAULT) = (theme(all[:light]).values + theme(all[:dark]).values).map(&:upcase).uniq
end

# Renders a chart.json spec into one standalone SVG on cf:diagram's skin.
# Deterministic: the same spec and roles give the same bytes, with no clock,
# randomness, or hash-order dependence. Geometry follows from the data; the
# lint (chart_lint.rb) re-renders the spec to confirm every mark.
#
#   ruby chart_render.rb SPEC.json [--out FILE] [--repo DIR] [--tokens FILE]
class ChartRender
  class Error < StandardError; end

  TYPES = %w[bar stacked-bar line schedule table scatter heatmap].freeze
  SERIES_TYPES = %w[bar stacked-bar line scatter].freeze
  W = 880
  PAD = 32
  RIGHT = W - 48
  TOP = 88
  SANS = 'Geist, Inter, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", ' \
         '"Noto Sans CJK SC", "Noto Sans CJK JP", sans-serif'
  CJK = /[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]/

  def self.render(spec, roles: ChartPalette::DEFAULT) = new(spec, roles: roles).svg

  def initialize(spec, roles: ChartPalette::DEFAULT)
    raise Error, "spec must be a JSON object" unless spec.is_a?(Hash)

    @spec = spec
    @type = spec["type"]
    raise Error, "type #{@type.inspect} is not one of #{TYPES.join(', ')}" unless TYPES.include?(@type)
    raise Error, "title is required" if spec["title"].to_s.strip.empty?

    @roles = roles
  end

  def svg
    height, body = send("build_#{@type.tr('-', '_')}")
    [
      %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{W} #{n(height)}" width="#{W}" height="#{n(height)}" ) +
        %(role="img" aria-labelledby="t d" data-chart-type="#{@type}">),
      "  #{el('title', { 'id' => 't' }, @spec['title'])}",
      "  #{el('desc', { 'id' => 'd' }, desc)}",
      style,
      "  #{el('rect', 'class' => 'bg', 'x' => 0, 'y' => 0, 'width' => W, 'height' => height, 'fill' => @roles[:light]['--bg'])}",
      "  #{el('text', { 'class' => 'chart-title', 'x' => PAD, 'y' => 44, 'font-size' => 18 }, @spec['title'])}",
      *body.map { |line| "  #{line}" },
      *data_table.map { |line| "  #{line}" },
      "</svg>",
      ""
    ].join("\n")
  end

  private

  # --- shared pieces -------------------------------------------------------

  def desc = @spec["desc"].to_s.strip.empty? ? "A #{@type.tr('-', ' ')} chart: #{@spec['title']}." : @spec["desc"]

  def style
    decl = ->(roles) { ChartPalette.theme(roles).map { |k, v| "#{k}: #{v};" }.join(" ") }
    series = (1..ChartPalette::SERIES_MAX).map { |i| ".s#{i} { fill: var(--s#{i}); } .line-s#{i} { stroke: var(--s#{i}); }" }
    ramp = (1..ChartPalette::RAMP_SHARES.size).map { |i| ".ramp-#{i} { fill: var(--ramp-#{i}); }" }
    <<~CSS.chomp.gsub(/^/, "  ")
      <style>
        svg { #{decl.(@roles[:light])} }
        @media (prefers-color-scheme: dark) {
          svg { #{decl.(@roles[:dark])} }
        }
        .bg { fill: var(--bg); }
        text { font-family: #{SANS}; }
        .chart-title { fill: var(--ink); font-weight: 600; }
        .axis-title { fill: var(--soft); }
        .tick-label, .legend-label { fill: var(--muted); }
        .cell { fill: var(--ink); }
        .header { fill: var(--ink); font-weight: 600; }
        .tick { stroke: var(--rule); stroke-width: 1; }
        .baseline { stroke: var(--ink); stroke-width: 1; }
        .rule-line { stroke: var(--rule); stroke-width: 1; }
        .mark-line { fill: none; stroke-width: 2; }
        .marks rect { stroke: var(--bg); stroke-width: 1; }
        #{series.join("\n    ")}
        #{ramp.join("\n    ")}
      </style>
    CSS
  end

  # The text alternative: one <desc> row per value, never drawn.
  def data_table
    rows = table_rows.map { |r| el("desc", {}, r) }
    [ %(<g data-role="data-table" aria-label="Data table">), *rows.map { |r| "  #{r}" }, "</g>" ]
  end

  def table_rows
    case @type
    when "table" then rows_of_table
    when "schedule" then tasks.map { |t| "#{t['name']}: #{t['start']} to #{t['end']}" }
    when "heatmap" then heat_cells.map { |r, c, v| "#{@spec['rows'][r]}, #{@spec['cols'][c]}: #{v}" }
    when "scatter" then series.flat_map { |s| s["points"].map { |x, y| "#{s['name']}: #{x}, #{y}" } }
    else series.flat_map { |s| s["values"].map { |k, v| "#{s['name']}, #{k}: #{v}" } }
    end
  end

  def rows_of_table
    cols = @spec["columns"]
    @spec["rows"].map { |row| cols.zip(row).map { |c, v| "#{c}: #{v}" }.join("; ") }
  end

  def axis_spec(name) = @spec[name].is_a?(Hash) ? @spec[name] : {}
  def axis_title(spec) = spec["unit"].to_s.empty? ? spec["label"].to_s : "#{spec['label']} (#{spec['unit']})"

  def series
    list = @spec["series"]
    raise Error, "series must be a non-empty array" unless list.is_a?(Array) && !list.empty?

    key = @type == "scatter" ? "points" : "values"
    list.each do |s|
      raise Error, "every series needs a name and #{key}" unless s.is_a?(Hash) && s["name"] && s[key].is_a?(Array)
    end
    list
  end

  def series_class(i) = "s#{i + 1}"

  def categories = series.flat_map { |s| s["values"].map { |k, _| k.to_s } }.uniq

  def value_of(s, cat) = s["values"].find { |k, _| k.to_s == cat }&.last

  # Ticks on a 1, 2, 5 ladder: the smallest step giving at most 6 ticks.
  def nice(lo, hi, integer: false)
    lo, hi = lo.to_f, hi.to_f
    if lo == hi
      lo -= 1
      hi += 1
    end
    span = hi - lo
    base = 10.0**(Math.log10(span).floor - 1)
    steps = (0..3).flat_map { |e| [ 1, 2, 5 ].map { |m| m * base * (10**e) } }
    steps = steps.select { |s| s >= 1 } if integer
    step = steps.find { |s| (((hi / s).ceil - (lo / s).floor) + 1) <= 6 } || steps.last
    first = (lo / step).floor
    count = (hi / step).ceil - first
    decimals = [ 0, -Math.log10(step).floor ].max
    ticks = (0..count).map { |i| ((first + i) * step).round(10) }
    [ ticks, decimals ]
  end

  def fmt(v, decimals)
    s = format("%.#{decimals}f", v)
    s.match?(/\A-0(\.0+)?\z/) ? s.delete_prefix("-") : s
  end

  def scale(d0, d1, r0, r1) = ->(v) { r0 + ((v.to_f - d0) / (d1 - d0) * (r1 - r0)) }

  def text_width(str, size) = str.to_s.each_char.sum { |c| c.match?(CJK) ? 1.0 : 0.6 } * size

  # A numeric value axis: data attributes, ticks across the plot, labels.
  def linear_axis(name, spec, ticks, decimals, position:, map:, plot:)
    left, top, right, bottom = plot
    attrs = { "class" => "axis", "data-axis" => name, "data-role" => position == :left ? "value-y" : "value-x",
              "data-scale" => spec.fetch("scale", "linear"), "data-label" => spec["label"].to_s, "data-unit" => spec["unit"].to_s,
              "data-min" => n(ticks.first), "data-max" => n(ticks.last) }
    out = [ open_tag("g", attrs) ]
    ticks.each do |t|
      p = map.(t)
      label = spec["format"] ? spec["format"].(t) : fmt(t, decimals)
      if position == :left
        out << "  #{el('line', 'class' => 'tick', 'data-value' => n(t), 'x1' => left, 'y1' => p, 'x2' => right, 'y2' => p)}"
        out << "  #{el('text', { 'class' => 'tick-label', 'x' => left - 8, 'y' => p + 4, 'font-size' => 12, 'text-anchor' => 'end' }, label)}"
      else
        out << "  #{el('line', 'class' => 'tick', 'data-value' => n(t), 'x1' => p, 'y1' => top, 'x2' => p, 'y2' => bottom)}"
        out << "  #{el('text', { 'class' => 'tick-label', 'x' => p, 'y' => bottom + 20, 'font-size' => 12, 'text-anchor' => 'middle' }, label)}"
      end
    end
    out << "  #{axis_title_el(spec, position, plot)}"
    out << "</g>"
  end

  # A category axis: one label per band, no tick lines.
  def band_axis(name, spec, labels, position:, centers:, plot:)
    left, _top, _right, bottom = plot
    attrs = { "class" => "axis", "data-axis" => name, "data-role" => "category", "data-scale" => "band",
              "data-label" => spec["label"].to_s, "data-unit" => spec["unit"].to_s }
    out = [ open_tag("g", attrs) ]
    labels.each_with_index do |label, i|
      c = centers[i]
      out << if position == :left
               "  #{el('text', { 'class' => 'tick-label', 'x' => left - 8, 'y' => c + 4, 'font-size' => 12, 'text-anchor' => 'end' }, label)}"
      else
               "  #{el('text', { 'class' => 'tick-label', 'x' => c, 'y' => bottom + 20, 'font-size' => 12, 'text-anchor' => 'middle' }, label)}"
      end
    end
    out << "  #{axis_title_el(spec, position, plot)}"
    out << "</g>"
  end

  # Left axes are titled above the plot, bottom axes below their tick labels.
  def axis_title_el(spec, position, plot)
    left, _top, right, bottom = plot
    if position == :left
      el("text", { "class" => "axis-title", "x" => PAD, "y" => 72, "font-size" => 12 }, axis_title(spec))
    else
      el("text", { "class" => "axis-title", "x" => (left + right) / 2.0, "y" => bottom + 44, "font-size" => 12, "text-anchor" => "middle" }, axis_title(spec))
    end
  end

  # Swatch and name per series, flowing left to right from the plot's left edge.
  def legend(x, y)
    out = [ open_tag("g", "class" => "legend") ]
    series.each_with_index do |s, i|
      out << "  #{el('rect', 'class' => "swatch #{series_class(i)}", 'data-series' => s['name'], 'x' => x, 'y' => y, 'width' => 12, 'height' => 12)}"
      out << "  #{el('text', { 'class' => 'legend-label', 'data-series' => s['name'], 'x' => x + 18, 'y' => y + 10, 'font-size' => 12 }, s['name'])}"
      x += 18 + text_width(s["name"], 12) + 24
    end
    out << "</g>"
  end

  def left_gutter(labels, size = 12) = PAD + (labels.map { |l| text_width(l, size) }.max || 0) + 8

  # --- bar and stacked-bar -------------------------------------------------

  def build_bar = bars(stacked: false)
  def build_stacked_bar = bars(stacked: true)

  def bars(stacked:)
    cats = categories
    raise Error, "bar charts need at least one category" if cats.empty?

    vals = if stacked
             cats.flat_map do |c|
               vs = series.map { |s| value_of(s, c).to_f }
               [ vs.select(&:positive?).sum, vs.select(&:negative?).sum ]
             end
    else
             series.flat_map { |s| s["values"].map { |_, v| v.to_f } }
    end
    ticks, dec = nice([ 0, vals.min ].min, [ 0, vals.max ].max)
    xs = axis_spec("x")
    ys = axis_spec("y")
    @spec["orientation"] == "horizontal" ? bars_horizontal(cats, ticks, dec, xs, ys, stacked) : bars_vertical(cats, ticks, dec, xs, ys, stacked)
  end

  def bars_vertical(cats, ticks, dec, xs, ys, stacked)
    left = left_gutter(ticks.map { |t| fmt(t, dec) })
    plot = [ left, TOP, RIGHT, TOP + 280 ]
    vmap = scale(ticks.first, ticks.last, plot[3], plot[1])
    step = (RIGHT - left) / cats.size.to_f
    centers = cats.each_index.map { |i| left + (step * (i + 0.5)) }
    body = linear_axis("y", ys, ticks, dec, position: :left, map: vmap, plot: plot)
    body += band_axis("x", xs, cats, position: :bottom, centers: centers, plot: plot)
    body += bar_marks(cats, centers, step * 0.7, vmap, stacked, vertical: true)
    y0 = vmap.(0)
    body << el("line", "class" => "baseline", "data-value" => 0, "x1" => left, "y1" => y0, "x2" => RIGHT, "y2" => y0)
    legend_y = plot[3] + 64
    [ legend_y + 40, body + legend(left, legend_y) ]
  end

  def bars_horizontal(cats, ticks, dec, xs, ys, stacked)
    left = left_gutter(cats)
    bottom = TOP + [ cats.size * 40, 160 ].max
    plot = [ left, TOP, RIGHT, bottom ]
    vmap = scale(ticks.first, ticks.last, left, RIGHT)
    step = (bottom - TOP) / cats.size.to_f
    centers = cats.each_index.map { |i| TOP + (step * (i + 0.5)) }
    body = band_axis("x", xs, cats, position: :left, centers: centers, plot: plot)
    body += linear_axis("y", ys, ticks, dec, position: :bottom, map: vmap, plot: plot)
    body += bar_marks(cats, centers, step * 0.7, vmap, stacked, vertical: false)
    x0 = vmap.(0)
    body << el("line", "class" => "baseline", "data-value" => 0, "x1" => x0, "y1" => TOP, "x2" => x0, "y2" => bottom)
    legend_y = bottom + 64
    [ legend_y + 40, body + legend(left, legend_y) ]
  end

  # One rect per series and category. Grouped bars split the band; stacked
  # bars share it and accumulate from the zero baseline.
  def bar_marks(cats, centers, band, vmap, stacked, vertical:)
    out = [ open_tag("g", "class" => "marks") ]
    cats.each_with_index do |cat, ci|
      pos = 0.0
      neg = 0.0
      series.each_with_index do |s, si|
        v = value_of(s, cat)
        next if v.nil?

        if stacked
          from = v.negative? ? neg : pos
          to = from + v
          v.negative? ? neg = to : pos = to
          offset = centers[ci] - (band / 2)
          thick = band
        else
          from = 0
          to = v
          thick = band / series.size
          offset = centers[ci] - (band / 2) + (thick * si)
        end
        a, b = [ vmap.(from), vmap.(to) ].minmax
        geom = vertical ? { "x" => offset, "y" => a, "width" => thick, "height" => b - a } : { "x" => a, "y" => offset, "width" => b - a, "height" => thick }
        out << "  #{el('rect', { 'class' => "mark #{series_class(si)}", 'data-series' => s['name'], 'data-key' => cat, 'data-value' => raw(v) }.merge(geom))}"
      end
    end
    out << "</g>"
  end

  # --- line ----------------------------------------------------------------

  def build_line
    cats = categories
    vals = series.flat_map { |s| s["values"].map { |_, v| v.to_f } }
    ticks, dec = nice(vals.min, vals.max)
    left = left_gutter(ticks.map { |t| fmt(t, dec) })
    plot = [ left, TOP, RIGHT, TOP + 280 ]
    vmap = scale(ticks.first, ticks.last, plot[3], plot[1])
    step = (RIGHT - left) / cats.size.to_f
    centers = cats.each_index.map { |i| left + (step * (i + 0.5)) }
    body = linear_axis("y", axis_spec("y"), ticks, dec, position: :left, map: vmap, plot: plot)
    body += band_axis("x", axis_spec("x"), cats, position: :bottom, centers: centers, plot: plot)
    body << open_tag("g", "class" => "marks")
    series.each_with_index do |s, si|
      pts = s["values"].map { |k, v| [ centers[cats.index(k.to_s)], vmap.(v) ] }
      d = pts.each_with_index.map { |(x, y), i| "#{i.zero? ? 'M' : 'L'}#{n(x)} #{n(y)}" }.join(" ")
      body << "  #{el('path', 'class' => "mark-line line-#{series_class(si)}", 'data-series' => s['name'], 'data-key' => 'line', 'd' => d)}"
      s["values"].each_with_index do |(k, v), i|
        x, y = pts[i]
        body << "  #{el('circle', 'class' => "mark #{series_class(si)}", 'data-series' => s['name'], 'data-key' => k.to_s, 'data-value' => raw(v), 'cx' => x, 'cy' => y, 'r' => 3)}"
      end
    end
    body << "</g>"
    legend_y = plot[3] + 64
    [ legend_y + 40, body + legend(left, legend_y) ]
  end

  # --- scatter -------------------------------------------------------------

  def build_scatter
    pts = series.flat_map { |s| s["points"] }
    raise Error, "scatter needs at least one point" if pts.empty?

    xt, xd = nice(*pts.map { |x, _| x.to_f }.minmax)
    yt, yd = nice(*pts.map { |_, y| y.to_f }.minmax)
    left = left_gutter(yt.map { |t| fmt(t, yd) })
    plot = [ left, TOP, RIGHT, TOP + 280 ]
    xmap = scale(xt.first, xt.last, left, RIGHT)
    ymap = scale(yt.first, yt.last, plot[3], TOP)
    body = linear_axis("y", axis_spec("y"), yt, yd, position: :left, map: ymap, plot: plot)
    body += linear_axis("x", axis_spec("x"), xt, xd, position: :bottom, map: xmap, plot: plot)
    body << open_tag("g", "class" => "marks")
    series.each_with_index do |s, si|
      s["points"].each_with_index do |(x, y), i|
        body << "  #{el('circle', 'class' => "mark #{series_class(si)}", 'data-series' => s['name'], 'data-key' => i, 'data-value' => "#{raw(x)},#{raw(y)}", 'cx' => xmap.(x), 'cy' => ymap.(y), 'r' => 4)}"
      end
    end
    body << "</g>"
    legend_y = plot[3] + 64
    [ legend_y + 40, body + legend(left, legend_y) ]
  end

  # --- schedule ------------------------------------------------------------

  def tasks
    list = @spec["tasks"]
    raise Error, "schedule needs a non-empty tasks array" unless list.is_a?(Array) && !list.empty?
    raise Error, "every task needs name, start and end" unless list.all? { |t| t.is_a?(Hash) && t["name"] && t["start"] && t["end"] }

    list
  end

  def dates? = tasks.all? { |t| [ t["start"], t["end"] ].all? { |v| v.is_a?(String) } }

  def time_of(v)
    return v.to_f unless v.is_a?(String)

    Date.iso8601(v).jd.to_f
  rescue Date::Error
    raise Error, "#{v.inspect} is not an ISO date (YYYY-MM-DD) or a number"
  end

  def build_schedule
    times = tasks.flat_map { |t| [ time_of(t["start"]), time_of(t["end"]) ] }
    ticks, dec = nice(times.min, times.max, integer: dates?)
    xs = axis_spec("x").dup
    xs["scale"] = "time"
    xs["format"] = ->(t) { Date.jd(t.round).strftime("%b %-d") } if dates?
    names = tasks.map { |t| t["name"].to_s }
    left = left_gutter(names)
    bottom = TOP + (names.size * 32)
    plot = [ left, TOP, RIGHT, bottom ]
    tmap = scale(ticks.first, ticks.last, left, RIGHT)
    centers = names.each_index.map { |i| TOP + (32 * i) + 16 }
    body = linear_axis("x", xs, ticks, dec, position: :bottom, map: tmap, plot: plot)
    body += band_axis("y", axis_spec("y"), names, position: :left, centers: centers, plot: plot)
    body << open_tag("g", "class" => "marks")
    tasks.each_with_index do |t, i|
      a = tmap.(time_of(t["start"]))
      b = tmap.(time_of(t["end"]))
      body << "  #{el('rect', 'class' => 'mark s1', 'data-series' => 'tasks', 'data-key' => t['name'], 'data-value' => "#{t['start']}..#{t['end']}",
                      'x' => a, 'y' => centers[i] - 8, 'width' => b - a, 'height' => 16)}"
    end
    body << "</g>"
    [ bottom + 80, body ]
  end

  # --- table ---------------------------------------------------------------

  def build_table
    cols = @spec["columns"]
    rows = @spec["rows"]
    raise Error, "table needs columns and rows arrays" unless cols.is_a?(Array) && rows.is_a?(Array) && !cols.empty?
    raise Error, "every row needs #{cols.size} cells" unless rows.all? { |r| r.is_a?(Array) && r.size == cols.size }

    widths = cols.each_index.map { |c| ([ text_width(cols[c], 13) ] + rows.map { |r| text_width(raw(r[c]), 13) }).max + 24 }
    raise Error, "table is #{widths.sum.round}px wide, over #{W - (2 * PAD)}; shorten cells or split it" if widths.sum > W - (2 * PAD)

    xs = widths.each_index.map { |c| PAD + widths[0...c].sum }
    right = PAD + widths.sum
    body = [ open_tag("g", "class" => "table") ]
    cols.each_with_index { |name, c| body << "  #{cell_text('header', xs[c], widths[c], TOP, name, numeric: numeric_col?(c))}" }
    body << "  #{el('line', 'class' => 'baseline', 'x1' => PAD, 'y1' => TOP + 10, 'x2' => right, 'y2' => TOP + 10)}"
    rows.each_with_index do |row, r|
      y = TOP + (28 * (r + 1))
      row.each_with_index do |v, c|
        body << "  #{cell_text('mark cell', xs[c], widths[c], y, raw(v), numeric: numeric_col?(c), key: "#{r},#{c}")}"
      end
      body << "  #{el('line', 'class' => 'rule-line', 'x1' => PAD, 'y1' => y + 10, 'x2' => right, 'y2' => y + 10)}"
    end
    body << "</g>"
    [ TOP + (28 * rows.size) + 48, body ]
  end

  def numeric_col?(c) = @spec["rows"].all? { |r| r[c].is_a?(Numeric) }

  def cell_text(cls, x, w, y, content, numeric:, key: nil)
    attrs = { "class" => cls }
    attrs.merge!("data-key" => key, "data-value" => content) if key
    if numeric
      attrs.merge!("x" => x + w - 12, "y" => y, "font-size" => 13, "text-anchor" => "end")
    else
      attrs.merge!("x" => x, "y" => y, "font-size" => 13)
    end
    el("text", attrs, content)
  end

  # --- heatmap -------------------------------------------------------------

  def heat_cells
    rows = @spec["rows"]
    cols = @spec["cols"]
    cells = @spec["cells"]
    raise Error, "heatmap needs rows, cols and cells arrays" unless [ rows, cols, cells ].all?(Array)
    raise Error, "cells must be #{rows.size} rows of #{cols.size} numbers" unless cells.size == rows.size && cells.all? { |r| r.is_a?(Array) && r.size == cols.size && r.all?(Numeric) }

    cells.each_with_index.flat_map { |row, r| row.each_with_index.map { |v, c| [ r, c, v ] } }
  end

  def build_heatmap
    cells = heat_cells
    rows = @spec["rows"].map(&:to_s)
    cols = @spec["cols"].map(&:to_s)
    lo, hi = cells.map(&:last).minmax
    left = left_gutter(rows)
    cw = (RIGHT - left) / cols.size.to_f
    bottom = TOP + (rows.size * 32)
    plot = [ left, TOP, RIGHT, bottom ]
    steps = ChartPalette::RAMP_SHARES.size
    body = band_axis("y", axis_spec("y"), rows, position: :left, centers: rows.each_index.map { |i| TOP + (32 * i) + 16 }, plot: plot)
    body += band_axis("x", axis_spec("x"), cols, position: :bottom, centers: cols.each_index.map { |i| left + (cw * (i + 0.5)) }, plot: plot)
    body << open_tag("g", "class" => "marks")
    cells.each do |r, c, v|
      bin = hi == lo ? steps : ((v - lo) / (hi - lo).to_f * steps).floor.clamp(0, steps - 1) + 1
      body << "  #{el('rect', 'class' => "mark ramp-#{bin}", 'data-key' => "#{r},#{c}", 'data-value' => raw(v),
                      'x' => left + (cw * c) + 1, 'y' => TOP + (32 * r) + 1, 'width' => cw - 2, 'height' => 30)}"
    end
    body << "</g>"
    body += scale_legend(left, bottom + 64, lo, hi)
    [ bottom + 104, body ]
  end

  def scale_legend(x, y, lo, hi)
    vs = axis_spec("value")
    out = [ open_tag("g", "class" => "scale-legend", "data-min" => raw(lo), "data-max" => raw(hi), "data-label" => vs["label"].to_s, "data-unit" => vs["unit"].to_s) ]
    out << "  #{el('text', { 'class' => 'legend-label', 'x' => x, 'y' => y + 10, 'font-size' => 12 }, raw(lo))}"
    sx = x + text_width(raw(lo), 12) + 8
    ChartPalette::RAMP_SHARES.each_index do |i|
      out << "  #{el('rect', 'class' => "swatch ramp-#{i + 1}", 'x' => sx + (24 * i), 'y' => y, 'width' => 24, 'height' => 12)}"
    end
    ex = sx + (24 * ChartPalette::RAMP_SHARES.size) + 8
    out << "  #{el('text', { 'class' => 'legend-label', 'x' => ex, 'y' => y + 10, 'font-size' => 12 }, raw(hi))}"
    title = axis_title(vs)
    unless title.empty?
      out << "  #{el('text', { 'class' => 'axis-title', 'x' => ex + text_width(raw(hi), 12) + 16, 'y' => y + 10, 'font-size' => 12 }, title)}"
    end
    out << "</g>"
  end

  # --- markup --------------------------------------------------------------

  # Numbers rounded to 2 places, trailing zeros dropped, so output is stable.
  def n(v)
    return v.to_s unless v.is_a?(Numeric)

    s = format("%.2f", v).sub(/\.?0+\z/, "")
    s == "-0" ? "0" : s
  end

  def raw(v) = v.is_a?(Float) && v == v.floor && v.abs < 1e15 ? v.to_i.to_s : v.to_s

  def esc(s) = s.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")

  def attrs_s(attrs) = attrs.map { |k, v| %( #{k}="#{esc(n(v))}") }.join

  def open_tag(name, attrs) = "<#{name}#{attrs_s(attrs)}>"

  def el(name, attrs = {}, text = nil)
    text.nil? ? "<#{name}#{attrs_s(attrs)}/>" : "<#{name}#{attrs_s(attrs)}>#{esc(text)}</#{name}>"
  end

  public

  def self.main(argv, out: $stdout, err: $stderr)
    opts = {}
    rest = OptionParser.new do |o|
      o.on("--out FILE") { |f| opts[:out] = f }
      o.on("--repo DIR") { |d| opts[:repo] = d }
      o.on("--tokens FILE") { |f| opts[:tokens] = f }
    end.parse(argv)
    raise Error, "usage: chart_render.rb SPEC.json [--out FILE] [--repo DIR] [--tokens FILE]" unless rest.size == 1

    spec = JSON.parse(File.read(rest.first))
    svg = render(spec, roles: ChartPalette.roles(repo: opts[:repo], tokens: opts[:tokens]))
    if opts[:out]
      FileUtils.mkdir_p(File.dirname(opts[:out]))
      File.write(opts[:out], svg)
    else
      out.write(svg)
    end
    0
  rescue Error, JSON::ParserError, OptionParser::ParseError, DiagramPalette::Error, DesignConfig::Error, SystemCallError => e
    err.puts("chart_render: #{e.message}")
    2
  end
end

exit(ChartRender.main(ARGV)) if $PROGRAM_NAME == __FILE__
