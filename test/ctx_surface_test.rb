# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/ctx_surface"

class CtxSurfaceTest < Minitest::Test
  include SkillTempHome

  NOW = Time.new(2026, 6, 28, 9, 0, 0, "-04:00")

  # A fake loader so select() runs against in-memory docs with zero disk. It
  # mirrors the three methods CtxSurface::Loader exposes.
  FakeStore = Struct.new(:docs, :roadmap_obj, :meta_map) do
    def live_docs = docs
    def roadmap = roadmap_obj
    def meta(name) = (meta_map || {})[name]
  end

  def doc(name, klass: "active", status: "active", body: "body of #{name}",
          touched: "2026-06-20T09:00:00-04:00", expires: nil, description: "desc #{name}")
    CtxStore::Doc.new(
      name:, description:, klass:, status:, ttl: nil, expires:, review_after: nil,
      last_touched: touched, origin_session_id: "s", origin_device: "laptop-a",
      supersedes: nil, body:
    )
  end

  def roadmap(*rows)
    table = +"| id | title | status | priority | updated | device | detail |\n"
    table << "|----|-------|--------|----------|---------|--------|--------|\n"
    rows.each { |r| table << "| #{r[:id]} | #{r[:title] || r[:id]} | #{r[:status]} | p1 | #{r[:updated]} | mac | #{r[:detail]} |\n" }
    CtxSurface::RoadmapParser.parse(table)
  end

  def select(docs, roadmap_obj: nil, meta: {})
    CtxSurface.select(cwd: "/w/code/demo", home: @home, now: NOW,
                      store: FakeStore.new(docs, roadmap_obj, meta))
  end

  def render(docs, **opts) = CtxSurface.render(select(docs, **opts))

  # 1. The focused row's plan is FULL; every sibling row's plan is INDEX only,
  #    and no sibling body text leaks into the rendered output.
  def test_focused_plan_is_full_siblings_are_index
    docs = [ doc("plan-a", body: "AAA focused body"),
             doc("plan-b", body: "BBB sibling body"),
             doc("plan-c", body: "CCC sibling body") ]
    rm = roadmap(
      { id: "row-a", status: "active", updated: "2026-06-28T08:00:00-04:00", detail: "plan-a" },
      { id: "row-b", status: "next", updated: "2026-06-27T08:00:00-04:00", detail: "plan-b" },
      { id: "row-c", status: "next", updated: "2026-06-26T08:00:00-04:00", detail: "plan-c" }
    )
    surface = select(docs, roadmap_obj: rm)
    out = CtxSurface.render(surface)

    assert_equal "plan-a", surface.focus.name
    assert_includes out, "AAA focused body"
    refute_includes out, "BBB sibling body"
    refute_includes out, "CCC sibling body"
    assert_includes out, "- plan-b - desc plan-b"
    assert_includes out, "- plan-c - desc plan-c"
    assert_empty surface.full, "siblings must not win a ranked-remainder FULL slot"
  end

  # 2. Bodies that sum past the line budget demote the lowest-ranked candidates to
  #    INDEX without ever truncating a body. Truth docs avoid the most-recent
  #    active focus pick so the remainder competes against the real doc cap.
  def test_budget_demotes_lowest_rank_never_truncates
    big = ->(n, day) { doc("t#{n}", klass: "truth", body: ([ "line" ] * 250).join("\n"),
                           touched: "2026-06-#{day}T09:00:00-04:00") }
    docs = (1..8).map { |n| big.call(n, 28 - n) } # t1 freshest, t8 oldest
    surface = select(docs)

    assert_equal %w[t1 t2], surface.full.map(&:name), "line budget admits the top two, then demotes"
    out = CtxSurface.render(surface)
    surface.full.each { |s| assert_includes out, s.doc.body, "a FULL doc renders its whole body" }
    assert_includes out, "- t3 - desc t3", "demoted candidates appear as whole INDEX lines"
  end

  # 3. The focus fallback chain: most-recently-touched active wins with no
  #    roadmap, an explicit .ctx-meta/focus pin then overrides it, and a roadmap
  #    active row outranks the pin.
  def test_focus_fallback_chain
    fresh = doc("fresh", touched: "2026-06-27T09:00:00-04:00")
    stale = doc("stale", touched: "2026-06-10T09:00:00-04:00")

    assert_equal "fresh", select([ fresh, stale ]).focus.name

    pinned = select([ fresh, stale ], meta: { "focus" => "stale" })
    assert_equal "stale", pinned.focus.name, "an explicit pin overrides recency"

    rm = roadmap({ id: "r1", status: "active", updated: "2026-06-28T08:00:00-04:00", detail: "fresh" })
    roadmap_wins = select([ fresh, stale ], roadmap_obj: rm, meta: { "focus" => "stale" })
    assert_equal "fresh", roadmap_wins.focus.name, "the roadmap active row beats the pin"
  end

  # 4. Expired ephemeral and archived docs are OMITTED entirely; an unexpired
  #    ephemeral earns exactly one INDEX line and never a body.
  def test_expired_ephemeral_and_archived_omitted
    docs = [
      doc("dead", klass: "ephemeral", expires: "2026-06-01", body: "DEAD body"),
      doc("gone", klass: "active", status: "archived", body: "GONE body"),
      doc("scratch", klass: "ephemeral", expires: "2026-12-01", body: "SCRATCH body")
    ]
    out = render(docs)

    refute_includes out, "dead"
    refute_includes out, "gone"
    refute_includes out, "SCRATCH body"
    assert_equal 1, out.scan("- scratch - desc scratch").size
  end

  # 5. When truth INDEX lines alone exceed the cap, every truth line survives and
  #    the non-truth overflow is dropped with a (+N more) note.
  def test_truth_floor_survives_overbudget
    truths = (1..62).map { |n| doc(format("truth%02d", n), klass: "truth", status: "done") }
    others = (1..3).map { |n| doc("eph#{n}", klass: "ephemeral", expires: "2026-12-01") }
    surface = select(truths + others)

    truth_lines = surface.index.select { |s| s.klass == "truth" }
    assert_equal 62, truth_lines.size, "all truth lines win the cap"
    refute(surface.index.any? { |s| s.klass == "ephemeral" }, "no ephemeral line displaces a truth line")
    assert_equal "(+3 more docs, run cf:ctx list)", surface.overflow_note
  end

  # 6. select() is a pure function of its inputs: two runs render byte-identically.
  def test_determinism
    docs = [ doc("a"), doc("b", klass: "truth"), doc("c", klass: "ephemeral", expires: "2026-12-01") ]
    rm = roadmap({ id: "r", status: "active", updated: "2026-06-28T08:00:00-04:00", detail: "a" })
    assert_equal render(docs, roadmap_obj: rm), render(docs, roadmap_obj: rm)
  end

  # 7. Fail silent: a malformed doc (empty name) drops out while its neighbors
  #    surface, and an empty store renders nothing rather than raising.
  def test_fail_silent
    good = doc("good", klass: "truth")
    malformed = CtxStore::Doc.new(name: "", description: "", klass: "", status: "active",
                                  ttl: nil, expires: nil, review_after: nil, last_touched: "",
                                  origin_session_id: "", origin_device: "", supersedes: nil, body: "x")
    out = render([ good, malformed ])
    assert_includes out, "good", "the well-formed doc still surfaces"
    refute_empty out

    empty = CtxSurface.render(CtxSurface.select(cwd: "/w/code/empty", home: @home, now: NOW))
    assert_equal "", empty
  end

  # The roadmap table parser tolerates the header and separator rows and splits
  # the seven known columns, ignoring any prose around the table.
  def test_roadmap_parser_extracts_rows
    rm = roadmap(
      { id: "x", title: "Build", status: "active", updated: "2026-06-28T08:00:00-04:00", detail: "plan-x" },
      { id: "y", title: "Next", status: "next", updated: "2026-06-27T08:00:00-04:00", detail: "-" }
    )
    assert_equal %w[x y], rm.rows.map(&:id)
    assert_equal "plan-x", rm.rows.first.detail
    assert_equal "active", rm.rows.first.status
  end
end
