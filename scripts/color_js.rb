#!/usr/bin/env ruby
# frozen_string_literal: true

require 'strscan'

# Hand-written JavaScript lexer shared by the cf:color stray scan and markup
# expression balancing. It knows only enough of the grammar to tell strings,
# templates, comments and regex literals apart from code, so a quote inside a
# regex or a brace inside a comment never confuses a caller. It never models
# JSX and never raises on any input; an unterminated construct is emitted as
# far as it was consumed.
module ColorJs
  # kind: :string, :template, :comment, :regex, :punct, :name or :number.
  # start/stop: character offsets into the scanned text, stop exclusive.
  # text: the source slice, delimiters included.
  Token = Data.define(:kind, :start, :stop, :text)

  # A "/" after one of these names starts a regex, not a division.
  REGEX_KEYWORDS = %w[return typeof instanceof in of new delete void throw case do else yield await].freeze
  # A ")" closing a "(" that followed one of these ends a statement head, so a
  # "/" after it starts a regex.
  CONDITION_KEYWORDS = %w[if while for with].freeze
  # A "{" after one of these opens a block, not an object literal.
  BLOCK_KEYWORDS = %w[else do try finally].freeze

  NAME = /[A-Za-z_$\u0080-\u{10FFFF}][\w$\u0080-\u{10FFFF}]*/
  NUMBER = /\d[\w.]*|\.\d[\w.]*/
  PUNCT = /=>|\+\+|--|\?\.|\.\.\.|[^\s\w$]/

  module_function

  # Yields every Token in text, in order; returns an Enumerator without a
  # block. Template interpolations are lexed only to find where the template
  # ends; tokens inside them are not yielded.
  def tokens(text, &block)
    return enum_for(:tokens, text) unless block

    source = clean(text)
    Lexer.new(StringScanner.new(source), source, block).run
    nil
  end

  # Given i, the index just past an opening "{", returns the index of the "}"
  # that balances it, skipping strings, templates (with nested "${}"),
  # comments and regexes. nil when the brace is never closed before len.
  def expression_end(text, i, len = text.length)
    source = clean(text.to_s[0, len].to_s)
    return nil if i.negative? || i > source.length

    scanner = StringScanner.new(source)
    scanner.pos = source[0, i].bytesize
    Lexer.new(scanner, source, nil).run(nested: true)
  end

  def clean(text)
    text = text.to_s
    text.valid_encoding? ? text : text.scrub('?')
  end

  # One pass over a StringScanner. Nested lexers share the scanner to find the
  # end of a "${}" interpolation; they emit nothing.
  class Lexer
    def initialize(scanner, source, emit)
      @s = scanner
      @source = source
      @emit = emit
      @regex_ok = true
      @parens = [] # true when the "(" followed if/while/for/with
      @braces = [] # :block or :object
      @prev = nil  # previous significant token
    end

    # Lexes to the end of input. With nested: true, stops at the "}" that
    # closes the enclosing expression and returns its character index (nil at
    # end of input).
    def run(nested: false)
      until @s.eos?
        next if @s.skip(/\s+/)

        start = @s.charpos
        return start if nested && @braces.empty? && @s.check(/\}/)

        lex_one(start)
      end
      nil
    end

    private

    def lex_one(start)
      if @s.check(%r{//|/\*})
        emit(:comment, start, scan_comment)
      elsif @s.check(%r{/}) && @regex_ok
        scan_regex
        significant(:regex, start)
      elsif @s.check(/['"]/)
        scan_string
        significant(:string, start)
      elsif @s.check(/`/)
        scan_template
        significant(:template, start)
      else
        lex_code(start)
      end
    end

    def lex_code(start)
      if @s.scan(NAME)
        significant(:name, start)
      elsif @s.scan(NUMBER)
        significant(:number, start)
      else
        @s.scan(PUNCT) || @s.getch
        punct(start)
      end
    end

    def scan_comment
      return @s.scan(%r{//[^\n]*}) if @s.check(%r{//})

      @s.scan(%r{/\*.*?\*/}m) || @s.scan(/.*/m)
    end

    # Ends after the closing slash and flags, or before a newline when
    # unterminated. A "/" inside [...] does not end it.
    def scan_regex
      @s.getch
      until @s.eos?
        break if @s.check(/\n/)
        next if @s.skip(/\\[^\n]?/) || @s.skip(/\[(?:\\[^\n]?|[^\]\\\n])*\]?/)

        break @s.skip(/\w*/) if @s.getch == '/'
      end
    end

    # Ends at the unescaped matching quote, or before a newline when
    # unterminated.
    def scan_string
      quote = @s.getch
      until @s.eos?
        break if @s.check(/\n/)
        next if @s.skip(/\\[^\n]?/)
        break if @s.getch == quote
      end
    end

    def scan_template
      @s.getch
      until @s.eos?
        next if @s.skip(/\\.?/m)

        if @s.skip(/\$\{/)
          @s.getch if Lexer.new(@s, @source, nil).run(nested: true)
          next
        end
        break if @s.getch == '`'
      end
    end

    def punct(start)
      text = @source[start...@s.charpos]
      case text
      when '(' then @parens.push(@prev&.kind == :name && CONDITION_KEYWORDS.include?(@prev.text))
      when '{' then @braces.push(brace_kind)
      end
      significant(:punct, start)
      @regex_ok = regex_after_punct(text)
    end

    def regex_after_punct(text)
      case text
      when ')' then @parens.pop || false
      when '}' then @braces.pop != :object
      when ']', '++', '--' then false
      else true
      end
    end

    # Best effort: "{" after "=>" is taken as a block, right for arrow bodies
    # ("() => ({})" is decided by its "(" instead). A labeled block ("l: {")
    # is taken as an object literal, so a "/" after its "}" reads as division.
    def brace_kind
      return :block if @prev.nil?

      case @prev.kind
      when :punct then %w[; { } ) =>].include?(@prev.text) ? :block : :object
      when :name then REGEX_KEYWORDS.include?(@prev.text) && !BLOCK_KEYWORDS.include?(@prev.text) ? :object : :block
      else :block
      end
    end

    # A keyword after "." or "?." is a property name ("a.return / 2"), so it
    # never puts the lexer in regex position.
    def significant(kind, start)
      member = @prev&.kind == :punct && %w[. ?.].include?(@prev.text)
      @prev = emit(kind, start, @source[start...@s.charpos])
      @regex_ok = kind == :name && !member && REGEX_KEYWORDS.include?(@prev.text)
    end

    def emit(kind, start, text)
      token = Token.new(kind: kind, start: start, stop: start + text.to_s.length, text: text.to_s)
      @emit&.call(token)
      token
    end
  end
end
