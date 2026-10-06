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
  # A hex literal glued to a preceding word is still rejected for "&" (HTML
  # entities such as &#8599;, never real CSS) but not for a preceding word
  # character: in a tokenized CSS declaration value "solid#123456" is the
  # ident "solid" followed by the hash token "#123456", two separate tokens,
  # so HEX_CSS (used wherever the scanned text is itself a CSS value: CSS/
  # Sass/Less declarations, and a style= attribute split into declarations)
  # only guards against "&". HEX keeps the stricter guard (also "-" and any
  # word character) for contexts that are not tokenized CSS: a raw fill=/
  # stroke= attribute value and prose-adjacent text, where a hash glued to a
  # word is far more likely to be a url() fragment or similar than a real
  # hex color.
  HEX = /(?<![&\w-])#(?:\h{8}|\h{6}|\h{4}|\h{3})\b/.freeze
  HEX_CSS = /(?<!&)#(?:\h{8}|\h{6}|\h{4}|\h{3})\b/.freeze
  HEX_FULL = /\A#(?:\h{8}|\h{6}|\h{4}|\h{3})\z/.freeze
  NAMED_WORD = /(?<![\w$@#.-])[A-Za-z]+(?![\w(-])/.freeze
  QUOTED_OR_URL = /"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|url\([^)]*\)/i.freeze
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
  BOUND_ATTR_PREFIX = /\A(?::|v-bind:)/i.freeze
  TAG_NAME = /[a-zA-Z][\w:-]*/.freeze
  ATTR_NAME_TOKEN = /[:@]?[\w.:-]+/.freeze
  # script and style hold raw text (never nested tags); textarea and title
  # hold RCDATA (text only, scanned as nothing: decision 2 is attributes and
  # values, never a text node). Content runs to the matching case-insensitive
  # end tag, or end of file when there is none.
  RAW_TEXT_ELEMENTS = %w[script style].freeze
  RCDATA_ELEMENTS = %w[textarea title].freeze
  MDX_ATTR = /\b(?:style|fill|stroke|className|class)\s*=\s*(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')/mi.freeze
  IMPORT_EXPORT_LINE = /\A[ \t]*(?:import|export)\b/.freeze
  EXPR_CONTEXT_CHARS = /[(\[{,;:=!&|?+\-*%^~<>]/.freeze
  EXPR_CONTEXT_KEYWORDS = %w[return typeof instanceof in of new delete void throw else do yield case].freeze

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

      findings.concat(value_findings(path, decl.value, decl.value_line, decl.name))
    end
    sheet.at_rule_stmts.each do |stmt|
      stmt.prelude.scan(ColorCheck::TAILWIND) do
        findings << finding(path, stmt.line, 'tailwind', stmt.prelude)
      end
    end
    findings
  end

  def color_bearing_property?(name)
    return true if name.start_with?('--', '$', '@')

    name.match?(COLOR_BEARING_PROPERTY)
  end

  # Scans one declaration value line by line (so a multiline value keeps
  # correct line numbers): url() spans and quoted strings are blanked out
  # first, then the blanked text is scanned for hex, color functions,
  # gradients and, only when property_name is color-bearing, bare
  # named-color words.
  def value_findings(file, value, value_line, property_name)
    findings = []
    color_bearing = color_bearing_property?(property_name)
    value.each_line.with_index do |line, idx|
      lineno = value_line + idx
      blanked = blank_quoted_and_urls(line)
      blanked.scan(HEX_CSS) { findings << finding(file, lineno, 'literal', line) }
      blanked.scan(ColorCheck::COLOR_FN) { findings << finding(file, lineno, 'literal', line) }
      blanked.scan(ColorCheck::GRADIENT) { findings << finding(file, lineno, 'gradient', line) }
      next unless color_bearing

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

      findings.concat(value_findings(path, m[2], lineno, m[1]))
    end
    findings
  end

  # --- Markup: .html .vue .svelte .astro ---------------------------------

  # A single forward pass over the markup text: one tokenizer, not a stack of
  # regex pre-passes. It walks literal "<" characters and, in order, strips
  # an HTML comment ("<!--...-->") or a CDATA section ("<![CDATA[...]]>") as
  # text with no further interpretation; skips closing tags, doctypes and
  # processing instructions; and for every other start tag reads its
  # attribute list up to the tag's own closing ">" (honoring quoted values,
  # unquoted values and Svelte's "{expr}" form), then, for script/style (raw
  # text) and textarea/title (RCDATA), consumes the element's content up to
  # its matching case-insensitive end tag without lexing any "<" inside it
  # as a tag. Because this runs before anything is blanked or cut out, a
  # "<!--" or "<style>" that appears only inside a script string, or inside
  # a quoted attribute value, is just data and never swallows real markup.
  def markup_file_findings(path, text, token_file)
    findings = []
    i = 0
    len = text.length
    while i < len
      lt = text.index('<', i)
      break unless lt

      if text[lt, 4] == '<!--'
        close = text.index('-->', lt + 4)
        i = close ? close + 3 : len
        next
      end

      if text[lt, 9].casecmp?('<![cdata[')
        close = text.index(']]>', lt + 9)
        i = close ? close + 3 : len
        next
      end

      nxt = text[lt + 1]
      if nxt.nil? || nxt == '/' || nxt == '!' || nxt == '?'
        i = lt + 1
        next
      end

      name_match = TAG_NAME.match(text, lt + 1)
      unless name_match && name_match.begin(0) == lt + 1
        i = lt + 1
        next
      end

      tag_name = name_match[0].downcase
      lang_value = nil
      tag_end = scan_tag_attrs(text, name_match.end(0), len) do |n, v, vs, curly|
        base_name = n.sub(BOUND_ATTR_PREFIX, '')
        attr = base_name.downcase
        lang_value = v if attr == 'lang' && !v.nil?
        next if v.nil?
        next unless ATTR_NAMES.include?(attr)

        bound = curly || BOUND_ATTR_PREFIX.match?(n)
        line_offset = text[0...vs].count("\n")
        if bound
          # A Vue/Svelte bound attribute's value is a JS expression, not a
          # literal: scan it with the script lexer so a bare identifier
          # ("red") is never a finding but a real quoted color string
          # still is.
          findings.concat(script_findings(path, v, line_offset: line_offset))
        else
          findings.concat(markup_attr_value_findings(path, v, line_offset, attr))
        end
      end

      if RAW_TEXT_ELEMENTS.include?(tag_name) || RCDATA_ELEMENTS.include?(tag_name)
        content_start = tag_end
        end_match = /<\/#{tag_name}\s*>/i.match(text, content_start)
        content_end = end_match ? end_match.begin(0) : len
        if tag_name == 'script'
          line_offset = text[0...content_start].count("\n")
          findings.concat(script_findings(path, text[content_start...content_end], line_offset: line_offset))
        elsif tag_name == 'style'
          line_offset = text[0...content_start].count("\n")
          dialect = lang_value && %w[scss less].include?(lang_value.downcase) ? lang_value.downcase.to_sym : :css
          sheet = ColorCss.parse(text[content_start...content_end], dialect: dialect, line_offset: line_offset)
          findings.concat(css_sheet_findings(path, token_file, sheet))
        end
        # RCDATA (textarea, title): content is a text node, out of scope.
        i = end_match ? end_match.end(0) : len
      else
        i = tag_end
      end
    end
    findings
  end

  # Scans one tag's attribute list starting just after its name, up to the
  # tag's own closing ">" (respecting quotes and Svelte-style "{...}"
  # values), yielding [name, raw_value, value_start_index, curly] for each
  # attribute that has a value (curly is true for a Svelte-style "{...}"
  # value, which is always a JS expression). Returns the index just past the
  # ">".
  def scan_tag_attrs(text, idx, len)
    i = idx
    while i < len
      c = text[i]
      if c == '>'
        return i + 1
      elsif c =~ /\s/ || c == '/'
        i += 1
      else
        i = scan_one_tag_attr(text, i, len) { |n, v, vs, curly| yield(n, v, vs, curly) }
      end
    end
    i
  end

  def scan_one_tag_attr(text, i, len)
    name_match = ATTR_NAME_TOKEN.match(text, i)
    return i + 1 unless name_match && name_match.begin(0) == i

    name = name_match[0]
    j = name_match.end(0)
    j += 1 while j < len && text[j] =~ /[ \t\r\n]/
    unless j < len && text[j] == '='
      yield(name, nil, nil, false)
      return name_match.end(0)
    end

    j += 1
    j += 1 while j < len && text[j] =~ /[ \t\r\n]/
    scan_tag_attr_value(text, name, j, len) { |n, v, vs, curly| yield(n, v, vs, curly) }
  end

  def scan_tag_attr_value(text, name, j, len)
    if j < len && (text[j] == '"' || text[j] == "'")
      quote = text[j]
      vstart = j + 1
      close = text.index(quote, vstart) || len
      yield(name, text[vstart...close], vstart, false)
      close + 1
    elsif j < len && text[j] == '{'
      depth = 1
      k = j + 1
      while k < len && depth.positive?
        depth += 1 if text[k] == '{'
        depth -= 1 if text[k] == '}'
        k += 1
      end
      vstart = j + 1
      yield(name, text[vstart...(k - 1)], vstart, true)
      k
    else
      vstart = j
      k = j
      k += 1 while k < len && text[k] !~ %r{[\s>/]}
      yield(name, text[vstart...k], vstart, false)
      k
    end
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
    sheet.decls.each { |decl| findings.concat(value_findings(path, decl.value, decl.value_line, decl.name)) }
    findings
  end

  def attr_value_findings(path, line, value, named_whole_only:)
    findings = []
    blanked = blank_quoted_and_urls(value)
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
  def script_findings(path, text, line_offset: 0, allowed_ranges: nil)
    findings = []
    scan_js(path, text, 0, text.length, line_offset, allowed_ranges, findings)
    findings
  end

  # The core JS scanner. When stop_at_brace is true, it is scanning a "{...}"
  # (or a template "${...}") whose opening brace the caller already
  # consumed: it tracks brace depth from 1 and returns the index just past
  # the matching close brace instead of running to the end of text.
  def scan_js(path, text, i, len, line_offset, allowed_ranges, findings, stop_at_brace: false)
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
        findings.concat(classified_string(path, text, start, content, line_offset, allowed_ranges))
      when '`'
        start = i
        content, i = scan_script_template(path, text, i, len, line_offset, allowed_ranges, findings)
        findings.concat(classified_string(path, text, start, content, line_offset, allowed_ranges))
      when '<'
        i = if jsx_tag_start?(text, i)
              scan_jsx(path, text, i, len, line_offset, allowed_ranges, findings)
        else
              i + 1
        end
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

  def jsx_tag_start?(text, i)
    nxt = text[i + 1]
    return false if nxt.nil? || !nxt.match?(/[A-Za-z>]/)

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
  def scan_script_template(path, text, i, len, line_offset, allowed_ranges, findings)
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
        i = scan_js(path, text, i + 2, len, line_offset, allowed_ranges, findings, stop_at_brace: true)
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
  def scan_jsx(path, text, i, len, line_offset, allowed_ranges, findings)
    self_closing, j = scan_jsx_open_tag(path, text, i, len, line_offset, allowed_ranges, findings)
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
        depth += 1
        j += 1
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
    [ true, j ]
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
          return close ? close + 1 : len
        elsif text[j + 1]&.match?(/[A-Za-z]/)
          j = scan_jsx(path, text, j, len, line_offset, allowed_ranges, findings)
        else
          j += 1
        end
      when '{'
        j = scan_js(path, text, j + 1, len, line_offset, allowed_ranges, findings, stop_at_brace: true)
      else
        j += 1
      end
    end
    j
  end

  # --- shared string classification -----------------------------------------

  def classified_string(path, text, start, content, line_offset, allowed_ranges)
    return [] if allowed_ranges && allowed_ranges.none? { |r| r.cover?(start) }

    line = text[0...start].count("\n") + 1 + line_offset
    key = lookback_key(text, start)
    position_a = !key.nil? && (%w[style fill stroke].include?(key) || key.match?(COLOR_KEY))
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
