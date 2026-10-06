#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'color_css'

# Classifies a parsed CSS sheet's custom-property declarations into a light
# base context and named theme variants (data-theme attributes, class
# strategies, prefers-color-scheme media queries, and the bare shadcn/ui
# .X {} shape), and records any context the model declines to merge as
# unsupported with a reason. Never raises; a sheet that uses no recognized
# theme form simply yields a base variant and whatever unsupported contexts
# its text-role tokens fall into.
module ColorThemes
  # theme: "light" for the base context, else the theme name. contexts: the
  # display labels of every context folded into this variant. decls: the
  # effective Hash of custom properties, base first then overrides, insertion
  # order kept.
  Variant = Data.define(:theme, :contexts, :decls)
  # A context the model will not merge, with the custom properties declared
  # in it, so text roles there still get one row each.
  Unsupported = Data.define(:label, :decls, :why)
  Model = Data.define(:variants, :unsupported)

  ROOT_PREFIX = /\A(?::root|html)/.freeze
  DATA_THEME_QUALIFIER = /\A\[data-theme\s*=\s*["']?([\w-]+)["']?\]/.freeze
  CLASS_QUALIFIER = /\A\.([\w-]+)/.freeze
  NOT_QUALIFIER = /\A:not\(\s*(?:\[data-theme\s*=\s*["']?[\w-]+["']?\]|\.[\w-]+)\s*\)/.freeze
  BARE_CLASS = /\A\.([\w-]+)\z/.freeze
  BARE_ATTR = /\A\[data-theme\s*=\s*["']?([\w-]+)["']?\]\z/.freeze
  MEDIA_SCHEME = /\A@media\s+(?:(?:only\s+)?(?:screen|all)\s+and\s+)?\(\s*prefers-color-scheme\s*:\s*(light|dark)\s*\)\s*\z/i.freeze

  module_function

  # Classifies one selector from a declaration's selectors list, using the
  # declaration's at-rule stack, SCSS parents and rule identity.
  # rule_custom_only maps rule_id => true when every declaration in that rule
  # block is a custom property or color-scheme (needed for the bare .X /
  # [data-theme=X] form, decision 6).
  # => [:base] | [:theme, name, label] | [:unsupported, label, why] | [:other, label]
  def classify(selector, decl, rule_custom_only: {})
    at_rules = decl.at_rules.reject { |a| a.start_with?('@layer') }

    media_name, bad = split_media_frames(at_rules)
    return [ :unsupported, context_label(media_name_prelude(at_rules), selector), "inside #{bad}" ] if bad

    return [ :unsupported, context_label(media_name_prelude(at_rules), selector), 'nested rule' ] unless decl.parents.empty?

    names = root_qualifier_names(selector)
    if names
      if names.size > 1
        return [ :unsupported, context_label(media_name_prelude(at_rules), selector), 'multiple theme markers' ]
      end

      return combine(media_name, names.first, at_rules, selector)
    end

    if ((m = BARE_CLASS.match(selector)) || (m = BARE_ATTR.match(selector))) && rule_custom_only[decl.rule_id]
      return combine(media_name, m[1], at_rules, selector)
    end

    [ :other, context_label(media_name_prelude(at_rules), selector) ]
  end

  # Builds the theme model from a parsed Sheet: a base (light) variant, one
  # variant per other recognized theme name (collapsing identical effective
  # maps within a theme), and the unsupported contexts that carry a
  # text-role token.
  def build(sheet)
    rule_custom_only = rule_custom_only_map(sheet.decls)

    base = {}
    base_contexts = []
    theme_decls = {} # [name, label] => {decl_name => value}, insertion order
    theme_order = []
    unsupported = {} # label => {decls:, why:, other:}

    sheet.decls.each do |decl|
      next unless decl.name.start_with?('--')

      decl.selectors.each do |selector|
        kind, a, b = classify(selector, decl, rule_custom_only:)
        case kind
        when :base
          base[decl.name] = decl.value
          base_contexts << selector unless base_contexts.include?(selector)
        when :theme
          key = [ a, b ]
          unless theme_decls.key?(key)
            theme_decls[key] = {}
            theme_order << key
          end
          theme_decls[key][decl.name] = decl.value
        when :unsupported
          entry = (unsupported[a] ||= { decls: {}, why: b, other: false })
          entry[:decls][decl.name] = decl.value
        when :other
          entry = (unsupported[a] ||= { decls: {}, why: 'not a recognized theme context', other: true })
          entry[:decls][decl.name] = decl.value
        end
      end
    end

    Model.new(
      variants: build_variants(base, base_contexts, theme_decls, theme_order),
      unsupported: finalize_unsupported(unsupported)
    )
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

  def media_name_prelude(at_rules)
    at_rules.find { |ar| MEDIA_SCHEME.match?(ar) }
  end

  def context_label(media_prelude, selector)
    media_prelude ? "#{media_prelude} #{selector}" : selector
  end

  def combine(media_name, selector_name, at_rules, selector)
    label = context_label(media_name_prelude(at_rules), selector)
    if media_name.nil? && selector_name.nil?
      [ :base ]
    elsif media_name.nil?
      [ :theme, selector_name, label ]
    elsif selector_name.nil?
      [ :theme, media_name, label ]
    elsif media_name == selector_name
      [ :theme, media_name, label ]
    else
      [ :unsupported, label, 'conflicting theme markers' ]
    end
  end

  # Walks :root/html qualifiers (data-theme attrs, classes, :not(...)) and
  # returns the positive theme names found, or nil when the selector is not a
  # pure root form (so the caller falls through to the bare-form check).
  def root_qualifier_names(selector)
    m = ROOT_PREFIX.match(selector)
    return nil unless m

    rest = selector[m.end(0)..]
    names = []
    until rest.empty?
      if (q = DATA_THEME_QUALIFIER.match(rest))
        names << q[1]
        rest = rest[q.end(0)..]
      elsif (q = CLASS_QUALIFIER.match(rest))
        names << q[1]
        rest = rest[q.end(0)..]
      elsif (q = NOT_QUALIFIER.match(rest))
        rest = rest[q.end(0)..]
      else
        return nil
      end
    end
    names
  end

  def rule_custom_only_map(decls)
    by_rule = Hash.new { |h, k| h[k] = [] }
    decls.each { |d| by_rule[d.rule_id] << d if d.rule_id }
    by_rule.transform_values { |ds| ds.all? { |d| d.name.start_with?('--') || d.name == 'color-scheme' } }
  end

  def build_variants(base, base_contexts, theme_decls, theme_order)
    by_name = {}
    unless base.empty? && base_contexts.empty?
      base_contexts.each { |ctx| (by_name['light'] ||= []) << [ ctx, base ] }
    end
    theme_order.each do |key|
      name, label = key
      (by_name[name] ||= []) << [ label, base.merge(theme_decls[key]) ]
    end

    variants = []
    by_name.each do |name, entries|
      collapsed = []
      entries.each do |label, effective|
        existing = collapsed.find { |c| c[:decls] == effective }
        if existing
          existing[:contexts] << label unless existing[:contexts].include?(label)
        else
          collapsed << { contexts: [ label ], decls: effective }
        end
      end
      collapsed.each { |c| variants << Variant.new(theme: name, contexts: c[:contexts], decls: c[:decls]) }
    end
    variants
  end

  def finalize_unsupported(unsupported)
    unsupported.filter_map do |label, entry|
      next if entry[:other] && entry[:decls].keys.none? { |n| ColorThemes.text_role_name?(n) }

      Unsupported.new(label: label, decls: entry[:decls], why: entry[:why])
    end
  end

  # Whole-hyphen-segment match for the pairing text roles (text, fg, title,
  # link as a leading or trailing segment; ink only as an exact name or a
  # trailing segment, never a leading one, so "--ink-like" is not a text
  # role while "--link-hover" and "--text-muted" still are).
  TEXT_ROLE_WORDS = %w[text fg ink title link].freeze
  TEXT_ROLE_LEADING_WORDS = %w[text fg title link].freeze

  def text_role_name?(name)
    segments = name.sub(/\A--/, '').split('-')
    return false if segments.empty?

    return true if segments.size == 1 && TEXT_ROLE_WORDS.include?(segments.first.downcase)
    return true if TEXT_ROLE_LEADING_WORDS.include?(segments.first.downcase)

    TEXT_ROLE_WORDS.include?(segments.last.downcase)
  end
end
