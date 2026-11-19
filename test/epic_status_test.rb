# frozen_string_literal: true

require "json"
require "fileutils"
require "tmpdir"
require "benchmark"
require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/epic_status"

class EpicStatusTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/epic", __dir__)
  CLEAN = File.join(FIXTURES, "clean/epic.md")
  CLEAN_PLANS = File.join(FIXTURES, "clean/plans")
  GH = File.join(FIXTURES, "gh")
  PERF = File.join(FIXTURES, "perf/epic.md")
  PERF_PLANS = File.join(FIXTURES, "perf/plans")
  PERF_GH = File.join(FIXTURES, "perf/gh")

  def setup
    @home = Dir.mktmpdir
    @prev_home = ENV["HOME"]
    ENV["HOME"] = @home
  end

  def teardown
    ENV["HOME"] = @prev_home
    FileUtils.remove_entry(@home)
  end

  def write_stack_record(repo, filename, prs)
    dir = File.join(StackStore.root, StackStore.repo_dir(EpicStatus.repo_id(repo)))
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, filename), JSON.generate({ "repo" => repo, "prs" => prs }))
  end

  def clean_epic = EpicStore.load(CLEAN, plans_root: CLEAN_PLANS)

  def test_truth_table_agrees_with_every_rule_in_the_ordered_decision_list
    # P1#Phase 2 is linked by both a stack record and the trailer search, at
    # the same PR number: the one-authoritative-PR-per-node dedup case.
    write_stack_record("other-org/shared-lib", "demo.json",
                        [ { "number" => 102, "phase" => "demo/shared-token-client#Phase 2", "state" => "preparing" } ])
    # P2#Phase 1 has an open PR but its stack record reads paused: rule 3
    # (blocked) must win over rule 5 (in_progress, since it has no upstream).
    write_stack_record("sample-org/api", "demo.json",
                        [ { "number" => 103, "phase" => "demo/api-token-issue#Phase 1", "state" => "paused" } ])

    nodes = EpicStatus.run(clean_epic, EpicGh::Fake.new(GH))
    expected = JSON.parse(File.read(File.join(GH, "expected_status.json")))

    actual = nodes.to_h { |node| [ node.id, node.state ] }
    assert_equal expected, actual
  end

  def test_dedup_does_not_double_count_as_ambiguous
    write_stack_record("other-org/shared-lib", "demo.json",
                        [ { "number" => 102, "phase" => "demo/shared-token-client#Phase 2", "state" => "preparing" } ])
    write_stack_record("sample-org/api", "demo.json",
                        [ { "number" => 103, "phase" => "demo/api-token-issue#Phase 1", "state" => "paused" } ])

    nodes = EpicStatus.run(clean_epic, EpicGh::Fake.new(GH))
    node = nodes.find { |n| n.id == "P1#Phase 2" }

    assert_equal "in_progress", node.state
    assert_equal 102, node.pr["number"]
  end

  def test_conflicting_links_are_unknown_and_never_unlock_downstream
    write_stack_record("other-org/shared-lib", "demo.json",
                        [ { "number" => 102, "phase" => "demo/shared-token-client#Phase 2", "state" => "preparing" } ])
    write_stack_record("sample-org/api", "demo.json",
                        [ { "number" => 103, "phase" => "demo/api-token-issue#Phase 1", "state" => "paused" } ])

    nodes = EpicStatus.run(clean_epic, EpicGh::Fake.new(GH))
    node = nodes.find { |n| n.id == "P3#Phase 2" }

    assert_equal "unknown", node.state
    assert_nil node.pr
  end

  def test_gh_error_on_pr_view_reads_unknown
    stub = Object.new
    def stub.pr_search_trailer(_repo, _ref) = [ 999 ]
    def stub.pr_view(_repo, _number) = raise(EpicGh::Error, "boom")

    node = EpicStatus.classify(stub, "x/y", "P1#Phase 1", done_upstream: true)

    assert_equal "unknown", node.state
  end

  def test_gh_error_on_trailer_search_reads_unknown
    stub = Object.new
    def stub.pr_search_trailer(_repo, _ref) = raise(EpicGh::Error, "boom")

    node = EpicStatus.classify(stub, "x/y", "P1#Phase 1", done_upstream: true)

    assert_equal "unknown", node.state
  end

  def test_json_report_matches_the_node_classification
    write_stack_record("other-org/shared-lib", "demo.json",
                        [ { "number" => 102, "phase" => "demo/shared-token-client#Phase 2", "state" => "preparing" } ])
    write_stack_record("sample-org/api", "demo.json",
                        [ { "number" => 103, "phase" => "demo/api-token-issue#Phase 1", "state" => "paused" } ])

    nodes = EpicStatus.run(clean_epic, EpicGh::Fake.new(GH))
    report = EpicStatus.to_json_report(nodes)

    assert_equal 7, report["nodes"].size
    assert_equal 1, report["counts"]["done"]
    assert_equal 1, report["counts"]["unknown"]
  end

  def test_cli_json_output_is_parseable
    write_stack_record("other-org/shared-lib", "demo.json",
                        [ { "number" => 102, "phase" => "demo/shared-token-client#Phase 2", "state" => "preparing" } ])
    write_stack_record("sample-org/api", "demo.json",
                        [ { "number" => 103, "phase" => "demo/api-token-issue#Phase 1", "state" => "paused" } ])

    out = StringIO.new
    err = StringIO.new
    code = EpicStatus::CLI.run([ "--json", "--fake-gh", GH, "--plans-root", CLEAN_PLANS, CLEAN ], out:, err:)

    assert_equal 0, code
    report = JSON.parse(out.string)
    assert_equal 7, report["nodes"].size
  end

  def test_cli_text_report_groups_nodes_by_state_with_counts
    write_stack_record("other-org/shared-lib", "demo.json",
                        [ { "number" => 102, "phase" => "demo/shared-token-client#Phase 2", "state" => "preparing" } ])
    write_stack_record("sample-org/api", "demo.json",
                        [ { "number" => 103, "phase" => "demo/api-token-issue#Phase 1", "state" => "paused" } ])

    out = StringIO.new
    EpicStatus::CLI.run([ "--fake-gh", GH, "--plans-root", CLEAN_PLANS, CLEAN ], out:, err: StringIO.new)

    assert_match(/done 1/, out.string)
    assert_match(%r{P1#Phase 1 https://github\.com/other-org/shared-lib/pull/101}, out.string)
  end

  def test_twenty_pr_fixture_classifies_everything_done_under_ten_seconds
    epic = EpicStore.load(PERF, plans_root: PERF_PLANS)
    nodes = nil
    elapsed = Benchmark.realtime { nodes = EpicStatus.run(epic, EpicGh::Fake.new(PERF_GH)) }

    assert_equal 20, nodes.size
    assert(nodes.all? { |n| n.state == "done" })
    assert_operator elapsed, :<, 10
  end

  def test_no_evidence_and_no_upstream_reads_next
    nodes = EpicStatus.run(clean_epic, EpicGh::Fake.new(GH))
    node = nodes.find { |n| n.id == "P4#Phase 1" }

    assert_equal "next", node.state
    assert_nil node.pr
  end

  def test_missing_pr_fixture_in_fake_gh_raises_a_fixture_error
    assert_raises(EpicGh::Error) { EpicGh::Fake.new(GH).pr_view("no/such", 1) }
  end
end
