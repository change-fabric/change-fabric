#!/usr/bin/env ruby
# frozen_string_literal: true

require 'strscan'

# Hand-written CSS/SCSS/Less tokenizer behind the cf:color checker rewrite.
# Finds declarations and block-less at-rules with enough context (selector
# list, at-rule stack, SCSS nesting, rule identity) for the theme model and
# value resolver to work from. It never models the cascade itself and never
# raises on malformed input; problems are recorded as diagnostics in
# Sheet#errors and scanning continues.
module ColorCss
  # name: "--bg", "color", or "$brand" (SCSS). value: raw text with comments
  # replaced by spaces (newlines kept) and !important removed. line: line of
  # the name. value_line: line where the value starts. selectors: the
  # innermost enclosing rule's selector list, each entry whitespace-collapsed
  # (empty for top-level declarations). parents: selector lists of enclosing
  # rules outside the innermost one (SCSS nesting; empty in plain CSS).
  # at_rules: enclosing at-rule preludes outermost first, e.g.
  # ["@media (prefers-color-scheme: dark)"].
  # rule_id: integer identity of the enclosing rule block (nil at top level),
  # so a consumer can ask whether a whole block is custom-property-only.
  Decl = Data.define(:name, :value, :important, :line, :value_line, :selectors, :parents, :at_rules, :rule_id)
  AtRule = Data.define(:name, :prelude, :line, :at_rules) # block-less: @apply, @import
  Sheet = Data.define(:decls, :at_rule_stmts, :errors) # errors: [String] diagnostics, never raised

  DECL_NAME = /\A(\s*)(--[\w-]+|\$[\w-]+|-?[A-Za-z][\w-]*)(\s*):(.*)\z/m.freeze
  AT_RULE_STMT = /\A(\s*)(@[\w-]+)(\s*)(.*)\z/m.freeze
  IMPORTANT = /\A(.*?)\s*!\s*important\s*\z/mi.freeze

  module_function

  # Tokenizes text into a Sheet. dialect is :css, :scss or :less; line_offset
  # is added to every reported line (used for <style> blocks inside markup).
  def parse(text, dialect: :css, line_offset: 0)
    Parser.new(text, dialect: dialect, line_offset: line_offset).parse
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
    Frame = Struct.new(:kind, :selectors, :rule_id, :text, keyword_init: true)

    def initialize(text, dialect:, line_offset:)
      @scanner = StringScanner.new(text)
      @dialect = dialect
      @line_offset = line_offset
      @decls = []
      @at_rule_stmts = []
      @errors = []
      @frames = []
      @paren_depth = 0
      @paren_is_url = []
      @next_rule_id = 1
      @line = 1
      @segment = +''
      @segment_start_line = 1
    end

    def parse
      scan_one until @scanner.eos?
      flush_at_eof
      ColorCss::Sheet.new(decls: @decls, at_rule_stmts: @at_rule_stmts, errors: @errors)
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
          @segment << ch
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
      @segment << text
      @line += text.count("\n")
    end

    def consume_blanked(text)
      @segment << text.gsub(/[^\n]/, ' ')
      @line += text.count("\n")
    end

    def scss_like?
      @dialect == :scss || @dialect == :less
    end

    def inside_url?
      @paren_is_url.include?(true)
    end

    def scan_slash
      if @scanner.match?(%r{/\*})
        scan_block_comment
      elsif @scanner.match?(%r{//}) && scss_like? && !inside_url?
        scan_line_comment
      else
        consume_text(@scanner.getch)
      end
    end

    def scan_block_comment
      start_line = @line + @line_offset
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

    def scan_line_comment
      @scanner.scan(%r{//})
      @scanner.scan(/[^\n]*/) # dropped entirely: no segment text, no newline consumed
    end

    def scan_string(quote)
      start_line = @line + @line_offset
      @segment << @scanner.getch # opening quote
      loop do
        found = @scanner.scan_until(/\\.|\\\z|\n|#{Regexp.escape(quote)}/m)
        if found.nil?
          rest = @scanner.rest
          @scanner.terminate
          @segment << rest
          @errors << "unterminated string (line #{start_line})"
          return
        end

        @segment << found
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
      before = @segment.sub(/\s+\z/, '')
      is_url = before[-3, 3]&.downcase == 'url'
      @paren_is_url << is_url
      @paren_depth += 1
      @segment << @scanner.getch
    end

    def scan_close_paren
      @paren_depth -= 1 if @paren_depth.positive?
      @paren_is_url.pop
      @segment << @scanner.getch
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
        flush_segment_as_decl
        close_block
        start_new_segment
      end
    end

    def start_new_segment
      @segment = +''
      @segment_start_line = @line
    end

    def flush_segment_as_decl_or_at_rule
      body = @segment
      return if body.strip.empty?

      emit_declaration(body) || emit_at_rule_stmt(body)
    end

    def flush_segment_as_decl
      body = @segment
      return if body.strip.empty?

      emit_declaration(body)
    end

    def open_block
      prelude = @segment
      stripped = prelude.strip
      if stripped.start_with?('@')
        @frames << Frame.new(kind: :at_rule, selectors: nil, rule_id: nil, text: collapse_ws(stripped))
      else
        rule_id = @next_rule_id
        @next_rule_id += 1
        selectors = ColorCss.split_top_level(prelude).map { |s| collapse_ws(s) }.reject(&:empty?)
        @frames << Frame.new(kind: :rule, selectors: selectors, rule_id: rule_id, text: nil)
      end
    end

    def close_block
      if @frames.empty?
        @errors << "unmatched } (line #{@line + @line_offset})"
      else
        @frames.pop
      end
    end

    def emit_declaration(body)
      m = DECL_NAME.match(body)
      return false unless m

      leading_ws, name, mid_ws, rest = m[1], m[2], m[3], m[4]
      name_line = @segment_start_line + leading_ws.count("\n")
      colon_line = name_line + mid_ws.count("\n")
      value_leading_ws = rest[/\A\s*/]
      value_line = colon_line + value_leading_ws.count("\n")

      raw_value = rest.strip
      important = false
      if (im = IMPORTANT.match(raw_value))
        raw_value = im[1].strip
        important = true
      end

      selectors, parents, at_rules, rule_id = current_context
      @decls << Decl.new(
        name:, value: raw_value, important:,
        line: name_line + @line_offset, value_line: value_line + @line_offset,
        selectors:, parents:, at_rules:, rule_id:
      )
      true
    end

    def emit_at_rule_stmt(body)
      m = AT_RULE_STMT.match(body)
      return false unless m

      leading_ws, name, _mid_ws, rest = m[1], m[2], m[3], m[4]
      at_line = @segment_start_line + leading_ws.count("\n")
      at_rules = current_context[2]
      @at_rule_stmts << AtRule.new(name:, prelude: rest.strip, line: at_line + @line_offset, at_rules:)
      true
    end

    def current_context
      rule_frames = @frames.select { |f| f.kind == :rule }
      at_rule_frames = @frames.select { |f| f.kind == :at_rule }
      if rule_frames.empty?
        selectors = []
        parents = []
        rule_id = nil
      else
        innermost = rule_frames.last
        selectors = innermost.selectors
        parents = rule_frames[0...-1].map(&:selectors)
        rule_id = innermost.rule_id
      end
      at_rules = at_rule_frames.map(&:text)
      [ selectors, parents, at_rules, rule_id ]
    end

    def flush_at_eof
      body = @segment
      emit_declaration(body) unless body.strip.empty?
      @errors << "unexpected end of input with #{@frames.size} open block(s)" if @frames.any?
    end

    def collapse_ws(str)
      str.strip.gsub(/\s+/, ' ')
    end
  end
end
