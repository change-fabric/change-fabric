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

  CUSTOM_PROPERTY_NAME = /\A--[\w-]+\z/.freeze
  COLOR_FN_NAMES = %w[rgb rgba hsl hsla hwb oklch oklab lab lch color].freeze
  UNRESOLVED_FN_NAMES = %w[oklch oklab lab lch hwb color color-mix].freeze
  CASCADE_KEYWORDS = %w[inherit initial unset revert revert-layer].freeze
  # A real var( function token: not the tail of a longer ident (xvar(, my-var(,
  # _var(, 2var() and not an escaped name (\var(). CSS names are ASCII
  # case-insensitive, so VAR( counts.
  VAR_CALL = /(?<![-\w\\])var\(/i.freeze

  module_function

  # Resolves one declaration value to a Result. decls is a Hash of
  # name => raw value text (custom properties visible in this context), used
  # only to follow a whole-value var() reference. seen tracks custom
  # property names already being resolved, to catch var() cycles.
  def resolve(value, decls, seen: Set.new)
    v = value.to_s.strip
    return Result.new(color: nil, reason: 'unrecognized color value: ') if v.empty?

    return hex_result(v) if v.match?(/\A#(?:\h{8}|\h{6}|\h{4}|\h{3})\z/)

    if (m = v.match(/\Argba?\((.*)\)\z/im))
      return parse_rgb_function(m[1])
    end

    if (m = v.match(/\Ahsla?\((.*)\)\z/im))
      return parse_hsl_function(m[1])
    end

    return Result.new(color: Rgba.new(r: 0, g: 0, b: 0, a: 0.0), reason: nil) if v.match?(/\Atransparent\z/i)

    if v.match?(/\A[A-Za-z]+\z/) && NAMED.key?(v.downcase)
      rgb = NAMED[v.downcase]
      return Result.new(color: Rgba.new(r: rgb[0], g: rgb[1], b: rgb[2], a: 1.0), reason: nil)
    end

    return resolve_var(v, decls, seen) if v.match?(/\Avar\(/i)

    return Result.new(color: nil, reason: 'currentColor depends on the element') if v.match?(/\AcurrentColor\z/i)
    return Result.new(color: nil, reason: 'light-dark() is not supported') if v.match?(/\Alight-dark\(/i)

    if (m = v.match(/\A(#{UNRESOLVED_FN_NAMES.join('|')})\(/i))
      fn = m[1].downcase
      return Result.new(color: nil, reason: "#{fn}() is not resolved by this checker")
    end

    if (m = v.match(/\A(#{CASCADE_KEYWORDS.join('|')})\z/i))
      kw = m[1].downcase
      return Result.new(color: nil, reason: "#{kw} depends on the cascade")
    end

    Result.new(color: nil, reason: "unrecognized color value: #{v[0, 40]}")
  end

  # True when value is one hex color, one named color other than
  # transparent and currentcolor, or one color function call whose
  # arguments contain no var(.
  def literal?(value)
    v = value.to_s.strip
    return false if v.empty?
    return true if v.match?(/\A#(?:\h{8}|\h{6}|\h{4}|\h{3})\z/)

    if (m = v.match(/\A([A-Za-z]+)\((.*)\)\z/m))
      fn = m[1].downcase
      return false unless COLOR_FN_NAMES.include?(fn)

      return !strip_css_strings(m[2]).match?(VAR_CALL)
    end

    return false unless v.match?(/\A[A-Za-z]+\z/)

    name = v.downcase
    return false if name == 'transparent' || name == 'currentcolor'

    NAMED.key?(name)
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

  # Parses the inside of a var(...) call into [name, fallback], or nil when
  # text is not a well-formed var() reference. fallback is nil when absent or
  # blank.
  def parse_var_ref(text)
    m = text.match(/\Avar\(\s*(.*)\)\z/im)
    return nil unless m
    # The closing paren must belong to this var( itself, so a value that is
    # several references in a row (var(--r) var(--g)) is not one reference.
    return nil unless matching_paren(text, 3) == text.length - 1

    parts = ColorCss.split_top_level(m[1])
    name = parts[0]&.strip
    fallback = parts.size > 1 ? parts[1..].join(',').strip : nil
    fallback = nil if fallback && fallback.empty?

    # Only a custom-property name (the same --name grammar ColorCss parses
    # declarations with) is a reference; var(foo), var(), var(-x) and
    # var(--a b) are malformed and stay unresolved, fallback or not.
    return nil unless name&.match?(CUSTOM_PROPERTY_NAME)

    [ name, fallback ]
  end

  # A custom property that is part of a var() dependency cycle is
  # guaranteed-invalid at computed-value time per CSS Variables, regardless
  # of any fallback written on a var() reference inside that cycle, so the
  # cycle check below runs before the fallback is ever consulted. A fallback
  # does rescue an undefined name, and a defined name whose value computes to
  # the guaranteed-invalid value (see guaranteed_invalid?).
  def resolve_var(v, decls, seen)
    ref = parse_var_ref(v)
    return Result.new(color: nil, reason: "unrecognized color value: #{v[0, 40]}") unless ref

    name, fallback = ref
    return Result.new(color: nil, reason: "var() cycle through #{name}") if seen.include?(name)
    if decls.key?(name)
      result = resolve(decls[name], decls, seen: seen + [ name ])
      if result.color && fallback && (hit = fallback_cycle(fallback, decls, seen))
        return Result.new(color: nil, reason: "var() cycle through #{hit}")
      end
      return result unless fallback && result.color.nil? && guaranteed_invalid?(result.reason, seen)

      return resolve(fallback, decls, seen:)
    end

    return Result.new(color: nil, reason: "#{name} is not defined in this theme") unless fallback

    resolve(fallback, decls, seen:)
  end

  # A var() inside a fallback is a dependency even when the fallback goes
  # unused (CSS Variables cycle rules), so a defined reference that resolved
  # still closes a cycle when any name in its fallback, followed through the
  # declarations, reaches a property already being resolved. Returns that
  # name, or nil.
  def fallback_cycle(text, decls, seen, visited = Set.new)
    strip_css_strings(text).scan(/#{VAR_CALL}\s*(--[^\s,()]+)/).flatten.each do |dep|
      return dep if seen.include?(dep)
      next if visited.include?(dep) || !decls.key?(dep)

      visited << dep
      hit = fallback_cycle(decls[dep], decls, seen, visited)
      return hit if hit
    end
    nil
  end

  # True when a failed substitution left the referenced property with the
  # guaranteed-invalid value (an undefined name with no fallback, or a cycle
  # the current reference is not itself part of), so the referencing var()'s
  # own fallback applies. A cycle through a name already in seen means the
  # referencing property is inside the cycle and stays invalid.
  def guaranteed_invalid?(reason, seen)
    return true if reason.to_s.end_with?(' is not defined in this theme')

    m = reason.to_s.match(/\Avar\(\) cycle through (\S+)\z/)
    !m.nil? && !seen.include?(m[1])
  end

  # Replaces the contents of every CSS string (single or double quoted,
  # backslash escapes honored) with nothing, keeping the quotes, so a scan
  # for var( or parentheses never matches text inside a string. Strings do
  # not create custom-property dependencies.
  def strip_css_strings(text)
    text.to_s.gsub(/"(?:[^"\\]|\\.)*"?|'(?:[^'\\]|\\.)*'?/m) { |str| str[0] * 2 }
  end

  # Finds the paren closing the one at open_idx, skipping any paren inside a
  # CSS string.
  def matching_paren(text, open_idx)
    level = 0
    in_string = nil
    escaped = false
    (open_idx...text.length).each do |j|
      ch = text[j]
      if in_string
        if escaped then escaped = false
        elsif ch == "\\" then escaped = true
        elsif ch == in_string then in_string = nil
        end
        next
      end
      case ch
      when '"', "'" then in_string = ch
      when '(' then level += 1
      when ')'
        level -= 1
        return j if level.zero?
      end
    end
    nil
  end

  def invalid_value(args)
    Result.new(color: nil, reason: "unrecognized color value: #{args.to_s.strip[0, 40]}")
  end

  # Strict CSS <number> and <percentage> grammar: a bare numeric literal,
  # optionally signed and fractional, with an optional exponent. Anything
  # else (a stray identifier, empty text) is not a number, and must never
  # silently become 0 via String#to_f.
  NUMBER_RE = /[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?/

  def parse_number(token)
    t = token.to_s.strip
    return nil unless t.match?(/\A#{NUMBER_RE}\z/)

    finite_or_nil(t.to_f)
  end

  # An exponent such as 1e999 overflows to Infinity; a non-finite value is
  # not a usable number and must not reach rounding or arithmetic.
  def finite_or_nil(value)
    value.finite? ? value : nil
  end

  def parse_percentage(token)
    t = token.to_s.strip
    m = t.match(/\A(#{NUMBER_RE})%\z/)
    return nil unless m

    finite_or_nil(m[1].to_f)
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
        parts = comma_parts.map(&:strip)
        return [ parts[0, 3], parts[3], true ] if parts.size == 4

        [ parts, nil, true ]
      else
        # Modern space syntax has no comma-based 4th-argument alpha: alpha
        # must be introduced with '/'. A bare 4th space-separated token is
        # invalid syntax, not a guessed alpha, so it is left in place for the
        # channel-count check in the caller to reject.
        parts = args.strip.split(/\s+/).reject(&:empty?)
        [ parts, nil, false ]
      end
    else
      channel_str = main.strip
      comma_parts = ColorCss.split_top_level(channel_str)
      # Slash alpha is modern space syntax only; legacy comma channels with a
      # slash alpha (rgb(255, 0, 0 / 50%)) are invalid, not a mixed form.
      return [ [], nil, false ] if comma_parts.size > 1

      parts = channel_str.split(/\s+/).reject(&:empty?)
      [ parts, alpha_part.strip, false ]
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
    return Result.new(color: nil, reason: "invalid hue: #{channels[0].strip[0, 40]}") unless h

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

  # Hue accepts a bare number (treated as deg) or an explicit angle unit;
  # anything else is not a valid hue and must not silently become 0.
  def parse_hue(text)
    t = text.to_s.strip
    m = t.match(/\A(#{NUMBER_RE})(deg|grad|rad|turn)?\z/i)
    return nil unless m

    num = finite_or_nil(m[1].to_f)
    return nil unless num

    # Unit conversion can overflow a finite literal (1e308turn), so the
    # converted angle is checked again before it reaches % 360.
    unit = m[2]&.downcase
    return nil unless finite_or_nil(num * HUE_SCALE.fetch(unit, 1))

    # Like rgb() channels, the angle stays exact (Rational) so equal colors
    # spelled in deg, grad or turn share a key; rad involves pi and is inexact.
    return finite_or_nil(num * 180.0 / Math::PI)&.to_r if unit == "rad"

    bounded_rational(m[1]) * HUE_SCALE.fetch(unit, 1)
  end

  HUE_SCALE = { "grad" => Rational(9, 10), "turn" => 360 }.freeze

  # Saturation and lightness must be percentages; a bare number here is
  # invalid CSS, not a 0..1 fraction to guess at.
  def parse_percent_fraction(text)
    pct = parse_percentage(text.to_s.strip)
    return nil unless pct

    (bounded_rational(text.to_s.strip.chomp("%")) / 100).clamp(0, 1)
  end

  # Returns [value 0..255, :num|:pct], or nil if text is not a valid number
  # or percentage. The value stays fractional so contrast sees the exact
  # channel; rounding is for display only.
  # Like alpha, a channel is scaled exactly (Rational) and converted to Float
  # once, so 33.3% and 84.915 land on the same Float and share a palette key.
  def parse_channel(text)
    t = text.to_s.strip
    if (pct = parse_percentage(t))
      # 1e308% overflows when scaled to 0..255; recheck after conversion.
      return unless finite_or_nil(pct / 100.0 * 255.0)

      [ (bounded_rational(t.chomp("%")) * 255 / 100).clamp(0, 255).to_f, :pct ]
    elsif parse_number(t)
      [ bounded_rational(t).clamp(0, 255).to_f, :num ]
    end
  end

  # Alpha is parsed exactly (Rational) and converted to Float once, so every
  # spelling of the same value (.333, 0.333, 33.3%, 3.33e1%) lands on the
  # same Float and shares one palette key.
  def parse_alpha(text)
    t = text.to_s.strip
    exact =
      if (m = t.match(/\A(#{NUMBER_RE})%\z/))
        bounded_rational(m[1])&./(100)
      elsif t.match?(/\A#{NUMBER_RE}\z/)
        bounded_rational(t)
      end
    exact&.clamp(0, 1)&.to_f
  end

  # Rational("1e999999999") builds a giant integer before any clamp, so an
  # exponent past this bound is parsed via Float instead. Such a value
  # clamps to 0 or 1, so exactness is not needed there; an infinite Float
  # keeps its sign so it still clamps the way the exact value would.
  MAX_EXACT_EXPONENT = 32

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
