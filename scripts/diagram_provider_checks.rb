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

  # A small CSS selector matcher: compound selectors (type, #id, .class)
  # joined by descendant or child combinators. Attribute, pseudo, and
  # sibling selectors parse to nil so callers pick a conservative answer.
  module Selector
    module_function

    COMPOUND = /\A(?<type>[a-z][\w-]*|\*)?(?<rest>(?:[.#][\w-]+)*)\z/

    # Steps left to right, each [combinator to its left, type, simples].
    def parse(sel)
      steps = []
      combinator = :descendant
      sel.gsub(/\s*>\s*/, " > ").split.each do |token|
        next combinator = :child if token == ">"

        m = COMPOUND.match(token)
        return nil unless m

        steps << [ combinator, m[:type], m[:rest].scan(/([.#])([\w-]+)/) ]
        combinator = :descendant
      end
      steps.empty? ? nil : steps
    end

    def match?(steps, el)
      *left, (combinator, type, simples) = steps
      compound?(el, type, simples) && left_match?(left, el.parent, combinator)
    end

    def left_match?(steps, el, combinator)
      return true if steps.empty?

      *left, (next_combinator, type, simples) = steps
      return compound?(el, type, simples) && left_match?(left, el.parent, next_combinator) if combinator == :child

      while el.is_a?(REXML::Element)
        return true if compound?(el, type, simples) && left_match?(left, el.parent, next_combinator)

        el = el.parent
      end
      false
    end

    def compound?(el, type, simples)
      return false unless el.is_a?(REXML::Element)
      return false if type && type != "*" && el.name != type

      classes = el.attributes["class"].to_s.split
      simples.all? { |kind, name| kind == "#" ? el.attributes["id"] == name : classes.include?(name) }
    end
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
  # A stylesheet rule that matches an element inside an icon body (such as
  # `.node rect` or a bare `path`) would recolor the pack's artwork at
  # render time, so it is an error too.
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
      painting = css.scan(/([^{}]+)\{([^{}]*)\}/).reject { |_, body| inert?(body) }.map(&:first)
      painting.flat_map { |list| list.split(",").map(&:strip) }.uniq.filter_map do |sel|
        next unless reaches?(doc, sel)

        finding("style", "selector #{sel.inspect} reaches into icon bodies and would recolor them", fix_for(sel))
      end
    end

    # Properties that never change how the artwork is drawn. A rule made only
    # of these cannot recolor an icon; anything else is treated as painting.
    INERT = %w[pointer-events cursor user-select transition transition-property
               transition-duration transition-delay transition-timing-function].freeze

    def inert?(body)
      props = body.scan(/(?:\A|;)\s*([\w-]+)\s*:/).flatten.map(&:downcase)
      !props.empty? && props.all? { |prop| INERT.include?(prop) }
    end

    def fix_for(sel)
      return "scope it with a class or a child combinator so it cannot match inside an icon" unless sel.match?(/\s/)

      "use a child combinator, such as #{sel.sub(/\s+(\S+)\z/, ' > \1').inspect}"
    end

    # True when the selector matches an element inside some icon body. A
    # selector the matcher cannot parse falls back to the syntactic rule: a
    # bare shape type that a child combinator does not pin.
    def reaches?(doc, sel)
      steps = Selector.parse(sel)
      return syntactic_reach?(sel) unless steps

      doc.icons.any? { |icon| REXML::XPath.match(icon.element, ".//*").any? { |el| Selector.match?(steps, el) } }
    end

    def syntactic_reach?(sel)
      parts = sel.split(/\s+/)
      parts.last.match?(REACHING) && parts[-2] != ">"
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

      off = (CloudIcons.colors(icon.body) - pack.colors(icon.slug)).map do |c|
        finding(where, "color #{c} is not in the #{icon.provider} pack file for #{icon.slug}", "inline the pack file unmodified")
      end
      return off unless off.empty?
      pinned = pack.file(icon.slug)
      unless icon.view_box.to_s.split.join(" ") == CloudIcons.view_box(pinned).to_s.split.join(" ")
        return [ finding(where, "viewBox #{icon.view_box.inspect} differs from the pinned #{icon.provider} file for #{icon.slug}", "re-inline the icon from the pack") ]
      end
      return [] if canonical(icon.body) == canonical(CloudIcons.inner(pinned))

      [ finding(where, "icon body differs from the pinned #{icon.provider} file for #{icon.slug}", "re-inline the icon from the pack") ]
    end

    # Element tree with sorted attributes, ignoring whitespace and comments,
    # so serialization differences are not edits but changed artwork is.
    def canonical(markup)
      tree = ->(el) { [ el.name, el.attributes.to_h.sort, el.elements.map { |child| tree.call(child) } ] }
      REXML::Document.new("<svg>#{markup}</svg>").root.elements.map { |el| tree.call(el) }
    rescue REXML::ParseException
      nil
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
      unless icon.view_box && icon.box.w.positive? && icon.box.h.positive? && view_box_valid?(icon.view_box)
        return [ finding(where, "svg.icon needs width, height, and a viewBox with positive size", "set x, y, width, height, and viewBox") ]
      end
      return [ finding(where, "a plate is drawn over the icon", "move <rect class=\"plate\"> before the icon's <svg>") ] if plate_after?(icon)

      kind, id = icon.owner
      case kind
      when :node then in_node(doc, icon, id, where, context)
      when :group then in_group(doc, icon, id, where)
      else [ finding(where, "icon sits in no node or provider group", "place it inside a g.node or g.group") ]
      end
    end

    def view_box_valid?(view_box)
      nums = view_box.to_s.split(/[\s,]+/).map { |n| Float(n, exception: false) }
      nums.size == 4 && nums.none?(&:nil?) && nums[2].positive? && nums[3].positive?
    end

    def plate_after?(icon)
      wrap = icon.element.parent
      siblings = wrap.elements.to_a
      siblings.drop(siblings.index(icon.element) + 1).any? { |el| el.name == "rect" && el.attributes["class"].to_s.split.include?("plate") }
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
      if plate && DiagramSvg::Geometry.box(plate).contains_box?(icon.box.inset(-PLATE_PAD))
        fills = shape_fills(doc, plate)
        return resolve(fills, roles, nil) if fills.values.all? { |f| f && f != "none" }
      end

      kind, id = icon.owner
      resolve(owner_fills(doc, kind, id), roles, kind == :node ? "var(--surface)" : "var(--bg)")
    end

    def resolve(fills, roles, default)
      %i[light dark].to_h do |theme|
        fill = fills[theme]
        fill = default if fill.nil? || fill == "none"
        [ theme, DiagramPalette.resolve_hex(roles[theme], fill) ]
      end
    end

    def owner_fills(doc, kind, id)
      case kind
      when :node then node_fills(doc, doc.node(id))
      when :group then group_fills(doc, doc.group(id))
      else {}
      end
    end

    def group_fills(doc, group)
      rect = group && group.element.elements.find { |el| el.name == "rect" }
      rect ? shape_fills(doc, rect) : {}
    end

    def node_fills(doc, node)
      shape = node && node.element.elements.find { |el| DiagramSvg::SHAPES.include?(el.name) }
      shape ? shape_fills(doc, shape) : {}
    end

    # A shape's rendered fill per theme, by CSS precedence: an !important
    # stylesheet rule, then inline style, then the last matching rule (dark
    # rules over light), then the presentation attribute. Specificity is not
    # weighed.
    def shape_fills(doc, shape)
      inline = fill_decl(shape.attributes["style"].to_s)&.first
      attr = shape.attributes["fill"]
      theme_rules(doc).transform_values do |rules|
        value, important = sheet_fill(rules, shape)
        (important && value) || inline || value || attr
      end
    end

    # [value, important?] of the last fill declaration in a body, or nil.
    def fill_decl(body)
      raw = body.scan(/(?:\A|;)\s*fill\s*:\s*([^;]+)/).flatten.last&.strip
      raw && [ raw.sub(/\s*!important\z/i, ""), raw.match?(/!important\z/i) ]
    end

    def theme_rules(doc)
      css = SvgChecks::DeclaredProperty.stylesheet(doc)
      dark_media = css.scan(/@media[^{]*prefers-color-scheme:\s*dark[^{]*\{((?:[^{}]*\{[^{}]*\})*[^{}]*)\}/m).flatten
      top = DiagramPalette.rules(css.gsub(/@media[^{]*\{(?:[^{}]*\{[^{}]*\})*[^{}]*\}/m, ""))
      themed, light = top.partition { |sel, _| sel.match?(/data-theme=["']?dark/) }
      dark = themed.map { |sel, body| [ sel.gsub(/[^\s,]*\[data-theme=["']?dark["']?\]\s*/, ""), body ] }
      { light: light, dark: light + dark + dark_media.flat_map { |m| DiagramPalette.rules(m) } }
    end

    # The winning matching fill: !important first, then selector
    # specificity, then source order.
    def sheet_fill(rules, shape)
      ranked = rules.each_with_index.filter_map do |(sels, body), index|
        decl = fill_decl(body)
        next unless decl

        specs = sels.split(",").map(&:strip).filter_map { |sel| (steps = Selector.parse(sel)) && Selector.match?(steps, shape) && specificity(steps) }
        [ decl, [ decl.last ? 1 : 0, specs.max, index ] ] unless specs.empty?
      end
      ranked.max_by(&:last)&.first
    end

    # [ids, classes, types] for a parsed selector.
    def specificity(steps)
      steps.each_with_object([ 0, 0, 0 ]) do |(_, type, simples), acc|
        acc[0] += simples.count { |kind, _| kind == "#" }
        acc[1] += simples.count { |kind, _| kind == "." }
        acc[2] += 1 if type && type != "*"
      end
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
      doc.edges.filter_map do |edge|
        count = edge.subpaths.sum { |segs| side_changes(segs, group.box) }
        finding(edge.id, "edge crosses the #{group.id} border #{count} times", "route it to cross each group border at most once") if count > 1
      end
    end

    # Border crossings along one subpath: sample each segment at its border
    # hits and the midpoints between them, drop samples on the border, and
    # count inside/outside changes. A vertex on the border then counts once
    # when the path changes side there, and not at all when it only touches.
    def side_changes(segs, box)
      sides = segs.flat_map { |s| samples(s, box) }.filter_map { |x, y| side(box, x, y) }
      sides.each_cons(2).count { |a, b| a != b }
    end

    def samples(seg, box)
      ts = ([ 0.0, 1.0 ] + box.edges.filter_map { |b| hit(seg, b) }).uniq.sort
      points = ts.each_cons(2).flat_map { |a, b| [ a, (a + b) / 2.0 ] } + [ 1.0 ]
      points.map { |t| [ seg.x1 + (t * seg.dx), seg.y1 + (t * seg.dy) ] }
    end

    # Where along seg (0..1) it meets border segment b, or nil.
    def hit(seg, b)
      den = (seg.dx * b.dy) - (seg.dy * b.dx)
      return nil if den.abs < 1e-9

      t = (((b.x1 - seg.x1) * b.dy) - ((b.y1 - seg.y1) * b.dx)) / den.to_f
      u = (((b.x1 - seg.x1) * seg.dy) - ((b.y1 - seg.y1) * seg.dx)) / den.to_f
      t if t.between?(0.0, 1.0) && u.between?(0.0, 1.0)
    end

    def side(box, x, y)
      return :in if box.contains_point?(x, y)

      :out unless box.edges.any? { |e| e.distance_to_point(x, y) < 1e-6 }
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
