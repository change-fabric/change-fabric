# frozen_string_literal: true

require 'set'
require_relative 'color_value'

# Tokenizes a class/className attribute value or an @apply prelude into
# Tailwind utilities and classifies each color utility. One Entry per color
# utility; its text is the original utility, variants included. status is
# :finding (a palette, black/white or bracket color literal), :exempt
# (current/transparent/inherit, or a word or var() naming a declared token)
# or :unresolved (an unknown color word or an undeclared var()).
module ColorTailwind
  Entry = Data.define(:text, :status, :reason)

  PREFIXES = %w[
    bg text border border-x border-y border-t border-r border-b border-l border-s border-e
    ring ring-offset outline divide shadow inset-shadow inset-ring drop-shadow
    from via to fill stroke decoration accent caret placeholder
  ].sort_by { |p| -p.length }.freeze
  HUES = %w[
    slate gray zinc neutral stone red orange amber yellow lime green emerald
    teal cyan sky blue indigo violet purple fuchsia pink rose
  ].freeze
  PALETTE = /\A(?:#{HUES.join('|')})-\d{2,3}\z|\A(?:black|white)\z/.freeze
  EXEMPT_WORDS = %w[current transparent inherit].freeze
  NON_COLOR_WORDS = Set.new(%w[
    xs sm md base lg xl 2xl 3xl 4xl 5xl 6xl 7xl 8xl 9xl left right center justify
    start end wrap nowrap clip ellipsis balance pretty none solid dashed dotted
    double hidden inner offset px
  ]).freeze
  NUMERIC = /\A\d+(?:\.\d+)?%?\z/.freeze
  VAR_REF = /\Avar\((--[\w-]+)\)\z/.freeze
  UNKNOWN_WORD_REASON = 'unknown Tailwind color word'
  UNDECLARED_VAR_REASON = 'var() names no declared token'

  module_function

  # value: the raw attribute or prelude text. tokens: the set of custom
  # property names ("--brand") declared in the loaded token file.
  def findings(value, tokens: Set.new)
    value.to_s.split(/[ \t\r\n\f]+/).filter_map { |utility| classify(utility, tokens) }
  end

  def classify(utility, tokens)
    core = strip_opacity(strip_variants(utility.delete_prefix('!').delete_suffix('!')))
    prefix = PREFIXES.find { |p| core.start_with?("#{p}-") }
    return nil unless prefix

    status, reason = classify_rest(core.delete_prefix("#{prefix}-"), tokens)
    status && Entry.new(text: utility, status:, reason:)
  end

  def classify_rest(rest, tokens)
    return [ :finding ] if PALETTE.match?(rest)
    return bracket(rest[1...-1], tokens) if rest.start_with?('[') && rest.end_with?(']')
    return [ :exempt ] if EXEMPT_WORDS.include?(rest)
    return nil if NON_COLOR_WORDS.include?(rest) || NUMERIC.match?(rest)
    return [ :exempt ] if tokens.include?("--#{rest}")

    [ :unresolved, UNKNOWN_WORD_REASON ]
  end

  def bracket(inner, tokens)
    content = inner.tr('_', ' ').sub(/\Acolor:/i, '').strip
    return [ :finding ] if ColorValue.literal?(content)

    ref = content.match(VAR_REF)
    return nil unless ref
    return [ :exempt ] if tokens.include?(ref[1])

    [ :unresolved, UNDECLARED_VAR_REASON ]
  end

  # Drops every variant prefix up to the last ":" outside [...].
  def strip_variants(utility)
    cut = last_top_level(utility, ':')
    cut ? utility[(cut + 1)..] : utility
  end

  def strip_opacity(core)
    cut = last_top_level(core, '/')
    cut ? core[0...cut] : core
  end

  def last_top_level(text, char)
    depth = 0
    found = nil
    text.each_char.with_index do |c, i|
      case c
      when '[' then depth += 1
      when ']' then depth -= 1 if depth.positive?
      when char then found = i if depth.zero?
      end
    end
    found
  end
end
