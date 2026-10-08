#!/usr/bin/env ruby
# frozen_string_literal: true

require 'strscan'

# Hand-written CSS tokenizer behind the cf:color token-file reader. Finds
# declarations, block-less at-rules and block openings with enough context
# (selector list, at-rule stack, enclosing block) for ColorTokens to classify
# a token file strictly. It never models the cascade itself and never raises
# on malformed input; problems are recorded as diagnostics in Sheet#errors
# and scanning continues.
module ColorCss
  # name: "--bg" or "color". value: raw text with comments replaced by
  # spaces (newlines kept) and !important removed. line: line of the name.
  # selectors: the innermost enclosing rule's selector list, each entry
  # whitespace-collapsed (empty for top-level declarations). block_id: id of
  # the innermost enclosing block, rule or at-rule (nil at top level),
  # matching a BlockOpen in Sheet#blocks.
  Decl = Data.define(:name, :value, :important, :line, :block_id)
  AtRule = Data.define(:name, :prelude, :line, :block_id) # block-less: @import, @tailwind
  # One "{" opening, rule or at-rule. prelude: the source text before the
  # brace with comments removed outright (not replaced by spaces), so
  # ":root/**/.dark" stays one compound selector while ":root .dark" keeps
  # its whitespace combinator. parent: the enclosing block's id or nil.
  # glued: a removed comment sat where CSS sees a token boundary but the
  # comment-free prelude would read one token (@me/**/dia as @media,
  # :ro/**/ot as :root), so the prelude is not what CSS parses and callers
  # must reject it rather than classify it.
  BlockOpen = Data.define(:id, :parent, :prelude, :line, :glued)
  Sheet = Data.define(:decls, :at_rule_stmts, :errors, :blocks) # errors: [String] diagnostics, never raised

  # One escape per CSS Syntax 3 4.3.7: a backslash then 1-6 hex digits and
  # one optional whitespace, or any code point but a newline, or end of
  # input. A backslash before a newline matches nothing: it is no escape.
  ESCAPE = /\\(?:\h{1,6}(?:\r\n|[ \t\n\r\f])?|[^\n\r\f]|\z)/.freeze
  # A custom-property name as written: "--" then ident code points (ASCII
  # word characters, "-", anything >= U+0080) or escapes, so --\61 and
  # --caf\e9 are declarations. Its value is decoded by custom_property_name.
  CUSTOM_NAME_SRC = /--(?:[\w\u0080-\u{10FFFF}-]|#{ESCAPE})+/.freeze
  DECL_NAME = /\A(\s*)(#{CUSTOM_NAME_SRC}|\$[\w-]+|@[\w-]+|-?[A-Za-z][\w-]*)(\s*):(.*)\z/m.freeze
  AT_RULE_STMT = /\A(\s*)(@[\w-]+)(\s*)(.*)\z/m.freeze
  IMPORTANT = /\A(.*?)\s*!\s*important\s*\z/mi.freeze
  ESCAPE_AT = /\G#{ESCAPE}/.freeze
  # A code point that continues an ident, number or at-keyword token; a
  # backslash starts an escape, which does too.
  TOKEN_CP = /[-_a-zA-Z0-9\\\u0080-\u{10FFFF}]/.freeze

  module_function

  # Tokenizes text into a Sheet. One leading U+FEFF byte-order mark is
  # dropped first, as CSS Syntax 3 decoding does, so every reader sees the
  # same first token whether or not the file was saved with a BOM.
  def parse(text)
    Parser.new(text.to_s.delete_prefix("\uFEFF")).sheet
  end

  # Whether deleting a comment between left and right would merge the text
  # on both sides into one token CSS keeps apart (CSS Syntax 3: a comment is
  # a token boundary). True between two ident code points (col/**/or), after
  # @ or # (@/**/media), inside a number (1/**/.5, 1/**/%, +/**/1), and
  # between / and * (which would open a new comment). False elsewhere, so
  # :root/**/.dark stays one compound.
  def comment_glues?(left, right)
    l = left.to_s[-1]
    r = right.to_s[0]
    return false if l.nil? || r.nil?
    return true if l == "/" && r == "*"
    return true if (l.match?(TOKEN_CP) || l == "@" || l == "#") && r.match?(TOKEN_CP)
    return true if l.match?(/[0-9]/) && (r == "%" || (r == "." && right.to_s[1].to_s.match?(/[0-9]/)))

    l.match?(/[+.]/) && r.match?(/[0-9]/)
  end

  # The escape whose backslash is at text[i], decoded per CSS Syntax 3
  # 4.3.7: [code point, index just past the escape]. Hex digits name a code
  # point (zero, a surrogate or one past U+10FFFF becomes U+FFFD) and eat one
  # following whitespace; any other code point stands for itself; a
  # backslash at end of input is U+FFFD. nil when text[i] is not a backslash
  # or the backslash precedes a newline, which is no escape at all.
  def decode_escape(text, i)
    m = text[i] == "\\" && text.match(ESCAPE_AT, i)
    return nil unless m

    hex = m[0][/\A\\(\h+)/, 1]
    return [ m[0][1] || "\uFFFD", m.end(0) ] unless hex

    cp = hex.to_i(16)
    cp = 0xFFFD if cp.zero? || cp > 0x10FFFF || (0xD800..0xDFFF).cover?(cp)
    [ cp.chr(Encoding::UTF_8), m.end(0) ]
  end

  # Index past the backslash at i and the code point it escapes, so no
  # scanner ever reads an escaped ; { } ( ) , or quote as a delimiter. A
  # backslash before a newline is a lone delimiter: just past it.
  def skip_escape(text, i)
    decode_escape(text, i)&.last || i + 1
  end

  # Splits text at top-level occurrences of sep, respecting parentheses,
  # quoted strings and escapes, so ":is(a, b)" stays one entry and a comma
  # inside a string or written as \, is never a split point. Entries are not
  # whitespace-collapsed here; callers do that themselves.
  def split_top_level(text, sep = ",")
    out = []
    start = 0
    depth = 0
    i = 0
    while i < text.length
      case text[i]
      when "\\" then i = skip_escape(text, i)
        next
      when '"', "'" then i = skip_string(text, i)
        next
      when "(" then depth += 1
      when ")" then depth -= 1 if depth.positive?
      when sep
        if depth.zero?
          out << text[start...i]
          start = i + 1
        end
      end
      i += 1
    end
    out << text[start..]
    out
  end

  # One function token in a value: name is its value with escapes decoded,
  # then ASCII downcased (non-ASCII kept as written), so \var(, v\61 r( and
  # VAR( are all "var". start is the index of its first character, open the
  # index of its "(".
  FunctionToken = Data.define(:name, :start, :open)

  # Every real function token in text, per CSS Syntax 3: a maximal run of
  # ident code points ([-_a-zA-Z0-9], any code point >= U+0080, or a
  # backslash escape) that is a valid identifier and is followed directly by
  # "(". Quoted strings and comments are skipped, as are the contents of an
  # unquoted url(...) token, a #hash or @at-keyword name, and a run that
  # starts like a number (2var). Escapes are decoded before the name is
  # compared, as CSS does, so \var( is var( and \75 rl( is url(.
  def function_tokens(text)
    text = text.to_s
    tokens = []
    i = 0
    while i < text.length
      ch = text[i]
      if ch == '"' || ch == "'"
        i = skip_string(text, i)
      elsif text[i, 2] == "/*"
        close = text.index("*/", i + 2)
        i = close ? close + 2 : text.length
      elsif ident_char_at?(text, i)
        start = i
        i = skip_ident_run(text, i)
        prev = start.positive? ? text[start - 1] : nil
        next unless text[i] == "(" && prev != "#" && prev != "@" && ident_start?(text[start...i])

        tok = FunctionToken.new(name: decode_ident(text[start...i]).downcase(:ascii), start:, open: i)
        tokens << tok
        i = tok.name == "url" ? skip_unquoted_url(text, i) : i + 1
      else
        i += 1
      end
    end
    tokens
  end

  # text with every function name ASCII-lowercased and nothing else touched:
  # custom-property names, url() contents and strings stay exact. A name
  # spelled with escapes becomes its decoded value when that value needs no
  # escaping (\56 AR( becomes var(), else it is only ASCII-lowercased.
  def downcase_function_names(text)
    out = text.to_s.dup
    function_tokens(text).reverse_each do |t|
      plain = t.name.match?(/\A[-_a-z0-9\u0080-\u{10FFFF}]+\z/) && ident_start?(t.name)
      out[t.start...t.open] = plain ? t.name : out[t.start...t.open].downcase(:ascii)
    end
    out
  end

  # text with every escape outside quoted strings and comments decoded, as
  # [decoded, nil], so anchored matching (var(, rgb(, red, #hex) sees the
  # name CSS sees: \76 ar( is var( and \72 ed is red. An escape is decoded
  # only inside an identifier run that stays a plain identifier once
  # decoded; an escape that would become a delimiter (\( \; \, a quote or
  # whitespace), part of a #hash or @name, or part of a number (1\65 3 is a
  # dimension, not 1e3) has no plain spelling, so [nil, reason] is returned
  # instead of a guess.
  def decode_value_escapes(text)
    text = text.to_s
    return [ text, nil ] unless text.include?("\\")

    out = +""
    i = 0
    while i < text.length
      ch = text[i]
      if ch == '"' || ch == "'"
        j = skip_string(text, i)
      elsif text[i, 2] == "/*"
        close = text.index("*/", i + 2)
        j = close ? close + 2 : text.length
      elsif ident_char_at?(text, i)
        j = skip_ident_run(text, i)
        run = text[i...j]
        if run.include?("\\")
          decoded = plain_ident(run, i.positive? ? text[i - 1] : nil)
          return [ nil, "unrecognized color value: #{text.strip[0, 40]} (escape has no plain spelling)" ] unless decoded

          out << decoded
          i = j
          next
        end
      else
        j = i + 1
      end
      out << text[i...j]
      i = j
    end
    [ out, nil ]
  end

  # The decoded value of an escaped identifier run, or nil when the run is
  # not an identifier (a number or dimension, a #hash or @name) or decodes to
  # anything but identifier code points.
  def plain_ident(run, prev)
    return nil if prev == "#" || prev == "@" || !ident_start?(run)

    decoded = decode_ident(run)
    decoded if decoded.match?(/\A[-_a-zA-Z0-9\u0080-\u{10FFFF}]+\z/) && ident_start?(decoded)
  end

  # A custom-property name's value, the one thing every name comparison
  # uses: escapes decoded per CSS Syntax 3, so --\61 and --a name one
  # property whether declared or referenced. Case is kept: names are
  # case-sensitive.
  def custom_property_name(raw)
    decode_ident(raw.to_s)
  end

  # The decoded custom-property name opening text (after optional leading
  # whitespace), as the first argument of a var() would, or nil when text
  # does not start with one.
  def leading_custom_property_name(text)
    text = text.to_s
    start = text.index(/\S/)
    return nil unless start && text[start, 2] == "--"

    custom_property_name(text[start...skip_ident_run(text, start)])
  end

  # An identifier run's value: each escape replaced by its code point.
  def decode_ident(run)
    out = +""
    i = 0
    while i < run.length
      ch, i = decode_escape(run, i) || [ run[i], i + 1 ]
      out << ch
    end
    out
  end

  # Index just past the string opening at i, or of the raw newline that
  # leaves it unterminated, or end of text. Inside a string a backslash
  # before a newline continues the line; any other escape is consumed whole.
  def skip_string(text, i)
    quote = text[i]
    j = i + 1
    while j < text.length
      case text[j]
      when "\\"
        j = text[j + 1, 2] == "\r\n" ? j + 3 : (decode_escape(text, j)&.last || j + 2)
        next
      when quote then return j + 1
      when "\n", "\r", "\f" then return j
      end
      j += 1
    end
    text.length
  end

  def ident_char_at?(text, i)
    ch = text[i]
    ch.match?(/[-_a-zA-Z0-9]/) || ch.ord >= 0x80 || !decode_escape(text, i).nil?
  end

  def skip_ident_run(text, i)
    i = text[i] == "\\" ? skip_escape(text, i) : i + 1 while i < text.length && ident_char_at?(text, i)
    i
  end

  # A run is an identifier when it starts with "--", "-" plus a name-start
  # code point or escape, or a name-start code point or escape. A leading
  # digit (or "-" then digit) makes it a number or dimension instead.
  def ident_start?(run)
    rest = run.start_with?("--") ? "" : run.delete_prefix("-")
    return run.start_with?("--") if rest.empty?

    rest.match?(/\A(?:[_a-zA-Z]|\\|[^\x00-\x7f])/)
  end

  # Past the ")" closing an unquoted url( token at open, or just past "(" when
  # the url is quoted (then its contents are an ordinary string argument).
  def skip_unquoted_url(text, open)
    j = open + 1
    j += 1 while j < text.length && text[j].match?(/\s/)
    return open + 1 if text[j] == '"' || text[j] == "'"

    while j < text.length
      return j + 1 if text[j] == ")"

      j = text[j] == "\\" ? skip_escape(text, j) : j + 1
    end
    text.length
  end

  # Internal stateful scan. Not part of the public API; callers only ever
  # reach this through ColorCss.parse.
  class Parser
    Frame = Struct.new(:kind, :selectors, :id, :text, keyword_init: true)

    def initialize(text)
      @decls = []
      @at_rule_stmts = []
      @blocks = []
      @errors = []
      @next_id = 1
      @scanner = StringScanner.new(text)
      @frames = []
      @paren_depth = 0
      @line = 1
      @segment = +''
      @raw = +''
      @comment_pending = false
      @glued = false
      @segment_start_line = 1
      scan_one until @scanner.eos?
      flush_at_eof
    end

    def sheet
      ColorCss::Sheet.new(decls: @decls, at_rule_stmts: @at_rule_stmts, errors: @errors, blocks: @blocks)
    end

    private

    def scan_one
      if (text = @scanner.scan(/[^\/'"();{}\\]+/))
        consume_text(text)
        return
      end
      return if @scanner.eos?

      ch = @scanner.peek(1)
      case ch
      when "\\"
        # An escape is ordinary value text, so an escaped ; { } ( ) or quote
        # never ends a declaration or moves the block or paren depth. A
        # backslash before a newline escapes nothing and is taken alone.
        consume_text(@scanner.scan(ESCAPE) || @scanner.getch)
      when '/'
        scan_slash
      when "'", '"'
        scan_string(ch)
      when '('
        scan_open_paren
      when ')'
        scan_close_paren
      when ';', '{', '}'
        @scanner.getch
        if @paren_depth.positive?
          append(ch)
        else
          dispatch_terminator(ch)
        end
      else
        # Unreachable given the char classes above; advance defensively so a
        # surprise character can never stall the scan.
        @scanner.getch
      end
    end

    def consume_text(text)
      append(text)
      @line += text.count("\n")
    end

    # A comment: blanked in the segment, absent from the raw text. The only
    # place comments are stripped. Blanking to spaces keeps the token
    # boundary (so col/**/or: never reads as a color: declaration); removal
    # does not, so the next append checks whether the raw text just glued
    # two tokens together.
    def consume_blanked(text)
      @segment << text.gsub(/[^\n]/, ' ')
      @line += text.count("\n")
      @comment_pending = true
    end

    def append(text)
      if @comment_pending && !text.empty?
        @glued ||= ColorCss.comment_glues?(@raw, text)
        @comment_pending = false
      end
      @segment << text
      @raw << text
    end

    def scan_slash
      if @scanner.match?(%r{/\*})
        scan_block_comment
      else
        consume_text(@scanner.getch)
      end
    end

    def scan_block_comment
      start_line = @line
      consume_blanked(@scanner.scan(%r{/\*}))
      body = @scanner.scan_until(/\*\//)
      if body
        consume_blanked(body)
      else
        rest = @scanner.rest
        @scanner.terminate
        consume_blanked(rest)
        @errors << "unterminated comment (line #{start_line})"
      end
    end

    def scan_string(quote)
      start_line = @line
      append(@scanner.getch) # opening quote
      loop do
        found = @scanner.scan_until(/\\\r\n|\\.|\\\z|\n|#{Regexp.escape(quote)}/m)
        if found.nil?
          rest = @scanner.rest
          @scanner.terminate
          append(rest)
          @errors << "unterminated string (line #{start_line})"
          return
        end

        append(found)
        matched = @scanner.matched
        @line += found.count("\n")
        case matched
        when quote
          return
        when "\n"
          @errors << "unterminated string (line #{start_line})"
          return
        else
          next # a backslash escape (possibly an escaped newline); string continues
        end
      end
    end

    def scan_open_paren
      append(@scanner.getch)
      @paren_depth += 1
    end

    def scan_close_paren
      @paren_depth -= 1 if @paren_depth.positive?
      append(@scanner.getch)
    end

    def dispatch_terminator(ch)
      case ch
      when ';'
        flush_segment_as_decl_or_at_rule
        start_new_segment
      when '{'
        open_block
        start_new_segment
      when '}'
        flush_segment_as_decl_or_at_rule
        close_block
        start_new_segment
      end
    end

    def start_new_segment
      @segment = +''
      @raw = +''
      @comment_pending = false
      @glued = false
      @segment_start_line = @line
    end

    def flush_segment_as_decl_or_at_rule
      body = @segment
      return if body.strip.empty?

      return if emit_declaration(body) || emit_at_rule_stmt(body)

      line = @segment_start_line + body[/\A\s*/].count("\n")
      @errors << "unparsed segment #{collapse_ws(body).inspect} (line #{line})"
    end

    def open_block
      prelude = @segment
      id = @next_id
      @next_id += 1
      line = @segment_start_line + prelude[/\A\s*/].count("\n")
      @blocks << BlockOpen.new(id:, parent: @frames.last&.id, prelude: @raw.strip, line:, glued: @glued)
      stripped = @raw.strip
      @frames << if stripped.start_with?('@')
                   Frame.new(kind: :at_rule, selectors: nil, id:, text: collapse_ws(stripped))
      else
                   selectors = ColorCss.split_top_level(prelude).map { |s| collapse_ws(s) }.reject(&:empty?)
                   Frame.new(kind: :rule, selectors:, id:, text: nil)
      end
    end

    def close_block
      if @frames.empty?
        @errors << "unmatched } (line #{@line})"
      else
        @frames.pop
      end
    end

    def emit_declaration(body)
      m = DECL_NAME.match(body)
      return false unless m

      leading_ws, name, _mid_ws, rest = m[1], m[2], m[3], m[4]
      # "@name: value;" is the start of a block-less at-rule (@apply,
      # @import and the like), not a declaration.
      return false if name.start_with?('@')

      name_line = @segment_start_line + leading_ws.count("\n")
      name = ColorCss.custom_property_name(name) if name.start_with?("--")

      raw_value = rest.strip
      important = false
      if (im = IMPORTANT.match(raw_value))
        raw_value = im[1].strip
        important = true
      end

      _selectors, block_id = current_context
      @decls << Decl.new(name:, value: raw_value, important:, line: name_line, block_id:)
      true
    end

    def emit_at_rule_stmt(body)
      m = AT_RULE_STMT.match(body)
      return false unless m

      leading_ws, name, _mid_ws, rest = m[1], m[2], m[3], m[4]
      at_line = @segment_start_line + leading_ws.count("\n")
      _selectors, block_id = current_context
      @at_rule_stmts << AtRule.new(name:, prelude: rest.strip, line: at_line, block_id:)
      true
    end

    def current_context
      innermost = @frames.reverse.find { |f| f.kind == :rule }
      [ innermost ? innermost.selectors : [], @frames.last&.id ]
    end

    def flush_at_eof
      flush_segment_as_decl_or_at_rule
      open = @frames.size
      @errors << "unexpected end of input with #{open} open block(s)" if open.positive?
    end

    def collapse_ws(str)
      str.strip.gsub(/\s+/, ' ')
    end
  end
end
