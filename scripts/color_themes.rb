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
  # One page state: marker is nil for the unmarked page or a theme name;
  # os is nil (no OS axis in the sheet), "light" or "dark".
  State = Data.define(:marker, :os)
  # theme: "default" for the unmarked page, else the marker name, joined
  # with " | " when several markers share identical declarations. states:
  # every page State that resolves to decls. contexts: one display label per
  # state. decls: the effective Hash of custom properties, resolved by the
  # cascade (not a last-write merge).
  Variant = Data.define(:theme, :contexts, :decls, :states)
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
  # [data-theme=X] form, whose block is only trusted as a theme when nothing
  # in it carries non-color semantics).
  # => [:base, excluded_names]
  #  | [:theme, name, label]
  #  | [:media_base, media_name, excluded_names, label]
  #  | [:unsupported, label, why]
  #  | [:other, label]
  # excluded_names (from :not(...) qualifiers on a zero-positive-name root
  # form) names a theme this declaration does not apply to; it still applies,
  # unconditionally, to every other variant (base inheritance).
  def classify(selector, decl, rule_custom_only: {}, at_rules: nil)
    at_rules ||= non_layer_frames(decl.at_rules)

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

  # Builds the theme model from a parsed Sheet: one variant per distinct
  # resolved page state (unmarked default, each marker, each OS scheme),
  # each resolved by the cascade over every declaration live in that state,
  # and the unsupported contexts.
  def build(sheet)
    candidates, unsupported = classify_sheet(sheet)
    variants = evaluate(candidates, page_states(candidates))
    Model.new(variants:, unsupported: finalize_unsupported(unsupported))
  end

  # Every page state the sheet enumerates, mapped to the custom-property
  # names live in it (independent of the cascade winner). Lets a caller
  # check that each state's text roles are all reported.
  def state_names(sheet)
    candidates, = classify_sheet(sheet)
    page_states(candidates).to_h do |state|
      live = candidates.select { |kind, rest, _| applies?(kind, rest, state) }
      [ state, live.map { |_, _, entry| entry.name }.uniq ]
    end
  end

  # => [candidates, unsupported]: candidates are [kind, payload, Entry] for
  # every :base, :theme and :media_base classification; unsupported maps a
  # context label to {decls:, why:}.
  def classify_sheet(sheet)
    rule_custom_only = rule_custom_only_map(sheet.decls)
    sibling_index = compute_layer_order(sheet)

    candidates = [] # [kind, payload, Entry]
    unsupported = {} # label => {decls:, why:}
    order_idx = 0

    sheet.decls.each do |decl|
      next unless decl.name.start_with?('--')

      layer_rank = layer_rank_for(decl, sibling_index)
      at_rules = non_layer_frames(decl.at_rules)

      decl.selectors.each do |selector|
        order_idx += 1
        kind, *rest = classify(selector, decl, rule_custom_only:, at_rules:)
        entry = Entry.new(
          name: decl.name, value: decl.value, important: decl.important,
          b: 0, c: 0, layer_rank:, order: order_idx,
          label: context_label(at_rules, selector)
        )
        entry.b, entry.c = selector_specificity(selector)

        case kind
        when :base, :theme, :media_base
          candidates << [ kind, rest, entry ]
        else
          record_unsupported(unsupported, decl, kind, rest)
        end
      end
    end

    [ candidates, unsupported ]
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

  # Drops only well-formed @layer frames (they rank the cascade, they do not
  # condition it). A malformed @layer frame stays in the stack, so
  # split_media_frames reports the declaration unsupported instead of
  # silently treating it as unlayered.
  def non_layer_frames(at_rules)
    at_rules.reject { |a| LAYER_FRAME.match?(a) }
  end

  def context_label(at_rules, selector)
    at_rules.empty? ? selector : "#{at_rules.join(' ')} #{selector}"
  end

  # Exact lookup over the Supported column for theme contexts: a context
  # either matches one supported shape or is reported unsupported with a
  # reason. Nothing is folded into the nearest shape.
  def combine(media_name, selector_name, excluded, at_rules, selector)
    label = context_label(at_rules, selector)
    return [ :base, excluded ] if media_name.nil? && selector_name.nil?
    return [ :media_base, media_name, excluded, label ] if selector_name.nil?
    return [ :theme, selector_name, label ] if media_name.nil?

    why = media_name == selector_name ? 'media condition on a theme selector' : 'conflicting theme markers'
    [ :unsupported, label, why ]
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
    events = [] # [pos, idx, path]

    sheet.at_rule_stmts.each do |stmt|
      parent = layer_path_for(stmt.at_rules)
      case stmt.name
      when '@layer'
        ColorCss.split_top_level(stmt.prelude).each_with_index do |nm, i|
          name = nm.strip
          next if name.empty? || !LAYER_NAME.match?(name)

          events << [ stmt.pos, i, parent + name.split('.') ]
        end
      when '@import'
        m = IMPORT_LAYER.match(stmt.prelude)
        events << [ stmt.pos, 0, parent + m[1].split('.') ] if m
      end
    end

    sheet.decls.each do |decl|
      path = layer_path_for(decl.at_rules)
      (1..path.size).each do |len|
        events << [ decl.pos, Float::INFINITY, path.first(len) ]
      end
    end

    first_seen = {}
    events.sort_by { |pos, idx, _| [ pos, idx ] }.each do |(_, _, path)|
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

  def record_unsupported(unsupported, decl, kind, rest)
    label, why = kind == :unsupported ? rest : [ rest[0], 'not a recognized theme context' ]
    u = (unsupported[label] ||= { decls: {}, why: })
    u[:decls][decl.name] = decl.value
  end

  # Every page state the sheet can put the root in: the unmarked page plus
  # each marker (a positive selector name or a :not() excluded name), crossed
  # with the OS color schemes when a prefers-color-scheme block exists.
  def page_states(candidates)
    markers = candidates.flat_map do |kind, rest, _|
      case kind
      when :base then rest[0]
      when :theme then [ rest[0] ]
      else rest[1]
      end
    end
    os_states = candidates.any? { |kind, _, _| kind == :media_base } ? %w[light dark] : [ nil ]
    ([ nil ] + markers.uniq).product(os_states).map { |marker, os| State.new(marker:, os:) }
  end

  def applies?(kind, rest, state)
    case kind
    when :base then !rest[0].include?(state.marker)
    when :theme then state.marker == rest[0]
    else state.os == rest[0] && !rest[1].include?(state.marker)
    end
  end

  # Resolves each page state by the cascade over the declarations live in
  # it, and merges states whose effective declarations are identical.
  def evaluate(candidates, states)
    seen = {}
    states.each do |state|
      live = candidates.select { |kind, rest, _| applies?(kind, rest, state) }.map(&:last)
      next if live.empty?

      decls = live.group_by(&:name).transform_values { |entries| winning_value(entries) }
      (seen[decls] ||= []) << state
    end
    seen.map { |decls, merged| variant_for(decls, merged) }
  end

  def variant_for(decls, states)
    theme = states.map { |s| s.marker || 'default' }.uniq.join(' | ')
    Variant.new(theme:, contexts: states.map { |s| state_label(s) }, decls:, states:)
  end

  def state_label(state)
    label = "marker #{state.marker || 'default'}"
    state.os ? "#{label}, os #{state.os}" : label
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

  # Every unsupported context is kept, whether or not it carries a text
  # role, so no custom-property declaration silently leaves the model.
  # Rendering decides which of them produce contrast rows.
  def finalize_unsupported(unsupported)
    unsupported.map do |label, entry|
      Unsupported.new(label: label, decls: entry[:decls], why: entry[:why])
    end
  end

  # Whole-hyphen-segment match for the pairing text roles: text, fg,
  # foreground, ink, title and link each count as a text role in any segment position
  # (leading, middle or trailing), so Primer-style names such as
  # "--color-fg-default" and "--color-text-muted" are recognized, except
  # "ink" never counts as a leading segment on its own ("--ink-like" stays a
  # plain token; a bare "--ink" or a trailing "--color-ink" still match).
  TEXT_ROLE_WORDS = %w[text fg foreground ink title link].freeze

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
