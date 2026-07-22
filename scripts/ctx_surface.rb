#!/usr/bin/env ruby
# frozen_string_literal: true

require 'date'
require_relative 'ctx_paths'
require_relative 'ctx_store'
require_relative 'skill_registry'

# Deterministic SessionStart context selection: decides WHICH cf:ctx docs to
# inject and at WHAT fidelity, under a hard budget, with no LLM call, no
# randomness, and no clock dependence beyond comparing expires/last_touched to
# `now`. The whole point of the store is that injection stays cheap, so the
# algorithm is biased toward one-line INDEX entries and against full bodies.
# Full bodies are the scarce resource; the budget is spent on them deliberately.
#
# Fidelity levels: FULL (header line plus body), INDEX (a single line), OMITTED
# (not injected, still recallable). Selection assigns exactly one level to every
# live doc plus the roadmap. See cf-ctx-surfacing-design.md for the full spec.
module CtxSurface
  # All TUNABLE. The byte budget is the real guard; the line budget is the
  # human-legible proxy. The floor (roadmap + focused plan) is exempt from the
  # line/byte budgets and from the doc cap's roadmap slot, so it cannot be
  # blocked; the ranked remainder competes for what is left.
  CTX_FULL_DOC_CAP       = 4       # full docs (incl. focused plan, excl. ROADMAP)
  CTX_FULL_LINE_BUDGET   = 600     # total body lines across ranked-remainder FULL docs
  CTX_FULL_BYTE_BUDGET   = 24_000  # total body bytes across ranked-remainder FULL docs
  CTX_INDEX_LINE_CAP     = 60      # max index lines emitted (truth counted first)
  CTX_PER_DOC_FULL_LINES = 300     # a doc body over this is never FULL, only INDEX

  # A doc paired with its derived size, built once at load. Sizing the body is a
  # measure, not a semantic read, so ranking stays frontmatter-only.
  Sized = Data.define(:doc, :body_lines, :body_bytes) do
    def self.of(doc)
      body = doc.body.to_s
      new(doc:, body_lines: body.empty? ? 0 : body.lines.count, body_bytes: body.bytesize)
    end

    def name = doc.name
    def klass = doc.klass
    def status = doc.status
    def oversize? = body_lines > CTX_PER_DOC_FULL_LINES
  end

  # The parsed ROADMAP.md: its body (rendered FULL inside the floor) and its
  # table rows (used only to resolve focus and force siblings to INDEX). Small by
  # construction (the 40-row store cap), so parsing it is cheap.
  Roadmap = Data.define(:body, :body_lines, :rows) do
    def body_oversize? = body_lines > CTX_PER_DOC_FULL_LINES
  end

  # One ROADMAP table row. `detail` names a plan doc (a slug, not a path) or is
  # blank. `updated` is an ISO-8601 string compared lexically, never parsed.
  Row = Data.define(:id, :title, :status, :priority, :updated, :device, :detail)

  # Which row produced the focus and the focused doc it resolves to. `row` is nil
  # when focus came from the meta pointer or the most-recently-touched fallback.
  Focus = Data.define(:doc, :row)

  # The selection result the hook renders. `focus_demoted` means the focused plan
  # was too large to inline and dropped to an INDEX line; `notes` carries the
  # human-readable reasons for any demotion.
  Surface = Data.define(:roadmap, :roadmap_demoted, :focus, :focus_demoted,
                        :full, :index, :overflow_note, :notes)

  # Pure entrypoint. `now`/`home` are injected so tests are clock- and
  # machine-independent; `store` lets a test pass a fake loader with zero disk.
  def self.select(cwd:, home: Dir.home, now: Time.now, store: nil)
    store ||= Loader.new(cwd:, home:)
    docs    = eligible(store.live_docs.map { |doc| Sized.of(doc) }, now)
    roadmap = store.roadmap
    focus   = resolve_focus(roadmap:, docs:, meta: store.meta('focus'))
    build_surface(docs:, roadmap:, focus:)
  end

  # additionalContext markdown the hook emits. Empty string when nothing surfaces.
  def self.render(surface) = Renderer.new(surface).to_md

  # OMITTED filter (section 2): archived docs and expired ephemeral docs are dead
  # weight and never even earn an INDEX line. Malformed docs are already dropped
  # by the loader (they parse to a nameless Doc), so a blank name is filtered too.
  def self.eligible(sized, now)
    today = now.to_date
    sized.reject do |s|
      s.name.empty? || s.status == 'archived' ||
        !CtxPaths.klass?(s.klass) || expired_ephemeral?(s, today)
    end
  end

  def self.expired_ephemeral?(sized, today)
    return false unless sized.klass == 'ephemeral'
    return false if sized.doc.expires.to_s.empty?

    Date.parse(sized.doc.expires) < today
  rescue ArgumentError
    false
  end

  # Focus fallback chain (section 3): roadmap active row, roadmap next row, the
  # .ctx-meta/focus pointer, then the most-recently-touched active doc. First rule
  # that yields an eligible doc wins; the meta pointer sits deliberately below the
  # roadmap so a stale pin can never shadow live work.
  def self.resolve_focus(roadmap:, docs:, meta:)
    by_name = docs.to_h { |s| [ s.name, s ] }
    from_roadmap(roadmap, 'active', by_name) ||
      from_roadmap(roadmap, 'next', by_name) ||
      from_meta(meta, by_name) ||
      most_recent_active(docs)
  end

  # The newest-`updated` row of a status, id-ascending on ties, whose detail
  # resolves to an eligible doc. Deterministic: ISO-8601 `updated` compares
  # lexically, so no parse and no timezone ambiguity beyond the stored string.
  def self.from_roadmap(roadmap, status, by_name)
    return nil unless roadmap

    roadmap.rows.select { |row| row.status == status }
           .sort_by { |row| [ row.updated.to_s, neg(row.id) ] }
           .reverse
           .each do |row|
      doc = resolve_plan(row, by_name)
      return Focus.new(doc:, row:) if doc
    end
    nil
  end

  # A row id sorts ascending on ties, but the surrounding sort is reversed for
  # newest-first, so the id key is negated to keep id ascending after the reverse.
  def self.neg(id) = id.to_s.codepoints.map { |c| -c }

  def self.resolve_plan(row, by_name)
    name = row.detail.to_s.strip
    return nil if name.empty? || name == '-'

    by_name[name]
  end

  def self.from_meta(meta, by_name)
    name = meta.to_s.strip
    return nil if name.empty?

    doc = by_name[name]
    doc && Focus.new(doc:, row: nil)
  end

  # Zero-roadmap fallback: the freshest active/status-active doc, name tie-break.
  def self.most_recent_active(docs)
    candidate = docs.select { |s| s.klass == 'active' && s.status == 'active' }
                    .min_by { |s| [ neg_str(s.doc.last_touched), s.name ] }
    candidate && Focus.new(doc: candidate, row: nil)
  end

  # Sorts an ISO-8601 string newest-first under an ascending min_by: invert each
  # byte. A blank/short value sorts last (oldest), matching the spec's epoch-zero.
  def self.neg_str(value) = value.to_s.codepoints.map { |c| -c }

  def self.build_surface(docs:, roadmap:, focus:)
    by_name      = docs.to_h { |s| [ s.name, s ] }
    siblings     = sibling_plan_names(roadmap, focus, by_name)
    focus_sized  = focus&.doc
    focus_demote = focus_sized&.oversize? || false
    notes        = []

    roadmap_demoted = roadmap&.body_oversize? || false
    notes << 'roadmap exceeded the inline size cap; recall it with cf:ctx recall ROADMAP' if roadmap_demoted
    notes << "focused plan #{focus_sized.name} was too large to inline; recall it by name" if focus_demote

    full_focus = focus_sized unless focus_demote
    full, = rank_remainder(docs:, focus: full_focus, siblings:)
    index, overflow = index_lines(docs:, full:, focus_full: full_focus)

    Surface.new(roadmap:, roadmap_demoted:, focus: focus_sized, focus_demoted: focus_demote,
                full:, index:, overflow_note: overflow, notes:)
  end

  # Detail docs of every NON-focused row are forced to INDEX, computed before
  # ranking so a recently touched sibling can never steal a FULL slot. That is the
  # mechanism that keeps the budget on the one focused plan.
  def self.sibling_plan_names(roadmap, focus, by_name)
    return [] unless roadmap

    focused_id = focus&.row&.id
    roadmap.rows.reject { |row| row.id == focused_id && !focused_id.nil? }
           .filter_map { |row| resolve_plan(row, by_name)&.name }
           .uniq
  end

  # FULL-eligible candidates (truth-active, active-active, body within the per-doc
  # cap), minus the floor's focused plan and the forced-INDEX siblings, walked in
  # rank order and admitted to FULL until any budget dimension is hit. The instant
  # one does not fit, it and every lower-ranked candidate are demoted to INDEX: we
  # drop lowest-rank, never truncate a body and never skip ahead to bin-pack.
  def self.rank_remainder(docs:, focus:, siblings:)
    excluded = [ focus&.name, *siblings ].compact
    ranked = docs.select { |s| full_eligible?(s) }
                 .reject { |s| excluded.include?(s.name) }
                 .sort { |a, b| compare_rank(a, b, focus) }
    admit(ranked, CTX_FULL_DOC_CAP - (focus ? 1 : 0))
  end

  def self.full_eligible?(sized)
    return false if sized.oversize?

    (sized.klass == 'truth' || sized.klass == 'active') && sized.status == 'active'
  end

  def self.admit(ranked, doc_budget)
    full = []
    lines = 0
    bytes = 0
    ranked.each_with_index do |s, i|
      lines += s.body_lines
      bytes += s.body_bytes
      fits = full.size < doc_budget && lines <= CTX_FULL_LINE_BUDGET && bytes <= CTX_FULL_BYTE_BUDGET
      return [ full, ranked[i..] ] unless fits

      full << s
    end
    [ full, [] ]
  end

  # Rank tuple (section 2), compared lexically so the order is fully explainable:
  # tier ascending, then last_touched descending, then name ascending. Names are
  # unique per store, so this is a total, reproducible order on every device.
  def self.compare_rank(a, b, focus)
    by_tier = tier(a, focus) <=> tier(b, focus)
    return by_tier unless by_tier.zero?

    by_touch = b.doc.last_touched.to_s <=> a.doc.last_touched.to_s
    return by_touch unless by_touch.zero?

    a.name <=> b.name
  end

  def self.tier(sized, focus)
    return 0 if focus && sized.name == focus.name
    return 1 if sized.klass == 'truth' && sized.status == 'active'
    return 2 if sized.klass == 'active' && sized.status == 'active' && focus.nil?
    return 3 if sized.klass == 'active' && sized.status == 'active'

    4
  end

  # INDEX emission (section 5): every eligible doc not rendered FULL, partitioned
  # truth then active then ephemeral, each freshest-first. Truth lines are counted
  # first and always win the cap; non-truth overflow is dropped with a note.
  def self.index_lines(docs:, full:, focus_full:)
    shown = (full.map(&:name) + [ focus_full&.name ]).compact
    remaining = docs.reject { |s| shown.include?(s.name) }
    truth = sort_index(remaining.select { |s| s.klass == 'truth' })
    other = sort_index(remaining.reject { |s| s.klass == 'truth' })

    slots = [ CTX_INDEX_LINE_CAP - truth.size, 0 ].max
    kept = truth + other.first(slots)
    dropped = other.size - other.first(slots).size
    overflow = dropped.positive? ? "(+#{dropped} more docs, run cf:ctx list)" : nil
    [ kept, overflow ]
  end

  # Truth first within its group, active before ephemeral within the other group,
  # each by last_touched descending then name, mirroring the rank order without a
  # focus (index lines never carry the tier-0 focus distinction).
  def self.sort_index(group)
    group.sort do |a, b|
      by_klass = klass_order(a.klass) <=> klass_order(b.klass)
      next by_klass unless by_klass.zero?

      by_touch = b.doc.last_touched.to_s <=> a.doc.last_touched.to_s
      by_touch.zero? ? a.name <=> b.name : by_touch
    end
  end

  def self.klass_order(klass) = { 'truth' => 0, 'active' => 1, 'ephemeral' => 2 }.fetch(klass, 3)

  # The only component that touches the filesystem (glob + read), isolated so
  # `select` is unit-testable against an injected fake. Every read is rescued
  # per-file so one unreadable doc never sinks the whole surface.
  class Loader
    def initialize(cwd:, home: Dir.home)
      @cwd = cwd
      @home = home
    end

    # Every parseable live doc across the classes. A malformed doc parses to a
    # nameless Doc and is filtered out by CtxSurface.eligible.
    def live_docs
      CtxPaths::CLASSES.flat_map do |klass|
        dir = CtxPaths.class_dir(klass, @cwd, home: @home)
        Dir.glob(File.join(dir, '*.md')).sort.filter_map { |path| safe_parse(path) }
      end
    end

    def roadmap
      path = CtxPaths.roadmap(@cwd, home: @home)
      return nil unless File.file?(path)

      RoadmapParser.parse(File.read(path))
    rescue StandardError
      nil
    end

    def meta(name)
      path = CtxPaths.meta(name, @cwd, home: @home)
      File.file?(path) ? File.read(path).strip : nil
    rescue StandardError
      nil
    end

    private

    def safe_parse(path)
      CtxStore::Doc.parse(File.read(path))
    rescue StandardError
      nil
    end
  end

  # Parses ROADMAP.md (frontmatter optional) into a body plus its table rows. A
  # file with no table yields zero rows, never an error: a roadmap that does not
  # parse degrades to "no roadmap" for focus while its body can still render.
  module RoadmapParser
    COLUMNS = %i[id title status priority updated device detail].freeze

    def self.parse(text)
      _front, body = SkillRegistry::Frontmatter.split(text)
      body = body.to_s.strip
      Roadmap.new(body:, body_lines: body.empty? ? 0 : body.lines.count, rows: rows(body))
    end

    # Table rows only: a line that starts with a pipe, is not the header, and is
    # not the `|---|` separator. Each is split into the seven known columns.
    def self.rows(body)
      body.lines.map(&:strip).select { |line| line.start_with?('|') }
          .reject { |line| separator?(line) || header?(line) }
          .filter_map { |line| row(line) }
    end

    def self.separator?(line) = line.gsub(/[|\s:-]/, '').empty?

    def self.header?(line) = cells(line).first&.downcase == 'id'

    def self.row(line)
      values = cells(line)
      return nil if values.empty?

      Row.new(**COLUMNS.each_with_index.to_h { |col, i| [ col, values[i].to_s ] })
    end

    # Inner cells of a `| a | b |` line: drop the empty edges the outer pipes make.
    def self.cells(line)
      parts = line.split('|').map(&:strip)
      parts.shift if parts.first == ''
      parts.pop if parts.last == ''
      parts
    end
  end

  # Renders a Surface to the markdown additionalContext block. Plain hyphens only,
  # no slop glyphs (glyph_guard.rb would deny otherwise). Emits "" when there is
  # nothing to surface so the hook can stay silent on an empty store.
  class Renderer
    HEADER = '## Project context (cf:ctx)'

    def initialize(surface) = @s = surface

    def to_md
      sections = [ roadmap_section, focus_section, full_section, index_section, notes_section ].compact
      return '' if sections.empty?

      ([ HEADER ] + sections).join("\n\n") + "\n"
    end

    private

    def roadmap_section
      return nil unless @s.roadmap
      return "### Roadmap\n(roadmap too large to inline; recall with cf:ctx recall ROADMAP)" if @s.roadmap_demoted

      "### Roadmap\n#{@s.roadmap.body}"
    end

    def focus_section
      return nil unless @s.focus
      return nil if @s.focus_demoted

      "### Focused plan: #{@s.focus.name}\n#{@s.focus.doc.body}"
    end

    def full_section
      return nil if @s.full.empty?

      blocks = @s.full.map { |sized| "#{full_header(sized)}\n#{sized.doc.body}" }
      "### In focus and durable (full)\n\n#{blocks.join("\n\n")}"
    end

    def index_section
      return nil if @s.index.empty? && @s.overflow_note.nil?

      lines = @s.index.map { |sized| index_line(sized) }
      lines << @s.overflow_note if @s.overflow_note
      "### Index (recall by name with cf:ctx recall <name>)\n#{lines.join("\n")}"
    end

    def notes_section
      return nil if @s.notes.empty?

      "### Notes\n#{@s.notes.map { |note| "- #{note}" }.join("\n")}"
    end

    def full_header(sized)
      "#### #{sized.name} - #{sized.doc.description} (#{sized.klass}, #{date(sized)})"
    end

    def index_line(sized)
      "- #{sized.name} - #{sized.doc.description} (#{sized.klass}, #{date(sized)})"
    end

    def date(sized) = sized.doc.last_touched.to_s[0, 10]
  end
end
