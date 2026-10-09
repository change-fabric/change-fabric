#!/usr/bin/env ruby
# frozen_string_literal: true

require 'set'
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
  # brace with comments removed, so ":root/**/.dark" stays one compound
  # selector while ":root .dark" keeps its whitespace combinator; a comment
  # whose removal would merge two tokens (comment_glues?) leaves one space
  # instead, so "@layer/**/base" reads "@layer base" and "@la/**/yer" reads
  # "@la yer", the token sequence CSS sees. parent: the enclosing block's id
  # or nil. glued: at least one comment left such a space, so callers that
  # cannot read the spaced prelude can say a comment split a token.
  BlockOpen = Data.define(:id, :parent, :prelude, :line, :glued)
  Sheet = Data.define(:decls, :at_rule_stmts, :errors, :blocks) # errors: [String] diagnostics, never raised

  # CSS whitespace (CSS Syntax 3 4.2): space, tab and a newline, which is
  # LF, or CR or FF before preprocessing. The one definition every lexing
  # step here uses, never Ruby's \s or String#strip: both also take U+000B
  # (and strip takes U+0000), which CSS reads as an ordinary delim, so
  # rgb(0\v0\v0) is not three channels and "--a\v" is not the name --a.
  WS_CHARS = " \t\n\r\f"
  WS_SRC = "[ \\t\\n\\r\\f]"
  WS_RUN = /#{WS_SRC}+/.freeze

  # The digits of a hex color's #hash name: 3, 4, 6 or 8 hex digits.
  HEX_HASH_NAME = /\A(?:\h{8}|\h{6}|\h{4}|\h{3})\z/.freeze

  # One escape per CSS Syntax 3 4.3.7: a backslash then 1-6 hex digits and
  # one optional whitespace, or any code point but a newline, or end of
  # input. A backslash before a newline matches nothing: it is no escape.
  ESCAPE = /\\(?:\h{1,6}(?:\r\n|[ \t\n\r\f])?|[^\n\r\f]|\z)/.freeze
  # The one definition of an identifier code point (CSS Syntax 3 4.2): an
  # ASCII letter, digit, "_" or "-", or any code point >= U+0080. Spelled
  # out rather than \w, which in Ruby is ASCII-only, so every identifier
  # pattern below agrees on non-ASCII names (@layer café, --caf\e9).
  IDENT_CP = /[-_a-zA-Z0-9\u0080-\u{10FFFF}]/.freeze
  # A code point that may start an identifier (after an optional "-").
  NAME_START_CP = /[_a-zA-Z\u0080-\u{10FFFF}]/.freeze
  # One identifier unit as written: an ident code point or an escape.
  IDENT_UNIT = /(?:#{IDENT_CP}|#{ESCAPE})/.freeze
  # One whole identifier as written: "--" then any units, or an optional
  # "-", a name-start code point or escape, then any units.
  IDENT_SRC = /(?:--#{IDENT_UNIT}*|-?(?:#{NAME_START_CP}|#{ESCAPE})#{IDENT_UNIT}*)/.freeze
  # A custom-property name as written: "--" then ident units, so --\61 and
  # --caf\e9 are declarations. Its value is decoded by custom_property_name.
  CUSTOM_NAME_SRC = /--#{IDENT_UNIT}+/.freeze
  # A Tailwind @theme namespace reset as written: --* or --<prefix>-*
  # (--color-*). ColorTokens accepts it only inside @theme.
  NAMESPACE_RESET_SRC = /--(?:#{IDENT_UNIT}*-)?\*/.freeze
  # Any identifier spelled with at least one escape (\2d \2d x, -\2d x). It
  # is a declaration name only when it decodes to a custom-property name
  # (ColorCss.custom_property_ref); emit_declaration checks that.
  ESCAPED_NAME_SRC = /#{IDENT_CP}*#{ESCAPE}#{IDENT_UNIT}*/.freeze
  DECL_NAME = /\A(#{WS_SRC}*)(#{NAMESPACE_RESET_SRC}|#{CUSTOM_NAME_SRC}|\$#{IDENT_CP}+|@#{IDENT_UNIT}+|-?#{NAME_START_CP}#{IDENT_CP}*|#{ESCAPED_NAME_SRC})(#{WS_SRC}*):(.*)\z/m.freeze
  # A segment that has begun a custom-property declaration: its name (literal
  # or escaped, checked by custom_property_ref) and the colon.
  CUSTOM_VALUE_START = /\A#{WS_SRC}*(#{CUSTOM_NAME_SRC}|#{ESCAPED_NAME_SRC})#{WS_SRC}*:/.freeze
  # A block-less at-rule; its name may be spelled with escapes (@t\61ilwind),
  # which ColorTokens decodes before comparing.
  AT_RULE_STMT = /\A(#{WS_SRC}*)(@#{IDENT_UNIT}+)(#{WS_SRC}*)(.*)\z/m.freeze
  # An at-rule block's name as written, escapes included (@t\68 eme).
  AT_BLOCK_NAME = /\A@#{IDENT_UNIT}+/.freeze
  # At-rules whose block holds declarations rather than rules: Tailwind's
  # @theme and the CSS descriptor at-rules. Inside one, as inside a style
  # rule, "--name: {" opens a {} block in the value, not a nested rule.
  DECLARATION_AT_RULES = %w[@theme @font-face @page @property @counter-style
                            @font-palette-values @position-try @view-transition].freeze
  ESCAPE_AT = /\G#{ESCAPE}/.freeze
  # A code point that continues an ident, number or at-keyword token; a
  # backslash starts an escape, which does too.
  TOKEN_CP = /(?:#{IDENT_CP}|\\)/.freeze
  # A <number> as CSS Syntax 3 4.3.12 consumes one: an optional sign,
  # digits with an optional fraction (a "." only with a digit after it) or a
  # fraction alone, and an exponent only when "e" is followed by a digit, or
  # a sign and a digit, written literally. An escape is never part of one.
  NUMBER_SRC = /[+-]?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?/.freeze
  NUMBER_AT = /\G#{NUMBER_SRC}/.freeze
  # One numeric token (CSS Syntax 3 4.3.3). number: the number as written.
  # type: :number, :percentage or :dimension. unit: a dimension's unit with
  # its escapes decoded (case kept), else nil.
  NumericToken = Data.define(:number, :type, :unit)
  # The identifiers downcase_keywords may ASCII-fold, as decoded lowercase
  # Sets. functions: names directly before "(". keywords: bare identifiers
  # anywhere. within: per enclosing function name, bare identifiers folded
  # only inside that function's own parentheses (`in srgb` in color-mix()).
  CaseFolds = Data.define(:functions, :keywords, :within)
  EMPTY_SET = Set.new.freeze

module_function

  # text with leading and trailing CSS whitespace removed (WS_CHARS).
  def strip_ws(text)
    text = text.to_s
    text[ws_range(text, 0, text.length)]
  end

  # The Range of text[s...e] that strip_ws would keep.
  def ws_range(text, s, e)
    s += 1 while s < e && WS_CHARS.include?(text[s])
    e -= 1 while e > s && WS_CHARS.include?(text[e - 1])
    s...e
  end

  # text split on runs of CSS whitespace, empty pieces dropped.
  def split_ws(text)
    text.to_s.split(WS_RUN).reject(&:empty?)
  end

  # text stripped, each inner run of CSS whitespace collapsed to one space.
  def collapse_ws(text)
    strip_ws(text).gsub(WS_RUN, " ")
  end

  # Tokenizes text into a Sheet. One leading U+FEFF byte-order mark is
  # dropped first, as CSS Syntax 3 decoding does, so every reader sees the
  # same first token whether or not the file was saved with a BOM. The rest
  # is then preprocessed (ColorCss.preprocess), so the scanner only ever
  # meets LF as a newline.
  def parse(text)
    Parser.new(preprocess(text.to_s.delete_prefix("\uFEFF"))).sheet
  end

  # CSS Syntax 3 3.3 input preprocessing: CRLF, a lone CR and FF each become
  # one LF, and NUL or a surrogate (invalid UTF-8 in a Ruby string) becomes
  # U+FFFD. Without it a CR or FF inside a quoted value would not end the
  # string as CSS does, and line numbers would skip CR-only line breaks.
  def preprocess(text)
    text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
        .scrub("\uFFFD").gsub(/\r\n?|\f/, "\n").tr("\0", "\uFFFD")
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

  # The closer of each CSS simple block opener: (), [] and {}.
  BLOCK_CLOSER = { "(" => ")", "[" => "]", "{" => "}" }.freeze

  # Moves the open-block stack past one character, per CSS Syntax 3
  # "consume a simple block": an opener pushes its closer, the closer on top
  # pops it, and any other closer (a "]" inside "(", a ")" at top level) is
  # an ordinary token that moves nothing. The one bracket rule every scanner
  # here uses, so ";", "," or "!" inside [a;b] or {a:b} is never top level.
  def track_block(stack, ch)
    if (closer = BLOCK_CLOSER[ch])
      stack << closer
    elsif !stack.empty? && ch == stack.last
      stack.pop
    end
    stack
  end

  # Splits text at top-level occurrences of sep, respecting (), [] and {}
  # blocks, quoted strings and escapes, so ":is(a, b)" stays one entry and a comma
  # inside a string or written as \, is never a split point. Entries are not
  # whitespace-collapsed here; callers do that themselves.
  def split_top_level(text, sep = ",")
    out = []
    start = 0
    stack = []
    i = 0
    while i < text.length
      case text[i]
      when "\\" then i = skip_escape(text, i)
        next
      when '"', "'" then i = skip_string(text, i)
        next
      when sep
        if stack.empty?
          out << text[start...i]
          start = i + 1
        end
      else track_block(stack, text[i])
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
    tokens = []
    scan_value(text) { |tok, _i| tokens << tok if tok.is_a?(FunctionToken) }
    tokens
  end

  # The one value lexer function_tokens and ColorValue.var_calls share, in a
  # single pass: yields each FunctionToken with the index of the
  # "(" it opens (nil for an unquoted url(...), whose token closes itself),
  # and each other simple-block character ("(", ")", "[", "]", "{", "}")
  # and "," as the character and its index. Nothing inside a string,
  # comment, escape or unquoted url() is yielded.
  def scan_value(text)
    text = text.to_s
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
        after = tok.name == "url" ? skip_unquoted_url(text, i) : i + 1
        yield tok, (after == i + 1 ? i : nil)
        i = after
      else
        yield ch, i if ch == "," || BLOCK_CLOSER.key?(ch) || BLOCK_CLOSER.value?(ch)
        i += 1
      end
    end
  end

  # text with every identifier listed in folds (CaseFolds) written
  # ASCII-lowercased, and every numeric token (10PX, 1E3) too: number
  # exponents and dimension units are ASCII case-insensitive. Any other
  # identifier keeps its case, since a custom property may hand it to a
  # case-sensitive <custom-ident> (--animation: FadeIn is not fadein).
  # Left exact as well: custom-property names (--Ink), #hash and @names,
  # quoted strings, comments and unquoted url() contents. Non-ASCII code
  # points are never folded. Escapes are kept as written; pass the text
  # through canonical_idents first to compare escaped and plain spellings.
  def downcase_keywords(text, folds)
    text = text.to_s
    out = +""
    enclosing = []
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
        prev = i.positive? ? text[i - 1] : nil
        named = prev == "#" || prev == "@"
        fn = !named && text[j] == "(" && ident_start?(run) ? decode_ident(run).downcase(:ascii) : nil
        out << (!named && folds_run?(run, fn, enclosing.last, folds) ? run.downcase(:ascii) : run)
        if fn
          k = fn == "url" ? skip_unquoted_url(text, j) : j + 1
          enclosing << fn if k == j + 1
          out << text[j...k]
          j = k
        end
        i = j
        next
      else
        enclosing << enclosing.last if ch == "("
        enclosing.pop if ch == ")"
        j = i + 1
      end
      out << text[i...j]
      i = j
    end
    out
  end

  # Whether downcase_keywords folds one identifier or numeric run: a
  # numeric token always; a function name (fn, decoded) when folds lists
  # it; a bare identifier when folds lists it as a keyword or within the
  # innermost enclosing function (a plain "(" block counts as part of the
  # function it sits in). Custom-property names never fold.
  def folds_run?(run, fn, enclosing, folds)
    return true unless ident_start?(run)
    return folds.functions.include?(fn) if fn
    return false if custom_property_ref(run)

    name = decode_ident(run).downcase(:ascii)
    folds.keywords.include?(name) || folds.within.fetch(enclosing, EMPTY_SET).include?(name)
  end

  # text with every escape outside quoted strings and comments decoded, as
  # [decoded, nil], so anchored matching (var(, rgb(, red, #hex) sees the
  # name CSS sees: \76 ar( is var( and \72 ed is red. An escape is decoded
  # only inside an identifier run that stays a plain identifier once
  # decoded, inside a dimension's unit whose decoded spelling lexes as the
  # same token (0d\65 g is 0deg, plain_dimension), or inside a #hash name
  # that decodes to a hex color's digits (#\66 ff is #fff); an escape that
  # would become a delimiter (\( \; \, a quote or whitespace), part of any
  # other #hash or an @name, or a unit whose decoded spelling lexes
  # differently (1\65 3 is unit e3, not 1e3) has no plain spelling, so
  # [nil, reason] is returned instead of a guess.
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
          return [ nil, "unrecognized color value: #{strip_ws(text)[0, 40]} (escape has no plain spelling)" ] unless decoded

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
  # not an identifier (an @name, a #hash whose name is not a hex color's
  # digits) or decodes to anything but identifier code points. A run that
  # starts a number is a dimension, decoded by plain_dimension.
  def plain_ident(run, prev)
    return hex_hash_name(run) if prev == "#"
    return nil if prev == "@"
    return plain_dimension(run) unless ident_start?(run)

    decoded = decode_ident(run)
    decoded if decoded.match?(/\A#{IDENT_CP}+\z/) && ident_start?(decoded)
  end

  # An escaped dimension run with its unit decoded (0d\65 g is 0deg,
  # 0\44 EG is 0DEG), or nil when the decoded spelling would lex as a
  # different token: 1\65 3 is 1 with unit e3, not the number 1e3, and
  # 50\25 is 50 with unit %, not a percentage. Neither has a plain spelling.
  def plain_dimension(run)
    tok = numeric_token(run)
    return nil unless tok&.type == :dimension

    plain = "#{tok.number}#{tok.unit}"
    plain if numeric_token(plain) == tok
  end

  # text read as exactly one numeric token, per CSS Syntax 3 4.3.3 consume
  # a numeric token: a number (NUMBER_SRC), then a "%" (a percentage), or
  # an identifier sequence when the next code points would start one, an
  # escape included (a dimension, its unit decoded), or nothing (a number).
  # nil when text holds anything more or is not a number at all. The one
  # numeric lexer: every number, percentage, hue and alpha reader uses it,
  # so an escaped unit reads the same everywhere.
  def numeric_token(text)
    text = text.to_s
    m = text.match(NUMBER_AT, 0)
    return nil unless m

    number = m[0]
    k = m.end(0)
    return NumericToken.new(number:, type: :number, unit: nil) if k == text.length
    return (k + 1 == text.length ? NumericToken.new(number:, type: :percentage, unit: nil) : nil) if text[k] == "%"
    return nil unless starts_ident_at?(text, k) && skip_ident_run(text, k) == text.length

    NumericToken.new(number:, type: :dimension, unit: decode_ident(text[k..]))
  end

  # Whether the code points at text[k] would start an identifier sequence
  # (CSS Syntax 3 4.3.9): "--", or an optional "-" then a name-start code
  # point or a valid escape (a backslash not before a newline).
  def starts_ident_at?(text, k)
    j = text[k] == "-" ? k + 1 : k
    return true if j > k && text[j] == "-"

    ch = text[j]
    return false if ch.nil?

    ch.match?(NAME_START_CP) || !decode_escape(text, j).nil?
  end

  # A #hash name's decoded value when it is 3, 4, 6 or 8 hex digits, the
  # only hash a color reads, else nil. CSS decodes escapes in a hash name
  # before the color parser sees it, so #\66 ff, #f\66 f and #\46\46\46
  # are #fff and #FFF.
  def hex_hash_name(run)
    decoded = decode_ident(run)
    decoded if decoded.match?(HEX_HASH_NAME)
  end

  # A custom-property name's value, the one thing every name comparison
  # uses: escapes decoded per CSS Syntax 3, so --\61 and --a name one
  # property whether declared or referenced. Case is kept: names are
  # case-sensitive.
  def custom_property_name(raw)
    decode_ident(raw.to_s)
  end

  # The one test for "is this a custom-property name": run must be exactly
  # one identifier token (any mix of literal code points and escapes, so
  # \2d \2d a, -\2d a and \-\-a all count) whose decoded value starts with
  # "--" and has at least one more code point. Returns that decoded name,
  # or nil. Never test raw text for a literal "--": CSS decodes escapes
  # before it asks whether an identifier is a custom property.
  def custom_property_ref(run)
    run = run.to_s
    return nil if run.empty? || !ident_char_at?(run, 0) || skip_ident_run(run, 0) != run.length

    name = custom_property_name(run)
    name if name.length > 2 && name.start_with?("--")
  end

  # The decoded custom-property name text is, as the whole first argument
  # of a var() (css-variables-1): exactly one identifier token that is a
  # custom-property name (custom_property_ref), with only whitespace and
  # comments around it. Anything else (var(--b junk), var(--b --c),
  # var(--b/**/--c), var()) is nil: a malformed var() that makes its whole
  # declaration invalid at parse time.
  def sole_custom_property_ref(text)
    text = text.to_s
    name = nil
    i = 0
    while i < text.length
      if WS_CHARS.include?(text[i])
        i += 1
      elsif text[i, 2] == "/*"
        close = text.index("*/", i + 2)
        i = close ? close + 2 : text.length
      elsif name.nil? && ident_char_at?(text, i)
        stop = skip_ident_run(text, i)
        name = custom_property_ref(text[i...stop])
        return nil unless name

        i = stop
      else
        return nil
      end
    end
    name
  end

  # A declaration value split from its priority suffix, as [value,
  # important]. The suffix is found by tokens, as CSS Syntax 3 5.4.6 does:
  # at top level (inside no (), [] or {} block), the last two significant tokens
  # outside strings and comments are a "!" delim and an ident whose decoded value is
  # "important", ASCII case-insensitive, so !\69mportant, !IMPORTANT and
  # ! /* note */ important all count, while an escaped \! (part of an
  # ident), a quoted "!important" or one inside a function does not. value
  # is the text before the "!", stripped.
  def split_priority(text)
    text = text.to_s
    bang = nil
    last = nil
    stack = []
    i = 0
    while i < text.length
      ch = text[i]
      if text[i, 2] == "/*"
        close = text.index("*/", i + 2)
        i = close ? close + 2 : text.length
        next
      elsif WS_CHARS.include?(ch)
        i += 1
        next
      end

      prev = last
      if ch == '"' || ch == "'"
        j = skip_string(text, i)
        last = [ :other, i ]
      elsif ident_char_at?(text, i)
        j = skip_ident_run(text, i)
        last = [ :ident, i, j ]
      else
        j = i + 1
        track_block(stack, ch)
        last = [ ch == "!" ? :bang : :other, i ]
      end
      bang = prev && prev[0] == :bang ? prev[1] : nil
      i = j
    end
    return [ strip_ws(text), false ] unless bang && stack.empty? && last[0] == :ident

    run = text[last[1]...last[2]]
    return [ strip_ws(text), false ] unless ident_start?(run) && decode_ident(run).downcase(:ascii) == "important"

    [ strip_ws(text[0...bang]), true ]
  end

  # text with every escaped identifier (and #hash name) outside strings,
  # comments and unquoted url() contents decoded (decode_ident) and written
  # back in one canonical spelling (serialize_ident), so two spellings CSS
  # reads as one token compare equal: --\69 nk is --ink, r\67 b( is rgb(,
  # 120d\65 g is 120deg (canonical_dimension). Case is kept and a number is
  # left as written.
  def canonical_idents(text)
    text = text.to_s
    return text unless text.include?("\\")

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
        hash = i.positive? && text[i - 1] == "#"
        if hash || ident_start?(run)
          decoded = decode_ident(run)
          out << (run.include?("\\") ? serialize_ident(decoded, name_only: hash) : run)
          if text[j] == "(" && !hash && decoded.downcase(:ascii) == "url"
            k = skip_unquoted_url(text, j)
            out << text[j...k]
            j = k
          end
          i = j
          next
        end
        if run.include?("\\") && (dim = canonical_dimension(run))
          out << dim
          i = j
          next
        end
      else
        j = i + 1
      end
      out << text[i...j]
      i = j
    end
    out
  end

  # An escaped dimension run written back in one canonical spelling, so
  # 120d\65 g and 120deg compare equal: the number as written, then the
  # decoded unit serialized (serialize_ident), with its first code point
  # escaped too when the plain spelling would lex as another token (unit e3
  # is 1\65 3, never 1e3). nil when run is not a dimension.
  def canonical_dimension(run)
    tok = numeric_token(run)
    return nil unless tok&.type == :dimension

    spelled = "#{tok.number}#{serialize_ident(tok.unit)}"
    return spelled if numeric_token(spelled) == tok

    "#{tok.number}\\#{tok.unit[0].ord.to_s(16)} #{serialize_ident(tok.unit[1..], name_only: true)}"
  end

  # text with every terminated quoted string outside comments decoded (CSS
  # Syntax 3 4.3.5: an escape is its code point, a backslash before a newline
  # is dropped) and written back double-quoted with only " and \ escaped, so
  # "d\61rk", 'dark' and "dark" compare equal. An unterminated string and
  # every escape outside a string are left as written.
  def canonical_strings(text)
    text = text.to_s
    out = +""
    i = 0
    while i < text.length
      ch = text[i]
      if ch == '"' || ch == "'"
        value, j = string_value(text, i)
        out << (value ? %("#{value.gsub(/["\\]/) { "\\#{_1}" }}") : text[i...j])
      elsif ch == "\\"
        j = skip_escape(text, i)
        out << text[i...j]
      elsif text[i, 2] == "/*"
        close = text.index("*/", i + 2)
        j = close ? close + 2 : text.length
        out << text[i...j]
      else
        j = i + 1
        out << ch
      end
      i = j
    end
    out
  end

  # The string opening at text[i]: [decoded value, index just past it], the
  # value nil when a raw newline or end of input leaves it unterminated.
  def string_value(text, i)
    quote = text[i]
    out = +""
    j = i + 1
    while j < text.length
      ch = text[j]
      return [ out, j + 1 ] if ch == quote
      return [ nil, j ] if ch == "\n"

      if ch == "\\" && text[j + 1] == "\n"
        j += 2
        next
      end
      ch, j = decode_escape(text, j) || [ ch, j + 1 ]
      out << ch
    end
    [ nil, text.length ]
  end

  # A decoded identifier written back with escapes only where CSS needs one
  # (CSSOM serialize an identifier): a non-ident code point, a leading digit
  # or "-" then digit, and a lone "-". name_only (a #hash name) has no start
  # rules. Each escape is hex plus one space, so the spelling is unique.
  def serialize_ident(value, name_only: false)
    return "\\2d " if value == "-" && !name_only

    out = +""
    value.each_char.with_index do |c, k|
      leading_digit = !name_only && c.match?(/[0-9]/) && (k.zero? || (k == 1 && value[0] == "-"))
      out << (c.match?(IDENT_CP) && !leading_digit ? c : "\\#{c.ord.to_s(16)} ")
    end
    out
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

  # False past the end of text, so an empty value holds no identifier.
  def ident_char_at?(text, i)
    ch = text[i]
    return false if ch.nil?

    ch.match?(IDENT_CP) || !decode_escape(text, i).nil?
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

    rest.match?(/\A(?:#{NAME_START_CP}|\\)/)
  end

  # Past the ")" closing an unquoted url( token at open, or just past "(" when
  # the url is quoted (then its contents are an ordinary string argument).
  def skip_unquoted_url(text, open)
    j = open + 1
    j += 1 while j < text.length && WS_CHARS.include?(text[j])
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
    Frame = Struct.new(:kind, :selectors, :id, :text, :declarations, keyword_init: true)

    def initialize(text)
      @decls = []
      @at_rule_stmts = []
      @blocks = []
      @errors = []
      @next_id = 1
      @scanner = StringScanner.new(text)
      @frames = []
      @brackets = []
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
      if (text = @scanner.scan(/[^\/'"()\[\];{}\\]+/))
        consume_text(text)
        return
      end
      return if @scanner.eos?

      ch = @scanner.peek(1)
      case ch
      when "\\"
        # An escape is ordinary value text, so an escaped ; { } ( ) or quote
        # never ends a declaration or moves the block stack. A
        # backslash before a newline escapes nothing and is taken alone.
        consume_text(@scanner.scan(ESCAPE) || @scanner.getch)
      when '/'
        scan_slash
      when "'", '"'
        scan_string(ch)
      when '(', '[', ')', ']'
        scan_block_char(@scanner.getch)
      when ';', '}'
        @scanner.getch
        if @brackets.empty?
          dispatch_terminator(ch)
        else
          scan_block_char(ch)
        end
      when '{'
        @scanner.getch
        if @brackets.empty? && !custom_property_value?
          dispatch_terminator(ch)
        else
          scan_block_char(ch)
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
    # does not, so the next append puts one space in the raw text where it
    # would otherwise glue two tokens together.
    def consume_blanked(text)
      @segment << text.gsub(/[^\n]/, ' ')
      @line += text.count("\n")
      @comment_pending = true
    end

    def append(text)
      if @comment_pending && !text.empty?
        if ColorCss.comment_glues?(@raw, text)
          @raw << " "
          @glued = true
        end
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

    # A bracket, or a ; { } inside an open block: value text that moves the
    # block stack (ColorCss.track_block), so ; and } inside (), [] or a
    # value-level {} never end the declaration.
    def scan_block_char(ch)
      ColorCss.track_block(@brackets, ch)
      append(ch)
    end

    # Whether the segment so far is "--name:" inside a declaration context
    # (a style rule or a DECLARATION_AT_RULES block), so a "{" here opens a
    # {} block in a custom property's value rather than a nested rule (CSS
    # Syntax 3 consume a declaration; CSS Nesting). At top level, or inside
    # a rule-holding at-rule such as @media or @layer alone, the block holds
    # rules only, so "--x: {" there stays a rule.
    def custom_property_value?
      return false unless @frames.any?(&:declarations)

      m = CUSTOM_VALUE_START.match(@segment)
      m && !ColorCss.custom_property_ref(m[1]).nil?
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
      return if ColorCss.strip_ws(body).empty?

      return if emit_declaration(body) || emit_at_rule_stmt(body)

      line = @segment_start_line + body[/\A#{WS_SRC}*/].count("\n")
      @errors << "unparsed segment #{collapse_ws(body).inspect} (line #{line})"
    end

    def open_block
      prelude = @segment
      id = @next_id
      @next_id += 1
      line = @segment_start_line + prelude[/\A#{WS_SRC}*/].count("\n")
      @blocks << BlockOpen.new(id:, parent: @frames.last&.id, prelude: ColorCss.strip_ws(@raw), line:, glued: @glued)
      stripped = ColorCss.strip_ws(@raw)
      @frames << if stripped.start_with?('@')
                   Frame.new(kind: :at_rule, selectors: nil, id:, text: collapse_ws(stripped),
                             declarations: declaration_at_rule?(stripped))
      else
                   selectors = ColorCss.split_top_level(prelude).map { |s| collapse_ws(s) }.reject(&:empty?)
                   Frame.new(kind: :rule, selectors:, id:, text: nil, declarations: true)
      end
    end

    # Whether an at-rule block (by its prelude, escapes decoded so @t\68 eme
    # is @theme) holds declarations rather than rules.
    def declaration_at_rule?(prelude)
      name = ColorCss.canonical_idents(prelude)[AT_BLOCK_NAME].to_s.downcase(:ascii)
      DECLARATION_AT_RULES.include?(name)
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
      if name.include?("\\")
        name = ColorCss.custom_property_ref(name)
        return false unless name
      end

      raw_value, important = ColorCss.split_priority(rest)

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
      @at_rule_stmts << AtRule.new(name:, prelude: ColorCss.strip_ws(rest), line: at_line, block_id:)
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
      ColorCss.collapse_ws(str)
    end
  end
end
