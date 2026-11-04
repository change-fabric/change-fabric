#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "color_math"
require_relative "design_config"

# Resolves a project's own token file into cf:diagram's color roles, so a
# diagram is drawn in the brand of the repo it lives in. The token file is
# found the way the rest of change-fabric finds it: an explicit path, then
# change_config.design.tokens in the root CHANGE.md, then a tokens.css at
# the repo root. Light values come from the first `:root` block, dark ones
# from the first block inside `@media (prefers-color-scheme: dark)` (or a
# `[data-theme="dark"]` rule), each resolved through `var()` and
# `color-mix(in srgb, ...)` to literal hex, because a standalone SVG cannot
# reach the app's stylesheet.
#
#   ruby diagram_palette.rb [--repo DIR] [--tokens FILE] [--json]
module DiagramPalette
  class Error < StandardError; end

  # Diagram role => app tokens to try, first match wins. A role with no
  # match is derived (see DERIVED) or falls back to the default skin.
  ROLE_SOURCES = {
    "--bg" => %w[--bg --background --paper --color-bg],
    "--surface" => %w[--surface --card --panel-bg --paper-2 --bg],
    "--ink" => %w[--ink --text --fg --foreground --heading],
    "--muted" => %w[--muted --text-muted --muted-foreground --secondary],
    "--soft" => %w[--soft --muted --text-muted --muted-foreground],
    "--line" => %w[--line --border-strong --muted --text-muted],
    "--rule" => %w[--rule --border --hairline --divider],
    "--accent" => %w[--accent --primary --brand --link],
    "--link" => %w[--link --accent --primary]
  }.freeze
  # accent-tint: the accent mixed into bg at this share, as a focal fill.
  TINT_SHARE = { light: 0.10, dark: 0.14 }.freeze
  TEXT_ROLES = %w[--ink --muted --soft --accent --link].freeze
  TEXT_MIN = 4.5
  STROKE_MIN = 3.0
  FLOORS = TEXT_ROLES.to_h { |r| [ r, TEXT_MIN ] }.merge("--line" => STROKE_MIN).freeze

  Result = Data.define(:source, :light, :dark, :warnings) do
    def hexes = (light.values + dark.values).uniq

    def css
      decl = ->(roles) { roles.map { |k, v| "#{k}: #{v};" }.join(" ") }
      "svg { #{decl.(light)} }\n@media (prefers-color-scheme: dark) {\n  svg { #{decl.(dark)} }\n}"
    end

    def to_h = { source:, light:, dark:, warnings: }
  end

  module_function

  def locate(repo:, tokens: nil)
    return File.expand_path(tokens, repo) if tokens

    configured = DesignConfig.load(repo).tokens
    [ configured, "tokens.css" ].map { |p| File.expand_path(p, repo) }.find { |p| File.file?(p) }
  end

  # `css` overrides the file's text, for a caller that has already expanded
  # its local @imports, so imported declarations reach the roles too.
  def resolve(path, css: nil)
    raise Error, "cannot read tokens #{path}" unless path && File.file?(path)

    css = strip_comments(css || File.read(path))
    light_vars = declarations(root_block(css))
    dark_vars = light_vars.merge(declarations(dark_block(css)))
    light = roles(light_vars, :light)
    dark = roles(dark_vars, :dark)
    Result.new(source: path, light:, dark:, warnings: contrast_warnings(light, :light) + contrast_warnings(dark, :dark))
  end

  def strip_comments(css) = css.gsub(%r{/\*.*?\*/}m, "")

  # Top-level `:root` rules (media blocks removed), dark ones excluded.
  def root_block(css)
    top = css.gsub(/@media[^{]*\{(?:[^{}]*\{[^{}]*\})*[^{}]*\}/m, "")
    rules(top).select { |sel, _| sel.include?(":root") && !sel.include?("dark") }.map(&:last).join(";\n")
  end

  # Rules inside a dark color-scheme media block, else `[data-theme=dark]` rules.
  def dark_block(css)
    media = css.scan(/@media[^{]*prefers-color-scheme:\s*dark[^{]*\{((?:[^{}]*\{[^{}]*\})*[^{}]*)\}/m).flatten
    bodies = media.flat_map { |m| rules(m).map(&:last) }
    return bodies.join(";\n") unless bodies.empty?

    rules(css).select { |sel, _| sel.match?(/data-theme=["']?dark/) }.map(&:last).join(";\n")
  end

  def rules(css) = css.scan(/([^{}]+)\{([^{}]*)\}/m).map { |sel, body| [ sel.strip, body ] }

  def declarations(block)
    block.scan(/(--[\w-]+)\s*:\s*([^;]+?)\s*(?:;|\z)/m).to_h { |k, v| [ k, v.strip ] }
  end

  def roles(vars, theme)
    found = ROLE_SOURCES.transform_values { |names| names.filter_map { |n| vars[n] && color(vars, vars[n]) }.map { |c| hex(c) } }
    bg = found["--bg"].first
    raise Error, "no background or text color found in the token file" unless bg && found["--ink"].first

    # A role takes the first candidate that clears its floor against bg, else the first found.
    out = found.to_h do |role, hexes|
      floor = FLOORS.fetch(role, 0)
      [ role, hexes.find { |h| contrast(h, bg) >= floor } || hexes.first ]
    end

    out["--surface"] ||= out["--bg"]
    out["--muted"] ||= hex(mix(rgb(out["--ink"]), rgb(out["--bg"]), 0.7))
    out["--soft"] ||= out["--muted"]
    out["--line"] ||= out["--muted"]
    out["--rule"] ||= hex(mix(rgb(out["--ink"]), rgb(out["--bg"]), 0.15))
    out["--accent"] ||= out["--ink"]
    out["--link"] ||= out["--accent"]
    out["--accent-tint"] = hex(mix(rgb(out["--accent"]), rgb(out["--bg"]), TINT_SHARE.fetch(theme)))
    out
  end

  # A CSS color value to [r, g, b] in 0..1, following var() and srgb color-mix.
  def color(vars, value, depth = 0)
    return nil if depth > 16

    v = value.strip
    if (m = v.match(/\Avar\(\s*(--[\w-]+)\s*(?:,\s*(.+))?\)\z/))
      ref = vars[m[1]] || m[2]
      return ref && color(vars, ref, depth + 1)
    end
    if (m = v.match(/\Acolor-mix\(\s*in\s+srgb\s*,(.+)\)\z/m))
      a, b = split_args(m[1])
      return mix_args(vars, a, b, depth)
    end
    rgb(v)
  end

  def mix_args(vars, a, b, depth)
    pa = a[/\s(\d+(?:\.\d+)?)%\s*\z/, 1]&.to_f
    pb = b[/\s(\d+(?:\.\d+)?)%\s*\z/, 1]&.to_f
    ca = color(vars, a.sub(/\s\d+(?:\.\d+)?%\s*\z/, ""), depth + 1)
    cb = color(vars, b.sub(/\s\d+(?:\.\d+)?%\s*\z/, ""), depth + 1)
    return nil unless ca && cb

    share = mix_share(pa, pb)
    return nil unless share

    mix(ca, cb, share)
  end

  # CSS color-mix weights: one given implies the complement, both given are
  # normalized by their sum, neither means 50/50. A zero sum is invalid.
  def mix_share(pa, pb)
    return 0.5 unless pa || pb
    return pa / 100 unless pb
    return 1 - (pb / 100) unless pa
    return nil unless (pa + pb).positive?

    pa / (pa + pb)
  end

  # Splits "A p%, B" on the top-level comma.
  def split_args(s)
    depth = 0
    s.each_char.with_index do |c, i|
      depth += 1 if c == "("
      depth -= 1 if c == ")"
      return [ s[0...i], s[(i + 1)..] ] if c == "," && depth.zero?
    end
    [ s, "" ]
  end

  def mix(a, b, share) = a.zip(b).map { |x, y| (x * share) + (y * (1 - share)) }

  def rgb(v)
    h = v.to_s.strip[/\A#(\h{3}|\h{6})\z/, 1]
    return nil unless h

    h = h.chars.map { |c| c * 2 }.join if h.size == 3
    h.scan(/../).map { |p| p.to_i(16) / 255.0 }
  end

  def hex(c) = format("#%02X%02X%02X", *c.map { |x| (x.clamp(0, 1) * 255).round })

  def contrast(a, b)
    ca, cb = [ a, b ].map { |h| r, g, bl = rgb(h); ColorMath::Rgba.new(r:, g:, b: bl, a: 1.0) }
    ColorMath.contrast_ratio(ca, cb)
  end

  def contrast_warnings(roles, theme)
    pairs = TEXT_ROLES.product(%w[--bg --surface]).map { |fg, bg| [ fg, bg, TEXT_MIN ] }
    pairs << [ "--accent", "--accent-tint", TEXT_MIN ] << [ "--line", "--bg", STROKE_MIN ]
    pairs.filter_map { |fg, bg, floor| below(theme, fg, bg, contrast(roles[fg], roles[bg]), floor) }
  end

  def below(theme, fg, bg, ratio, floor)
    "#{theme}: #{fg} on #{bg} is #{ratio.round(2)}:1, under #{floor}" if ratio < floor
  end

  def main(argv)
    opts = { repo: Dir.pwd, tokens: nil, json: false }
    OptionParser.new do |o|
      o.on("--repo DIR") { |d| opts[:repo] = d }
      o.on("--tokens FILE") { |f| opts[:tokens] = f }
      o.on("--json") { opts[:json] = true }
    end.parse!(argv)
    path = locate(repo: opts[:repo], tokens: opts[:tokens])
    unless path
      warn "diagram_palette: no token file found; use the default skin in grammar.md"
      return 3
    end
    result = resolve(path)
    if opts[:json]
      puts JSON.pretty_generate(result.to_h)
    else
      puts "/* palette from #{path} */", result.css
      result.warnings.each { |w| warn "diagram_palette: #{w}" }
    end
    result.warnings.empty? ? 0 : 1
  rescue Error, DesignConfig::Error, OptionParser::ParseError => e
    warn "diagram_palette: #{e.message}"
    2
  end
end

exit DiagramPalette.main(ARGV) if $PROGRAM_NAME == __FILE__
