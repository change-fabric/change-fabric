#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'color_css'
require_relative 'color_value'

# Stray color literal, Tailwind and gradient findings for the cf:color
# checker, scoped per the project's decision 2 ("values and attributes
# only"): CSS declaration values, markup style=/fill=/stroke=/class=
# attributes, and script string literals that are the whole value of a
# color-bearing key or attribute. Never selectors, never url() fragments,
# never prose. References ColorCheck::COLOR_FN, ColorCheck::TAILWIND and
# ColorCheck::GRADIENT lazily (inside method bodies only), so this file does
# not require 'color_check' and stays free of the require cycle that would
# create.
module ColorScan
  # A hex literal, guarded on the left against "&" (HTML entities), a word
  # character or "-" (so --red, &#8599; and url fragments glued to a word
  # never match), and restricted to the four valid CSS hex lengths.
  HEX = /(?<![&\w-])#(?:\h{8}|\h{6}|\h{4}|\h{3})\b/.freeze
  HEX_FULL = /\A#(?:\h{8}|\h{6}|\h{4}|\h{3})\z/.freeze
  NAMED_WORD = /(?<![\w$@#.-])[A-Za-z]+(?![\w(-])/.freeze
  QUOTED_OR_URL = /"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|url\([^)]*\)/i.freeze
  COLOR_KEY = /(^|[a-z])(color|colour|background|bg|fill|stroke|border|outline|shadow)/i.freeze
  SCRIPT_COLOR_FN_FULL = /\A(?:#{ColorValue::COLOR_FN_NAMES.join('|')})\(.*\)\z/im.freeze
  ATTR_KEYS = %w[style fill stroke].freeze
  STYLE_BLOCK = /<style(?:\s+[^>]*)?>(.*?)<\/style>/mi.freeze
  SCRIPT_BLOCK = /<script(?:\s+[^>]*)?>(.*?)<\/script>/mi.freeze
  MARKUP_ATTR = /\b(style|fill|stroke|class|className)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)')/mi.freeze
  MDX_ATTR = /\b(?:style|fill|stroke|className|class)\s*=\s*(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')/mi.freeze
  IMPORT_EXPORT_LINE = /\A[ \t]*(?:import|export)\b/.freeze

  module_function

  # Scans one already-read file for stray literal, tailwind and gradient
  # findings. token_file is the detected token source's path (or nil); its
  # own custom-property declarations are exempt, ordinary rules in it are
  # still scanned.
  def findings_for(path, text, token_file:)
    ext = File.extname(path).delete_prefix('.').downcase
    case ext
    when 'css', 'scss', 'less'
      css_file_findings(path, text, token_file, ext.to_sym)
    when 'sass'
      sass_file_findings(path, text, token_file)
    when 'html', 'vue', 'svelte', 'astro'
      markup_file_findings(path, text, token_file)
    when 'js', 'jsx', 'ts', 'tsx'
      script_findings(path, text)
    when 'mdx'
      mdx_findings(path, text)
    else
      []
    end
  end

  # --- CSS / SCSS / Less -----------------------------------------------

  def css_file_findings(path, text, token_file, dialect)
    css_sheet_findings(path, token_file, ColorCss.parse(text, dialect: dialect))
  end

  def css_sheet_findings(path, token_file, sheet)
    findings = []
    sheet.decls.each do |decl|
      next if path == token_file && decl.name.start_with?('--')

      findings.concat(value_findings(path, decl.value, decl.value_line))
    end
    sheet.at_rule_stmts.each do |stmt|
      stmt.prelude.scan(ColorCheck::TAILWIND) do
        findings << finding(path, stmt.line, 'tailwind', stmt.prelude)
      end
    end
    findings
  end

  # Scans one declaration value line by line (so a multiline value keeps
  # correct line numbers): url() spans and quoted strings are blanked out
  # first, then the blanked text is scanned for hex, color functions,
  # gradients and bare named-color words.
  def value_findings(file, value, value_line)
    findings = []
    value.each_line.with_index do |line, idx|
      lineno = value_line + idx
      blanked = blank_quoted_and_urls(line)
      blanked.scan(HEX) { findings << finding(file, lineno, 'literal', line) }
      blanked.scan(ColorCheck::COLOR_FN) { findings << finding(file, lineno, 'literal', line) }
      blanked.scan(ColorCheck::GRADIENT) { findings << finding(file, lineno, 'gradient', line) }
      named_color_words(blanked).each { findings << finding(file, lineno, 'literal', line) }
    end
    findings
  end

  def blank_quoted_and_urls(text)
    text.gsub(QUOTED_OR_URL) { |m| m.gsub(/[^\n]/, ' ') }
  end

  def named_color_words(blanked)
    blanked.scan(NAMED_WORD).select { |w| ColorValue::NAMED.key?(w.downcase) }
  end

  # --- Sass (indented syntax) --------------------------------------------

  def sass_file_findings(path, text, token_file)
    findings = []
    uncommented = text.gsub(%r{/\*.*?\*/}m) { |m| m.gsub(/[^\n]/, ' ') }
    uncommented.each_line.with_index(1) do |line, lineno|
      code = line.chomp.sub(%r{//.*\z}, '')
      m = code.match(/\A\s*(\$?[\w-]+)\s*:\s*(.+)\z/)
      next unless m
      next if path == token_file && m[1].start_with?('--')

      findings.concat(value_findings(path, m[2], lineno))
    end
    findings
  end

  # --- Markup: .html .vue .svelte .astro ---------------------------------

  def markup_file_findings(path, text, token_file)
    findings = []
    remainder = +text.dup

    text.to_enum(:scan, STYLE_BLOCK).each do
      m = Regexp.last_match
      findings.concat(style_block_findings(path, text, token_file, m))
      blank_range!(remainder, m.begin(0), m.end(0))
    end

    text.to_enum(:scan, SCRIPT_BLOCK).each do
      m = Regexp.last_match
      line_offset = text[0...m.begin(1)].count("\n")
      findings.concat(script_findings(path, m[1], line_offset: line_offset))
      blank_range!(remainder, m.begin(0), m.end(0))
    end

    findings.concat(markup_attr_findings(path, remainder))
    findings
  end

  def style_block_findings(path, text, token_file, match)
    tag = match[0][/\A<style[^>]*>/mi] || '<style>'
    lang = tag[/lang\s*=\s*["']?(scss|less)["']?/i, 1]
    dialect = lang ? lang.downcase.to_sym : :css
    line_offset = text[0...match.begin(1)].count("\n")
    sheet = ColorCss.parse(match[1], dialect: dialect, line_offset: line_offset)
    css_sheet_findings(path, token_file, sheet)
  end

  def blank_range!(str, from, to)
    str[from...to] = str[from...to].gsub(/[^\n]/, ' ')
  end

  def markup_attr_findings(path, text)
    findings = []
    text.to_enum(:scan, MARKUP_ATTR).each do
      m = Regexp.last_match
      attr = m[1].downcase
      value = m[2] || m[3]
      line = text[0...m.begin(0)].count("\n") + 1
      findings.concat(markup_attr_value_findings(path, line, attr, value))
    end
    findings
  end

  def markup_attr_value_findings(path, line, attr, value)
    case attr
    when 'style'
      value.split(';').flat_map do |decl|
        _prop, _sep, val = decl.partition(':')
        val.empty? ? [] : attr_value_findings(path, line, val, named_whole_only: false)
      end
    when 'fill', 'stroke'
      attr_value_findings(path, line, value, named_whole_only: true)
    when 'class', 'classname'
      value.scan(ColorCheck::TAILWIND).map { finding(path, line, 'tailwind', value) }
    else
      []
    end
  end

  def attr_value_findings(path, line, value, named_whole_only:)
    findings = []
    blanked = blank_quoted_and_urls(value)
    blanked.scan(HEX) { findings << finding(path, line, 'literal', value) }
    blanked.scan(ColorCheck::COLOR_FN) { findings << finding(path, line, 'literal', value) }
    blanked.scan(ColorCheck::GRADIENT) { findings << finding(path, line, 'gradient', value) }
    if named_whole_only
      stripped = value.strip
      if stripped.match?(/\A[A-Za-z]+\z/) && ColorValue::NAMED.key?(stripped.downcase)
        findings << finding(path, line, 'literal', value)
      end
    else
      named_color_words(blanked).each { findings << finding(path, line, 'literal', value) }
    end
    findings
  end

  # --- Script: .js .jsx .ts .tsx -------------------------------------------

  # Walks text, skipping comments, collecting single/double-quoted strings
  # and backtick templates (${...} spans skipped), and classifies each one.
  # allowed_ranges, when given, restricts which string start positions are
  # eligible to produce a finding at all (used by MDX to keep prose out of
  # scope); nil scans every string (plain JS/TS/JSX/TSX files).
  def script_findings(path, text, line_offset: 0, allowed_ranges: nil)
    findings = []
    i = 0
    len = text.length
    while i < len
      case text[i]
      when '/'
        i = skip_script_comment(text, i, len)
      when '"', "'"
        start = i
        content, i = scan_script_string(text, i, len)
        findings.concat(classified_string(path, text, start, content, line_offset, allowed_ranges))
      when '`'
        start = i
        content, i = scan_script_template(text, i, len)
        findings.concat(classified_string(path, text, start, content, line_offset, allowed_ranges))
      else
        i += 1
      end
    end
    findings
  end

  def skip_script_comment(text, i, len)
    if text[i + 1] == '/'
      nl = text.index("\n", i)
      nl || len
    elsif text[i + 1] == '*'
      close = text.index('*/', i + 2)
      close ? close + 2 : len
    else
      i + 1
    end
  end

  def scan_script_string(text, i, len)
    quote = text[i]
    content = +''
    i += 1
    while i < len
      c = text[i]
      if c == '\\' && i + 1 < len
        content << c << text[i + 1]
        i += 2
      elsif c == quote
        i += 1
        break
      elsif c == "\n"
        break
      else
        content << c
        i += 1
      end
    end
    [ content, i ]
  end

  def scan_script_template(text, i, len)
    content = +''
    i += 1
    while i < len
      c = text[i]
      if c == '\\' && i + 1 < len
        content << c << text[i + 1]
        i += 2
      elsif c == '`'
        i += 1
        break
      elsif c == '$' && text[i + 1] == '{'
        i = skip_script_interpolation(text, i + 2, len)
      else
        content << c
        i += 1
      end
    end
    [ content, i ]
  end

  def skip_script_interpolation(text, i, len)
    depth = 1
    while i < len && depth.positive?
      c = text[i]
      case c
      when '{'
        depth += 1
        i += 1
      when '}'
        depth -= 1
        i += 1
      when '"', "'", '`'
        i += 1
        i += 1 while i < len && text[i] != c
        i += 1
      else
        i += 1
      end
    end
    i
  end

  def classified_string(path, text, start, content, line_offset, allowed_ranges)
    return [] if allowed_ranges && allowed_ranges.none? { |r| r.cover?(start) }

    line = text[0...start].count("\n") + 1 + line_offset
    key = lookback_key(text, start)
    position_a = !key.nil? && (ATTR_KEYS.include?(key) || key.match?(COLOR_KEY))
    classify_string(path, line, content, position_a)
  end

  def classify_string(path, line, content, position_a)
    findings = []
    stripped = content.strip
    if HEX_FULL.match?(stripped)
      short = [ 3, 4 ].include?(stripped.length - 1)
      findings << finding(path, line, 'literal', content) if !short || position_a
    elsif SCRIPT_COLOR_FN_FULL.match?(stripped)
      findings << finding(path, line, 'literal', content)
    elsif stripped.match?(/\A[A-Za-z]+\z/) && ColorValue::NAMED.key?(stripped.downcase)
      findings << finding(path, line, 'literal', content)
    end
    findings << finding(path, line, 'gradient', content) if ColorCheck::GRADIENT.match?(content)
    content.scan(ColorCheck::TAILWIND) { findings << finding(path, line, 'tailwind', content) }
    findings
  end

  # Looks back past whitespace from a string's start index for ":" (object
  # or style-object key) or "=" (JSX attribute), then past more whitespace
  # for the key itself (an identifier, or a quoted key, unquoted). Returns
  # nil when no such key is found.
  def lookback_key(text, start_idx)
    i = skip_ws_back(text, start_idx - 1)
    return nil unless i >= 0 && (text[i] == ':' || text[i] == '=')

    i = skip_ws_back(text, i - 1)
    return nil if i.negative?

    if text[i] == '"' || text[i] == "'"
      quoted_key_before(text, i)
    else
      identifier_before(text, i)
    end
  end

  def skip_ws_back(text, i)
    i -= 1 while i >= 0 && text[i].match?(/[ \t]/)
    i
  end

  def quoted_key_before(text, close_idx)
    quote = text[close_idx]
    j = close_idx - 1
    j -= 1 while j >= 0 && text[j] != quote
    return nil if j.negative?

    text[(j + 1)...close_idx]
  end

  def identifier_before(text, end_idx)
    j = end_idx
    j -= 1 while j >= 0 && text[j].match?(/[\w$]/)
    key = text[(j + 1)..end_idx]
    key.nil? || key.empty? ? nil : key
  end

  # --- MDX -----------------------------------------------------------------

  # Fenced code blocks and inline code spans are blanked out entirely.
  # String literals are only eligible inside import/export lines, {...}
  # expressions, and style=/fill=/stroke=/className=/class= attribute
  # values; everything else (prose) is never scanned.
  def mdx_findings(path, text)
    blanked = blank_mdx_code(text)
    ranges = import_export_ranges(blanked) + brace_ranges(blanked) + mdx_attr_ranges(blanked)
    script_findings(path, blanked, allowed_ranges: ranges)
  end

  def blank_mdx_code(text)
    blanked = text.gsub(/```.*?```/m) { |m| m.gsub(/[^\n]/, ' ') }
    blanked = blanked.gsub(/~~~.*?~~~/m) { |m| m.gsub(/[^\n]/, ' ') }
    blanked.gsub(/`[^`\n]*`/) { |m| m.gsub(/[^\n]/, ' ') }
  end

  def import_export_ranges(text)
    ranges = []
    offset = 0
    text.each_line do |line|
      ranges << (offset...(offset + line.length)) if line.match?(IMPORT_EXPORT_LINE)
      offset += line.length
    end
    ranges
  end

  def brace_ranges(text)
    ranges = []
    depth = 0
    start = nil
    text.each_char.with_index do |c, idx|
      if c == '{'
        start = idx if depth.zero?
        depth += 1
      elsif c == '}' && depth.positive?
        depth -= 1
        if depth.zero? && start
          ranges << (start...(idx + 1))
          start = nil
        end
      end
    end
    ranges
  end

  def mdx_attr_ranges(text)
    ranges = []
    text.to_enum(:scan, MDX_ATTR).each do
      m = Regexp.last_match
      ranges << (m.begin(0)...m.end(0))
    end
    ranges
  end

  # --- shared --------------------------------------------------------------

  def finding(file, line, kind, text)
    ColorCheck::Finding.new(file: file, line: line, kind: kind, text: text.to_s.strip)
  end
end
