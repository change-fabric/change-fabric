#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'set'
require_relative 'color_value'
require_relative 'color_tokens'

# Advisory checker for the cf:color minimal palette doctrine. Reads the
# palette from one strict token file (ColorTokens), reports its errors, the
# palette count against the four-color target, and WCAG contrast for the
# declared pairs in light and dark. Never raises on a bad file. Exits 0 by
# default; under --strict, token-file errors or failing contrast pairs exit
# 1.
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

  module_function

  def run(root, tokens_override: nil, strict: false)
    located = ColorTokens.locate(root, tokens_override)
    tokens = located.is_a?(ColorTokens::Error) ? nil : ColorTokens.read(File.expand_path(located))
    token_errors = tokens ? tokens.errors : [ located ]
    contrast = tokens ? compute_contrast(tokens) : []
    exit_code = strict && (!token_errors.empty? || contrast.any? { |c| c.status == 'fail' }) ? 1 : 0
    Report.new(tokens: tokens&.path, token_errors:, palette: tokens && palette_of(tokens), contrast:, exit_code:)
  end

  def palette_of(tokens)
    Palette.new(file: tokens.path, authored: tokens.authored.map { |a| a.slice(:value, :names) },
                derived: tokens.derived, error_token: tokens.error_token)
  end

  # One row per declared pair (ColorTokens.pairs) in light, and again in
  # dark when the token file declares a dark block. The page background is
  # composited over white; any other translucent surface over the resolved
  # page background (unresolved when that backdrop cannot be determined); a
  # foreground over its background. One Resolver per variant serves every
  # row, so a var() chain shared by many pairs is analyzed once.
  def compute_contrast(tokens)
    variants = tokens.dark? ? %i[light dark] : %i[light]
    variants.flat_map do |variant|
      decls = tokens.variants[variant]
      resolver = ColorValue::Resolver.new(decls)
      ColorTokens.pairs(decls).map { |fg, bg| contrast_row(variant, fg, bg, decls, resolver) }
    end
  end

  def contrast_row(variant, fg, bg, decls, resolver = ColorValue::Resolver.new(decls))
    bg_result = resolve_token(bg, decls, resolver)
    fg_result = resolve_token(fg, decls, resolver)
    reason = (fg_result.color.nil? && "#{fg}: #{fg_result.reason}") || (bg_result.color.nil? && "#{bg}: #{bg_result.reason}")
    backdrop = reason ? nil : backdrop_for(bg, bg_result.color, decls, resolver)
    reason ||= backdrop if backdrop.is_a?(String)
    return ContrastPair.new(variant: variant.to_s, fg:, bg:, ratio: nil, status: 'unresolved', reason:) if reason

    bg_color = ColorValue.flatten(bg_result.color, over: backdrop)
    ratio = ColorValue.contrast_ratio(ColorValue.flatten(fg_result.color, over: bg_color), bg_color)
    ContrastPair.new(variant: variant.to_s, fg:, bg:, ratio: ratio.round(2), status: status_for(ratio), reason: nil)
  end

  # The opaque color a surface is painted over: white for the page
  # background or any opaque surface, else the page background flattened
  # over white. Returns a reason String when a translucent surface's
  # backdrop cannot be resolved.
  def backdrop_for(bg, bg_color, decls, resolver)
    return ColorValue::WHITE if bg == ColorTokens::PAGE_BACKGROUND || bg_color.a >= 1.0

    page = resolve_token(ColorTokens::PAGE_BACKGROUND, decls, resolver)
    return "#{bg}: translucent over #{ColorTokens::PAGE_BACKGROUND}, which #{page.reason}" if page.color.nil?

    ColorValue.flatten(page.color, over: ColorValue::WHITE)
  end

  def resolve_token(name, decls, resolver)
    return ColorValue::Result.new(color: nil, reason: 'is not declared') unless decls.key?(name)

    resolver.resolve(decls[name], Set[name])
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
      palette: report.palette&.authored,
      contrast: report.contrast.map do |c|
        { variant: c.variant, fg: c.fg, bg: c.bg, ratio: c.ratio, status: c.status, reason: c.reason }
      end,
      exit_code: report.exit_code
    )
  end

  module CLI
    module_function

    def run(argv, out: $stdout)
      root = '.'
      tokens = nil
      json = false
      strict = false

      args = argv.dup
      until args.empty?
        token = args.shift
        case token
        when '--tokens'
          tokens = args.shift
        when '--json'
          json = true
        when '--strict'
          strict = true
        else
          root = token
        end
      end

      report = ColorCheck.run(root, tokens_override: tokens, strict:)
      out.puts(json ? ColorCheck.to_json_report(report) : ColorCheck.render(report))
      exit(report.exit_code)
    end
  end
end

ColorCheck::CLI.run(ARGV) if __FILE__ == $PROGRAM_NAME
