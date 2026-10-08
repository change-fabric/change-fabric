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
  BlockOpen = Data.define(:id, :parent, :prelude, :line)
  Sheet = Data.define(:decls, :at_rule_stmts, :errors, :blocks) # errors: [String] diagnostics, never raised

  DECL_NAME = /\A(\s*)(--[\w-]+|\$[\w-]+|@[\w-]+|-?[A-Za-z][\w-]*)(\s*):(.*)\z/m.freeze
  AT_RULE_STMT = /\A(\s*)(@[\w-]+)(\s*)(.*)\z/m.freeze
  IMPORTANT = /\A(.*?)\s*!\s*important\s*\z/mi.freeze

  module_function

  # Tokenizes text into a Sheet.
  def parse(text)
    Parser.new(text).sheet
  end

  # Splits text at top-level occurrences of sep, respecting parentheses and
  # quoted strings, so ":is(a, b)" stays one entry and a comma inside a
  # string is never a split point. Entries are not whitespace-collapsed here;
  # callers do that themselves.
  def split_top_level(text, sep = ',')
    out = []
    current = +''
    depth = 0
    in_string = nil
    escaped = false
    text.each_char do |ch|
      if in_string
        current << ch
        if escaped
          escaped = false
        elsif ch == '\\'
          escaped = true
        elsif ch == in_string
          in_string = nil
        end
        next
      end

      case ch
      when "'", '"'
        in_string = ch
        current << ch
      when '('
        depth += 1
        current << ch
      when ')'
        depth -= 1 if depth.positive?
        current << ch
      else
        if ch == sep && depth.zero?
          out << current
          current = +''
        else
          current << ch
        end
      end
    end
    out << current
    out
  end

  # One function token in a value: name is the source spelling ASCII
  # downcased (non-ASCII and escapes kept as written), start the index of
  # its first character, open the index of its "(".
  FunctionToken = Data.define(:name, :start, :open)

  # Every real function token in text, per CSS Syntax 3: a maximal run of
  # ident code points ([-_a-zA-Z0-9], any code point >= U+0080, or a
  # backslash escape) that is a valid identifier and is followed directly by
  # "(". Quoted strings and comments are skipped, as are the contents of an
  # unquoted url(...) token, a #hash or @at-keyword name, and a run that
  # starts like a number (2var). Escapes are not decoded, so \var( never
  # equals var(.
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

        tok = FunctionToken.new(name: text[start...i].downcase(:ascii), start:, open: i)
        tokens << tok
        i = tok.name == "url" ? skip_unquoted_url(text, i) : i + 1
      else
        i += 1
      end
    end
    tokens
  end

  # text with every function name ASCII-lowercased and nothing else touched:
  # custom-property names, url() contents and strings stay exact.
  def downcase_function_names(text)
    out = text.to_s.dup
    function_tokens(text).each { |t| out[t.start...t.open] = t.name }
    out
  end

  # Index just past the string opening at i (or end of text if unterminated).
  def skip_string(text, i)
    quote = text[i]
    j = i + 1
    while j < text.length
      case text[j]
      when "\\" then j += 2
        next
      when quote then return j + 1
      when "\n" then return j
      end
      j += 1
    end
    text.length
  end

  def ident_char_at?(text, i)
    ch = text[i]
    ch.match?(/[-_a-zA-Z0-9]/) || ch.ord >= 0x80 || (ch == "\\" && i + 1 < text.length && text[i + 1] != "\n")
  end

  def skip_ident_run(text, i)
    i += text[i] == "\\" ? 2 : 1 while i < text.length && ident_char_at?(text, i)
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

      j += text[j] == "\\" ? 2 : 1
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
      @segment_start_line = 1
      scan_one until @scanner.eos?
      flush_at_eof
    end

    def sheet
      ColorCss::Sheet.new(decls: @decls, at_rule_stmts: @at_rule_stmts, errors: @errors, blocks: @blocks)
    end

    private

    def scan_one
      if (text = @scanner.scan(/[^\/'"();{}]+/))
        consume_text(text)
        return
      end
      return if @scanner.eos?

      ch = @scanner.peek(1)
      case ch
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

    # A comment: blanked in the segment, absent from the raw text.
    def consume_blanked(text)
      @segment << text.gsub(/[^\n]/, ' ')
      @line += text.count("\n")
    end

    def append(text)
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
        found = @scanner.scan_until(/\\.|\\\z|\n|#{Regexp.escape(quote)}/m)
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
      @blocks << BlockOpen.new(id:, parent: @frames.last&.id, prelude: @raw.strip, line:)
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
