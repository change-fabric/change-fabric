#!/usr/bin/env ruby
# frozen_string_literal: true

require 'set'
require_relative 'color_css'

# Parses and resolves a single CSS declaration value to an opaque or
# translucent sRGB color, or a reason the checker declined to resolve it.
# Supports hex, named colors, rgb()/rgba() and hsl()/hsla() with literal
# channels, and a whole-value var(--x) or var(--x, fallback) reference to
# another token. color-mix(), oklch/oklab/lab/lch/hwb/color(), a var()
# used inside a function's channel arguments, and a `none` channel are all
# unresolved, not errors: the checker lists them with a reason and leaves
# the pair to be stated manually. Stdlib only; no CSS parser dependency
# beyond ColorCss.
module ColorValue
  # r, g, b integers 0..255. a float 0..1.
  Rgba = Data.define(:r, :g, :b, :a)
  # Exactly one of color/reason is non-nil.
  Result = Data.define(:color, :reason)

  WHITE = Rgba.new(r: 255, g: 255, b: 255, a: 1.0)

  # The 148 CSS named colors (CSS Color Module Level 4), lowercase keys.
  # `transparent` is a separate keyword, handled outside this table.
  NAMED = {
    'aliceblue' => [ 240, 248, 255 ],
    'antiquewhite' => [ 250, 235, 215 ],
    'aqua' => [ 0, 255, 255 ],
    'aquamarine' => [ 127, 255, 212 ],
    'azure' => [ 240, 255, 255 ],
    'beige' => [ 245, 245, 220 ],
    'bisque' => [ 255, 228, 196 ],
    'black' => [ 0, 0, 0 ],
    'blanchedalmond' => [ 255, 235, 205 ],
    'blue' => [ 0, 0, 255 ],
    'blueviolet' => [ 138, 43, 226 ],
    'brown' => [ 165, 42, 42 ],
    'burlywood' => [ 222, 184, 135 ],
    'cadetblue' => [ 95, 158, 160 ],
    'chartreuse' => [ 127, 255, 0 ],
    'chocolate' => [ 210, 105, 30 ],
    'coral' => [ 255, 127, 80 ],
    'cornflowerblue' => [ 100, 149, 237 ],
    'cornsilk' => [ 255, 248, 220 ],
    'crimson' => [ 220, 20, 60 ],
    'cyan' => [ 0, 255, 255 ],
    'darkblue' => [ 0, 0, 139 ],
    'darkcyan' => [ 0, 139, 139 ],
    'darkgoldenrod' => [ 184, 134, 11 ],
    'darkgray' => [ 169, 169, 169 ],
    'darkgreen' => [ 0, 100, 0 ],
    'darkgrey' => [ 169, 169, 169 ],
    'darkkhaki' => [ 189, 183, 107 ],
    'darkmagenta' => [ 139, 0, 139 ],
    'darkolivegreen' => [ 85, 107, 47 ],
    'darkorange' => [ 255, 140, 0 ],
    'darkorchid' => [ 153, 50, 204 ],
    'darkred' => [ 139, 0, 0 ],
    'darksalmon' => [ 233, 150, 122 ],
    'darkseagreen' => [ 143, 188, 143 ],
    'darkslateblue' => [ 72, 61, 139 ],
    'darkslategray' => [ 47, 79, 79 ],
    'darkslategrey' => [ 47, 79, 79 ],
    'darkturquoise' => [ 0, 206, 209 ],
    'darkviolet' => [ 148, 0, 211 ],
    'deeppink' => [ 255, 20, 147 ],
    'deepskyblue' => [ 0, 191, 255 ],
    'dimgray' => [ 105, 105, 105 ],
    'dimgrey' => [ 105, 105, 105 ],
    'dodgerblue' => [ 30, 144, 255 ],
    'firebrick' => [ 178, 34, 34 ],
    'floralwhite' => [ 255, 250, 240 ],
    'forestgreen' => [ 34, 139, 34 ],
    'fuchsia' => [ 255, 0, 255 ],
    'gainsboro' => [ 220, 220, 220 ],
    'ghostwhite' => [ 248, 248, 255 ],
    'gold' => [ 255, 215, 0 ],
    'goldenrod' => [ 218, 165, 32 ],
    'gray' => [ 128, 128, 128 ],
    'grey' => [ 128, 128, 128 ],
    'green' => [ 0, 128, 0 ],
    'greenyellow' => [ 173, 255, 47 ],
    'honeydew' => [ 240, 255, 240 ],
    'hotpink' => [ 255, 105, 180 ],
    'indianred' => [ 205, 92, 92 ],
    'indigo' => [ 75, 0, 130 ],
    'ivory' => [ 255, 255, 240 ],
    'khaki' => [ 240, 230, 140 ],
    'lavender' => [ 230, 230, 250 ],
    'lavenderblush' => [ 255, 240, 245 ],
    'lawngreen' => [ 124, 252, 0 ],
    'lemonchiffon' => [ 255, 250, 205 ],
    'lightblue' => [ 173, 216, 230 ],
    'lightcoral' => [ 240, 128, 128 ],
    'lightcyan' => [ 224, 255, 255 ],
    'lightgoldenrodyellow' => [ 250, 250, 210 ],
    'lightgray' => [ 211, 211, 211 ],
    'lightgreen' => [ 144, 238, 144 ],
    'lightgrey' => [ 211, 211, 211 ],
    'lightpink' => [ 255, 182, 193 ],
    'lightsalmon' => [ 255, 160, 122 ],
    'lightseagreen' => [ 32, 178, 170 ],
    'lightskyblue' => [ 135, 206, 250 ],
    'lightslategray' => [ 119, 136, 153 ],
    'lightslategrey' => [ 119, 136, 153 ],
    'lightsteelblue' => [ 176, 196, 222 ],
    'lightyellow' => [ 255, 255, 224 ],
    'lime' => [ 0, 255, 0 ],
    'limegreen' => [ 50, 205, 50 ],
    'linen' => [ 250, 240, 230 ],
    'magenta' => [ 255, 0, 255 ],
    'maroon' => [ 128, 0, 0 ],
    'mediumaquamarine' => [ 102, 205, 170 ],
    'mediumblue' => [ 0, 0, 205 ],
    'mediumorchid' => [ 186, 85, 211 ],
    'mediumpurple' => [ 147, 112, 219 ],
    'mediumseagreen' => [ 60, 179, 113 ],
    'mediumslateblue' => [ 123, 104, 238 ],
    'mediumspringgreen' => [ 0, 250, 154 ],
    'mediumturquoise' => [ 72, 209, 204 ],
    'mediumvioletred' => [ 199, 21, 133 ],
    'midnightblue' => [ 25, 25, 112 ],
    'mintcream' => [ 245, 255, 250 ],
    'mistyrose' => [ 255, 228, 225 ],
    'moccasin' => [ 255, 228, 181 ],
    'navajowhite' => [ 255, 222, 173 ],
    'navy' => [ 0, 0, 128 ],
    'oldlace' => [ 253, 245, 230 ],
    'olive' => [ 128, 128, 0 ],
    'olivedrab' => [ 107, 142, 35 ],
    'orange' => [ 255, 165, 0 ],
    'orangered' => [ 255, 69, 0 ],
    'orchid' => [ 218, 112, 214 ],
    'palegoldenrod' => [ 238, 232, 170 ],
    'palegreen' => [ 152, 251, 152 ],
    'paleturquoise' => [ 175, 238, 238 ],
    'palevioletred' => [ 219, 112, 147 ],
    'papayawhip' => [ 255, 239, 213 ],
    'peachpuff' => [ 255, 218, 185 ],
    'peru' => [ 205, 133, 63 ],
    'pink' => [ 255, 192, 203 ],
    'plum' => [ 221, 160, 221 ],
    'powderblue' => [ 176, 224, 230 ],
    'purple' => [ 128, 0, 128 ],
    'rebeccapurple' => [ 102, 51, 153 ],
    'red' => [ 255, 0, 0 ],
    'rosybrown' => [ 188, 143, 143 ],
    'royalblue' => [ 65, 105, 225 ],
    'saddlebrown' => [ 139, 69, 19 ],
    'salmon' => [ 250, 128, 114 ],
    'sandybrown' => [ 244, 164, 96 ],
    'seagreen' => [ 46, 139, 87 ],
    'seashell' => [ 255, 245, 238 ],
    'sienna' => [ 160, 82, 45 ],
    'silver' => [ 192, 192, 192 ],
    'skyblue' => [ 135, 206, 235 ],
    'slateblue' => [ 106, 90, 205 ],
    'slategray' => [ 112, 128, 144 ],
    'slategrey' => [ 112, 128, 144 ],
    'snow' => [ 255, 250, 250 ],
    'springgreen' => [ 0, 255, 127 ],
    'steelblue' => [ 70, 130, 180 ],
    'tan' => [ 210, 180, 140 ],
    'teal' => [ 0, 128, 128 ],
    'thistle' => [ 216, 191, 216 ],
    'tomato' => [ 255, 99, 71 ],
    'turquoise' => [ 64, 224, 208 ],
    'violet' => [ 238, 130, 238 ],
    'wheat' => [ 245, 222, 179 ],
    'white' => [ 255, 255, 255 ],
    'whitesmoke' => [ 245, 245, 245 ],
    'yellow' => [ 255, 255, 0 ],
    'yellowgreen' => [ 154, 205, 50 ]
  }.freeze

  COLOR_FN_NAMES = %w[rgb rgba hsl hsla hwb oklch oklab lab lch color].freeze
  UNRESOLVED_FN_NAMES = %w[oklch oklab lab lch hwb color color-mix].freeze
  # The CSS-wide keywords, the one list both value classification and the
  # token file's reserved layer names read.
  CSS_WIDE_KEYWORDS = %w[initial inherit unset revert revert-layer revert-rule].freeze
  GUARANTEED_INVALID_KEYWORDS = %w[initial inherit unset].freeze
  # A color space or hue-interpolation keyword, read only inside color()
  # and color-mix() (`in`, srgb, display-p3, shorter hue).
  COLOR_SPACE_KEYWORDS = %w[in srgb srgb-linear display-p3 a98-rgb prophoto-rgb rec2020
                            xyz xyz-d50 xyz-d65 hsl hwb lab lch oklab oklch
                            shorter longer increasing decreasing hue].to_set.freeze
  # The one list of identifiers a color value reads ASCII case-insensitively
  # (ColorCss.downcase_keywords): every function name this module knows,
  # every color keyword and CSS-wide keyword, and color-space keywords
  # inside the functions that take one. Any other identifier keeps its case.
  CASE_FOLDS = ColorCss::CaseFolds.new(
    functions: (COLOR_FN_NAMES + UNRESOLVED_FN_NAMES + %w[var light-dark url]).to_set.freeze,
    keywords: (NAMED.keys + %w[transparent currentcolor] + CSS_WIDE_KEYWORDS).to_set.freeze,
    within: { "color" => COLOR_SPACE_KEYWORDS, "color-mix" => COLOR_SPACE_KEYWORDS }.freeze
  )
  # The functions whose arguments a color value reads as colors.
  COLOR_ARG_FNS = (COLOR_FN_NAMES + UNRESOLVED_FN_NAMES + %w[light-dark]).uniq.freeze
  # Identifiers read case-insensitively as a color function's argument: a
  # color keyword, relative-color `from`, a `none` channel, and in color()
  # and color-mix() a color-space keyword.
  COLOR_ARG_KEYWORDS = (NAMED.keys + %w[transparent currentcolor from none]).to_set.freeze
  # The folds for a value that is not one color on its own: function names
  # and numeric tokens fold, and a bare identifier folds only as a color
  # function's argument. Anywhere else it may reach a case-sensitive
  # <custom-ident> after substitution (`1s RED` names keyframes, not a color).
  TOKEN_FOLDS = ColorCss::CaseFolds.new(
    functions: CASE_FOLDS.functions,
    keywords: ColorCss::EMPTY_SET,
    within: COLOR_ARG_FNS.to_h { |fn| [ fn, COLOR_ARG_KEYWORDS | CASE_FOLDS.within.fetch(fn, ColorCss::EMPTY_SET) ] }.freeze
  )

  module_function

  # Resolves one declaration value to a Result. decls is a Hash of
  # name => raw value text (custom properties visible in this context), used
  # only to follow a whole-value var() reference. seen tracks custom
  # property names already being resolved, to catch var() cycles.
  #
  # Escapes are decoded once here (ColorCss.decode_value_escapes), so every
  # anchored match below sees the name CSS sees: \76 ar(--x) is a var()
  # reference and \72 ed is red. A value whose escape has no plain spelling
  # is unresolved with that reason rather than guessed at. A whole-value
  # var() is recognized by its tokens before that decoding, and only the
  # branch CSS substitutes is decoded, so an escape in an unused fallback
  # never rejects the reference.
  #
  # The cycle check runs first, before any unsupported or unresolved early
  # return: a value whose var() dependency graph reaches a property already
  # being resolved puts that property in a cycle, whatever else the value
  # holds (color-mix(), oklch(), a nested fallback).
  #
  # One Resolver serves the whole call: it builds the var() dependency graph
  # lazily, finds cyclic properties with one Tarjan pass, and memoizes each
  # property's result, so a long chain of references costs linear time and
  # no deep Ruby recursion.
  def resolve(value, decls, seen: Set.new)
    Resolver.new(decls).resolve(value, seen)
  end

  # The body of resolve once the cycle check has passed: resolver picks the
  # branch a whole-value var() substitutes (Resolver#resolve_value), and the
  # text it lands on is parsed as a color.
  def resolve_with(value, resolver)
    resolver.resolve_value(value)
  end

  # A value that is not a whole-value var() parsed as a color.
  def resolve_text(value)
    v, escape_reason = ColorCss.decode_value_escapes(ColorCss.strip_ws(value))
    return Result.new(color: nil, reason: escape_reason) if escape_reason

    v = ColorCss.strip_ws(v)
    return Result.new(color: nil, reason: EMPTY_REASON) if v.empty?

    return hex_result(v) if v.match?(/\A#(?:\h{8}|\h{6}|\h{4}|\h{3})\z/)

    # Keywords and function names are ASCII case-insensitive (CSS Syntax 3),
    # never Unicode-folded as Ruby /i and String#downcase are, so a name
    # spelled with the Kelvin sign U+212A is not "black". key is v
    # ASCII-lowercased, the same length, so its offsets index v too.
    key = v.downcase(:ascii)
    if (m = key.match(/\Argba?\((.*)\)\z/m))
      return parse_rgb_function(v[m.begin(1)...m.end(1)])
    end

    if (m = key.match(/\Ahsla?\((.*)\)\z/m))
      return parse_hsl_function(v[m.begin(1)...m.end(1)])
    end

    return Result.new(color: Rgba.new(r: 0, g: 0, b: 0, a: 0.0), reason: nil) if key == "transparent"

    if (rgb = NAMED[key])
      return Result.new(color: Rgba.new(r: rgb[0], g: rgb[1], b: rgb[2], a: 1.0), reason: nil)
    end

    return Result.new(color: nil, reason: "unrecognized color value: #{v[0, 40]}") if key.start_with?("var(")

    return Result.new(color: nil, reason: 'currentColor depends on the element') if key == "currentcolor"
    return Result.new(color: nil, reason: 'light-dark() is not supported') if key.start_with?("light-dark(")

    if (m = key.match(/\A(#{UNRESOLVED_FN_NAMES.join('|')})\(/))
      fn = m[1]
      return Result.new(color: nil, reason: "#{fn}() is not resolved by this checker")
    end

    if (kw = css_wide_keyword(v))
      return Result.new(color: nil, reason: css_wide_reason(kw))
    end

    Result.new(color: nil, reason: "unrecognized color value: #{v[0, 40]}")
  end

  # True when value is one hex color, one named color other than
  # transparent and currentcolor, or one color function call whose
  # arguments contain no var(. Escapes are decoded first, as in resolve.
  def literal?(value)
    v = ColorCss.decode_value_escapes(ColorCss.strip_ws(value)).first
    v = v && ColorCss.strip_ws(v)
    return false if v.nil? || v.empty?
    return true if v.match?(/\A#(?:\h{8}|\h{6}|\h{4}|\h{3})\z/)

    if (m = v.match(/\A([A-Za-z]+)\((.*)\)\z/m))
      fn = m[1].downcase(:ascii)
      return false unless COLOR_FN_NAMES.include?(fn)

      return ColorCss.function_tokens(m[2]).none? { |t| t.name == "var" }
    end

    return false unless v.match?(/\A[A-Za-z]+\z/)

    name = v.downcase(:ascii)
    return false if name == 'transparent' || name == 'currentcolor'

    NAMED.key?(name)
  end

  # The CaseFolds a whole value is compared under: CASE_FOLDS when the
  # value is one color or CSS-wide keyword alone (sole_keyword?), so RED
  # and red or INHERIT and inherit agree, else TOKEN_FOLDS, which folds a
  # bare identifier only as a color function's own argument. A whole color
  # call such as oklch(from RED l c NONE) takes TOKEN_FOLDS too, so its
  # `from` and `none` fold while Foo(RED) nested in color-mix() keeps its
  # case: Foo may hand RED to a case-sensitive <custom-ident>.
  def case_folds(value)
    sole_keyword?(value) ? CASE_FOLDS : TOKEN_FOLDS
  end

  # True when value is one identifier CASE_FOLDS folds (a color or CSS-wide
  # keyword). Escapes are read as CSS reads them.
  def sole_keyword?(value)
    text = ColorCss.strip_ws(value)
    ColorCss.ident_char_at?(text, 0) && ColorCss.skip_ident_run(text, 0) == text.length && ColorCss.ident_start?(text) &&
      CASE_FOLDS.keywords.include?(ColorCss.decode_ident(text).downcase(:ascii))
  end

  # Composites a possibly translucent color over an opaque background.
  # Channels stay fractional so contrast grading sees the exact composite.
  def flatten(rgba, over:)
    f = rgba.a
    r = (rgba.r * f + over.r * (1 - f)).clamp(0, 255)
    g = (rgba.g * f + over.g * (1 - f)).clamp(0, 255)
    b = (rgba.b * f + over.b * (1 - f)).clamp(0, 255)
    Rgba.new(r:, g:, b:, a: 1.0)
  end

  def to_hex(rgba)
    format('#%02x%02x%02x', *[ rgba.r, rgba.g, rgba.b ].map { |c| c.round.clamp(0, 255) })
  end

  def contrast_ratio(a, b)
    la = relative_luminance(a)
    lb = relative_luminance(b)
    lighter = [ la, lb ].max
    darker = [ la, lb ].min
    (lighter + 0.05) / (darker + 0.05)
  end

  def relative_luminance(rgba)
    r, g, b = [ rgba.r, rgba.g, rgba.b ].map { |c| c / 255.0 }
    rl, gl, bl = [ r, g, b ].map { |c| c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4 }
    (0.2126 * rl) + (0.7152 * gl) + (0.0722 * bl)
  end

  # --- internal helpers below; still module_function so they are testable
  # as ColorValue.foo, but not part of the documented public API. ---

  def hex_result(v)
    h = v.delete_prefix('#')
    h = h.chars.map { |c| c * 2 }.join if h.length == 3 || h.length == 4
    r = h[0, 2].to_i(16)
    g = h[2, 2].to_i(16)
    b = h[4, 2].to_i(16)
    a = h.length == 8 ? (h[6, 2].to_i(16) / 255.0) : 1.0
    Result.new(color: Rgba.new(r:, g:, b:, a:), reason: nil)
  end

  # Parses a whole-value var(...) call into [name, fallback], or nil when
  # text is not one well-formed var() reference. Read off one var_calls
  # scan of the tokens, not decoded text, so an escaped spelling
  # such as \76 ar( is still var( while the fallback stays exactly as
  # written: it is decoded only if CSS substitutes it. fallback is nil only
  # when there is no comma at all; a comma followed by nothing (or
  # whitespace) is an empty fallback, "", which CSS treats as a valid empty
  # token sequence, not as an absent fallback.
  def parse_var_ref(text)
    text = ColorCss.strip_ws(text)
    call = whole_var_call(text, var_calls(text).to_h { |c| [ c.start, c ] }, 0...text.length)
    name, fallback = call && var_arguments(text, call, call.close)
    [ name, fallback && text[fallback] ] if name
  end

  # One var( call in a value, as offsets into the text it was scanned from:
  # its name token's start, its "(", its first top-level "," (nil when it
  # has none), its matching ")" (nil while unclosed), and the nearest var()
  # call it is nested in (nil at top level).
  VarCall = Struct.new(:start, :open, :comma, :close, :parent, keyword_init: true)

  # The var() call that is all of text[range], or nil. Its closing paren
  # must be the range's last character, so a value that is several
  # references in a row (var(--r) var(--g)) is not one reference.
  def whole_var_call(text, by_start, range)
    call = by_start[range.begin]
    call if call && call.close == range.end - 1
  end

  # Every var( call in text, from one ColorCss.scan_value pass, in source
  # order (an enclosing call before the calls nested in it). Open blocks
  # follow ColorCss.track_block, so a ")" or "," inside a nested [] or {}
  # block is an ordinary token that neither closes a call nor splits it.
  def var_calls(text)
    calls = []
    closers = [] # each open block's closer, as ColorCss.track_block keeps it
    owners = [] # each open block's VarCall, or nil for any other block
    open_vars = [] # the open VarCalls, innermost last
    ColorCss.scan_value(text) do |tok, i|
      if tok.is_a?(ColorCss::FunctionToken)
        next unless i

        call = VarCall.new(start: tok.start, open: i, parent: open_vars.last) if tok.name == "var"
        calls << call if call
        open_vars << call if call
        closers << ")"
        owners << call
      elsif tok == ","
        owners.last.comma ||= i if closers.last == ")" && owners.last
      else
        depth = closers.length
        ColorCss.track_block(closers, tok)
        if closers.length > depth
          owners << nil
        elsif closers.length < depth && (call = owners.pop)
          call.close = i
          open_vars.pop
        end
      end
    end
    calls
  end

  # The whole-value var() chain of text, walked once, without rescanning:
  # each var(name, fallback) whose fallback is itself one whole var() call
  # is one link. Yields [name, has_fallback] per link, outermost first, and
  # returns the text the chain ends on (the value itself when it is not a
  # var(), else the innermost fallback that is not one), or nil when the
  # last link has no fallback. Each link is found by its offsets into the
  # one scan of text, so a deeply nested fallback costs linear time and no
  # Ruby recursion.
  def var_chain(text)
    text = ColorCss.strip_ws(text)
    by_start = var_calls(text).to_h { |c| [ c.start, c ] }
    range = 0...text.length
    while (call = whole_var_call(text, by_start, range)) && (ref = var_arguments(text, call, call.close))
      yield ref[0], !ref[1].nil?
      return nil unless ref[1]

      range = ref[1]
    end
    text[range]
  end

  # The CSS-wide keyword a whole value is, ASCII case-insensitive and with
  # escapes decoded (INITIAL and \69 nitial are initial), or nil. The one
  # test both resolve and Resolver#fails? use, so a value the checker
  # reports as a keyword is the value it treats as one during substitution.
  def css_wide_keyword(value)
    v = ColorCss.decode_value_escapes(ColorCss.strip_ws(value)).first
    v = v && ColorCss.strip_ws(v).downcase(:ascii)
    v if CSS_WIDE_KEYWORDS.include?(v)
  end

  # The CSS-wide keyword a whole value is when that keyword makes a token
  # the guaranteed-invalid value, or nil. The token file declares every
  # custom property on the root element (:root and the dark block), and an
  # unregistered custom property there has no parent to inherit from, so
  # inherit and unset compute to its initial value, the guaranteed-invalid
  # value, exactly as initial does. revert, revert-layer and revert-rule
  # depend on the cascade the checker does not model, so they are not among them. The
  # one test resolve and Resolver#fails? use for a guaranteed-invalid
  # keyword.
  def guaranteed_invalid_keyword(value)
    kw = css_wide_keyword(value)
    kw if GUARANTEED_INVALID_KEYWORDS.include?(kw)
  end

  # Why a whole-value CSS-wide keyword is unresolved (see
  # guaranteed_invalid_keyword).
  def css_wide_reason(keyword)
    return "#{keyword} is the guaranteed-invalid value" if GUARANTEED_INVALID_KEYWORDS.include?(keyword)

    "#{keyword} depends on the cascade"
  end

  # The [name, fallback] of one var() call in text, ending at close (its
  # ")", or the end of text while unclosed), or nil when the first argument
  # is not a custom-property name. fallback is the stripped Range of text
  # after the first top-level comma, nil only when there is no comma at
  # all. The one place that splits name from fallback, so parse_var_ref,
  # var_chain and Resolver#substitution_fails? agree on what an empty
  # fallback is (see parse_var_ref).
  #
  # Only one identifier that decodes to a custom-property name, alone in
  # the first argument but for whitespace and comments
  # (ColorCss.sole_custom_property_ref), is a reference; var(foo), var(),
  # var(-x), var(--a b) and var(--a --b) are malformed, fallback or not,
  # and make the whole value invalid (see malformed_var).
  def var_arguments(text, call, close)
    name = ColorCss.sole_custom_property_ref(text[(call.open + 1)...(call.comma || close)])
    return nil unless name

    [ name, call.comma && ColorCss.ws_range(text, call.comma + 1, close) ]
  end

  # The source text of the first malformed var() call in text (see
  # var_arguments), nested fallbacks included, or nil when every var() is
  # well formed. Per css-variables-1 such a value is invalid at parse time:
  # the browser ignores the whole declaration, so it is never a dependency
  # source and never substitutes anything.
  def malformed_var(text)
    text = text.to_s
    call, = var_refs(text).find { |_, ref| ref.nil? }
    call && text[call.start..(call.close || (text.length - 1))]
  end

  # [call, var_arguments] for every var() call in text (var_calls), in
  # source order: the one structural read malformed_var and
  # var_dependencies share.
  def var_refs(text)
    var_calls(text).map { |call| [ call, var_arguments(text, call, call.close || text.length) ] }
  end

  def malformed_result(call_text)
    Result.new(color: nil, reason: "malformed #{call_text[0, 40]} makes the declaration invalid")
  end

  EMPTY_REASON = "empty value is not a color"

  def cycle_result(name)
    Result.new(color: nil, reason: "var() cycle through #{name}")
  end

  # Every custom-property name text depends on, directly or through the
  # declarations, in depth-first order. A var() anywhere counts (inside an
  # unused fallback, color-mix(), oklch() or any other function), per the
  # CSS Variables cycle rules. An undefined name is listed but not followed.
  # Iterative, so a long chain of references cannot overflow the stack.
  def dependency_closure(text, decls, found = [])
    walk_dependencies(var_dependencies(text), found) { |dep| decls.key?(dep) ? var_dependencies(decls[dep]) : [] }
  end

  # Depth-first preorder walk from roots, appending each newly reached name
  # to found; the block returns a name's own dependencies.
  def walk_dependencies(roots, found = [])
    listed = found.to_set
    stack = [ [ roots, 0 ] ]
    until stack.empty?
      frame = stack.last
      if frame[1] >= frame[0].size
        stack.pop
        next
      end
      dep = frame[0][frame[1]]
      frame[1] += 1
      next unless listed.add?(dep)

      found << dep
      stack << [ yield(dep), 0 ]
    end
    found
  end

  # The custom-property names each real var() call in text references
  # (var_refs), in order, or none at all when any var() in text is
  # malformed (malformed_var): the browser ignores that whole declaration,
  # so it has no dependency edges. Strings, longer idents such as évar( or
  # my-var( are not var() calls; an escaped spelling such as \var( or
  # v\61 r( is one, since CSS decodes escapes before matching. Each name is
  # decoded the same way (ColorCss.custom_property_name), so var(--\61)
  # depends on --a and is compared against seen and decls as such.
  def var_dependencies(text)
    refs = var_refs(text.to_s).map(&:last)
    refs.any?(&:nil?) ? [] : refs.map(&:first)
  end

  # One resolution context over a decls Hash: the var() dependency graph,
  # the set of cyclic properties, which properties compute to the
  # guaranteed-invalid value, and each property's resolved Result, all
  # computed at most once and only for properties the resolution reaches.
  #
  # Per CSS Variables, a custom property is guaranteed-invalid at
  # computed-value time when it is part of a var() cycle, or when its value
  # substitutes a var() whose property is undefined or guaranteed-invalid
  # and that var() has no fallback (or a fallback that itself fails). A
  # property whose value is empty, or substitutes an empty fallback, is
  # defined: its value is the empty token sequence, so a var() referencing
  # it takes that empty value and never its own fallback.
  class Resolver
    def initialize(decls)
      @decls = decls
      @refs = {}
      @deps = {}
      @results = {}
      @branches = {}
      @fails = {}
      @index = {}
      @low = {}
      @edges = {}
      @cyclic = Set.new
    end

    # A value whose var() dependency graph reaches a property already being
    # resolved (seen) puts that property in a cycle, whatever else the
    # value holds (color-mix(), oklch(), a nested fallback). Only this root
    # check needs seen: every property resolved below it is reached from
    # value and is not cyclic, so it can never reach a seen name, and its
    # result does not depend on seen, which is what makes it memoizable.
    def resolve(value, seen)
      if (bad = ColorValue.malformed_var(value))
        return ColorValue.malformed_result(bad)
      end

      hit = cycle_hit(value, seen)
      return ColorValue.cycle_result(hit) if hit

      ColorValue.resolve_with(value, self)
    end

    # The seen property value's var() dependency graph reaches, or nil. The
    # usual root check, a property's own value with seen holding just that
    # property, asks whether the property reaches itself, which is whether
    # it is cyclic; the memoized Tarjan pass answers that without walking
    # the graph again for every property resolved over the same chain. Any
    # other seen set walks the graph.
    def cycle_hit(value, seen)
      return nil if seen.empty?

      name = seen.first
      return (cyclic?(name) ? name : nil) if seen.size == 1 && @decls[name] == value

      roots = ColorValue.var_dependencies(value)
      ColorValue.walk_dependencies(roots) { |dep| deps(dep) }.find { |dep| seen.include?(dep) }
    end

    # value resolved: the branch CSS substitutes for its whole-value var()
    # chain (see branch), or the value itself parsed as a color.
    def resolve_value(value)
      resolve_branch(*branch(value))
    end

    # The Result of one branch (see branch).
    def resolve_branch(kind, target)
      case kind
      when :property then property(target)
      when :failed then failed_reference(target)
      else ColorValue.resolve_text(target)
      end
    end

    # Which branch of value's whole-value var() chain (ColorValue.var_chain)
    # CSS substitutes, picked by one loop over the chain's links:
    # [:property, name] for the first referenced property that is defined
    # and does not fail, [:failed, name] for a failing reference with no
    # fallback, or [:text, text] for the text the chain ends on.
    #
    # A cyclic referenced property is invalid and the var()'s fallback
    # applies (resolve has already ruled out a cycle through the referencing
    # property). An undefined name, or a defined one that computes to the
    # guaranteed-invalid value, is rescued by a fallback too, even an empty
    # one; any other defined property is substituted as it is, empty value
    # included, and the fallback is ignored. A fallback stays raw text until
    # it is the branch chosen, so only then is it decoded (resolve_text).
    def branch(value)
      tail = ColorValue.var_chain(value) do |name, has_fallback|
        return [ :property, name ] if declared?(name) && !fails?(name)
        return [ :failed, name ] unless has_fallback
      end
      [ :text, tail ]
    end

    # The Result of var(name) with no fallback when name fails.
    def failed_reference(name)
      return Result.new(color: nil, reason: "#{name} is ignored: its value holds a malformed var()") if @decls.key?(name) && !declared?(name)
      return Result.new(color: nil, reason: "#{name} is not defined in this theme") unless declared?(name)
      return ColorValue.cycle_result(name) if cyclic?(name)
      if (kw = ColorValue.guaranteed_invalid_keyword(@decls[name]))
        return Result.new(color: nil, reason: "#{name} is #{kw}, the guaranteed-invalid value")
      end

      property(name)
    end

    # True when var(name) with no fallback fails: name is undefined, cyclic,
    # its whole value is initial, inherit or unset (the guaranteed-invalid
    # value; see ColorValue.guaranteed_invalid_keyword), or its value substitutes a failing
    # var(). Computed in dependency post-order with an explicit stack; the
    # non-cyclic part of the graph is acyclic, so every dependency is
    # settled before its dependent.
    def fails?(name)
      stack = [ [ name, false ] ]
      until stack.empty?
        n, expanded = stack.pop
        next if @fails.key?(n)

        if !declared?(n) || cyclic?(n) || ColorValue.guaranteed_invalid_keyword(@decls[n])
          @fails[n] = true
        elsif expanded
          @fails[n] = substitution_fails?(@decls[n].to_s)
        else
          stack << [ n, true ]
          deps(n).each { |d| stack << [ d, false ] unless @fails.key?(d) }
        end
      end
      @fails[name]
    end

    def cyclic?(name)
      tarjan(name) if declared?(name) && !@index.key?(name)
      @cyclic.include?(name)
    end

    # The var() dependencies of a defined property, or none for an undefined
    # one.
    def deps(name)
      @deps[name] ||= declared?(name) ? refs(name).map { |_, ref| ref[0] } : []
    end

    # True when name has a declaration the browser keeps: one whose value
    # holds a malformed var() (ColorValue.malformed_var) is ignored at parse
    # time, as if it were never written, so it is undefined here too.
    def declared?(name)
      @decls.key?(name) && refs(name).none? { |_, ref| ref.nil? }
    end

    private

    # A defined property's Result, memoized. A run of properties each
    # substituting the next (--a: var(--b); --b: var(--x, var(--c)); ...,
    # whichever branch is chosen) is resolved from its far end first, so
    # each step finds the next one already memoized and the Ruby stack
    # stays shallow however long the chain is.
    def property(name)
      return @results[name] if @results.key?(name)

      chain = [ name ]
      loop do
        kind, nxt = decl_branch(chain.last)
        break unless kind == :property && !@results.key?(nxt)

        chain << nxt
      end
      chain.reverse_each { |n| @results[n] ||= resolve_branch(*decl_branch(n)) }
      @results[name]
    end

    # ColorValue.var_refs of a declared name's value, scanned once.
    def refs(name)
      @refs[name] ||= ColorValue.var_refs(@decls[name].to_s)
    end

    def decl_branch(name)
      @branches[name] ||= branch(@decls[name])
    end

    # True when substituting every var() in text fails: a var() whose name
    # fails (see fails?) with no fallback, or with a fallback that itself
    # fails. A var() nested in another's fallback is only reached through
    # that fallback. An empty fallback substitutes nothing and never fails.
    #
    # One scan (ColorValue.var_calls) finds every call; they are settled
    # innermost first in reverse source order, so each call's fallback
    # verdict is known before the call itself, with no recursion per
    # nesting level. Every name is a dependency fails? has already settled.
    def substitution_fails?(text)
      fallback_fails = {}
      failing = false
      ColorValue.var_calls(text).reverse_each do |call|
        ref = ColorValue.var_arguments(text, call, call.close || text.length)
        fails = ref.nil? || (fails?(ref[0]) && (ref[1].nil? || fallback_fails.fetch(call.start, false)))
        parent = call.parent
        if parent.nil?
          failing ||= fails
        elsif parent.comma && call.start > parent.comma
          fallback_fails[parent.start] ||= fails
        end
      end
      failing
    end

    # Iterative Tarjan strongly-connected-components pass from root over
    # defined properties; a component of two or more, or one property that
    # references itself, is a cycle. Every property it visits is settled.
    def tarjan(root)
      open = []
      on_open = Set.new
      work = []
      enter = lambda do |n|
        @index[n] = @low[n] = @index.size
        open << n
        on_open << n
        work << [ n, 0 ]
      end
      enter.call(root)
      until work.empty?
        frame = work.last
        node = frame[0]
        edges = (@edges[node] ||= deps(node).select { |d| declared?(d) })
        if frame[1] < edges.size
          nxt = edges[frame[1]]
          frame[1] += 1
          if !@index.key?(nxt)
            enter.call(nxt)
          elsif on_open.include?(nxt)
            @low[node] = [ @low[node], @index[nxt] ].min
          end
          next
        end

        work.pop
        @low[work.last[0]] = [ @low[work.last[0]], @low[node] ].min unless work.empty?
        next unless @low[node] == @index[node]

        component = []
        loop do
          n = open.pop
          on_open.delete(n)
          component << n
          break if n == node
        end
        @cyclic.merge(component) if component.size > 1 || edges.include?(node)
      end
    end
  end

  def invalid_value(args)
    Result.new(color: nil, reason: "unrecognized color value: #{ColorCss.strip_ws(args)[0, 40]}")
  end

  # Strict CSS <number> and <percentage> grammar, read by the one numeric
  # lexer (ColorCss.numeric_token): a bare numeric literal, optionally signed
  # and fractional, with an optional exponent. Anything else (a stray
  # identifier, a dimension, empty text) is not a number, and must never
  # silently become 0 via String#to_f.
  def parse_number(token)
    tok = numeric_token(token, :number)
    tok && finite_or_nil(tok.number.to_f)
  end

  # text's one numeric token (ColorCss.numeric_token) when it has one of
  # types, else nil.
  def numeric_token(text, *types)
    tok = ColorCss.numeric_token(ColorCss.strip_ws(text))
    tok if tok && types.include?(tok.type)
  end

  # An exponent such as 1e999 overflows to Infinity; a non-finite value is
  # not a usable number and must not reach rounding or arithmetic.
  def finite_or_nil(value)
    value.finite? ? value : nil
  end

  # A percentage's number, or nil. 50\25 is a dimension with unit %, never
  # a percentage.
  def parse_percentage(token)
    tok = numeric_token(token, :percentage)
    tok && finite_or_nil(tok.number.to_f)
  end

  # Legacy comma syntax (rgb(1, 2, 3)) requires all three channels to be the
  # same kind, number or percentage; a modern space-separated channel list
  # has no such restriction in this checker. Returns [raw_parts, alpha_text,
  # legacy]: the unparsed channel tokens, the raw alpha token text (or nil),
  # and whether legacy comma syntax was used.
  def extract_channels_and_alpha(args)
    main, slash, alpha_part = args.partition('/')
    if slash.empty?
      comma_parts = ColorCss.split_top_level(args)
      if comma_parts.size > 1
        parts = comma_parts.map { |p| ColorCss.strip_ws(p) }
        return [ parts[0, 3], parts[3], true ] if parts.size == 4

        [ parts, nil, true ]
      else
        # Modern space syntax has no comma-based 4th-argument alpha: alpha
        # must be introduced with '/'. A bare 4th space-separated token is
        # invalid syntax, not a guessed alpha, so it is left in place for the
        # channel-count check in the caller to reject.
        parts = ColorCss.split_ws(args)
        [ parts, nil, false ]
      end
    else
      channel_str = ColorCss.strip_ws(main)
      comma_parts = ColorCss.split_top_level(channel_str)
      # Slash alpha is modern space syntax only; legacy comma channels with a
      # slash alpha (rgb(255, 0, 0 / 50%)) are invalid, not a mixed form.
      return [ [], nil, false ] if comma_parts.size > 1

      parts = ColorCss.split_ws(channel_str)
      [ parts, ColorCss.strip_ws(alpha_part), false ]
    end
  end

  def parse_rgb_function(args)
    channels, alpha_tok, legacy = extract_channels_and_alpha(args)
    return invalid_value(args) unless channels.size == 3

    parsed = channels.map { |t| parse_channel(t) }
    return invalid_value(args) if parsed.any?(&:nil?)

    if legacy && parsed.map(&:last).uniq.size > 1
      return Result.new(color: nil, reason: 'rgb() channels must be all numbers or all percentages')
    end

    r, g, b = parsed.map(&:first)

    a = 1.0
    if alpha_tok
      a = parse_alpha(alpha_tok)
      return invalid_value(args) unless a
    end

    Result.new(color: Rgba.new(r:, g:, b:, a:), reason: nil)
  end

  def parse_hsl_function(args)
    channels, alpha_tok, = extract_channels_and_alpha(args)
    return invalid_value(args) unless channels.size == 3

    h = parse_hue(channels[0])
    return Result.new(color: nil, reason: "invalid hue: #{ColorCss.strip_ws(channels[0])[0, 40]}") unless h

    s = parse_percent_fraction(channels[1])
    return invalid_value(args) unless s

    l = parse_percent_fraction(channels[2])
    return invalid_value(args) unless l

    a = 1.0
    if alpha_tok
      a = parse_alpha(alpha_tok)
      return invalid_value(args) unless a
    end

    r, g, b = hsl_to_rgb(h, s, l)
    Result.new(color: Rgba.new(r:, g:, b:, a:), reason: nil)
  end

  # Hue accepts a bare number (treated as deg) or a dimension whose unit,
  # escapes decoded and ASCII case folded, is an angle unit (0d\65 g and
  # 0\44 EG are 0deg); anything else is not a valid hue and must not
  # silently become 0.
  def parse_hue(text)
    tok = numeric_token(text, :number, :dimension)
    return nil unless tok

    unit = tok.unit&.downcase(:ascii)
    return nil unless unit.nil? || HUE_UNITS.include?(unit)

    num = finite_or_nil(tok.number.to_f)
    return nil unless num

    # Unit conversion can overflow a finite literal (1e308turn), so the
    # converted angle is checked again before it reaches % 360.
    return nil unless finite_or_nil(num * HUE_SCALE.fetch(unit, 1))

    # Like rgb() channels, the angle stays exact (Rational) so equal colors
    # spelled in deg, grad or turn share a key; rad involves pi and is inexact.
    return finite_or_nil(num * 180.0 / Math::PI)&.to_r if unit == "rad"

    exact_hue(tok.number, HUE_SCALE.fetch(unit, 1))
  end

  # Reduces a hue literal modulo a full turn exactly, without building the
  # full power of ten, so 1e33deg and its expanded integer give one hue.
  # The value is mantissa * 10**exp * scale; with scale = p/q, the
  # numerator is reduced mod 360 * q and divided by q. A negative exponent
  # leaves a value bounded_rational keeps exact.
  def exact_hue(number, scale)
    m = number.match(/\A([+-]?)(\d*)\.?(\d*)(?:[eE]([+-]?\d+))?\z/)
    return nil if m[4] && m[4].delete("+-").length > MAX_EXPONENT_DIGITS

    exp = m[4].to_i - m[3].length
    return bounded_rational(number) * scale if exp.negative?

    mantissa = "#{m[1]}#{m[2]}#{m[3]}".to_i * scale.numerator
    modulus = 360 * scale.denominator
    Rational((mantissa % modulus) * 10.pow(exp, modulus) % modulus, scale.denominator)
  end

  MAX_EXPONENT_DIGITS = 18

  HUE_SCALE = { "grad" => Rational(9, 10), "turn" => Rational(360) }.freeze
  HUE_UNITS = %w[deg grad rad turn].freeze

  # Saturation and lightness must be percentages; a bare number here is
  # invalid CSS, not a 0..1 fraction to guess at.
  def parse_percent_fraction(text)
    tok = numeric_token(text, :percentage)
    return nil unless tok && finite_or_nil(tok.number.to_f)

    (bounded_rational(tok.number) / 100).clamp(0, 1)
  end

  # Returns [value 0..255, :num|:pct], or nil if text is not a valid number
  # or percentage. The value stays fractional so contrast sees the exact
  # channel; rounding is for display only.
  # Like alpha, a channel is scaled exactly (Rational) and converted to Float
  # once, so 33.3% and 84.915 land on the same Float and share a palette key.
  def parse_channel(text)
    tok = numeric_token(text, :number, :percentage)
    return nil unless tok && finite_or_nil(tok.number.to_f)

    if tok.type == :percentage
      # 1e308% overflows when scaled to 0..255; recheck after conversion.
      return unless finite_or_nil(tok.number.to_f / 100.0 * 255.0)

      [ (bounded_rational(tok.number) * 255 / 100).clamp(0, 255).to_f, :pct ]
    else
      [ bounded_rational(tok.number).clamp(0, 255).to_f, :num ]
    end
  end

  # Alpha is parsed exactly (Rational) and converted to Float once, so every
  # spelling of the same value (.333, 0.333, 33.3%, 3.33e1%) lands on the
  # same Float and shares one palette key.
  def parse_alpha(text)
    tok = numeric_token(text, :number, :percentage)
    return nil unless tok

    exact = bounded_rational(tok.number)
    exact /= 100 if tok.type == :percentage
    exact.clamp(0, 1).to_f
  end

  # Rational("1e999999999") builds a giant integer before any clamp, so an
  # exponent past this bound is parsed via Float instead. The bound sits
  # past Float range in both directions (10**400 is still cheap to build),
  # so every exponent a Float could carry stays exact and 1e-33deg equals
  # its expanded decimal. Past it a value clamps to 0 or 1 (or is a hue
  # step far below any channel's resolution), so exactness is not needed;
  # an infinite Float keeps its sign so it still clamps the way the exact
  # value would.
  MAX_EXACT_EXPONENT = 400

  def bounded_rational(number)
    exp = number[/[eE]([+-]?\d+)\z/, 1].to_i
    return Rational(number) if exp.abs <= MAX_EXACT_EXPONENT

    float = number.to_f
    float.finite? ? float.to_r : Rational(float.positive? ? 10**MAX_EXACT_EXPONENT : -(10**MAX_EXACT_EXPONENT))
  end

  def hsl_to_rgb(h, s, l)
    # h, s and l are Rational; the arithmetic stays exact and converts to
    # Float once at the end, like parse_channel, so hsl() and rgb() spellings
    # of one color land on the same Float.
    hue = h.to_r % 360
    sat = s.to_r.clamp(0, 1)
    lum = l.to_r.clamp(0, 1)
    c = (1 - ((2 * lum) - 1).abs) * sat
    x = c * (1 - (((hue / 60) % 2) - 1).abs)
    m = lum - (c / 2)
    r1, g1, b1 =
      case hue
      when 0...60 then [ c, x, 0 ]
      when 60...120 then [ x, c, 0 ]
      when 120...180 then [ 0, c, x ]
      when 180...240 then [ 0, x, c ]
      when 240...300 then [ x, 0, c ]
      else [ c, 0, x ]
      end
    # Channels stay fractional; only display (to_hex) rounds.
    [ r1, g1, b1 ].map { |ch| ((ch + m) * 255).clamp(0, 255).to_f }
  end
end
