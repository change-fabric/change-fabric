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
