#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'color_css'
require_relative 'color_markup'
require_relative 'color_value'

# Stray color literal, Tailwind and gradient findings for the cf:color
# checker, scoped to values and attributes only: CSS declaration values,
# markup style=/fill=/stroke=/class= attributes, and script string literals
# that are the whole value of a color-bearing key or attribute. Never
# selectors, never url() fragments, never prose. References
# ColorCheck::COLOR_FN, ColorCheck::TAILWIND and ColorCheck::GRADIENT lazily
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
  COLOR_KEY = /(^|[a-z])(color|colour|background|bg|fill|stroke|border|outline|shadow)/i.freeze
  # A CSS property name is color-bearing (a bare named-color word in its
  # value is in scope) when the property itself is about color: "color",
  # "background(-color)", "border(-color)", "outline(-color)", "box-shadow"/
  # "text-shadow", "fill", "stroke", "caret-color", "accent-color" and the
  # like. A custom property or preprocessor variable ("--x", "$x", "@x" in
  # Less) is always in scope: it carries no non-color CSS semantics of its
  # own. Everything else, including animation-name, grid-area, font-family
  # and container-name (custom idents that happen to collide with a named
  # color, such as "snow", "navy" or "Red"), is out of scope: those bare
  # words are not color literals in that property.
  COLOR_BEARING_PROPERTY = /(?:\A|-)(?:color|colour|background|bg|fill|stroke|border|outline|shadow)(?:\z|-)/i.freeze
  SCRIPT_COLOR_FN_FULL = /\A(?:#{ColorValue::COLOR_FN_NAMES.join('|')})\(.*\)\z/im.freeze
  ATTR_NAMES = %w[style fill stroke class classname].freeze
  MDX_ATTR = /\b(?:style|fill|stroke|className|class)\s*=\s*(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')/mi.freeze
  IMPORT_EXPORT_LINE = /\A[ \t]*(?:import|export)\b/.freeze
  EXPR_CONTEXT_CHARS = /[(\[{,;:=!&|?+\-*%^~<>]/.freeze
  EXPR_CONTEXT_KEYWORDS = %w[return typeof instanceof in of new delete void throw else do yield case].freeze
  # The attribute enclosing a bound value: name without its binding prefix,
  # binding one of :static, :vue_bind, :svelte_brace, :jsx_brace, and start,
  # the index in the scanned text where the attribute's expression begins.
  AttrCtx = Data.define(:name, :binding, :start) do
    def color_bearing?
      # A kebab-case name is read as its camelCase form (data-color as
      # dataColor), so COLOR_KEY sees the same word boundary either way.
      ATTR_NAMES.include?(name.downcase) || name.delete('-').match?(COLOR_KEY)
    end
  end

  module_function

  # Scans one already-read file for stray literal, tailwind and gradient
  # findings. token_file is the detected token source's path (or nil); its
  # own custom-property declarations are exempt, ordinary rules in it are
  # still scanned.
  def findings_for(path, text, token_file:)
    scan(path, text, token_file:).first
  end

  # Like findings_for, but returns [findings, unresolved]: color-shaped
  # strings whose key context could not be determined are kept apart as
  # ColorCheck::Unresolved entries instead of being dropped.
  def scan(path, text, token_file:)
    all_entries(path, text, token_file).partition { |e| e.is_a?(ColorCheck::Finding) }
  end

  # Debug accessor for the no-silent-drop invariant: every color-shaped
  # literal the scanner sees, each in exactly one class. Returns
  # [[text, :finding | [:exempt, rule] | :unresolved], ...] in scan order,
  # where rule is one of EXEMPT_RULES or :non_color_key.
  def classify_all(path, text, token_file: nil)
    exempt = []
    Thread.current[:color_scan_exempt] = exempt
    entries = all_entries(path, text, token_file)
    classified = entries.filter_map do |e|
      next [ e.text, :unresolved ] if e.is_a?(ColorCheck::Unresolved)

      [ e.text, :finding ] if e.kind == 'literal'
    end
    classified + exempt
  ensure
    Thread.current[:color_scan_exempt] = nil
  end

  def all_entries(path, text, token_file)
    ext = File.extname(path).delete_prefix('.').downcase
    case ext
    when 'css', 'scss', 'less'
      css_file_findings(path, text, token_file, ext.to_sym)
    when 'sass'
      sass_file_findings(path, text, token_file)
    when 'html', 'vue', 'svelte', 'astro'
      markup_file_findings(path, text, token_file)
    when 'js', 'jsx', 'tsx'
      script_findings(path, text)
    when 'ts'
      # TypeScript proper has no JSX: "<T>x" there is an angle-bracket
      # assertion, so "<" never opens an element.
      script_findings(path, text, jsx: false)
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
      next if token_file?(path, token_file) && decl.name.start_with?('--')

      findings.concat(value_findings(path, decl.value, decl.value_line, decl.name, scan_value: decl.scan_value))
    end
    sheet.at_rule_stmts.each do |stmt|
      stmt.prelude.scan(ColorCheck::TAILWIND) do
        findings << finding(path, stmt.line, 'tailwind', stmt.prelude)
      end
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

  def color_bearing_property?(name)
    return true if name.start_with?('--', '$', '@')

    name.match?(COLOR_BEARING_PROPERTY)
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
    color_bearing = color_bearing_property?(property_name)
    raw_lines = value.lines
    (scan_value || ColorCss.scan_value(value)).each_line.with_index do |blanked, idx|
      lineno = value_line + idx
      line = raw_lines[idx]
      blanked.scan(HEX_CSS) { findings << finding(file, lineno, 'literal', line) }
      blanked.scan(ColorCheck::COLOR_FN) { findings << finding(file, lineno, 'literal', line) }
      blanked.scan(ColorCheck::GRADIENT) { findings << finding(file, lineno, 'gradient', line) }
      next unless color_bearing

      named_color_words(blanked).each { findings << finding(file, lineno, 'literal', line) }
    end
    findings
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
  def markup_file_findings(path, text, token_file)
    findings = []
    ColorMarkup.each_node(text) do |node|
      case node
      when ColorMarkup::Attr
        findings.concat(markup_attr_node_findings(path, text, node))
      when ColorMarkup::Raw
        next unless node.tag == 'script'

        line_offset = text[0...node.pos].count("\n")
        findings.concat(script_findings(path, node.body, line_offset: line_offset))
      when ColorMarkup::Style
        line_offset = text[0...node.pos].count("\n")
        lang = node.lang
        dialect = lang && %w[scss less].include?(lang.downcase) ? lang.downcase.to_sym : :css
        sheet = ColorCss.parse(node.body, dialect: dialect, line_offset: line_offset)
        findings.concat(css_sheet_findings(path, token_file, sheet))
      end
    end
    findings
  end

  def markup_attr_node_findings(path, text, node)
    base_name = node.name.sub(ColorMarkup::BOUND_ATTR_PREFIX, '')
    attr = base_name.downcase
    binding = attr_binding(node.name, node.curly)
    return [] unless binding != :static || ATTR_NAMES.include?(attr)

    line_offset = text[0...node.pos].count("\n")
    if binding == :static
      markup_attr_value_findings(path, node.value, line_offset, attr)
    else
      # A Vue/Svelte bound attribute's value is a JS expression, not a
      # literal: scan it with the script lexer, carrying the attribute
      # so a string that is the whole value keeps the attribute as key.
      ctx = AttrCtx.new(name: base_name, binding: binding, start: 0)
      script_findings(path, node.value, line_offset: line_offset, attr_ctx: ctx)
    end
  end

  def attr_binding(name, curly)
    return :svelte_brace if curly
    return :vue_bind if ColorMarkup::BOUND_ATTR_PREFIX.match?(name)

    :static
  end

  def markup_attr_value_findings(path, value, line_offset, attr)
    case attr
    when 'style'
      style_attr_findings(path, value, line_offset)
    when 'fill', 'stroke'
      attr_value_findings(path, line_offset + 1, value, named_whole_only: true)
    when 'class', 'classname'
      value.scan(ColorCheck::TAILWIND).map { finding(path, line_offset + 1, 'tailwind', value) }
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

  # Walks text, skipping comments and regex literals, collecting single/
  # double-quoted strings and backtick templates (${...} spans scanned as
  # ordinary JS, so a string literal inside an interpolation counts like any
  # other), and recognizing JSX: a tag's attribute list is scanned like any
  # other JS (quotes and {expr} both work as usual), but its children are
  # JSX text, not JS, so quotes and apostrophes there are prose, never a
  # string. allowed_ranges, when given, restricts which string start
  # positions are eligible to produce a finding at all (used by MDX to keep
  # prose out of scope); nil scans every string (plain JS/TS/JSX/TSX files).
  def script_findings(path, text, line_offset: 0, allowed_ranges: nil, jsx: true, attr_ctx: nil)
    findings = []
    scan_js(path, text, 0, text.length, line_offset, allowed_ranges, findings, jsx: jsx, attr_ctx: attr_ctx)
    findings
  end

  # The core JS scanner. When stop_at_brace is true, it is scanning a "{...}"
  # (or a template "${...}") whose opening brace the caller already
  # consumed: it tracks brace depth from 1 and returns the index just past
  # the matching close brace instead of running to the end of text.
  def scan_js(path, text, i, len, line_offset, allowed_ranges, findings, stop_at_brace: false, jsx: true, attr_ctx: nil)
    depth = stop_at_brace ? 1 : 0
    while i < len
      c = text[i]
      case c
      when '{'
        depth += 1 if stop_at_brace
        i += 1
      when '}'
        if stop_at_brace
          depth -= 1
          i += 1
          return i if depth.zero?
        else
          i += 1
        end
      when '/'
        i = if text[i + 1] == '/' || text[i + 1] == '*'
              skip_script_comment(text, i, len)
        elsif expression_context?(text, i)
              skip_script_regex(text, i, len)
        else
              i + 1
        end
      when '"', "'"
        start = i
        content, i = scan_script_string(text, i, len)
        findings.concat(classified_string(path, text, start, content, line_offset, allowed_ranges, attr_ctx:, end_idx: i))
      when '`'
        start = i
        content, i = scan_script_template(path, text, i, len, line_offset, allowed_ranges, findings, jsx: jsx)
        findings.concat(classified_string(path, text, start, content, line_offset, allowed_ranges, attr_ctx:, end_idx: i))
      when '<'
        i = jsx && jsx_tag_start?(text, i) ? scan_jsx_or_skip(path, text, i, len, line_offset, allowed_ranges, findings) : i + 1
      else
        i += 1
      end
    end
    i
  end

  # True when the character context right before index i is one where a new
  # expression (a regex literal, or a JSX element) is expected rather than a
  # division operator or a comparison continuing a value: after an operator,
  # punctuation that opens a new expression, or an expression keyword, or at
  # the very start of the text.
  def expression_context?(text, i)
    j = i - 1
    j -= 1 while j >= 0 && text[j] =~ /[ \t\n]/
    return true if j.negative?

    ch = text[j]

    # A postfix "++"/"--" (an identifier, ")" or "]" right before it) ends a
    # value, so the next "/" is division; the same pair with nothing but an
    # operator before it is prefix, which still expects an expression.
    if (ch == '+' || ch == '-') && j.positive? && text[j - 1] == ch
      k = j - 2
      k -= 1 while k >= 0 && text[k] =~ /[ \t\n]/
      postfix = k >= 0 && (text[k] =~ /[\w$]/ || text[k] == ')' || text[k] == ']')
      return !postfix
    end

    return true if EXPR_CONTEXT_CHARS.match?(ch)

    # A ")" ends a value (a call or a parenthesized expression), except when
    # it closes the head of an if/while/for/with/switch/catch, which is
    # followed by an expression (its body), never a division.
    if ch == ')'
      open = matching_open_paren(text, j)
      return open ? keyword_before_paren?(text, open) : false
    end

    return false if ch == ']'
    return false if ch == '"' || ch == "'" || ch == '`'

    if ch =~ /[\w$]/
      k = j
      k -= 1 while k >= 0 && text[k] =~ /[\w$]/
      word = text[(k + 1)..j]
      # A keyword right after "." or "?." is a property name ("a.return"),
      # not the keyword itself, so it is a value: the next "/" is division.
      before = k
      before -= 1 while before >= 0 && text[before] =~ /[ \t\n]/
      return false if before >= 0 && text[before] == '.'

      return EXPR_CONTEXT_KEYWORDS.include?(word)
    end

    true
  end

  KEYWORD_PAREN_HEADS = %w[if while for with switch catch].freeze

  # Finds the "(" matching a ")" at close_idx by counting nested parens
  # backward. Good enough for this heuristic lexer; it does not skip over
  # strings or comments, so a literal unbalanced paren inside one could
  # mislead it, same tradeoff as the rest of this scanner.
  def matching_open_paren(text, close_idx)
    depth = 0
    j = close_idx
    while j >= 0
      if text[j] == ')'
        depth += 1
      elsif text[j] == '('
        depth -= 1
        return j if depth.zero?
      end
      j -= 1
    end
    nil
  end

  def keyword_before_paren?(text, open_idx)
    k = open_idx - 1
    k -= 1 while k >= 0 && text[k] =~ /[ \t\n]/
    return false if k.negative? || text[k] !~ /[\w$]/

    e = k
    k -= 1 while k >= 0 && text[k] =~ /[\w$]/
    word = text[(k + 1)..e]
    KEYWORD_PAREN_HEADS.include?(word)
  end

  # A TSX generic arrow head ("<T,>(", "<T extends U>(") is a type
  # parameter list, never an element.
  TS_GENERIC_HEAD = /\G<\s*[A-Za-z_$][\w$]*\s*(?:,|extends\b)/.freeze

  def jsx_tag_start?(text, i)
    nxt = text[i + 1]
    return false if nxt.nil? || !nxt.match?(/[A-Za-z>]/)
    return false if text.match?(TS_GENERIC_HEAD, i)

    expression_context?(text, i)
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

  # A "/" starts a regex literal, rather than a division operator, in
  # expression context (see expression_context?). Character classes "[...]"
  # may contain an unescaped "/" that does not end the regex.
  def skip_script_regex(text, i, len)
    j = i + 1
    in_class = false
    while j < len
      c = text[j]
      if c == '\\' && j + 1 < len
        j += 2
      elsif c == '['
        in_class = true
        j += 1
      elsif c == ']'
        in_class = false
        j += 1
      elsif c == '/' && !in_class
        j += 1
        break
      elsif c == "\n"
        return j # unterminated regex; bail without consuming the newline
      else
        j += 1
      end
    end
    j += 1 while j < len && text[j] =~ /[a-zA-Z]/
    j
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

  # A "${...}" interpolation is ordinary JS, not template text: a string
  # literal inside it is scanned (and reported) exactly like any other JS
  # string, via the shared scan_js, rather than skipped wholesale.
  def scan_script_template(path, text, i, len, line_offset, allowed_ranges, findings, jsx: true)
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
        i = scan_js(path, text, i + 2, len, line_offset, allowed_ranges, findings, stop_at_brace: true, jsx: jsx)
      else
        content << c
        i += 1
      end
    end
    [ content, i ]
  end

  # --- JSX ------------------------------------------------------------------

  # i points to a "<" already judged to start a JSX element. Scans its
  # opening tag (attributes behave like any other JS: quotes and {expr}
  # values are both scanned normally), then, unless self-closing, its
  # children as JSX text until the matching closing tag. Returns the index
  # just past the whole element.
  # A "<" judged to start JSX that never closes (a TS assertion or generic
  # the heuristics missed, or a stray comparison) is not JSX after all: its
  # findings are dropped and scanning resumes as JS just past the "<", so no
  # file suffix is ever swallowed as JSX text.
  def scan_jsx_or_skip(path, text, i, len, line_offset, allowed_ranges, findings)
    mark = findings.length
    j = scan_jsx(path, text, i, len, line_offset, allowed_ranges, findings)
    return j if j

    findings.slice!(mark..)
    i + 1
  end

  # Returns the index just past the element, or nil when it never closes.
  def scan_jsx(path, text, i, len, line_offset, allowed_ranges, findings)
    self_closing, j = scan_jsx_open_tag(path, text, i, len, line_offset, allowed_ranges, findings)
    return nil if j.nil?
    return j if self_closing

    scan_jsx_children(path, text, j, len, line_offset, allowed_ranges, findings)
  end

  def scan_jsx_open_tag(path, text, i, len, line_offset, allowed_ranges, findings)
    j = i + 1
    depth = 0
    while j < len
      c = text[j]
      case c
      when '"', "'"
        start = j
        content, j = scan_script_string(text, j, len)
        findings.concat(classified_string(path, text, start, content, line_offset, allowed_ranges))
      when '`'
        start = j
        content, j = scan_script_template(path, text, j, len, line_offset, allowed_ranges, findings)
        findings.concat(classified_string(path, text, start, content, line_offset, allowed_ranges))
      when '{'
        name = depth.zero? && jsx_attr_name_before(text, j)
        if name
          ctx = AttrCtx.new(name: name, binding: :jsx_brace, start: j + 1)
          j = scan_js(path, text, j + 1, len, line_offset, allowed_ranges, findings, stop_at_brace: true, attr_ctx: ctx)
        else
          depth += 1
          j += 1
        end
      when '}'
        depth -= 1 if depth.positive?
        j += 1
      when '/'
        return [ true, j + 2 ] if depth.zero? && text[j + 1] == '>'

        j += 1
      when '>'
        return [ false, j + 1 ] if depth.zero?

        j += 1
      else
        j += 1
      end
    end
    [ true, nil ]
  end

  # The attribute name right before a JSX "name={" expression brace, or nil
  # when the brace is not an attribute value (a spread "{...props}").
  def jsx_attr_name_before(text, brace_idx)
    eq = skip_ws_back(text, brace_idx - 1)
    return nil unless eq >= 0 && text[eq] == '='

    k = skip_ws_back(text, eq - 1)
    e = k
    k -= 1 while k >= 0 && text[k].match?(/[\w:-]/)
    k == e ? nil : text[(k + 1)..e]
  end

  # JSX children: text is prose (never a string start) until "<" (a nested
  # element, or this element's own closing tag) or "{" (an embedded JS
  # expression, scanned like any other JS).
  def scan_jsx_children(path, text, i, len, line_offset, allowed_ranges, findings)
    j = i
    while j < len
      case text[j]
      when '<'
        if text[j + 1] == '/'
          close = text.index('>', j)
          return close && close + 1
        elsif text[j + 1]&.match?(/[A-Za-z]/)
          j = scan_jsx(path, text, j, len, line_offset, allowed_ranges, findings)
          return nil if j.nil?
        else
          j += 1
        end
      when '{'
        j = scan_js(path, text, j + 1, len, line_offset, allowed_ranges, findings, stop_at_brace: true)
      else
        j += 1
      end
    end
    nil
  end

  # --- shared string classification -----------------------------------------

  def classified_string(path, text, start, content, line_offset, allowed_ranges, attr_ctx: nil, end_idx: nil)
    return [] if allowed_ranges && allowed_ranges.none? { |r| r.cover?(start) }

    line = text[0...start].count("\n") + 1 + line_offset
    attr_key = attr_value_key(text, start, end_idx, attr_ctx)
    key = attr_key || lookback_key(text, start)
    position_a = !attr_key.nil? || (key.is_a?(String) && (%w[style fill stroke].include?(key) || key.match?(COLOR_KEY)))
    entries = classify_string(path, line, content, position_a, unknown_context: key == :unknown)
    record_exempt(content, key, entries)
    entries
  end

  # Under classify_all, a short hex string that produced neither a literal
  # finding nor an unresolved entry is recorded with the rule that exempted
  # it, so the accounting test can see it was classified, not dropped.
  def record_exempt(content, key, entries)
    sink = Thread.current[:color_scan_exempt]
    return unless sink && HEX_FULL.match?(content.strip)
    return if entries.any? { |e| e.is_a?(ColorCheck::Unresolved) || e.kind == 'literal' }

    sink << [ content.strip, [ :exempt, key.is_a?(String) ? :non_color_key : key ] ]
  end

  # A short (3/4-digit) hex string is only a color when its key says so: in
  # a positively exempt context (a non-color key, or a named EXEMPT_RULES
  # context) it is not a finding, and in a context the lookback could not
  # determine it is reported as unresolved rather than silently exempt.
  def classify_string(path, line, content, position_a, unknown_context: false)
    findings = []
    stripped = content.strip
    if HEX_FULL.match?(stripped)
      short = [ 3, 4 ].include?(stripped.length - 1)
      if !short || position_a
        findings << finding(path, line, 'literal', content)
      elsif unknown_context
        findings << unresolved(path, line, 'literal', content, UNKNOWN_CONTEXT_REASON)
      end
    elsif SCRIPT_COLOR_FN_FULL.match?(stripped)
      findings << finding(path, line, 'literal', content)
    elsif stripped.match?(/\A[A-Za-z]+\z/) && ColorValue::NAMED.key?(stripped.downcase)
      findings << finding(path, line, 'literal', content)
    end
    findings << finding(path, line, 'gradient', content) if ColorCheck::GRADIENT.match?(content)
    content.scan(ColorCheck::TAILWIND) { findings << finding(path, line, 'tailwind', content) }
    findings
  end

  # The enclosing attribute's name when the string at start...end_idx is in
  # position A of a color-bearing attribute: the whole expression value, or
  # a depth-0 branch of a top-level ternary, "??" or "||". nil otherwise, so
  # the caller falls back to lookback_key (object keys, exempt rules).
  def attr_value_key(text, start, end_idx, attr_ctx)
    return nil unless attr_ctx&.color_bearing? && end_idx
    return nil unless depth_zero?(text, attr_ctx.start, start)
    return nil unless branch_open?(text, attr_ctx.start, start) && branch_close?(text, end_idx)

    attr_ctx.name
  end

  # True when no bracket opened since expr_start is still open at idx.
  # Quoted strings are skipped so brackets inside them do not count.
  def depth_zero?(text, expr_start, idx)
    depth = 0
    j = expr_start
    while j < idx
      c = text[j]
      if c == '"' || c == "'" || c == '`'
        close = text.index(c, j + 1)
        j = close ? close + 1 : idx
        next
      end
      depth += 1 if '([{'.include?(c)
      depth -= 1 if ')]}'.include?(c)
      j += 1
    end
    depth.zero?
  end

  def branch_open?(text, expr_start, start)
    p = skip_ws_back(text, start - 1)
    return true if p < expr_start

    c = text[p]
    c == '?' || c == ':' || (c == '|' && p.positive? && text[p - 1] == '|')
  end

  def branch_close?(text, end_idx)
    k = end_idx
    k += 1 while k < text.length && text[k].match?(/\s/)
    return true if k >= text.length || text[k] == '}' || text[k] == ':'

    %w[?? ||].include?(text[k, 2])
  end

  UNKNOWN_CONTEXT_REASON = 'key context could not be determined'
  # Named, positive exempt contexts for a string with no key: the
  # character(s) right before it (after whitespace) identify it as a call
  # argument, an array element, the right side of a keyless return, or a
  # concatenation operand. Anything else is :unknown, never exempt.
  EXEMPT_RULES = %i[call_arg array_elem assign concat].freeze

  # Key context of the string starting at start_idx. Returns a key String
  # when ":" (object or style-object key) or "=" (attribute or assignment)
  # precedes it; one of EXEMPT_RULES when a positive exempt rule matches;
  # :unknown otherwise. A bound attribute's own value is keyed by the
  # carried AttrCtx (attr_value_key), not by looking back.
  def lookback_key(text, start_idx)
    i = skip_ws_back(text, start_idx - 1)
    return :unknown if i.negative?
    return key_before(text, i) if text[i] == ':' || text[i] == '='

    exempt_rule(text, i)
  end

  def key_before(text, sep_idx)
    i = skip_ws_back(text, sep_idx - 1)
    return :unknown if i.negative?

    key = text[i] == '"' || text[i] == "'" ? quoted_key_before(text, i) : identifier_before(text, i)
    return :unknown if key.nil? || ternary_branch?(text, sep_idx, i, key)

    key
  end

  # "ok ? a : '#123'" is a ternary's else branch, not an object key: the
  # token before ":" is itself preceded by "?", so the key is unknown.
  def ternary_branch?(text, sep_idx, key_end, key)
    return false unless text[sep_idx] == ':'

    key_start = key_end - key.length - (text[key_end] == '"' || text[key_end] == "'" ? 2 : 0)
    before = skip_ws_back(text, key_start)
    before >= 0 && text[before] == '?'
  end

  def exempt_rule(text, i)
    case text[i]
    when '(' then :call_arg
    when '[' then :array_elem
    when '+' then :concat
    when ',' then enclosing_rule(text, i)
    else
      identifier_before(text, i) == 'return' ? :assign : :unknown
    end
  end

  # For a "," separator, the innermost unclosed bracket decides: "(" is a
  # call argument list, "[" an array literal. A "{" (object literal) or no
  # bracket at all is :unknown.
  def enclosing_rule(text, comma_idx)
    depth = 0
    (comma_idx - 1).downto(0) do |j|
      c = text[j]
      if ')]}'.include?(c)
        depth += 1
      elsif '([{'.include?(c)
        return { '(' => :call_arg, '[' => :array_elem }.fetch(c, :unknown) if depth.zero?

        depth -= 1
      end
    end
    :unknown
  end

  def skip_ws_back(text, i)
    i -= 1 while i >= 0 && text[i].match?(/\s/)
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

  def unresolved(file, line, kind, text, reason)
    ColorCheck::Unresolved.new(file: file, line: line, kind: kind, text: text.to_s.strip, reason: reason)
  end
end
