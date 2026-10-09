#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'set'
require_relative 'color_math'
require_relative 'color_tokens'
require_relative 'color_compile'
require_relative 'color_browser'

# Advisory checker for the cf:color minimal palette doctrine. Locates the
# repo's token file, compiles it through the repo's own Tailwind when it
# needs one, and hands the resulting CSS to a pinned Chromium (ColorBrowser)
# to parse, cascade and resolve: whatever the browser computes is the
# answer. This module is policy only now: pairing, the dark-mechanism
# agreement rule, contrast math and reporting. Never raises on a bad file.
# Exits 0 by default; under --strict, token-file errors or failing contrast
# pairs exit 1.
#
# Full contract: skills/color/SKILL.md.
module ColorCheck
  TARGET = ColorTokens::TARGET

  Palette = Data.define(:file, :authored, :derived, :error_token)
  # status: "pass", "large-only", "fail" or "unresolved" (with a reason).
  ContrastPair = Data.define(:variant, :fg, :bg, :ratio, :status, :reason) do
    def resolved? = status != 'unresolved'
  end
  Report = Data.define(:tokens, :token_errors, :palette, :contrast, :exit_code)

  # The three independent dark activation mechanisms, as the disagreement
  # error names them.
  MECHANISMS = { class: '.dark class', attr: 'data-theme attribute', media: 'prefers-color-scheme media' }.freeze

  module_function

  # The report boundary: every failure, expected or not, comes back as a
  # Report. Expected cases (a bad --tokens, no docker, a failed compile) get
  # their own message; anything else (a browser start failure, a timeout, a
  # malformed browser reply) becomes "could not audit: <message>".
  def run(root, tokens_override: nil, strict: false, probe: ColorBrowser)
    path = nil
    located = ColorTokens.locate(root, tokens_override)
    return located_error_report(located, strict) if located.is_a?(ColorTokens::Error)

    path = File.expand_path(located)
    unless probe.available?
      return error_report(path, 'Docker is required: cf:color asks a pinned Chromium container to read the CSS', strict)
    end

    compiled = ColorCompile.read(File.expand_path(root), path)
    return compile_error_report(path, compiled.error, strict) if compiled.error

    probed = probe.probe(compiled.css)
    build_report(path, probed, strict)
  rescue StandardError => e
    error_report(path, "could not audit: #{e.message.to_s.scrub}", strict)
  end

  def located_error_report(located, strict)
    Report.new(tokens: nil, token_errors: [ located ], palette: nil, contrast: [],
               exit_code: strict ? 1 : 0)
  end

  def compile_error_report(path, message, strict)
    error_report(path, message, strict)
  end

  def build_report(path, probed, strict)
    if probed.import_error
      return error_report(path, 'the browser found an @import it could not load; bundle it first (Tailwind ' \
                                 'directives route through the compile step) or audit that file directly', strict)
    end

    mechanism_error, dark_map = resolve_mechanisms(probed.states)
    errors = [ mechanism_error ].compact
    palette = build_palette(path, probed)

    contrast = mechanism_error ? [] : compute_contrast(probed, dark_map)
    exit_code = strict && (!errors.empty? || contrast.any? { |c| c.status == 'fail' }) ? 1 : 0
    Report.new(tokens: path, token_errors: errors, palette:, contrast:, exit_code:)
  end

  def error_report(path, message, strict)
    Report.new(tokens: path, token_errors: [ ColorTokens::Error.new(line: nil, message: message.to_s.scrub) ],
               palette: nil, contrast: [], exit_code: strict ? 1 : 0)
  end

  # Each of .dark, [data-theme=dark] and prefers-color-scheme: dark is
  # tested alone, each over light; a mechanism is "in use" when its state
  # differs from light at all. With several in use they must all agree, or
  # there is no single dark palette to grade: an error naming the first two
  # that differ and the first differing name, and no contrast computed.
  # Returns [error_or_nil, dark_map] where dark_map is the in-use palette
  # (or light's own, when nothing is in use).
  def resolve_mechanisms(states)
    light = states.fetch(:light, {})
    in_use = %i[class attr media].select { |m| states[m] != light }
    return [ nil, light ] if in_use.empty?

    base_mechanism = in_use.first
    base = states[base_mechanism]
    in_use[1..].each do |mechanism|
      other = states[mechanism]
      name = (base.keys | other.keys).find { |n| base[n] != other[n] }
      next unless name

      message = "dark under #{MECHANISMS[base_mechanism]} and under #{MECHANISMS[mechanism]} differ at `#{name}`; " \
                'each activates alone, so dark must give the same palette under every mechanism'
      return [ ColorTokens::Error.new(line: nil, message:), base ]
    end
    [ nil, base ]
  end

  # Authored colors grouped by resolved color (channels and alpha rounded to
  # 4 places, so two spellings of one color share a group), with every name
  # that declares that color; --error is excluded from the count (it is the
  # one sanctioned exception beyond the four-color target). derived is a
  # count of declarations the browser resolved to a color through a var().
  def build_palette(path, probed)
    authored = {}
    derived = 0
    probed.declared_values.each do |name, values|
      values.each do |value|
        entry = probed.classified[value]
        next unless entry

        case entry[:kind]
        when 'authored'
          next if name == ColorTokens::ERROR_TOKEN

          slot = (authored[color_key(entry[:color])] ||= { value: value.strip, names: [] })
          slot[:names] << name unless slot[:names].include?(name)
        when 'derived'
          derived += 1
        end
      end
    end
    error_token = probed.names.include?(ColorTokens::ERROR_TOKEN)
    Palette.new(file: path, authored: authored.values, derived:, error_token:)
  end

  def color_key(color)
    [ color.r, color.g, color.b, color.a ].map { |c| c.round(4) }
  end

  # One row per declared pair (ColorTokens.pairs) in light, and again in
  # dark when some mechanism is in use. Pairs come from the union of names
  # across every variant the browser reported.
  def compute_contrast(probed, dark_map)
    light = probed.states.fetch(:light, {})
    dark_in_use = dark_map != light
    variants = dark_in_use ? %i[light dark] : %i[light]
    pairs = ColorTokens.pairs(probed.names)
    variants.flat_map do |variant|
      decls = variant == :light ? light : dark_map
      pairs.map { |fg, bg| contrast_row(variant, fg, bg, decls) }
    end
  end

  def contrast_row(variant, fg, bg, decls)
    fg_result = resolve_name(fg, decls, variant)
    bg_result = resolve_name(bg, decls, variant)
    reason = fg_result[:reason] || bg_result[:reason]
    backdrop = reason ? nil : backdrop_for(bg, bg_result[:color], decls, variant)
    reason ||= backdrop if backdrop.is_a?(String)
    return ContrastPair.new(variant: variant.to_s, fg:, bg:, ratio: nil, status: 'unresolved', reason:) if reason

    bg_color = ColorMath.flatten(bg_result[:color], over: backdrop)
    ratio = ColorMath.contrast_ratio(ColorMath.flatten(fg_result[:color], over: bg_color), bg_color)
    ContrastPair.new(variant: variant.to_s, fg:, bg:, ratio: shown_ratio(ratio), status: status_for(ratio), reason: nil)
  end

  def resolve_name(name, decls, variant)
    return { color: nil, reason: "#{name}: is not declared" } unless decls.key?(name)
    return { color: nil, reason: "#{name}: is not a color in #{variant}" } if decls[name].nil?

    { color: decls[name], reason: nil }
  end

  # The opaque color a surface is painted over: white for the page
  # background or any opaque surface, else the page background flattened
  # over white. Returns a reason String when a translucent surface's
  # backdrop cannot be resolved.
  def backdrop_for(bg, bg_color, decls, variant)
    return ColorMath::WHITE if bg == ColorTokens::PAGE_BACKGROUND || bg_color.a >= 1.0

    page = resolve_name(ColorTokens::PAGE_BACKGROUND, decls, variant)
    return "#{bg}: translucent over #{ColorTokens::PAGE_BACKGROUND}, which #{page[:reason]}" if page[:color].nil?

    ColorMath.flatten(page[:color], over: ColorMath::WHITE)
  end

  # The ratio rounded to two places, floored instead when rounding would
  # carry it across a threshold it misses (2.999 reads 2.99, never 3.0), so
  # the shown value and its status always agree.
  def shown_ratio(ratio)
    rounded = ratio.round(2)
    status_for(rounded) == status_for(ratio) ? rounded : ratio.floor(2)
  end

  def status_for(ratio)
    return 'pass' if ratio >= 4.5
    return 'large-only' if ratio >= 3.0

    'fail'
  end

  def render(report)
    lines = [ 'Token file:' ]
    lines << "  #{report.tokens || 'none'}"
    report.token_errors.each do |e|
      where = [ report.tokens, e.line ].compact.join(':')
      lines << "  error: #{where.empty? ? '' : "#{where}: "}#{e.message}"
    end
    lines << ''
    lines.concat(render_palette(report.palette))
    lines << ''
    lines << 'Contrast:'
    lines << '  none declared (name a foreground --x-text, --x-fg, --x-foreground or --x-ink)' if report.contrast.empty?
    report.contrast.each do |c|
      lines << if c.resolved?
                 "  [#{c.variant}] #{c.fg} on #{c.bg}: #{c.ratio}:1 (#{c.status})"
      else
                 "  [#{c.variant}] #{c.fg} on #{c.bg}: unresolved (#{c.reason}), state manually"
      end
    end
    lines.join("\n")
  end

  def render_palette(palette)
    return [ 'Palette:', '  no palette found; consider authoring one' ] unless palette

    lines = [ 'Palette:' ]
    palette.authored.each { |a| lines << "  authored: #{a[:value]} (#{a[:names].join(', ')})" }
    lines << "  derived declarations: #{palette.derived}"
    lines << "  --error present: #{palette.error_token}"
    n = palette.authored.size
    diff = n - TARGET
    where = diff <= 0 ? 'at or under target' : "#{diff} above target"
    lines << ''
    lines << 'Distance from target:'
    lines << "  #{n} authored colors; target is #{TARGET} plus optional --error (#{where})"
  end

  def to_json_report(report)
    JSON.generate(
      tokens: report.tokens,
      token_errors: report.token_errors.map { |e| { line: e.line, message: e.message } },
      palette: report.palette&.then { |p| { authored: p.authored, derived: p.derived, error_token: p.error_token } },
      contrast: report.contrast.map do |c|
        { variant: c.variant, fg: c.fg, bg: c.bg, ratio: c.ratio, status: c.status, reason: c.reason }
      end,
      exit_code: report.exit_code
    )
  end

  module CLI
    module_function

    def run(argv, out: $stdout)
      root = nil
      tokens = nil
      json = false
      strict = false

      args = argv.dup
      until args.empty?
        token = args.shift
        case token
        when '--tokens'
          usage_error('--tokens given twice') if tokens
          tokens = args.shift
          usage_error('--tokens needs a path') if tokens.nil? || tokens.start_with?('-')
        when '--json'
          json = true
        when '--strict'
          strict = true
        else
          usage_error("unknown option #{token}") if token.start_with?('-')
          usage_error("second repo root #{token}; quote a path with spaces") if root
          root = token
        end
      end

      report = ColorCheck.run(root || '.', tokens_override: tokens, strict:)
      out.puts(json ? ColorCheck.to_json_report(report) : ColorCheck.render(report))
      exit(report.exit_code)
    end

    # A malformed command line exits 2 before any audit, so a flag is never
    # read as a path, a misspelled --strict never passes as exit 0, and a
    # second root or --tokens never silently replaces the first.
    def usage_error(message)
      warn "color_check: #{message}"
      warn 'usage: color_check.rb [<repo root>] [--tokens <path>] [--json] [--strict]'
      exit(2)
    end
  end
end

ColorCheck::CLI.run(ARGV) if __FILE__ == $PROGRAM_NAME
