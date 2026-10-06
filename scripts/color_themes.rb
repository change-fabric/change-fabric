#!/usr/bin/env ruby
# frozen_string_literal: true

require 'set'
require_relative 'color_css'

# Classifies a parsed CSS sheet's custom-property declarations into a light
# base context and named theme variants (data-theme attributes, class
# strategies, prefers-color-scheme media queries, and the bare shadcn/ui
# .X {} shape), and resolves each variant's effective declarations by the
# real CSS cascade: importance, then cascade-layer order (unlayered above
# every layer, layers ordered by first declaration), then selector
# specificity, then source order. Any context the model declines to merge is
# recorded as unsupported with a reason. Never raises; a sheet that uses no
# recognized theme form simply yields a base variant and whatever unsupported
# contexts its text-role tokens fall into.
module ColorThemes
  # theme: "light" for the base context, else the theme name. contexts: the
  # display labels of every context that fed this variant. decls: the
  # effective Hash of custom properties, resolved by the cascade (not a
  # last-write merge).
  Variant = Data.define(:theme, :contexts, :decls)
  # A context the model will not merge, with the custom properties declared
  # in it, so text roles there still get one row each.
  Unsupported = Data.define(:label, :decls, :why)
  Model = Data.define(:variants, :unsupported)

  # One declaration as it competes for a property name inside one theme
  # variant: enough to resolve the cascade winner (importance, layer,
  # specificity, source order) and enough to label the context it came from.
  Entry = Struct.new(:name, :value, :important, :b, :c, :layer_rank, :order, :label, keyword_init: true)

  ROOT_PREFIX = /\A(?::root|html)/i.freeze
  DATA_THEME_QUALIFIER = /\A\[data-theme\s*=\s*["']?([\w-]+)["']?\]/.freeze
  CLASS_QUALIFIER = /\A\.([\w-]+)/.freeze
  NOT_QUALIFIER = /\A:not\(\s*(?:\[data-theme\s*=\s*["']?([\w-]+)["']?\]|\.([\w-]+))\s*\)/.freeze
  BARE_CLASS = /\A\.([\w-]+)\z/.freeze
  BARE_ATTR = /\A\[data-theme\s*=\s*["']?([\w-]+)["']?\]\z/.freeze
  MEDIA_SCHEME = /\A@media\s+(?:(?:only\s+)?(?:screen|all)\s+and\s+)?\(\s*prefers-color-scheme\s*:\s*(light|dark)\s*\)\s*\z/i.freeze
  # Matches a named or anonymous "@layer" block frame. A name may be a
  # dotted path written as a single statement ("@layer a.b"), which is
  # equivalent to nesting ("@layer a { @layer b { ... } }"); an anonymous
  # block frame carries no name here (the parser has already rewritten it
  # to a synthetic "%anon-N" name unique to its occurrence).
  LAYER_FRAME = /\A@layer\s+([\w%-]+(?:\.[\w%-]+)*)\s*\z/.freeze
  # A layer name inside "@layer a, b;" or "@import ... layer(x)", which may
  # itself be a dotted path.
  LAYER_NAME = /\A[\w%-]+(?:\.[\w%-]+)*\z/.freeze
  IMPORT_LAYER = /\blayer\(\s*([\w%-]+(?:\.[\w%-]+)*)\s*\)/i.freeze

  module_function

  # Classifies one selector from a declaration's selectors list, using the
  # declaration's at-rule stack and SCSS parents.
  # rule_custom_only maps rule_id => true when every declaration in that rule
  # block is a custom property or color-scheme (needed for the bare .X /
  # [data-theme=X] form, decision 6).
  # => [:base, excluded_names]
  #  | [:theme, name, label]
  #  | [:media_base, media_name, excluded_names, label]
  #  | [:unsupported, label, why]
  #  | [:other, label]
  # excluded_names (from :not(...) qualifiers on a zero-positive-name root
  # form) names a theme this declaration does not apply to; it still applies,
  # unconditionally, to every other variant (base inheritance).
  def classify(selector, decl, rule_custom_only: {})
    at_rules = decl.at_rules.reject { |a| a.start_with?('@layer') }

    media_name, bad = split_media_frames(at_rules)
    return [ :unsupported, context_label(at_rules, selector), "inside #{bad}" ] if bad
    return [ :unsupported, context_label(at_rules, selector), 'nested rule' ] unless decl.parents.empty?

    root_match = root_qualifier_match(selector)
    if root_match
      names, excluded = root_match
      if names.size > 1
        return [ :unsupported, context_label(at_rules, selector), 'multiple theme markers' ]
      end

      return combine(media_name, names.first, excluded, at_rules, selector)
    end

    if ((m = BARE_CLASS.match(selector)) || (m = BARE_ATTR.match(selector))) && rule_custom_only[decl.rule_id]
      return combine(media_name, m[1], [], at_rules, selector)
    end

    [ :other, context_label(at_rules, selector) ]
  end

  # Builds the theme model from a parsed Sheet: a base (light) variant, one
  # variant per other recognized theme name, each resolved by the cascade
  # over every declaration that applies to it, and the unsupported contexts
  # that carry a text-role token.
  def build(sheet)
    rule_custom_only = rule_custom_only_map(sheet.decls)
    sibling_index = compute_layer_order(sheet)

    base_entries = [] # [excluded_names, Entry]
    theme_entries = Hash.new { |h, k| h[k] = [] } # name => [Entry] (selector-origin)
    media_entries = Hash.new { |h, k| h[k] = [] } # media_name => [[excluded_names, Entry]]
    unsupported = {} # label => {decls:, why:, other:}
    selector_origin_names = Set.new
    order_idx = 0

    sheet.decls.each do |decl|
      next unless decl.name.start_with?('--')

      layer_rank = layer_rank_for(decl, sibling_index)

      decl.selectors.each do |selector|
        order_idx += 1
        kind, *rest = classify(selector, decl, rule_custom_only:)
        entry = Entry.new(
          name: decl.name, value: decl.value, important: decl.important,
          b: 0, c: 0, layer_rank:, order: order_idx,
          label: context_label(decl.at_rules.reject { |a| a.start_with?('@layer') }, selector)
        )
        entry.b, entry.c = selector_specificity(selector)

        case kind
        when :base
          base_entries << [ rest[0], entry ]
        when :theme
          selector_origin_names << rest[0]
          theme_entries[rest[0]] << entry
        when :media_base
          media_entries[rest[0]] << [ rest[1], entry ]
        when :unsupported
          label, why = rest
          u = (unsupported[label] ||= { decls: {}, why:, other: false })
          u[:decls][decl.name] = decl.value
        when :other
          label = rest[0]
          u = (unsupported[label] ||= { decls: {}, why: 'not a recognized theme context', other: true })
          u[:decls][decl.name] = decl.value
        end
      end
    end

    theme_names = ([ 'light' ] + selector_origin_names.to_a + media_entries.keys).uniq
    variants = theme_names.filter_map do |theme|
      build_variant(theme, base_entries, theme_entries, media_entries, selector_origin_names)
    end

    Model.new(variants:, unsupported: finalize_unsupported(unsupported))
  end

  # --- internal helpers; module_function for testability, not public API ---

  def split_media_frames(at_rules)
    media_name = nil
    at_rules.each do |ar|
      if (m = MEDIA_SCHEME.match(ar))
        return [ media_name, ar ] if media_name

        media_name = m[1].downcase
      else
        return [ media_name, ar ]
      end
    end
    [ media_name, nil ]
  end

  def context_label(at_rules, selector)
    at_rules.empty? ? selector : "#{at_rules.join(' ')} #{selector}"
  end

  def combine(media_name, selector_name, excluded, at_rules, selector)
    label = context_label(at_rules, selector)
    if selector_name
      return [ :unsupported, label, 'conflicting theme markers' ] if media_name && media_name != selector_name

      [ :theme, selector_name, label ]
    elsif media_name
      [ :media_base, media_name, excluded, label ]
    else
      [ :base, excluded ]
    end
  end

  # Walks :root/html qualifiers (data-theme attrs, classes, :not(...)) and
  # returns [positive_names, excluded_names], or nil when the selector is not
  # a pure root form (so the caller falls through to the bare-form check).
  # Leading whitespace is tolerated before each qualifier: a CSS comment
  # inside a prelude ("/* ... */") never produces a token, so this checker
  # treats any whitespace run there the same way, rather than mistaking a
  # comment-induced gap for a descendant combinator.
  def root_qualifier_match(selector)
    m = ROOT_PREFIX.match(selector)
    return nil unless m

    rest = selector[m.end(0)..]
    names = []
    excluded = []
    loop do
      rest = rest.sub(/\A\s+/, '')
      break if rest.empty?

      if (q = DATA_THEME_QUALIFIER.match(rest))
        names << q[1]
        rest = rest[q.end(0)..]
      elsif (q = CLASS_QUALIFIER.match(rest))
        names << q[1]
        rest = rest[q.end(0)..]
      elsif (q = NOT_QUALIFIER.match(rest))
        excluded << (q[1] || q[2])
        rest = rest[q.end(0)..]
      else
        return nil
      end
    end
    [ names, excluded ]
  end

  # CSS specificity (b, c) for the forms this checker recognizes: :root and
  # html each count as one simple selector (:root as a pseudo-class, html as
  # a type selector); every class or attribute qualifier counts as one,
  # whether bare or wrapped in :not(...), since :not()'s specificity is that
  # of its argument. No form here carries an id, so a is always 0 and
  # dropped.
  def selector_specificity(selector)
    b = 0
    c = 0
    rest = if selector.match?(/\A:root/i)
             b += 1
             selector.sub(/\A:root/i, '')
    elsif selector.match?(/\Ahtml/i)
      c += 1
      selector.sub(/\Ahtml/i, '')
    else
      selector
    end

    loop do
      rest = rest.sub(/\A\s+/, '')
      break if rest.empty?

      q = DATA_THEME_QUALIFIER.match(rest) || CLASS_QUALIFIER.match(rest) || NOT_QUALIFIER.match(rest)
      break unless q

      b += 1
      rest = rest[q.end(0)..]
    end

    [ b, c ]
  end

  def rule_custom_only_map(decls)
    by_rule = Hash.new { |h, k| h[k] = [] }
    decls.each { |d| by_rule[d.rule_id] << d if d.rule_id }
    by_rule.transform_values { |ds| ds.all? { |d| d.name.start_with?('--') || d.name == 'color-scheme' } }
  end

  # The dotted path of @layer frames a declaration (or block-less at-rule
  # statement) is nested in, as an array of segments, outermost first. A
  # single frame's own name may already be dotted ("@layer a.b"), which is
  # equivalent to nesting, so its segments are split out and flattened in
  # with any real nesting.
  def layer_path_for(at_rules)
    at_rules.each_with_object([]) do |ar, path|
      next unless ar.start_with?('@layer')

      m = LAYER_FRAME.match(ar)
      next unless m

      path.concat(m[1].split('.'))
    end
  end

  # Orders cascade layers by first declaration, whether that first mention
  # is a block-less "@layer a, b;" statement (which fixes order even before
  # any of those layers' blocks appear), an "@import ... layer(x)" (which
  # fixes order at the import's position, before the layer's own block),
  # or a named/anonymous "@layer x { }" block. Builds, for every distinct
  # layer path seen, its sibling index among paths sharing the same parent
  # path (so "a" and "a.b" are ordered independently of "b"), which is what
  # layer_rank_for needs to rank a parent's own direct declarations above
  # its sublayers while still ranking sibling layers by first declaration.
  def compute_layer_order(sheet)
    events = [] # [line, idx, path]

    sheet.at_rule_stmts.each do |stmt|
      parent = layer_path_for(stmt.at_rules)
      case stmt.name
      when '@layer'
        ColorCss.split_top_level(stmt.prelude).each_with_index do |nm, i|
          name = nm.strip
          next if name.empty? || !LAYER_NAME.match?(name)

          events << [ stmt.line, i, parent + name.split('.') ]
        end
      when '@import'
        m = IMPORT_LAYER.match(stmt.prelude)
        events << [ stmt.line, 0, parent + m[1].split('.') ] if m
      end
    end

    sheet.decls.each do |decl|
      path = layer_path_for(decl.at_rules)
      (1..path.size).each do |len|
        events << [ decl.line, Float::INFINITY, path.first(len) ]
      end
    end

    first_seen = {}
    events.sort_by { |line, idx, _| [ line, idx ] }.each do |(_, _, path)|
      key = path.join('.')
      first_seen[key] ||= path
    end

    # Group every distinct path by its immediate parent path, in first-seen
    # order, and number each group's children 0, 1, 2... by that order: a
    # path's rank is only ever compared against its own siblings.
    by_parent = Hash.new { |h, k| h[k] = [] }
    first_seen.each_value { |path| by_parent[path[0...-1].join('.')] << path.join('.') }

    sibling_index = {}
    by_parent.each_value do |children|
      children.each_with_index { |key, i| sibling_index[key] = i }
    end
    sibling_index
  end

  # Unlayered declarations always win over any layered one, whatever their
  # specificity or source order. Among layered declarations, a parent
  # layer's own direct declarations win over anything in its sublayers
  # (modelled by appending Infinity once the declaration's own path is
  # exhausted, which outranks a deeper path's next, finite sibling index),
  # and sibling layers are ranked by first declaration. Returns an array
  # key, comparable with <=>, where a greater key wins.
  def layer_rank_for(decl, sibling_index)
    path = layer_path_for(decl.at_rules)
    return [ Float::INFINITY ] if path.empty?

    key = []
    (1..path.size).each do |len|
      key << (sibling_index[path.first(len).join('.')] || 0)
    end
    key << Float::INFINITY
    key
  end

  # Resolves one theme's effective declaration map and contexts.
  #
  # An unconditional base entry (excluded_names from :not(...)) applies to
  # every theme not named in its excluded_names, including named themes
  # (ordinary inheritance). A selector-origin theme entry (an attribute,
  # class or bare form naming this theme) applies only to that theme. A
  # media-scheme base entry applies to its own media name, and also to any
  # OTHER theme that has a selector-origin occurrence somewhere in the
  # sheet (an attribute or class override is still live under an OS color
  # scheme the author never excluded it from); it never leaks into the
  # implicit base ("light" with no selector occurrence) or into another
  # pure-media theme, which is how repro1's plain OS-dark override stays its
  # own variant instead of contaminating light.
  def build_variant(theme, base_entries, theme_entries, media_entries, selector_origin_names)
    candidates = Hash.new { |h, k| h[k] = [] }

    base_entries.each do |excluded, entry|
      candidates[entry.name] << entry unless excluded.include?(theme)
    end

    theme_entries[theme].each { |entry| candidates[entry.name] << entry }

    media_entries.each do |media_name, list|
      list.each do |excluded, entry|
        next if excluded.include?(theme)
        next unless media_name == theme || selector_origin_names.include?(theme)

        candidates[entry.name] << entry
      end
    end

    return nil if candidates.empty?

    decls = candidates.transform_values { |entries| winning_value(entries) }
    Variant.new(theme:, contexts: contexts_for(theme, base_entries, theme_entries, media_entries), decls:)
  end

  # For !important declarations, the whole cascade-layer order is reversed
  # (an earlier layer beats a later one, and layered beats unlayered), so
  # every component of the layer_rank key is negated before comparison.
  def winning_value(entries)
    entries.max_by do |e|
      rank = e.important ? e.layer_rank.map { |v| -v } : e.layer_rank
      [ e.important ? 1 : 0, rank, e.b, e.c, e.order ]
    end.value
  end

  def contexts_for(theme, base_entries, theme_entries, media_entries)
    pool = []
    if theme == 'light'
      base_entries.each { |excluded, entry| pool << entry unless excluded.include?(theme) }
    end
    pool.concat(theme_entries[theme])
    media_entries.each do |media_name, list|
      list.each do |excluded, entry|
        next if excluded.include?(theme)
        next unless media_name == theme

        pool << entry
      end
    end
    pool.sort_by(&:order).map(&:label).uniq
  end

  def finalize_unsupported(unsupported)
    unsupported.filter_map do |label, entry|
      next if entry[:other] && entry[:decls].keys.none? { |n| ColorThemes.text_role_name?(n) }

      Unsupported.new(label: label, decls: entry[:decls], why: entry[:why])
    end
  end

  # Whole-hyphen-segment match for the pairing text roles: text, fg, ink,
  # title and link each count as a text role in any segment position
  # (leading, middle or trailing), so Primer-style names such as
  # "--color-fg-default" and "--color-text-muted" are recognized, except
  # "ink" never counts as a leading segment on its own ("--ink-like" stays a
  # plain token; a bare "--ink" or a trailing "--link-hover" still match).
  TEXT_ROLE_WORDS = %w[text fg ink title link].freeze

  def text_role_name?(name)
    segments = name.sub(/\A--/, '').split('-')
    return false if segments.empty?

    segments.each_with_index.any? do |seg, idx|
      word = seg.downcase
      next false unless TEXT_ROLE_WORDS.include?(word)
      next idx.positive? || segments.size == 1 if word == 'ink'

      true
    end
  end
end
