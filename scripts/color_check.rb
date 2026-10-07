#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'find'
require 'set'
require_relative 'color_css'
require_relative 'color_value'
require_relative 'color_tokens'
require_relative 'color_scan'
require_relative 'color_markup'

# Advisory checker for the cf:color minimal color system. Reads the palette
# from one strict token file (ColorTokens), reports its errors, stray color
# literals, Tailwind palette classes and gradients, and WCAG contrast for the
# declared pairs in light and dark. Never raises on a bad file. Exits 0 by
# default; under --strict, token-file errors or findings exit 1, while
# unresolved entries never do.
#
# Supported / reported-as-unsupported: full table in skills/color/SKILL.md.
module ColorCheck
  # CSS function names are ASCII case-insensitive (RGB(...) and rgb(...) are
  # the same function), so both are matched with /i. hwb( and color( are
  # color functions too, per the Supported table above.
  COLOR_FN = /\b(?:rgba?|hsla?|hwb|oklch|oklab|lab|lch|color)\(/i.freeze
  GRADIENT = /\b(?:linear|radial|conic|repeating-linear|repeating-radial)-gradient\(/i.freeze
  SKIP_DIRS = %w[node_modules dist build vendor .git coverage .next out].freeze
  SCAN_EXTS = %w[css scss sass less html js jsx ts tsx vue svelte astro mdx].freeze
  CSS_EXTS = %w[css scss less].freeze
  MARKUP_STYLE_EXTS = %w[html vue svelte astro].freeze
  TARGET = ColorTokens::TARGET

  Finding = Data.define(:file, :line, :kind, :text)
  # A color-shaped string the scan could not classify (its key context was
  # undeterminable). Listed in the report, never counted by --strict.
  Unresolved = Data.define(:file, :line, :kind, :text, :reason)
  Palette = Data.define(:file, :authored, :derived, :error_token)
  # status: "pass", "large-only", "fail" or "unresolved" (with a reason).
  ContrastPair = Data.define(:variant, :fg, :bg, :ratio, :status, :reason) do
    def resolved? = status != 'unresolved'
  end
  Report = Data.define(:tokens, :token_errors, :palette, :findings, :unresolved, :contrast, :exit_code, :parse_errors)

  module_function

  def run(root, tokens_override: nil, strict: false)
    files = scan_files(root)
    located = ColorTokens.locate(root, tokens_override)
    tokens = located.is_a?(ColorTokens::Error) ? nil : ColorTokens.read(File.expand_path(located))
    token_errors = tokens ? tokens.errors : [ located ]
    findings, unresolved, parse_errors = collect_findings(files, tokens&.path, token_names(tokens))
    exit_code = strict && !(token_errors.empty? && findings.empty?) ? 1 : 0
    Report.new(tokens: tokens&.path, token_errors:, palette: tokens && palette_of(tokens), findings:, unresolved:,
               contrast: tokens ? compute_contrast(tokens) : [], exit_code:, parse_errors:)
  end

  # Names declared in a clean token file; an errored one exempts nothing.
  def token_names(tokens)
    return Set.new unless tokens && tokens.errors.empty?

    Set.new(tokens.variants[:light].keys)
  end

  def palette_of(tokens)
    Palette.new(file: tokens.path, authored: tokens.authored.map { |a| a.slice(:value, :names) },
                derived: tokens.derived, error_token: tokens.error_token)
  end

  def scan_files(root)
    return [] unless Dir.exist?(root)

    out = []
    Find.find(root) do |path|
      if File.directory?(path)
        base = File.basename(path)
        if SKIP_DIRS.include?(base)
          Find.prune
        end
        next
      end
      next if File.basename(path).include?('.min.')
      next if path.end_with?('.lock', '.lock.json', 'package-lock.json', 'yarn.lock')

      ext = File.extname(path).delete_prefix('.')
      out << path if SCAN_EXTS.include?(ext)
    end
    out
  rescue StandardError
    out || []
  end

  # Parses a scanned CSS source for parse diagnostics: a whole .css/.scss/
  # .less file as itself, or the <style> blocks of a markup file (each
  # block's line_offset keeps reported lines true to the original file). Any
  # other extension yields nil.
  def css_source_sheet(file, text)
    ext = File.extname(file).delete_prefix('.')
    if CSS_EXTS.include?(ext)
      ColorCss.parse(text, dialect: ext.to_sym)
    elsif MARKUP_STYLE_EXTS.include?(ext)
      style_block_sheet(text)
    end
  rescue StandardError
    nil
  end

  # Only what the shared markup walker (ColorMarkup) sees as a real style
  # element is parsed: a "<style>" inside a comment, a script string, an
  # attribute value, a textarea or a title is text, never CSS.
  def style_block_sheet(text)
    blocks = ColorMarkup.each_node(text).grep(ColorMarkup::Style).map do |style|
      lang = style.lang&.[](/\A(scss|less)/i, 1)
      ColorCss::Block.new(text: style.body, dialect: lang ? lang.downcase.to_sym : :css,
                          line_offset: text[0...style.pos].count("\n"))
    end
    sheet = ColorCss.parse_blocks(blocks)
    return nil if sheet.decls.empty? && sheet.at_rule_stmts.empty? && sheet.errors.empty?

    sheet
  end

  # Delegates to ColorScan per file, inside a per-file rescue so a file that
  # cannot be scanned (a parse failure, a surprise encoding error) never
  # aborts the run: it yields one "unparsed" finding instead and the scan
  # continues. CSS source diagnostics (ColorCss::Sheet#errors) are collected
  # alongside as parse_errors; they are not findings themselves. Strings
  # with an undeterminable key context come back as a separate unresolved
  # list.
  def collect_findings(files, token_file, token_names = Set.new)
    findings = []
    unresolved = []
    parse_errors = []
    files.each do |file|
      text = safe_read(file)
      next unless text

      begin
        file_findings, file_unresolved = ColorScan.scan(file, text, token_file:, token_names:)
        findings.concat(file_findings)
        unresolved.concat(file_unresolved)
        sheet = css_source_sheet(file, text)
        sheet&.errors&.each { |e| parse_errors << { file:, message: e } }
      rescue StandardError => e
        findings << Finding.new(file:, line: 1, kind: 'unparsed', text: e.class.to_s)
      end
    end
    [ findings, unresolved, parse_errors ]
  end

  # One row per declared pair (ColorTokens.pairs) in light, and again in
  # dark when the token file declares a dark block. A background is
  # composited over white, a foreground over its background.
  def compute_contrast(tokens)
    variants = tokens.dark? ? %i[light dark] : %i[light]
    variants.flat_map do |variant|
      decls = tokens.variants[variant]
      ColorTokens.pairs(decls).map { |fg, bg| contrast_row(variant, fg, bg, decls) }
    end
  end

  def contrast_row(variant, fg, bg, decls)
    bg_result = resolve_token(bg, decls)
    fg_result = resolve_token(fg, decls)
    reason = (fg_result.color.nil? && "#{fg}: #{fg_result.reason}") || (bg_result.color.nil? && "#{bg}: #{bg_result.reason}")
    return ContrastPair.new(variant: variant.to_s, fg:, bg:, ratio: nil, status: 'unresolved', reason:) if reason

    bg_color = ColorValue.flatten(bg_result.color, over: ColorValue::WHITE)
    ratio = ColorValue.contrast_ratio(ColorValue.flatten(fg_result.color, over: bg_color), bg_color).round(2)
    ContrastPair.new(variant: variant.to_s, fg:, bg:, ratio:, status: status_for(ratio), reason: nil)
  end

  def resolve_token(name, decls)
    return ColorValue::Result.new(color: nil, reason: 'is not declared') unless decls.key?(name)

    ColorValue.resolve(decls[name], decls, seen: Set[name])
  end

  def status_for(ratio)
    return 'pass' if ratio >= 4.5
    return 'large-only' if ratio >= 3.0

    'fail'
  end

  def safe_read(path)
    File.read(path, encoding: 'UTF-8')
  rescue StandardError
    nil
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
    lines.concat(render_findings(report))
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

  def render_findings(report)
    lines = [ 'Findings by kind:' ]
    lines << '  none' if report.findings.empty?
    report.findings.group_by(&:kind).each do |kind, items|
      lines << "  #{kind}: #{items.size}"
      items.each { |f| lines << "    #{f.file}:#{f.line}: #{f.text}" }
    end
    unless report.unresolved.empty?
      lines << ''
      lines << 'Unresolved (not counted by --strict):'
      report.unresolved.each { |u| lines << "  #{u.file}:#{u.line} #{u.text} (#{u.reason})" }
    end
    lines
  end

  def to_json_report(report)
    JSON.generate(
      tokens: report.tokens,
      token_errors: report.token_errors.map { |e| { line: e.line, message: e.message } },
      palette: report.palette&.authored,
      contrast: report.contrast.map do |c|
        { variant: c.variant, fg: c.fg, bg: c.bg, ratio: c.ratio, status: c.status, reason: c.reason }
      end,
      findings: report.findings.map { |f| { file: f.file, line: f.line, kind: f.kind, text: f.text } },
      unresolved: report.unresolved.map { |u| { file: u.file, line: u.line, kind: u.kind, text: u.text, reason: u.reason } },
      exit_code: report.exit_code,
      parse_errors: report.parse_errors
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
