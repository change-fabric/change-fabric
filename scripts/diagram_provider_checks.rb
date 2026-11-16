# frozen_string_literal: true

require "rexml/document"
require_relative "svg_checks"
require_relative "cloud_icons"
require_relative "diagram_palette"

# The cf:diagram checks for provider architecture diagrams
# (data-provider="aws" on an architecture SVG): icon provenance against the
# pinned pack, icon placement, provider color contrast, and strict group
# nesting with clear label chips. A diagram with no provider icon and no
# provider group yields nothing here, so today's diagrams are unaffected.
module DiagramProviderChecks
  Base = SvgChecks::Base

  # The name a finding points at: the icon instance id, else its slug.
  def self.where(icon) = icon.element.parent.attributes["id"] || icon.slug || "icon"

  # Provider profile lookups shared by the provider checks.
  module Provider
    module_function

    def profile(provider) = provider && CloudIcons.manifest(provider)
    def groups(provider) = profile(provider)&.fetch("groups", nil) || {}

    # Light and dark hexes the profile allows for one group kind.
    def colors(provider, kind)
      spec = groups(provider)[kind]
      spec ? [ spec["color"], spec["dark"] ].compact.map(&:upcase) : []
    end

    # The group kind a --<provider>-<kind> custom property names, or nil.
    def role_kind(provider, name)
      provider && name.to_s[/\A--#{Regexp.escape(provider)}-([a-z0-9-]+)\z/, 1]
    end

    def roles(doc) = DiagramPalette.theme_roles(doc.style_text)

    def hexes(roles, value) = %i[light dark].to_h { |t| [ t, DiagramPalette.resolve_hex(roles[t], value) ] }
  end

  # Palette, plus the provenance exemption: a --<provider>-<kind> role whose
  # value is that kind's color in the declared provider's pack profile.
  class ProviderPalette < SvgChecks::Palette
    private

    def exempt?(doc, prop, value)
      kind = Provider.role_kind(doc.provider, prop)
      kind ? Provider.colors(doc.provider, kind).include?(value.upcase) : false
    end
  end

  # Every provider icon proves where it came from: a pack icon names its
  # provider, slug, and the sha256 of the pinned pack's file, and carries no
  # color that file does not. A fallback glyph warns and stays on palette.
  # A stylesheet rule that reaches into an icon body (a descendant selector
  # ending on a bare shape, such as `.node rect`) would recolor the pack's
  # artwork at render time, so it is an error too.
  class IconPackProvenance < Base
    ID = "icon-pack-provenance"
    REACHING = /\A(?:rect|path|circle|ellipse|polygon|polyline|line|g|svg|use|text|\*)\z/

    def call(doc, context)
      return [] if doc.icons.empty?

      leaks(doc) + doc.icons.flat_map { |icon| judge(icon, context) }
    end

    private

    def leaks(doc)
      css = SvgChecks::DeclaredProperty.stylesheet(doc).gsub(/@media[^{]*\{/, "")
      css.scan(/([^{}]+)\{[^{}]*\}/).flatten.flat_map { |list| list.split(",").map(&:strip) }.uniq.filter_map do |sel|
        next unless reaches?(doc, sel)

        finding("style", "selector #{sel.inspect} reaches into icon bodies and would recolor them",
                "use a child combinator, such as #{sel.sub(/\s+(\S+)\z/, ' > \1').inspect}")
      end
    end

    # A descendant combinator before a bare type, unless the rule is anchored
    # on an #id whose element holds no icon.
    def reaches?(doc, sel)
      parts = sel.split(/\s+/)
      return false unless parts.size >= 2 && parts.last.match?(REACHING) && parts[-2] != ">"

      id = parts.first[/\A#([\w-]+)\z/, 1]
      return true unless id

      host = doc.all_elements.find { |el| el.attributes["id"] == id }
      host ? doc.icons.any? { |i| doc.descendant?(i.element, host) } : false
    end

    def judge(icon, context)
      where = DiagramProviderChecks.where(icon)
      unless icon.provider && icon.slug
        return [ finding(where, "svg.icon is not wrapped in a g.icon with data-provider and data-icon", "wrap it as cloud_icons.rb inline does") ]
      end
      return [ finding(where, "provider #{icon.provider.inspect} has no pack profile", "use a provider under skills/diagram/packs") ] unless Provider.profile(icon.provider)
      return fallback(icon, context) if icon.fallback

      pack = context.packs&.pack(icon.provider)
      return verify(icon, pack, where) if pack

      [ finding(where, "#{icon.provider} pack is not cached, provenance not verified", "run ruby scripts/cloud_icons.rb #{icon.provider}", severity: "warn") ]
    end

    def verify(icon, pack, where)
      return [ finding(where, "#{icon.provider} pack has no icon #{icon.slug.inspect}", "use a pack slug or the Phosphor fallback") ] unless pack.file(icon.slug)
      unless icon.sha == pack.sha(icon.slug)
        return [ finding(where, "data-pack-sha does not match the pinned #{icon.provider} file for #{icon.slug}", "re-inline the icon from the pack") ]
      end

      (CloudIcons.colors(icon.body) - pack.colors(icon.slug)).map do |c|
        finding(where, "color #{c} is not in the #{icon.provider} pack file for #{icon.slug}", "inline the pack file unmodified")
      end
    end

    def fallback(icon, context)
      allowed = context.palette.map(&:upcase)
      off = CloudIcons.colors(icon.body).reject { |c| allowed.include?(c) }
      warn = finding(icon.slug, "#{icon.provider}:#{icon.slug} draws the Phosphor #{icon.fallback} fallback",
                     "cache the #{icon.provider} pack to draw the official icon", severity: "warn")
      [ warn ] + off.map { |c| finding(icon.slug, "fallback glyph color #{c} is not in the palette", "use a palette role") }
    end
  end

  # An icon is a placed box: positive size, a viewBox, inside the node or
  # provider group that owns it, and clear of that node's label.
  class IconBox < Base
    ID = "icon-box"

    def call(doc, context)
      doc.icons.flat_map { |icon| judge(doc, icon, context) }
    end

    private

    def judge(doc, icon, context)
      where = DiagramProviderChecks.where(icon)
      unless icon.view_box && icon.box.w.positive? && icon.box.h.positive?
        return [ finding(where, "svg.icon needs width, height, and a viewBox", "set x, y, width, height, and viewBox") ]
      end

      kind, id = icon.owner
      case kind
      when :node then in_node(doc, icon, id, where, context)
      when :group then in_group(doc, icon, id, where)
      else [ finding(where, "icon sits in no node or provider group", "place it inside a g.node or g.group") ]
      end
    end

    def in_node(doc, icon, id, where, context)
      node = doc.node(id)
      return [ finding(where, "icon owner node #{id.inspect} has no shape", "give the node a rect") ] unless node
      return [ finding(where, "icon box leaves node #{id}", "keep the icon inside the node box") ] unless node.box.contains_box?(icon.box)

      doc.texts.select { |t| t.node_id == id }.filter_map do |t|
        finding(where, "icon overlaps label #{t.key}", "move the label clear of the icon") if context.text_box(t).intersect?(icon.box)
      end
    end

    def in_group(doc, icon, id, where)
      group = doc.group(id)
      return [ finding(where, "icon sits in a group without data-group-kind", "declare the group kind") ] unless group
      return [] if group.box.contains_box?(icon.box)

      [ finding(where, "icon box leaves group #{id}", "keep the corner icon inside the group border") ]
    end
  end

  # Provider colors are trusted by provenance, never for legibility: an
  # icon's area-weighted outermost tile color, and each provider group role,
  # must clear STROKE_MIN against what it sits on in both themes. The fix is
  # a surface plate behind the icon, never a recolor.
  class IconContrast < Base
    ID = "icon-contrast"
    SHAPES = %w[rect circle ellipse polygon path].freeze
    PLATE_PAD = 2

    def call(doc, _context)
      roles = Provider.roles(doc)
      icons(doc, roles) + groups(doc, roles)
    end

    private

    def icons(doc, roles)
      doc.icons.reject(&:fallback).flat_map do |icon|
        tile = tile_color(icon.body)
        next [] unless tile

        DiagramPalette.brand_failures({ light: tile, dark: tile }, background(doc, icon, roles)).map do |theme, ratio|
          finding(DiagramProviderChecks.where(icon), "#{theme}: tile #{tile} is #{ratio.round(2)}:1 on its background, under #{DiagramPalette::STROKE_MIN}",
                  "add <rect class=\"plate\"> behind the icon inside its g.icon, at least #{PLATE_PAD}px larger on every side, filled with a surface that clears #{DiagramPalette::STROKE_MIN}:1")
        end
      end
    end

    def groups(doc, roles)
      return [] unless Provider.profile(doc.provider)

      bg = Provider.hexes(roles, "var(--bg)")
      names = roles[:dark].keys.select { |name| Provider.role_kind(doc.provider, name) }
      names.flat_map do |name|
        DiagramPalette.brand_failures(Provider.hexes(roles, "var(#{name})"), bg).map do |theme, ratio|
          finding(name, "#{theme}: #{name} is #{ratio.round(2)}:1 on --bg, under #{DiagramPalette::STROKE_MIN}",
                  "use the profile's dark value or a background that clears it")
        end
      end
    end

    # A plate counts only when it shows: it must extend PLATE_PAD past the
    # icon on every side, since an opaque tile hides a plate of its own size.
    def background(doc, icon, roles)
      plate = icon.plate
      if plate && DiagramSvg::Geometry.box(plate).contains_box?(icon.box.inset(-PLATE_PAD)) && plate.attributes["fill"]
        return Provider.hexes(roles, plate.attributes["fill"])
      end

      kind, id = icon.owner
      fill = owner_fill(doc, kind, id)
      fill = nil if fill == "none"
      Provider.hexes(roles, fill || (kind == :node ? "var(--surface)" : "var(--bg)"))
    end

    def owner_fill(doc, kind, id)
      case kind
      when :node then node_fill(doc.node(id))
      when :group then doc.group(id)&.fill
      end
    end

    # The fill attribute on a node's own shape, if it sets one.
    def node_fill(node)
      shape = node && node.element.elements.find { |el| DiagramSvg::SHAPES.include?(el.name) }
      shape&.attributes&.[]("fill")
    end

    # The fill covering the most area in the icon body: shapes with a
    # literal fill (own or inherited inside the body), weighted by bbox area.
    def tile_color(body)
      frag = REXML::Document.new("<svg>#{body}</svg>")
      areas = Hash.new(0.0)
      REXML::XPath.match(frag.root, "//*").each do |el|
        next unless SHAPES.include?(el.name)

        rgb = DiagramPalette.rgb(inherited_fill(el))
        area = rgb && area(el)
        areas[DiagramPalette.hex(rgb)] += area if area
      end
      areas.max_by(&:last)&.first
    rescue REXML::ParseException
      nil
    end

    def inherited_fill(el)
      while el.is_a?(REXML::Element)
        own = el.attributes["style"].to_s[/(?:\A|;)\s*fill\s*:\s*([^;]+)/, 1]&.strip || el.attributes["fill"]
        return own if own

        el = el.parent
      end
      nil
    end

    def area(el)
      return DiagramSvg::Geometry.box(el)&.then { |b| b.w * b.h } unless el.name == "path"

      segs = DiagramSvg::PathData.segments(el.attributes["d"].to_s)
      return nil if segs.empty?

      xs = segs.flat_map { |s| [ s.x1, s.x2 ] }
      ys = segs.flat_map { |s| [ s.y1, s.y2 ] }
      (xs.max - xs.min) * (ys.max - ys.min)
    end
  end

  # Provider groups nest strictly: each sits inside its parent with an
  # inset, never partly overlaps a group it is not nested in, follows the
  # profile's depth order, holds its nodes inside, and an edge crosses any
  # group border at most once.
  class GroupNesting < Base
    ID = "group-nesting"
    MIN_INSET = 16

    def call(doc, _context)
      groups = doc.groups
      groups.flat_map { |g| nesting(doc, g) + order(doc, g) + members(doc, g) + crossings(doc, g) } + overlaps(doc, groups)
    end

    private

    def nesting(doc, group)
      parent = group.parent && doc.group(group.parent)
      return [] unless parent && !parent.box.contains_box?(group.box, inset: MIN_INSET)

      [ finding(group.id, "group sits less than #{MIN_INSET}px inside #{parent.id}", "inset it at least #{MIN_INSET}px") ]
    end

    def order(doc, group)
      profile = Provider.profile(doc.provider)
      return [] unless profile

      kinds = Provider.groups(doc.provider)
      spec = kinds[group.kind]
      return [ finding(group.id, "group kind #{group.kind.inspect} is not in the #{doc.provider} profile", "use one of #{kinds.keys.join(', ')}") ] unless spec

      depth_order(doc, group, kinds, spec) + max_depth(group, profile["max_depth"])
    end

    def depth_order(doc, group, kinds, spec)
      parent = group.parent && doc.group(group.parent)
      pspec = parent && kinds[parent.kind]
      return [] unless pspec && pspec["depth"] >= spec["depth"]

      [ finding(group.id, "#{group.kind} cannot nest inside #{parent.kind}", "nest groups in the profile's depth order") ]
    end

    def max_depth(group, max)
      max && group.depth > max ? [ finding(group.id, "nesting depth #{group.depth} exceeds #{max}", "split by layer") ] : []
    end

    def members(doc, group)
      doc.nodes_in(group).reject { |n| group.box.contains_box?(n.box, inset: MIN_INSET) }.map do |n|
        finding(n.id, "node sits less than #{MIN_INSET}px inside group #{group.id}", "move it inside the group border")
      end
    end

    def crossings(doc, group)
      border = group.box.edges
      doc.edges.filter_map do |edge|
        count = edge.segments.sum { |s| border.count { |b| s.crosses?(b) } }
        finding(edge.id, "edge crosses the #{group.id} border #{count} times", "route it to cross each group border at most once") if count > 1
      end
    end

    def overlaps(doc, groups)
      groups.combination(2).filter_map do |a, b|
        next if ancestor?(doc, a, b) || ancestor?(doc, b, a) || !a.box.intersect?(b.box)

        finding(a.id, "group partly overlaps #{b.id}", "nest one inside the other or move them apart")
      end
    end

    def ancestor?(doc, anc, group)
      while group&.parent
        return true if group.parent == anc.id

        group = doc.group(group.parent)
      end
      false
    end
  end

  # A provider group's label chip (its direct texts and corner icons) sits
  # inside its border, clear of every child group and node, and no edge
  # runs through it.
  class GroupLabelClearance < Base
    ID = "group-label-clearance"

    def call(doc, context)
      doc.groups.flat_map do |group|
        chip = chip_box(doc, group, context)
        next [] unless chip

        inside(group, chip) + children(doc, group, chip) + edges(doc, group, chip)
      end
    end

    private

    def chip_box(doc, group, context)
      boxes = group.label_texts.filter_map { |el| (t = doc.texts.find { |x| x.element == el }) && context.text_box(t) }
      boxes += group.chip_icons.filter_map { |el| doc.icons.find { |i| i.element.parent == el }&.box }
      boxes.reduce { |a, b| a.union(b) }
    end

    def inside(group, chip)
      group.box.contains_box?(chip) ? [] : [ finding(group.id, "label chip leaves the group border", "move the label inside the top-left corner") ]
    end

    def children(doc, group, chip)
      kids = doc.groups.select { |g| g.parent == group.id }.map { |g| [ g.id, g.box ] } + doc.nodes_in(group).map { |n| [ n.id, n.box ] }
      kids.select { |_, box| box.intersect?(chip) }.map do |id, _|
        finding(group.id, "label chip overlaps #{id}", "move #{id} below the label chip")
      end
    end

    def edges(doc, group, chip)
      doc.edges.select { |e| e.segments.any? { |s| s.intersects_box?(chip) } }.map do |e|
        finding(e.id, "edge runs through the #{group.id} label chip", "route it clear of the label")
      end
    end
  end
end
