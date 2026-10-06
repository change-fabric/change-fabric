#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'find'
require 'set'
require_relative 'color_css'
require_relative 'color_value'
require_relative 'color_themes'
require_relative 'color_scan'

# Advisory checker for the cf:color minimal color system. Reports a repo's
# authored palette, stray color literals, Tailwind palette classes and
# gradients, and WCAG contrast for resolvable text/background pairs. Never
# raises on a bad file; every check runs and reports rather than failing
# fast. Exits 0 by default; --strict is the only way to get a non-zero exit,
# so the checker can be run freely without blocking anything.
#
# Supported / reported-as-unsupported (full table in skills/color/SKILL.md):
#
# Area: Theme contexts.
#   Supported: bare :root/html (base); [data-theme=X] or .X on :root/html,
#     with optional :not(...); bare .X or [data-theme=X] whose block is
#     custom-property-only; @media (prefers-color-scheme: light or dark);
#     @layer.
#   Unsupported: any other selector carrying a text role; other @media,
#     @supports, @container, @scope; SCSS nesting; conflicting theme markers.
# Area: Color values.
#   Supported: hex 3/4/6/8; rgb/rgba, hsl/hsla in comma or space syntax; the
#     148 named colors; transparent; !important.
#   Unsupported: oklch, oklab, lab, lch, hwb, color(); relative color syntax;
#     calc() in channels; CSS-wide keywords.
# Area: Value functions.
#   Supported: var() with or without fallback; color-mix(in srgb, ...) with
#     either or both percentages.
#   Unsupported: color-mix in any other space; light-dark(); currentColor.
# Area: Stray scan, CSS.
#   Supported: declaration values (hex, color functions, named colors),
#     @apply.
#   Unsupported: selectors, url() fragments, strings inside values, the
#     keywords transparent, currentColor, inherit, initial, unset, revert,
#     none.
# Area: Stray scan, markup and script.
#   Supported: style=, fill=, stroke=, class=/className= attribute values;
#     quoted strings that are exactly one color: any hex length when the
#     value of a color-bearing key (color, backgroundColor, borderColor,
#     fill, stroke, shadow and the like), otherwise only 6- or 8-digit hex,
#     a color function or a named color.
#   Unsupported: 3- or 4-digit hex strings outside a color-bearing key
#     (querySelector('#cafe')), hex inside longer strings ('/page#feed'),
#     ID selectors, <style> and <script> blocks, prose, text nodes, MDX
#     code blocks, CSS-in-JS template literals as CSS, SCSS variables and
#     mixins as tokens, standalone .svg files.
module ColorCheck
  COLOR_FN = /\b(?:rgba?|hsla?|oklch|oklab|lab|lch)\(/.freeze
  TAILWIND = /\b(?:bg|text|border|ring|from|to|via|fill|stroke|outline|divide|shadow)-(?:slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose)-\d{2,3}\b/.freeze
  GRADIENT = /\b(?:linear|radial|conic|repeating-linear|repeating-radial)-gradient\(/.freeze
  SKIP_DIRS = %w[node_modules dist build vendor .git coverage .next out].freeze
  SCAN_EXTS = %w[css scss sass less html js jsx ts tsx vue svelte astro mdx].freeze
  CSS_EXTS = %w[css scss less].freeze
  MARKUP_STYLE_EXTS = %w[html vue svelte astro].freeze
  ERROR_TOKEN = '--error'
  TARGET = 4

  BG_EXACT = %w[--bg --background --surface].freeze
  BG_NAME = /(?:^--|-)(?:bg|background|surface)(?:-|$)/i.freeze
  STYLE_BLOCK = /<style(?:\s+[^>]*)?>(.*?)<\/style>/mi.freeze

  Finding = Data.define(:file, :line, :kind, :text)
  Palette = Data.define(:file, :authored, :derived, :error_token)
  ContrastPair = Data.define(:theme, :text_token, :bg_token, :ratio, :passes_body, :passes_large, :resolved, :context, :reason)
  Report = Data.define(:palette, :findings, :contrast, :exit_code, :parse_errors)

  module_function

  def run(root, tokens_override: nil, strict: false)
    files = scan_files(root)
    token_file = tokens_override || detect_token_file(files)
    palette = token_file ? build_palette(token_file) : nil
    findings, parse_errors = collect_findings(files, token_file)
    contrast = token_file ? compute_contrast(token_file) : []

    over_target = palette && (palette.authored.size > TARGET)
    exit_code = if strict && (over_target || !findings.empty?)
                  1
    else
                  0
    end

    Report.new(palette:, findings:, contrast:, exit_code:, parse_errors:)
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

  # Parses a scanned CSS source candidate into a Sheet: a whole .css/.scss/
  # .less file as itself, or the <style> blocks of a markup file (dialect
  # from lang="scss|less", else css; each block's own line_offset keeps
  # reported lines true to the original file). Any other extension (JS, TS,
  # MDX) is never a token-file candidate and yields nil.
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

  def style_block_sheet(text)
    decls = []
    at_rule_stmts = []
    errors = []
    text.scan(STYLE_BLOCK) do
      m = Regexp.last_match
      tag = m[0][/\A<style[^>]*>/mi] || '<style>'
      lang = tag[/lang\s*=\s*["']?(scss|less)["']?/i, 1]
      dialect = lang ? lang.downcase.to_sym : :css
      line_offset = text[0...m.begin(1)].count("\n")
      sub = ColorCss.parse(m[1], dialect:, line_offset:)
      decls.concat(sub.decls)
      at_rule_stmts.concat(sub.at_rule_stmts)
      errors.concat(sub.errors)
    end
    return nil if decls.empty? && at_rule_stmts.empty? && errors.empty?

    ColorCss::Sheet.new(decls:, at_rule_stmts:, errors:)
  end

  def token_like?(value)
    v = value.strip
    ColorValue.literal?(v) || v.start_with?('color-mix(') || v.start_with?('var(')
  end

  # The token file is the scanned CSS source (whole file, or a markup file's
  # <style> blocks) defining the most --name: <color> declarations whose
  # value looks like a color (literal, color-mix(, or a var() reference).
  # Ties keep the first file found in scan order.
  def detect_token_file(files)
    best = nil
    best_count = 0
    files.each do |file|
      ext = File.extname(file).delete_prefix('.')
      next unless CSS_EXTS.include?(ext) || MARKUP_STYLE_EXTS.include?(ext)

      text = safe_read(file)
      next unless text

      sheet = css_source_sheet(file, text)
      next unless sheet

      count = sheet.decls.count { |d| d.name.start_with?('--') && token_like?(d.value) }
      next if count.zero?

      if count > best_count
        best = file
        best_count = count
      end
    end
    best
  end

  def parse_token_sheet(token_file)
    text = safe_read(token_file)
    return nil unless text

    css_source_sheet(token_file, text) || ColorCss.parse(text)
  end

  # Authored = literal color value. Derived = a value containing color-mix(
  # or var(. De-duplicated by normalized (downcased, whitespace-collapsed)
  # value across theme blocks so the same token reassigned in light/dark
  # counts once; the first-seen spelling is kept for display. --error is
  # reported separately and excluded from the authored count.
  def build_palette(token_file)
    sheet = parse_token_sheet(token_file)
    return Palette.new(file: token_file, authored: [], derived: 0, error_token: false) unless sheet

    authored_values = {}
    derived_count = 0
    error_token = false

    sheet.decls.each do |decl|
      next unless decl.name.start_with?('--')

      if decl.name == ERROR_TOKEN
        error_token = true
        next
      end

      if ColorValue.literal?(decl.value)
        key = decl.value.strip.downcase.gsub(/\s+/, ' ')
        entry = (authored_values[key] ||= { value: decl.value.strip, names: [] })
        entry[:names] << decl.name unless entry[:names].include?(decl.name)
      elsif decl.value.include?('color-mix(') || decl.value.include?('var(')
        derived_count += 1
      end
    end

    Palette.new(file: token_file, authored: authored_values.values, derived: derived_count, error_token:)
  end

  # Delegates to ColorScan per file, inside a per-file rescue so a file that
  # cannot be scanned (a parse failure, a surprise encoding error) never
  # aborts the run: it yields one "unparsed" finding instead and the scan
  # continues. CSS source diagnostics (ColorCss::Sheet#errors) are collected
  # alongside as parse_errors; they are not findings themselves.
  def collect_findings(files, token_file)
    findings = []
    parse_errors = []
    files.each do |file|
      text = safe_read(file)
      next unless text

      begin
        findings.concat(ColorScan.findings_for(file, text, token_file:))
        sheet = css_source_sheet(file, text)
        sheet&.errors&.each { |e| parse_errors << { file:, message: e } }
      rescue StandardError => e
        findings << Finding.new(file:, line: 1, kind: 'unparsed', text: e.class.to_s)
      end
    end
    [ findings, parse_errors ]
  end

  # Resolves every custom property in the token file's theme model (base
  # "light" plus named variants) via ColorValue, pairs text-role tokens
  # against the theme's background (or its own <base> token for a
  # "<base>-text" name), and computes WCAG 2.x contrast. Unsupported
  # contexts that carry a text-role token are reported unresolved with their
  # reason rather than guessed at.
  def compute_contrast(token_file)
    sheet = parse_token_sheet(token_file)
    return [] unless sheet

    model = ColorThemes.build(sheet)
    results = []
    model.variants.each { |v| results.concat(contrast_rows_for_variant(v)) }
    model.unsupported.each do |uns|
      uns.decls.each_key do |name|
        next unless ColorThemes.text_role_name?(name)

        results << ContrastPair.new(theme: 'unsupported', text_token: name, bg_token: nil, ratio: nil,
                                     passes_body: false, passes_large: false, resolved: false,
                                     context: uns.label, reason: "unsupported theme context: #{uns.label} (#{uns.why})")
      end
    end
    results
  rescue StandardError
    []
  end

  def contrast_rows_for_variant(variant)
    decls = variant.decls
    context = variant.contexts.join(' | ')
    bg_name = BG_EXACT.find { |n| decls.key?(n) } || decls.keys.find { |n| n.match?(BG_NAME) }
    bg_result = bg_name ? ColorValue.resolve(decls[bg_name], decls) : nil
    bg_color = bg_result&.color ? ColorValue.flatten(bg_result.color, over: ColorValue::WHITE) : nil

    decls.each_key.select { |n| ColorThemes.text_role_name?(n) }.map do |name|
      contrast_row_for(variant.theme, context, name, decls, bg_name, bg_result, bg_color)
    end
  end

  def contrast_row_for(theme, context, name, decls, bg_name, bg_result, bg_color)
    pair_bg_name = bg_name
    pair_bg_color = bg_color
    pair_bg_reason = pair_bg_reason_for(bg_name, bg_result)

    base_match = name.match(/\A(--[\w-]+)-text\z/)
    if base_match && decls.key?(base_match[1])
      pair_bg_name = base_match[1]
      base_result = ColorValue.resolve(decls[pair_bg_name], decls)
      if base_result.color
        pair_bg_color = ColorValue.flatten(base_result.color, over: bg_color || ColorValue::WHITE)
        pair_bg_reason = nil
      else
        pair_bg_color = nil
        pair_bg_reason = "background #{pair_bg_name}: #{base_result.reason}"
      end
    end

    build_contrast_pair(theme, context, name, decls[name], decls, pair_bg_name, pair_bg_color, pair_bg_reason)
  end

  def pair_bg_reason_for(bg_name, bg_result)
    return 'no background token in this theme' unless bg_name
    return "background #{bg_name}: #{bg_result.reason}" unless bg_result.color

    nil
  end

  def build_contrast_pair(theme, context, name, raw_value, decls, bg_name, bg_color, bg_reason)
    text_result = ColorValue.resolve(raw_value, decls)
    if text_result.color && bg_color
      text_color = ColorValue.flatten(text_result.color, over: bg_color)
      ratio = ColorValue.contrast_ratio(text_color, bg_color)
      ContrastPair.new(theme:, text_token: name, bg_token: bg_name, ratio: ratio.round(2),
                        passes_body: ratio >= 4.5, passes_large: ratio >= 3.0, resolved: true,
                        context:, reason: nil)
    else
      reason = text_result.color.nil? ? text_result.reason : bg_reason
      ContrastPair.new(theme:, text_token: name, bg_token: bg_name, ratio: nil, passes_body: false,
                        passes_large: false, resolved: false, context:, reason:)
    end
  end

  def safe_read(path)
    File.read(path, encoding: 'UTF-8')
  rescue StandardError
    nil
  end

  def render(report)
    lines = []
    lines << 'Palette:'
    if report.palette
      lines << "  token file: #{report.palette.file}"
      report.palette.authored.each { |a| lines << "  authored: #{a[:value]} (#{a[:names].join(', ')})" }
      lines << "  derived declarations: #{report.palette.derived}"
      lines << "  --error present: #{report.palette.error_token}"
      n = report.palette.authored.size
      diff = n - TARGET
      distance = if diff <= 0
                   "#{n} authored colors; target is #{TARGET} plus optional --error (at or under target)"
      else
                   "#{n} authored colors; target is #{TARGET} plus optional --error (#{diff} above target)"
      end
      lines << ''
      lines << 'Distance from target:'
      lines << "  #{distance}"
    else
      lines << '  no palette found; consider authoring one'
    end

    lines << ''
    lines << 'Findings by kind:'
    if report.findings.empty?
      lines << '  none'
    else
      report.findings.group_by(&:kind).each do |kind, items|
        lines << "  #{kind}: #{items.size}"
        items.each { |f| lines << "    #{f.file}:#{f.line}: #{f.text}" }
      end
    end

    lines << ''
    lines << 'Contrast:'
    if report.contrast.empty?
      lines << '  none resolvable'
    else
      contexts_per_theme = report.contrast.group_by(&:theme).transform_values { |rows| rows.map(&:context).uniq }
      report.contrast.each do |c|
        label = contexts_per_theme[c.theme].size > 1 ? "#{c.theme} #{c.context}" : c.theme
        if c.resolved
          status = c.passes_body ? 'pass 4.5:1' : (c.passes_large ? 'pass 3:1 only' : 'fail')
          lines << "  [#{label}] #{c.text_token} on #{c.bg_token}: #{c.ratio}:1 (#{status})"
        else
          lines << "  [#{label}] #{c.text_token} on #{c.bg_token}: unresolved (#{c.reason}), state manually"
        end
      end
    end

    lines.join("\n")
  end

  def to_json_report(report)
    JSON.generate(
      palette: report.palette && {
        file: report.palette.file,
        authored: report.palette.authored,
        derived: report.palette.derived,
        error_token: report.palette.error_token
      },
      findings: report.findings.map { |f| { file: f.file, line: f.line, kind: f.kind, text: f.text } },
      contrast: report.contrast.map do |c|
        { theme: c.theme, text_token: c.text_token, bg_token: c.bg_token, ratio: c.ratio,
          passes_body: c.passes_body, passes_large: c.passes_large, resolved: c.resolved,
          context: c.context, reason: c.reason }
      end,
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
