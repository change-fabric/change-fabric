# frozen_string_literal: true

require "digest"
require "json"
require "rexml/document"
require_relative "svg_checks"
require_relative "cloud_icons"
require_relative "diagram_palette"
require_relative "diagram_styles"

# The cf:diagram checks for provider architecture diagrams
# (data-provider="aws" on an architecture SVG): icon provenance against the
# pinned pack, icon placement, provider color contrast, and strict group
# nesting with clear label chips. A diagram with no provider icon and no
# provider group yields nothing here, so today's diagrams are unaffected.
#
# Colors are never resolved here. Contrast and recoloring read the computed
# styles the lint's pinned Chromium reports (DiagramStyles); without Docker
# those checks say so instead of guessing.
module DiagramProviderChecks
  Base = SvgChecks::Base
  DOCKER_REQUIRED = "Docker is required: provider icon colors are read from a pinned Chromium, which parses the CSS"

  # The name a finding points at: the icon instance id, else its slug.
  def self.where(icon) = icon.element.parent.attributes["id"] || icon.slug || "icon"

  # The computed styles for doc, or a finding that explains why not.
  def self.styles_or_finding(check, doc, context)
    styles = context.styles
    return [ nil, check.send(:finding, "svg", DOCKER_REQUIRED, "run diagram_lint.rb where Docker is available, without --no-measure") ] unless styles
    return [ nil, check.send(:finding, "svg", "computed styles do not line up with the parsed SVG", "re-run the lint; report it if it persists") ] unless styles.aligned?(doc)

    [ styles, nil ]
  end

  # Document index of every element, by identity, matching the browser's order.
  def self.index(doc) = doc.all_elements.each_with_index.to_h.compare_by_identity

  # Provider profile lookups shared by the provider checks.
  module Provider
    module_function

    def profile(provider) = provider && CloudIcons.manifest(provider)
    def groups(provider) = profile(provider)&.fetch("groups", nil) || {}

    # The official hex for one group kind.
    def colors(provider, kind)
      spec = groups(provider)[kind]
      spec ? [ spec["color"] ].compact.map(&:upcase) : []
    end

    # The group kind a --<provider>-<kind> custom property names, or nil.
    def role_kind(provider, name)
      provider && name.to_s[/\A--#{Regexp.escape(provider)}-([a-z0-9-]+)\z/, 1]
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

  # Every provider icon proves where it came from. A pack icon's g.icon holds
  # an optional leading plate, exactly one notice comment, and the svg.icon,
  # and that svg.icon (viewBox, preserveAspectRatio, and body; only x, y,
  # width, and height may vary) hashes the same as the pinned pack file
  # normalized the same way. Nothing in the diagram may change how the icon
  # renders: the browser compares each icon as placed with the same svg
  # alone, in both color schemes. A fallback glyph warns and stays on palette.
  class IconPackProvenance < Base
    ID = "icon-pack-provenance"

    def call(doc, context)
      return [] if doc.icons.empty?

      doc.icons.flat_map { |icon| judge(icon, context) } + recolored(doc, context)
    end

    # sha256 of an svg element's normalized viewport and body tree.
    def self.digest(view_box:, aspect:, children:)
      tree = lambda do |node|
        case node
        when REXML::Element then [ node.name, node.attributes.to_h.sort, node.children.filter_map { |c| tree.call(c) } ]
        when REXML::Text then (text = node.value.strip).empty? ? nil : text
        end
      end
      material = [ view_box.to_s.split(/[\s,]+/).map(&:to_f), aspect, children.filter_map { |c| tree.call(c) } ]
      Digest::SHA256.hexdigest(JSON.generate(material))
    end

    def self.placed_digest(svg)
      digest(view_box: svg.attributes["viewBox"], aspect: svg.attributes["preserveAspectRatio"], children: svg.children)
    end

    def self.pinned_digest(file)
      root = REXML::Document.new(file).root
      digest(view_box: CloudIcons.view_box(file), aspect: root.attributes["preserveAspectRatio"], children: root.children)
    end

    private

    def judge(icon, context)
      where = DiagramProviderChecks.where(icon)
      unless icon.provider && icon.slug
        return [ finding(where, "svg.icon is not wrapped in a g.icon with data-provider and data-icon", "wrap it as cloud_icons.rb inline does") ]
      end
      return [ finding(where, "provider #{icon.provider.inspect} has no pack profile", "use a provider under skills/diagram/packs") ] unless Provider.profile(icon.provider)
      return fallback(icon, context) if icon.fallback

      structure = structure(icon, where)
      return structure unless structure.empty?

      pack = context.packs&.pack(icon.provider)
      return verify(icon, pack, where) if pack

      [ finding(where, "#{icon.provider} pack is not cached, provenance not verified", "run ruby scripts/cloud_icons.rb #{icon.provider}", severity: "warn") ]
    end

    # [plate]? notice-comment svg.icon, and nothing else.
    def structure(icon, where)
      parts = icon.element.parent.children.reject { |c| c.is_a?(REXML::Text) && c.value.strip.empty? }
      parts = parts.drop(1) if plate?(parts.first)
      notice = CloudIcons.notice_comment(icon.provider)
      return [] if parts.size == 2 && parts[0].is_a?(REXML::Comment) && parts[0].string.strip == notice && parts[1] == icon.element

      [ finding(where, "g.icon must hold an optional leading plate, one notice comment, and the svg.icon, in that order",
                "re-inline it with cloud_icons.rb and put any plate first") ]
    end

    def plate?(node) = node.is_a?(REXML::Element) && node.name == "rect" && node.attributes["class"].to_s.split.include?("plate")

    # The only attributes the placed svg.icon root may carry: its class,
    # placement, and the two viewport attributes the digest covers. Anything
    # else (opacity, style, filter) would restyle the artwork unseen.
    ROOT_ATTRIBUTES = %w[class x y width height viewBox preserveAspectRatio].freeze

    def verify(icon, pack, where)
      file = pack.file(icon.slug)
      return [ finding(where, "#{icon.provider} pack has no icon #{icon.slug.inspect}", "use a pack slug or the Phosphor fallback") ] unless file

      extra = icon.element.attributes.keys - ROOT_ATTRIBUTES
      unless extra.empty?
        return [ finding(where, "svg.icon root carries #{extra.join(', ')}; only #{ROOT_ATTRIBUTES.join(', ')} are allowed",
                         "re-inline the icon from the pack and style its node or plate instead") ]
      end
      return [] if self.class.placed_digest(icon.element) == self.class.pinned_digest(file)

      [ finding(where, "svg.icon differs from the pinned #{icon.provider} file for #{icon.slug} (viewBox, preserveAspectRatio, or body)",
                "re-inline the icon from the pack unmodified") ]
    rescue REXML::ParseException
      [ finding(where, "the pinned #{icon.provider} file for #{icon.slug} does not parse", "re-fetch the pack") ]
    end

    # Pack icons whose rendering the diagram changes, one finding per icon
    # and scheme, naming the first changed property.
    def recolored(doc, context)
      pack_icons = doc.icons.reject(&:fallback).select(&:slug)
      return [] if pack_icons.empty?

      styles, problem = DiagramProviderChecks.styles_or_finding(self, doc, context)
      return [ problem ] if problem

      index = DiagramProviderChecks.index(doc)
      by_svg = pack_icons.to_h { |icon| [ index[icon.element], icon ] }
      DiagramStyles::SCHEMES.flat_map do |scheme|
        styles[scheme.to_sym].recolored.group_by { |r| r["icon"] }.filter_map do |svg_index, diffs|
          icon = by_svg[svg_index] or next
          d = diffs.first
          tag = doc.all_elements[d["el"]]&.name
          finding(DiagramProviderChecks.where(icon), "#{scheme}: the diagram changes #{d['prop']} of a #{tag} inside the icon (#{d['got']}, the pack draws #{d['want']})",
                  "scope the rule so it cannot reach inside g.icon")
        end
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
      unless icon.view_box && icon.box.w.positive? && icon.box.h.positive? && view_box_valid?(icon.view_box)
        return [ finding(where, "svg.icon needs width, height, and a viewBox with positive size", "set x, y, width, height, and viewBox") ]
      end

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
  # icon's area-weighted tile color must clear STROKE_MIN against what it
  # sits on, in both color schemes, both read as Chromium computes them.
  # What it sits on is the first painted surface behind it: a plate drawn
  # before it that shows PLATE_PAD past it, else its node or group shape,
  # else each enclosing group, else the diagram --bg. Provider group borders
  # keep the official colors exactly and are not graded. The fix is a
  # surface plate behind the icon, never a recolor.
  class IconContrast < Base
    ID = "icon-contrast"
    SHAPES = %w[rect circle ellipse polygon path].freeze
    PLATE_PAD = 2

    def call(doc, context)
      icons = doc.icons.reject(&:fallback)
      return [] if icons.empty?

      styles, problem = DiagramProviderChecks.styles_or_finding(self, doc, context)
      return [ problem ] if problem

      index = DiagramProviderChecks.index(doc)
      icons.flat_map { |icon| judge(doc, icon, styles, index) }
    end

    private

    def judge(doc, icon, styles, index)
      tiles = DiagramStyles::SCHEMES.to_h { |s| [ s.to_sym, tile_color(icon, styles[s.to_sym], index) ] }
      backs = DiagramStyles::SCHEMES.to_h { |s| [ s.to_sym, background(doc, icon, styles[s.to_sym], index) ] }
      DiagramPalette.brand_failures(tiles, backs).map do |theme, ratio|
        finding(DiagramProviderChecks.where(icon), "#{theme}: tile #{tiles[theme]} is #{ratio.round(2)}:1 on its background, under #{DiagramPalette::STROKE_MIN}",
                "add <rect class=\"plate\"> behind the icon inside its g.icon, at least #{PLATE_PAD}px larger on every side, filled with a surface that clears #{DiagramPalette::STROKE_MIN}:1")
      end
    end

    def fill(scheme, index, el) = el && DiagramStyles.hex(scheme.paint.dig(index[el], "fill"))

    def background(doc, icon, scheme, index)
      plate = icon.plate
      if plate && DiagramSvg::Geometry.box(plate).contains_box?(icon.box.inset(-PLATE_PAD))
        painted = fill(scheme, index, plate)
        return painted if painted
      end

      surfaces(doc, icon).each do |el|
        painted = fill(scheme, index, el)
        return painted if painted
      end
      DiagramStyles.hex(scheme.bg)
    end

    # The owner's shape, then each enclosing group's rect, innermost first.
    def surfaces(doc, icon)
      kind, id = icon.owner
      owner = kind == :node ? doc.node(id)&.element : doc.group(id)&.element
      own = owner && owner.elements.find { |el| SHAPES.include?(el.name) }
      enclosing = doc.groups.select { |g| g.element != owner && doc.descendant?(icon.element, g.element) }.sort_by { |g| -g.depth }
      [ own, *enclosing.map { |g| g.element.elements.find { |el| el.name == "rect" } } ].compact
    end

    # The computed fill covering the most area among the icon's shapes.
    def tile_color(icon, scheme, index)
      areas = Hash.new(0.0)
      REXML::XPath.match(icon.element, ".//*").each do |el|
        next unless SHAPES.include?(el.name)

        color = fill(scheme, index, el)
        area = color && area(el)
        areas[color] += area if area
      end
      areas.max_by(&:last)&.first
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
