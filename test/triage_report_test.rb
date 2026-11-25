# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "support/triage_fakes"

# The report is a pure function of its sources. These tests pin it to golden
# JSON for the C4 fixtures (several ready units, conflicting state, zero units,
# a partial stack) and check the rules the goldens cannot show by themselves.
class TriageReportTest < Minitest::Test
  def golden(name) = JSON.parse(File.read(File.join(TriageFakes::FIXTURES, name, "expected.json")))

  def unit(report, id) = report["units"].find { |row| row["unit"] == id } || flunk("no unit #{id}")

  # --- golden fixtures (C4) -------------------------------------------------

  def test_several_ready_units_match_golden_and_follow_the_tie_break
    report = TriageFakes.build("ready")
    assert_equal golden("ready"), JSON.parse(JSON.generate(report))
    assert_equal [ "acme/api#launch/P2#Phase 1", "acme/web#launch/P1#Phase 1" ], report["eligible"],
                 "repo order in the host map, then node order"
  end

  def test_conflicting_state_matches_golden_and_is_escalated_not_done
    report = TriageFakes.build("conflict")
    assert_equal golden("conflict"), JSON.parse(JSON.generate(report))
    node = unit(report, "acme/api#c/P1#Phase 1")
    assert_equal "escalated", node["state"]
    refute node["eligible"]
    assert_equal 0, node["percent"], "a conflicted node earns no percent"
  end

  def test_zero_units_matches_golden_and_prints_na_not_a_percent
    report = TriageFakes.build("zero")
    assert_equal golden("zero"), JSON.parse(JSON.generate(report))
    group = report["groups"].find { |row| row["name"] == "empty" }
    assert_nil group["percent"]
    assert_equal "n/a", group["percent_label"]
    assert_equal "n/a", unit(report, "acme/api#stack/empty-stack")["percent_label"]
    refute unit(report, "acme/api#stack/empty-stack")["eligible"], "an empty stack is never done and never eligible"
  end

  def test_a_partial_stack_matches_golden
    report = TriageFakes.build("partial")
    assert_equal golden("partial"), JSON.parse(JSON.generate(report))
    stack = unit(report, "acme/api#stack/s2")
    assert_equal 33, stack["percent"], "1 of 3 PRs merged"
    assert_equal "fix failing checks on #12", stack["next_step"]
    assert_equal [ "MERGED", "OPEN", "OPEN" ], stack["prs"].map { |pr| pr["state"] }
    assert_equal [ nil, 2, 0 ], stack["prs"].map { |pr| pr["unresolved_threads"] }
  end

  # --- percent and next step ------------------------------------------------

  def test_percent_is_done_units_over_all_units_and_truncates
    inputs = TriageFakes.inputs("partial")
    stacks = inputs[:stacks]
    stacks.first["prs"].each { |pr| pr["state"] = "merged" }
    inputs[:gh] = TriageFakes::Gh.new(JSON.parse(File.read(File.join(TriageFakes::FIXTURES, "partial", "gh.json"))).transform_values do |row|
      row.merge("state" => "MERGED")
    end)
    report = Triage::Report.new(**inputs).build
    assert_equal 100, unit(report, "acme/api#stack/s2")["percent"]
    assert_equal "done", unit(report, "acme/api#stack/s2")["state"]
    assert_equal "done", report["groups"].first["next_step"]
  end

  def test_next_step_walks_the_ready_bar
    steps = {
      { "ci" => "failed", "clean" => false, "unresolved_threads" => 0 } => "fix failing checks on #12",
      { "ci" => "passed", "clean" => false, "unresolved_threads" => 1 } => "resolve 1 review thread on #12",
      { "ci" => "passed", "clean" => false, "unresolved_threads" => 3 } => "resolve 3 review threads on #12",
      { "ci" => "pending", "clean" => false, "unresolved_threads" => 0 } => "wait for checks on #12",
      { "ci" => "passed", "clean" => false, "unresolved_threads" => 0 } => "bring #12 to CLEAN (rebase or fix conflicts)",
      { "ci" => "passed", "clean" => true, "unresolved_threads" => 0 } => "merge #12 at the ready bar"
    }
    steps.each do |facts, expected|
      table = { "acme/api#11" => { "state" => "MERGED" }, "acme/api#12" => facts.merge("state" => "OPEN"),
                "acme/api#13" => { "state" => "OPEN", "ci" => "pending", "clean" => false, "unresolved_threads" => 0 } }
      report = TriageFakes.build("partial", gh: TriageFakes::Gh.new(table))
      assert_equal expected, unit(report, "acme/api#stack/s2")["next_step"]
    end
  end

  # --- evidence ---------------------------------------------------------------

  def test_a_stack_linked_to_an_epic_node_counts_once_as_that_node
    inputs = TriageFakes.inputs("conflict")
    inputs[:gh] = TriageFakes::Gh.new({ "acme/api#7" => { "state" => "MERGED" } })
    report = Triage::Report.new(**inputs).build
    assert_equal [ "acme/api#c/P1#Phase 1", "acme/api#c/P1#Phase 2" ], report["units"].map { |row| row["unit"] }
    assert_equal "done", unit(report, "acme/api#c/P1#Phase 1")["state"]
    assert_equal "next", unit(report, "acme/api#c/P1#Phase 2")["state"], "the dependency is met"
    assert_equal 50, report["groups"].first["percent"]
  end

  def test_the_trailer_is_consulted_only_when_no_stack_names_the_node
    trailers = { "acme/api area/api-plan#Phase 1" => [ 99 ] }
    table = { "acme/api#99" => { "state" => "OPEN", "ci" => "passed", "clean" => true, "unresolved_threads" => 0 } }
    inputs = TriageFakes.inputs("conflict", stacks: [], epic_gh: TriageFakes::EpicGh.new(trailers), gh: TriageFakes::Gh.new(table))
    report = Triage::Report.new(**inputs).build
    assert_equal "active", unit(report, "acme/api#c/P1#Phase 1")["state"]
    assert_equal "merge #99 at the ready bar", unit(report, "acme/api#c/P1#Phase 1")["next_step"]

    with_stack = TriageFakes.inputs("conflict", epic_gh: TriageFakes::EpicGh.new(trailers))
    assert_equal [ 7 ], Triage::Report.new(**with_stack).build["units"].first["prs"].map { |pr| pr["number"] },
                 "the stack record wins over the trailer"
  end

  def test_a_node_blocked_by_an_active_unit_in_its_repo_is_not_eligible
    table = { "acme/api#7" => { "state" => "OPEN", "ci" => "pending", "clean" => false, "unresolved_threads" => 0 } }
    stack = { "slug" => "s1", "repo" => "acme/api", "prs" => [ { "number" => 7, "state" => "preparing", "phase" => "area/api-plan#Phase 1" } ] }
    inputs = TriageFakes.inputs("ready", stacks: [ stack ], gh: TriageFakes::Gh.new(table))
    report = Triage::Report.new(**inputs).build
    other = unit(report, "acme/api#launch/P3#Phase 1")
    assert_equal "next", other["state"]
    assert(other["blockers"].any? { |b| b.start_with?("repo_busy:") })
    assert_equal "active", unit(report, "acme/api#launch/P2#Phase 1")["state"]
    assert_equal [ "acme/web#launch/P1#Phase 1" ], report["eligible"]
  end

  def test_an_open_decision_naming_a_unit_blocks_it_and_rides_on_the_unit
    report = TriageFakes.build("ready")
    docs = unit(report, "acme/docs#launch/P4#Phase 1")
    assert_equal [ "open_decision" ], docs["blockers"]
    assert_equal [ "inbox:20261125-0900-docs-choice" ], docs["decisions"].map { |item| item["id"] }
    assert_equal 1, report["decisions"].size
  end

  def test_a_carve_out_or_tag_phase_is_never_eligible
    report = TriageFakes.build("ready")
    assert_equal [ "carve_out_or_tag" ], unit(report, "acme/api#launch/P3#Phase 1")["blockers"]
  end

  # --- failure modes ----------------------------------------------------------

  def test_gh_unavailable_marks_fields_unknown_and_records_a_finding
    gh = TriageFakes::Gh.new({ "acme/api#11" => "unavailable", "acme/api#12" => "unavailable", "acme/api#13" => "unavailable" })
    report = TriageFakes.build("partial", gh: gh)
    pr = unit(report, "acme/api#stack/s2")["prs"].first
    assert_equal({ "state" => "unknown", "ci" => "unknown", "clean" => "unknown", "unresolved_threads" => "unknown" },
                 pr.reject { |key, _| key == "number" })
    assert_includes report["findings"].map { |row| row["code"] }, "gh_unavailable"
    assert_equal "active", unit(report, "acme/api#stack/s2")["state"], "a stack in flight stays active"
  end

  def test_a_query_error_fails_loudly
    gh = TriageFakes::Gh.new({})
    assert_raises(Triage::GhLive::QueryError) { TriageFakes.build("partial", gh: gh) }
  end

  def test_a_trailer_search_failure_marks_the_node_unknown
    failing = Object.new
    def failing.pr_search_trailer(*) = raise(EpicGh::Error, "gh pr list: network down")
    report = TriageFakes.build("conflict", stacks: [], epic_gh: failing)
    assert_equal "unknown", unit(report, "acme/api#c/P1#Phase 1")["state"]
    assert_includes report["findings"].map { |row| row["code"] }, "gh_unavailable"
    refute unit(report, "acme/api#c/P1#Phase 1")["eligible"]
  end

  def test_no_epic_store_gives_a_stack_only_report
    Dir.mktmpdir do |dir|
      findings = []
      assert_empty Triage::Sources.epics(File.join(dir, "no-plans"), findings)
      assert_empty findings
    end
    report = TriageFakes.build("partial")
    assert_equal [ "stack" ], report["units"].map { |row| row["kind"] }.uniq
  end

  def test_a_corrupt_host_map_is_report_only_with_a_finding
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.join(TriageFakes::FIXTURES, "ready", "."), dir)
      File.write(File.join(dir, "hosts.yml"), "repos: [broken\n")
      map = Triage::HostMap.load(File.join(dir, "hosts.yml"))
      report = TriageFakes.build("ready", host_map: map, findings: [ { "code" => "host_map_invalid", "detail" => map.error } ])
      assert_includes report["findings"].map { |row| row["code"] }, "host_map_invalid"
      assert_equal "acme/docs#launch/P4#Phase 1", report["units"].map { |row| row["unit"] }.min_by { |id| id.start_with?("acme/docs") ? 0 : 1 }
      assert_empty report["hosts"]
    end
  end

  def test_an_epic_that_does_not_parse_is_a_finding_not_a_crash
    Dir.mktmpdir do |dir|
      path = File.join(dir, "epics", "bad")
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "epic.md"), "no frontmatter here\n")
      findings = []
      assert_empty Triage::Sources.epics(dir, findings)
      assert_equal [ "epic_invalid" ], findings.map { |row| row["code"] }
    end
  end

  # --- hosts, heartbeat and remote snapshots ----------------------------------

  def snapshot_for(host, now: TriageFakes::NOW, version: 1, repo: "acme/api")
    { "host" => host, "generation" => 5, "generated_at" => now.iso8601, "heartbeat_at" => now.iso8601,
      "repos" => [ { "repo" => repo, "assignment" => host, "assignment_version" => version, "units" => [] } ],
      "decisions" => [ { "id" => "vm:1", "kind" => "inbox", "subject" => "from the vm", "refs" => "", "host" => nil } ] }
  end

  def pulled(status, snapshot: nil, reason: nil) = Triage::Snapshot::Pulled.new(status: status, snapshot: snapshot, reason: reason)

  def test_a_stale_local_heartbeat_is_flagged_after_two_ticks
    beats = { "mini" => { "at" => TriageFakes::NOW - 1801, "generation" => 1 }, "vm" => { "at" => TriageFakes::NOW - 10, "generation" => 1 } }
    report = TriageFakes.build("ready", heartbeats: beats, host: "mini")
    rows = report["hosts"].to_h { |row| [ row["host"], row["status"] ] }
    assert_equal({ "mini" => "stale", "vm" => "fresh" }, rows)
    assert_includes report["findings"].map { |row| row["code"] }, "host_stale"
  end

  def test_an_unreachable_remote_snapshot_reads_stale_and_a_fresh_one_reads_fresh
    report = TriageFakes.build("ready", host: "mini", remote: { "vm" => pulled("unreachable", reason: "timed out after 10s") })
    vm = report["hosts"].find { |row| row["host"] == "vm" }
    assert_equal "stale", vm["status"]
    assert_includes vm["reason"], "timed out"

    fresh = TriageFakes.build("ready", host: "mini", remote: { "vm" => pulled("ok", snapshot: snapshot_for("vm", version: 2, repo: "acme/web")) })
    assert_equal "fresh", fresh["hosts"].find { |row| row["host"] == "vm" }["status"]
  end

  def test_a_remote_snapshot_older_than_two_ticks_reads_stale
    old = snapshot_for("vm", now: TriageFakes::NOW - 1900, version: 2, repo: "acme/web")
    report = TriageFakes.build("ready", host: "mini", remote: { "vm" => pulled("ok", snapshot: old) })
    assert_equal "stale", report["hosts"].find { |row| row["host"] == "vm" }["status"]
  end

  def test_remote_decisions_are_merged_with_content_and_tagged_with_their_host
    report = TriageFakes.build("ready", host: "mini", remote: { "vm" => pulled("ok", snapshot: snapshot_for("vm", version: 2, repo: "acme/web")) })
    item = report["decisions"].find { |row| row["id"] == "vm:1" }
    assert_equal "from the vm", item["subject"]
    assert_equal "vm", item["host"]
  end

  def test_an_assignment_version_mismatch_is_a_finding
    stale = snapshot_for("vm", version: 1, repo: "acme/web")
    report = TriageFakes.build("ready", host: "mini", remote: { "vm" => pulled("ok", snapshot: stale) })
    mismatch = report["findings"].find { |row| row["code"] == "assignment_mismatch" }
    refute_nil mismatch
    assert_includes mismatch["detail"], "acme/web"
  end

  def test_a_host_that_does_not_know_its_name_never_pulls
    pulls = []
    sources = Triage::Sources.collect(root: Dir.mktmpdir, now: TriageFakes::NOW, host: nil, plans_root: "/nonexistent", stack_root: "/nonexistent",
                                      gh: nil, epic_gh: nil, decisions: [], pull: ->(target) { pulls << target })
    assert_empty pulls
    assert_empty sources[:remote]
  end

  # --- "what changed" --------------------------------------------------------

  def test_changed_diffs_against_the_previous_published_report
    before = JSON.parse(JSON.generate(TriageFakes.build("partial")))
    table = { "acme/api#11" => { "state" => "MERGED" }, "acme/api#12" => { "state" => "MERGED" },
              "acme/api#13" => { "state" => "OPEN", "ci" => "pending", "clean" => false, "unresolved_threads" => 0 } }
    after = TriageFakes.build("partial", gh: TriageFakes::Gh.new(table), previous: before)
    fields = after["changed"].map { |row| [ row["unit"], row["field"], row["from"].to_s[0, 20], row["to"].to_s[0, 20] ] }
    assert_includes fields, [ "acme/api#stack/s2", "percent_label", "33%", "66%" ]
    assert_equal after["changed"], unit(after, "acme/api#stack/s2")["changed"]
  end

  def test_no_previous_report_means_nothing_changed
    assert_empty TriageFakes.build("partial")["changed"]
  end

  def test_an_added_and_a_removed_unit_are_reported
    before = JSON.parse(JSON.generate(TriageFakes.build("ready")))
    before["units"].shift
    before["units"] << before["units"].last.merge("unit" => "acme/gone#x/y")
    after = TriageFakes.build("ready", previous: before)
    kinds = after["changed"].map { |row| [ row["unit"], row["to"] ] }
    assert_includes kinds, [ "acme/api#launch/P2#Phase 1", "added" ]
    assert_includes kinds, [ "acme/gone#x/y", "removed" ]
  end

  def test_the_report_is_deterministic
    assert_equal JSON.generate(TriageFakes.build("ready")), JSON.generate(TriageFakes.build("ready"))
  end

  # --- text rendering ---------------------------------------------------------

  def test_text_output_lists_unfinished_groups_decisions_and_findings
    text = Triage::Report.render_text(TriageFakes.build("ready")).join("\n")
    assert_includes text, "launch 0/6 (0%) next: start P2#Phase 1 Build the thing"
    assert_includes text, "decisions waiting: 1"
    assert_includes text, "acme/docs#launch/P4#Phase 1 [next] blocked: open_decision"
  end

  def test_finished_groups_collapse_to_one_count_line
    inputs = TriageFakes.inputs("conflict", gh: TriageFakes::Gh.new({ "acme/api#7" => { "state" => "MERGED" } }),
                                           epic_gh: nil)
    report = Triage::Report.new(**inputs).build
    refute_includes Triage::Report.render_text(report).join("\n"), "finished:", "an epic at 50% is not finished"
    report["groups"].each { |group| group["done"] = group["total"] }
    assert_includes Triage::Report.render_text(report), "finished: 1"
  end
end
