#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'color_css'
require_relative 'color_markup'
require_relative 'color_tailwind'
require_relative 'color_value'

# Stray color literal, Tailwind and gradient findings for the cf:color
# checker, scoped to values and attributes only: CSS declaration values,
# markup style=/fill=/stroke=/class= attributes, and script strings whose
# whole trimmed text is a hex or rgb/hsl color literal. Never
# selectors, never url() fragments, never prose. References
# ColorCheck::COLOR_FN and ColorCheck::GRADIENT lazily
# (inside method bodies only), so this file does not require 'color_check'
# and stays free of the require cycle that would create.
module ColorScan
  # A hex literal glued to a preceding word is still rejected for "&" (HTML
  # entities such as &#8599;, never real CSS) but not for a preceding word
  # character: in a tokenized CSS declaration value "solid#123456" is the
  # ident "solid" followed by the hash token "#123456", two separate tokens,
  # so HEX_CSS (used wherever the scanned text is itself a CSS value: CSS/
  # Sass/Less declarations, and a style= attribute split into declarations)
  # only guards against "&".
  HEX_CSS = /(?<!&)#(?:\h{8}|\h{6}|\h{4}|\h{3})\b/.freeze
  HEX_FULL = /\A#(?:\h{8}|\h{6}|\h{4}|\h{3})\z/.freeze
  NAMED_WORD = /(?<![\w$@#.-])[A-Za-z]+(?![\w(-])/.freeze
  # Named-color classification of a CSS property, three-way. A bare
  # named-color word ("red", "navy") in the value of a property that accepts
  # a <color> per the CSS specs (Color 4, Backgrounds 3, Borders, Text 4,
  # Text Decoration 4, UI 4, Scrollbars, Multicol, Fill and Stroke, SVG 2,
  # Filter Effects, Masking) is a finding. In a property whose idents are
  # names, never colors (animation-name, font-family, grid-area and the
  # like), it is exempt. Any other property reports the word unresolved: an
  # unknown property is loud, never silently exempt. When unsure whether a
  # property accepts a color, it belongs in neither set.
  COLOR_PROPERTIES = Set.new(%w[
    color background background-color background-image
    outline outline-color
    text-decoration text-decoration-color text-emphasis text-emphasis-color
    text-shadow box-shadow column-rule column-rule-color
    caret-color accent-color scrollbar-color
    fill stroke stop-color flood-color lighting-color
    -webkit-text-stroke -webkit-text-stroke-color -webkit-text-fill-color
    -webkit-tap-highlight-color
    filter backdrop-filter mask mask-border border-image
  ]).freeze
  # border, border-color, every physical and logical side shorthand and its
  # -color longhand (also -webkit- prefixed). Not border-radius or -width.
  BORDER_COLOR_PROPERTY = /\A(?:-webkit-)?border(?:-(?:top|right|bottom|left|block|inline|block-start|block-end|inline-start|inline-end))?(?:-color)?\z/.freeze
  NAME_VALUED_PROPERTIES = Set.new(%w[
    animation animation-name
    grid-area grid-row grid-column grid-row-start grid-row-end
    grid-column-start grid-column-end grid-template-areas
    font font-family font-palette container container-name
    counter-reset counter-increment counter-set
    view-transition-name view-transition-class
    list-style list-style-type transition-property will-change
    anchor-name position-anchor timeline-scope
    scroll-timeline-name view-timeline-name page
  ]).freeze
  UNCLASSIFIED_PROPERTY_REASON = 'named color in unclassified property %s'
  SCRIPT_COLOR_FN_FULL = /\A(?:rgba?|hsla?)\(.*\)\z/im.freeze
  REGEX_CONTEXT_CHAR = /[(\[{,;:=!&|?+\-*%^~<>]/.freeze
  ATTR_NAMES = %w[style fill stroke class classname].freeze
  MDX_ATTR = /\b(?:style|fill|stroke|className|class)\s*=\s*(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')/mi.freeze
  IMPORT_EXPORT_LINE = /\A[ \t]*(?:import|export)\b/.freeze

  module_function

  # Scans one already-read file for stray literal, tailwind and gradient
  # findings. token_file is the detected token source's path (or nil); its
  # own custom-property declarations are exempt, ordinary rules in it are
  # still scanned.
  def findings_for(path, text, token_file:, token_names: Set.new)
    scan(path, text, token_file:, token_names:).first
  end

  # Like findings_for, but returns [findings, unresolved]: color-shaped
  # entries the scanner could not classify (a named color in an unknown
  # property, an unknown Tailwind word) are kept apart as
  # ColorCheck::Unresolved entries instead of being dropped.
  def scan(path, text, token_file:, token_names: Set.new)
    all_entries(path, text, token_file, token_names).partition { |e| e.is_a?(ColorCheck::Finding) }
  end

  # Debug accessor for the no-silent-drop invariant: every color-shaped
  # literal the scanner sees, each in exactly one class. Returns
  # [[text, :finding | :unresolved], ...] in scan order.
  def classify_all(path, text, token_file: nil)
    all_entries(path, text, token_file).filter_map do |e|
      next [ e.text, :unresolved ] if e.is_a?(ColorCheck::Unresolved)

      [ e.text, :finding ] if e.kind == 'literal'
    end
  end

  def all_entries(path, text, token_file, token_names = Set.new)
    ext = File.extname(path).delete_prefix('.').downcase
    case ext
    when 'css', 'scss', 'less'
      css_file_findings(path, text, token_file, ext.to_sym, token_names)
    when 'sass'
      sass_file_findings(path, text, token_file)
    when 'html', 'vue', 'svelte', 'astro'
      markup_file_findings(path, text, token_file, token_names)
    when 'js', 'jsx', 'ts', 'tsx'
      script_findings(path, text)
    when 'mdx'
      mdx_findings(path, text)
    else
      []
    end
  end

  # --- CSS / SCSS / Less -----------------------------------------------

  def css_file_findings(path, text, token_file, dialect, token_names)
    css_sheet_findings(path, token_file, ColorCss.parse(text, dialect: dialect), token_names)
  end

  def css_sheet_findings(path, token_file, sheet, token_names = Set.new)
    findings = []
    sheet.decls.each do |decl|
      next if token_file?(path, token_file) && decl.name.start_with?('--')

      findings.concat(value_findings(path, decl.value, decl.value_line, decl.name, scan_value: decl.scan_value))
    end
    sheet.at_rule_stmts.each do |stmt|
      next unless stmt.name.casecmp?('@apply')

      findings.concat(tailwind_entries(path, stmt.line, stmt.prelude, token_names))
    end
    findings
  end

  # path and token_file can arrive in different but equivalent spellings (a
  # --tokens CLI argument versus Find's "./"-prefixed scan path), so the
  # token-file exemption compares their File.expand_path forms, not the raw
  # strings.
  def token_file?(path, token_file)
    return false unless token_file

    File.expand_path(path) == File.expand_path(token_file)
  end

  # :finding, :exempt or :unresolved for a bare named-color word in the
  # value of property name. A custom property or preprocessor variable
  # ("--x", "$x", "@x" in Less) carries no CSS semantics of its own and is
  # always in scope.
  def named_color_class(name)
    return :finding if name.start_with?('--', '$', '@')

    prop = name.downcase
    return :finding if COLOR_PROPERTIES.include?(prop) || prop.match?(BORDER_COLOR_PROPERTY)
    return :exempt if NAME_VALUED_PROPERTIES.include?(prop)

    :unresolved
  end

  # Scans one declaration value line by line (so a multiline value keeps
  # correct line numbers). The scanned text is the CSS parser's mask of the
  # value (scan_value: a Decl's own, else ColorCss.scan_value): every string
  # and url() body is spaces of equal length, so a string continued by an
  # escaped newline stays masked on its later lines. That text is scanned
  # for hex, color functions, gradients and, only when property_name is
  # color-bearing, bare named-color words.
  def value_findings(file, value, value_line, property_name, scan_value: nil)
    findings = []
    named_class = named_color_class(property_name)
    raw_lines = value.lines
    (scan_value || ColorCss.scan_value(value)).each_line.with_index do |blanked, idx|
      lineno = value_line + idx
      line = raw_lines[idx]
      blanked.scan(HEX_CSS) { findings << finding(file, lineno, 'literal', line) }
      blanked.scan(ColorCheck::COLOR_FN) { findings << finding(file, lineno, 'literal', line) }
      blanked.scan(ColorCheck::GRADIENT) { findings << finding(file, lineno, 'gradient', line) }
      named_color_words(blanked).each do
        entry = named_entry(named_class, file, lineno, line, property_name)
        findings << entry if entry
      end
    end
    findings
  end

  def named_entry(named_class, file, lineno, line, property_name)
    case named_class
    when :finding then finding(file, lineno, 'literal', line)
    when :unresolved then unresolved(file, lineno, 'literal', line, format(UNCLASSIFIED_PROPERTY_REASON, property_name))
    end
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
      next if token_file?(path, token_file) && m[1].start_with?('--')

      findings.concat(value_findings(path, m[2], lineno, m[1]))
    end
    findings
  end

  # --- Markup: .html .vue .svelte .astro ---------------------------------

  # Consumes the shared ColorMarkup walker (one tokenizer, not a stack of
  # regex pre-passes): attribute values, script bodies and style bodies are
  # scanned in source order; textarea and title content is a text node and
  # out of scope. A "<!--" or "<style>" that appears only inside a script
  # string, or inside a quoted attribute value, is just data to the walker
  # and never swallows real markup.
  def markup_file_findings(path, text, token_file, token_names)
    findings = []
    ColorMarkup.each_node(text) do |node|
      case node
      when ColorMarkup::Attr
        findings.concat(markup_attr_node_findings(path, text, node, token_names))
      when ColorMarkup::Raw
        next unless node.tag == 'script'

        line_offset = text[0...node.pos].count("\n")
        findings.concat(script_findings(path, node.body, line_offset: line_offset))
      when ColorMarkup::Style
        line_offset = text[0...node.pos].count("\n")
        lang = node.lang
        dialect = lang && %w[scss less].include?(lang.downcase) ? lang.downcase.to_sym : :css
        sheet = ColorCss.parse(node.body, dialect: dialect, line_offset: line_offset)
        findings.concat(css_sheet_findings(path, token_file, sheet, token_names))
      end
    end
    findings
  end

  def markup_attr_node_findings(path, text, node, token_names)
    base_name = node.name.sub(ColorMarkup::BOUND_ATTR_PREFIX, '')
    attr = base_name.downcase
    bound = node.curly || ColorMarkup::BOUND_ATTR_PREFIX.match?(node.name)
    return [] unless bound || ATTR_NAMES.include?(attr)

    line_offset = text[0...node.pos].count("\n")
    # A Vue/Svelte bound attribute's value is a JS expression: the same
    # obvious-literal lexer as a script body.
    return script_findings(path, node.value, line_offset: line_offset) if bound

    markup_attr_value_findings(path, node.value, line_offset, attr, token_names)
  end

  def markup_attr_value_findings(path, value, line_offset, attr, token_names)
    case attr
    when 'style'
      style_attr_findings(path, value, line_offset)
    when 'fill', 'stroke'
      attr_value_findings(path, line_offset + 1, value, named_whole_only: true)
    when 'class', 'classname'
      tailwind_entries(path, line_offset + 1, value, token_names)
    else
      []
    end
  end

  # A style= attribute's value is itself CSS: parse it with ColorCss (which
  # keeps correct line numbers across a multiline value) and scan each
  # declaration exactly like a stylesheet value.
  def style_attr_findings(path, value, line_offset)
    sheet = ColorCss.parse(value, dialect: :css, line_offset: line_offset)
    findings = []
    sheet.decls.each { |decl| findings.concat(value_findings(path, decl.value, decl.value_line, decl.name, scan_value: decl.scan_value)) }
    findings
  end

  def attr_value_findings(path, line, value, named_whole_only:)
    findings = []
    blanked = ColorCss.scan_value(value)
    blanked.scan(HEX_CSS) { findings << finding(path, line, 'literal', value) }
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

  # A small lexer: skips comments, regex literals and template literals,
  # reads single- and double-quoted strings, and reports a string only when
  # the whole trimmed string is a hex color or an rgb()/rgba()/hsl()/hsla()
  # call. No key context, no JSX, no Tailwind. allowed_ranges, when given,
  # restricts which string start positions count (MDX keeps prose out).
  def script_findings(path, text, line_offset: 0, allowed_ranges: nil)
    findings = []
    each_script_string(text) do |start, content|
      next if allowed_ranges&.none? { |r| r.cover?(start) }
      next unless script_literal?(content.strip)

      line = text[0...start].count("\n") + 1 + line_offset
      findings << finding(path, line, 'literal', content)
    end
    findings
  end

  def script_literal?(stripped)
    HEX_FULL.match?(stripped) || SCRIPT_COLOR_FN_FULL.match?(stripped)
  end

  def each_script_string(text)
    i = 0
    len = text.length
    while i < len
      c = text[i]
      if c == '"' || c == "'"
        content, j = scan_script_string(text, i, len)
        yield i, content
        i = j
      else
        i = skip_script_token(text, i, len)
      end
    end
  end

  def skip_script_token(text, i, len)
    case text[i]
    when '`' then skip_script_template(text, i, len)
    when '/'
      if %w[/ *].include?(text[i + 1]) then skip_script_comment(text, i, len)
      elsif regex_context?(text, i) then skip_script_regex(text, i, len)
      else i + 1
      end
    else i + 1
    end
  end

  # A "/" opens a regex literal when the previous significant character
  # cannot end an operand (or there is none). "if (x) /re/" is read as
  # division; the rare miss only drops a finding on that line.
  def regex_context?(text, i)
    j = i - 1
    j -= 1 while j >= 0 && text[j].match?(/\s/)
    return true if j.negative?
    # "x++ / 2": a postfix ++ or -- ends an operand.
    return false if %w[+ -].include?(text[j]) && text[j - 1] == text[j]

    text[j].match?(REGEX_CONTEXT_CHAR)
  end

  def skip_script_comment(text, i, len)
    if text[i + 1] == '/'
      text.index("\n", i) || len
    else
      close = text.index('*/', i + 2)
      close ? close + 2 : len
    end
  end

  def skip_script_regex(text, i, len)
    j = i + 1
    in_class = false
    while j < len
      c = text[j]
      return j if c == "\n"

      if c == '\\' then j += 1
      elsif c == '[' then in_class = true
      elsif c == ']' then in_class = false
      elsif c == '/' && !in_class then return j + 1
      end
      j += 1
    end
    j
  end

  def skip_script_template(text, i, len)
    j = i + 1
    while j < len
      return j + 1 if text[j] == '`'

      j += text[j] == '\\' ? 2 : 1
    end
    len
  end

  def scan_script_string(text, i, len)
    quote = text[i]
    content = +''
    i += 1
    while i < len
      c = text[i]
      return [ content, i + 1 ] if c == quote
      return [ content, i ] if c == "\n"

      if c == '\\' && i + 1 < len
        content << c << text[i + 1]
        i += 2
      else
        content << c
        i += 1
      end
    end
    [ content, i ]
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
    idx = 0
    len = text.length
    while (open = text.index('{', idx))
      close = ColorMarkup.expression_end(text, open + 1, len)
      break unless close

      ranges << (open...close)
      idx = close
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

  # One entry per color utility in a class/className value or @apply
  # prelude: findings and unresolved words are reported, exempt ones dropped.
  def tailwind_entries(path, line, value, token_names)
    ColorTailwind.findings(value, tokens: token_names).filter_map do |e|
      case e.status
      when :finding then finding(path, line, 'tailwind', e.text)
      when :unresolved then unresolved(path, line, 'tailwind', e.text, e.reason)
      end
    end
  end

  def finding(file, line, kind, text)
    ColorCheck::Finding.new(file: file, line: line, kind: kind, text: text.to_s.strip)
  end

  def unresolved(file, line, kind, text, reason)
    ColorCheck::Unresolved.new(file: file, line: line, kind: kind, text: text.to_s.strip, reason: reason)
  end
end
