#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'find'
require 'set'

# Advisory checker for the cf:color minimal color system. Reports a repo's
# authored palette, stray color literals, Tailwind palette classes and
# gradients, and WCAG contrast for resolvable text/background pairs. Never
# raises on a bad file; every check runs and reports rather than failing
# fast. Exits 0 by default; --strict is the only way to get a non-zero exit,
# so the checker can be run freely without blocking anything.
module ColorCheck
  COLOR_FN = /\b(?:rgba?|hsla?|oklch|oklab|lab|lch)\(/.freeze
  LITERAL = /(?<!&)#\h{3,8}\b|#{COLOR_FN}/.freeze
  TAILWIND = /\b(?:bg|text|border|ring|from|to|via|fill|stroke|outline|divide|shadow)-(?:slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose)-\d{2,3}\b/.freeze
  GRADIENT = /\b(?:linear|radial|conic|repeating-linear|repeating-radial)-gradient\(/.freeze
  SKIP_DIRS = %w[node_modules dist build vendor .git coverage .next out].freeze
  SCAN_EXTS = %w[css scss sass less html js jsx ts tsx vue svelte astro mdx].freeze
  ERROR_TOKEN = '--error'
  TARGET = 4

  TOKEN_DECL = /(--[\w-]+)\s*:\s*([^;}]+)(?:;|(?=\}))/.freeze
  THEME_BLOCK = /:root(?:\[data-theme=["'][\w-]+["']\]|:not\([^)]*\))?\s*\{([^}]*)\}/m.freeze
  COLOR_MIX_SRGB = /color-mix\(\s*in\s+srgb\s*,\s*([^,]+?)\s+(\d+(?:\.\d+)?)%\s*,\s*([^)]+?)\s*\)/.freeze
  HEX = /^#(\h{3,4}|\h{6}|\h{8})$/.freeze
  TEXT_NAME = /(?:^--|-)(?:text|fg|ink|title|link)(?:-|$)/i.freeze
  BG_EXACT = %w[--bg --background --surface].freeze
  BG_NAME = /(?:^--|-)(?:bg|background|surface)(?:-|$)/i.freeze

  Finding = Data.define(:file, :line, :kind, :text)
  Palette = Data.define(:file, :authored, :derived, :error_token)
  ContrastPair = Data.define(:theme, :text_token, :bg_token, :ratio, :passes_body, :passes_large, :resolved)
  Report = Data.define(:palette, :findings, :contrast, :exit_code)

  module_function

  def run(root, tokens_override: nil, strict: false)
    files = scan_files(root)
    token_file = tokens_override || detect_token_file(files)
    palette = token_file ? build_palette(token_file) : nil
    findings = collect_findings(files, token_file)
    contrast = token_file ? compute_contrast(token_file) : []

    over_target = palette && (palette.authored.size > TARGET)
    exit_code = if strict && (over_target || !findings.empty?)
                  1
    else
                  0
    end

    Report.new(palette:, findings:, contrast:, exit_code:)
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

  # The token file is the scanned file defining the most --name: <color>
  # declarations whose value looks like a color (literal, color-mix(, or a
  # var() reference).
  def detect_token_file(files)
    best = nil
    best_count = 0
    files.each do |file|
      text = safe_read(file)
      next unless text

      count = text.scan(TOKEN_DECL).count { |_, value| color_like?(value) }
      next if count.zero?

      if count > best_count
        best = file
        best_count = count
      end
    end
    best
  end

  def color_like?(value)
    v = value.strip
    v.match?(HEX) || v.match?(COLOR_FN) || v.start_with?('color-mix(') || v.match?(/^var\(--[\w-]+\)$/)
  end

  # Authored = literal color value. Derived = color-mix(, var() reference, or
  # alpha over a token. De-duplicated by value across theme blocks so the
  # same token reassigned in light/dark counts once. --error is reported
  # separately and excluded from the authored count.
  def build_palette(token_file)
    text = safe_read(token_file) || ''
    authored_values = {}
    derived_count = 0
    error_token = false

    text.scan(TOKEN_DECL) do |name, raw_value|
      value = raw_value.strip
      if name == ERROR_TOKEN
        error_token = true
        next
      end

      if value.match?(HEX) || value.match?(COLOR_FN)
        authored_values[value] ||= []
        authored_values[value] << name unless authored_values[value].include?(name)
      elsif value.start_with?('color-mix(') || value.match?(/^var\(--[\w-]+\)$/)
        derived_count += 1
      end
    end

    authored = authored_values.map { |value, names| { value:, names: } }
    Palette.new(file: token_file, authored:, derived: derived_count, error_token:)
  end

  def collect_findings(files, token_file)
    findings = []
    files.each do |file|
      text = safe_read(file)
      next unless text

      # In the token file, only custom-property declarations are exempt;
      # ordinary rules there are scanned like any other file. Declarations
      # are blanked over the whole text (keeping newlines) so multiline
      # values are exempt and line numbers stay correct.
      text = text.gsub(TOKEN_DECL) { |decl| decl.gsub(/[^\n]/, '') } if file == token_file
      text.each_line.with_index(1) do |line, lineno|
        line.scan(LITERAL).each { findings << Finding.new(file:, line: lineno, kind: 'literal', text: line.strip) }
        line.scan(TAILWIND).each { findings << Finding.new(file:, line: lineno, kind: 'tailwind', text: line.strip) }
        line.scan(GRADIENT).each { findings << Finding.new(file:, line: lineno, kind: 'gradient', text: line.strip) }
      end
    end
    findings
  end

  # Resolves hex tokens and color-mix(in srgb, A p%, B) pairs (alpha over
  # transparent composites onto the theme background) per theme block, then
  # pairs text-like tokens against background-like tokens and computes WCAG
  # 2.x contrast. Unresolvable pairs are not emitted as ContrastPair entries;
  # callers list text-like tokens with no resolved color as unresolved.
  def compute_contrast(token_file)
    text = safe_read(token_file) || ''
    results = []
    base_decls = nil

    text.scan(THEME_BLOCK) do |(body)|
      theme_label = theme_label_for(text, body)
      own = {}
      body.scan(TOKEN_DECL) { |name, value| own[name] = value.strip }
      # Theme blocks inherit the base :root declarations, then override.
      decls = base_decls ? base_decls.merge(own) : own
      base_decls ||= own if theme_label == 'light'

      bg_name = BG_EXACT.find { |n| decls.key?(n) } || decls.keys.find { |n| n.match?(BG_NAME) }
      bg_color = bg_name && resolve_color(decls[bg_name], decls, bg_color: '#ffffff')

      decls.each do |name, raw|
        next unless name.match?(TEXT_NAME)

        pair_bg_name = bg_name
        pair_bg_color = bg_color
        if (m = name.match(/^(--[\w-]+)-text$/)) && decls.key?(m[1])
          pair_bg_name = m[1]
          pair_bg_color = resolve_color(decls[m[1]], decls, bg_color: bg_color || '#ffffff')
        end

        resolved = resolve_color(raw, decls, bg_color: pair_bg_color || '#ffffff')
        if resolved && pair_bg_color
          ratio = contrast_ratio(resolved, pair_bg_color)
          results << ContrastPair.new(theme: theme_label, text_token: name, bg_token: pair_bg_name,
                                       ratio: ratio.round(2), passes_body: ratio >= 4.5,
                                       passes_large: ratio >= 3.0, resolved: true)
        else
          results << ContrastPair.new(theme: theme_label, text_token: name, bg_token: pair_bg_name,
                                       ratio: nil, passes_body: false, passes_large: false, resolved: false)
        end
      end
    end

    results
  end

  def theme_label_for(full_text, block_body)
    idx = full_text.index(block_body) || 0
    preceding = full_text[0...idx]
    if preceding.match?(/data-theme=["']dark["']\]\s*\{\s*\z/m) || preceding =~ /:root\[data-theme=["']dark["']\]\s*\{[^{}]*\z/m
      'dark'
    elsif preceding =~ /prefers-color-scheme:\s*dark[\s\S]*:root:not[^{]*\{[^{}]*\z/m
      'dark'
    else
      'light'
    end
  end

  def resolve_color(raw, decls, bg_color:, seen: Set.new)
    v = raw.strip
    return flatten_alpha(v, bg_color) if v.match?(HEX)

    if (m = v.match(COLOR_MIX_SRGB))
      a_raw, pct, b_raw = m[1].strip, m[2].to_f, m[3].strip
      a = resolve_token_or_literal(a_raw, decls, bg_color:, seen:)
      b = if b_raw == 'transparent'
            bg_color
      else
            resolve_token_or_literal(b_raw, decls, bg_color:, seen:)
      end
      return nil unless a && b

      return mix_hex(a, b, pct)
    end

    if (m = v.match(/^var\((--[\w-]+)\)$/))
      return nil if seen.include?(m[1])

      ref = decls[m[1]]
      return ref ? resolve_color(ref, decls, bg_color:, seen: seen | [ m[1] ]) : nil
    end

    nil
  end

  def resolve_token_or_literal(token_text, decls, bg_color:, seen: Set.new)
    t = token_text.strip
    if (m = t.match(/^var\((--[\w-]+)\)$/))
      return nil if seen.include?(m[1])

      inner = decls[m[1]]
      inner ? resolve_color(inner, decls, bg_color:, seen: seen | [ m[1] ]) : nil
    elsif t.match?(HEX)
      flatten_alpha(t, bg_color)
    else
      nil
    end
  end

  def mix_hex(hex_a, hex_b, pct_a)
    ra, ga, ba = hex_rgb(hex_a)
    rb, gb, bb = hex_rgb(hex_b)
    f = pct_a / 100.0
    r = (ra * f + rb * (1 - f)).round
    g = (ga * f + gb * (1 - f)).round
    b = (ba * f + bb * (1 - f)).round
    format('#%02x%02x%02x', r, g, b)
  end

  # Composites a four- or eight-digit #RGBA/#RRGGBBAA over the background so a translucent
  # token is not graded as if it were opaque.
  def flatten_alpha(hex, bg_color)
    h = hex.delete_prefix('#')
    h = h.chars.map { |c| c * 2 }.join if h.length == 4
    return hex unless h.length == 8

    mix_hex("##{h[0, 6]}", bg_color, h[6, 2].to_i(16) * 100.0 / 255)
  end

  def hex_rgb(hex)
    h = hex.delete_prefix('#')
    h = h.chars.each_slice(1).map { |c| c.first * 2 }.join if h.length == 3
    [ h[0, 2].to_i(16), h[2, 2].to_i(16), h[4, 2].to_i(16) ]
  end

  def contrast_ratio(hex_a, hex_b)
    la = relative_luminance(hex_a)
    lb = relative_luminance(hex_b)
    lighter = [ la, lb ].max
    darker = [ la, lb ].min
    (lighter + 0.05) / (darker + 0.05)
  end

  def relative_luminance(hex)
    r, g, b = hex_rgb(hex).map { |c| c / 255.0 }
    rl, gl, bl = [ r, g, b ].map { |c| c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4 }
    0.2126 * rl + 0.7152 * gl + 0.0722 * bl
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
      report.contrast.each do |c|
        if c.resolved
          status = c.passes_body ? 'pass 4.5:1' : (c.passes_large ? 'pass 3:1 only' : 'fail')
          lines << "  [#{c.theme}] #{c.text_token} on #{c.bg_token}: #{c.ratio}:1 (#{status})"
        else
          lines << "  [#{c.theme}] #{c.text_token} on #{c.bg_token}: unresolved, state manually"
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
          passes_body: c.passes_body, passes_large: c.passes_large, resolved: c.resolved }
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
