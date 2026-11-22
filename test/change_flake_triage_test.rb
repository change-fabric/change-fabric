# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "yaml"
require "open3"
require "rbconfig"
require_relative "../scripts/change_flake_triage"
require_relative "../scripts/change_testcases_report"
require_relative "../scripts/change_suite"

# Flake triage: proposals from a synthetic ledger, never a suite edit.
class ChangeFlakeTriageTest < Minitest::Test
  TODAY = Date.new(2026, 11, 21)
  SCRIPT = File.expand_path("../scripts/change_flake_triage.rb", __dir__)

  def record(id, status, run, hash: "h1", suite: "checkout", steps: nil, quarantined: false)
    ChangeCaseResult.new(key: "#{suite}/#{id}", suite: suite, id: id, persona: "default", status: status, run_id: run,
                         attempts: [ { "number" => 1 } ], case_hash: hash, quarantined: quarantined,
                         quarantine_reason: quarantined ? "known" : nil,
                         step_durations: steps || [ { "index" => 0, "verb" => "goto" }, { "index" => 1, "verb" => "click", "label" => "pay" } ])
  end

  def series(id, statuses, **options)
    statuses.each_with_index.map { |status, index| record(id, status, "r#{index}", **options) }
  end

  def triage(records, **options) = ChangeFlakeTriage.new(records, today: TODAY, **options)

  def test_alternating_case_is_proposed_with_flips_step_and_a_week_expiry
    proposal = triage(series("pay", %w[pass fail pass fail pass])).proposals.fetch(0)

    assert_equal "checkout/pay", proposal.key
    assert_equal 4, proposal.flips
    assert_equal Date.new(2026, 11, 28), proposal.until_on
    assert_equal({ "index" => 1, "verb" => "click", "label" => "pay" }, proposal.last_failing_step)
  end

  def test_stable_pass_stable_fail_and_a_single_flip_are_not_proposed
    records = series("steady", %w[pass pass pass pass]) + series("broken", %w[fail fail fail]) + series("fixed", %w[fail fail pass pass])

    assert_empty triage(records).proposals
  end

  def test_threshold_and_window_are_honoured
    records = series("pay", %w[pass fail pass pass pass pass])

    assert_equal 1, triage(records, threshold: 2).proposals.size
    assert_empty triage(records, threshold: 2, runs: 4).proposals, "the old flips fall outside the window"
    assert_empty triage(records, threshold: 3).proposals
  end

  def test_only_runs_at_the_newest_case_hash_count
    records = series("pay", %w[pass fail pass fail], hash: "old") + series("pay", %w[pass pass], hash: "new")

    assert_empty triage(records).proposals, "an edited case is judged on its new definition"
    assert_equal 1, triage(series("pay", %w[pass pass], hash: "old") + series("pay", %w[fail pass fail], hash: "new")).proposals.size
  end

  def test_records_without_a_hash_compare_only_with_each_other
    legacy = series("pay", %w[pass fail pass], hash: nil)

    assert_equal 1, triage(legacy).proposals.size
    assert_empty triage(legacy + [ record("pay", "pass", "r9") ]).proposals
  end

  def test_skipped_runs_are_gaps_not_flips
    records = [ record("pay", "pass", "r0"), record("pay", "skipped", "r1"), record("pay", "pass", "r2"), record("pay", "skipped", "r3") ]

    assert_empty triage(records).proposals
  end

  def test_a_newer_skipped_record_still_sets_the_definition_and_the_quarantine
    old = series("pay", %w[pass fail pass], hash: "old")

    assert_empty triage(old + [ record("pay", "skipped", "r9", hash: "new") ]).proposals
    shielded = triage(old + [ record("pay", "skipped", "r9", hash: "old", quarantined: true) ])
    assert_empty shielded.proposals
    assert_equal [ "checkout/pay" ], shielded.already_quarantined
  end

  def test_a_live_quarantine_is_listed_not_proposed
    records = series("pay", %w[pass fail pass]) + [ record("pay", "fail", "r3", quarantined: true) ]
    result = triage(records)

    assert_empty result.proposals
    assert_equal [ "checkout/pay" ], result.already_quarantined
  end

  def test_empty_and_unknown_input
    assert_empty triage([]).proposals
    assert_empty triage(nil).proposals
    assert_match(/No case is flipping/, triage([]).to_markdown)
    assert_equal [], ChangeFlakeTriage.read_ledger(nil)
    assert_equal [], ChangeFlakeTriage.read_ledger("/nonexistent/history.jsonl")
  end

  def test_failing_run_with_no_steps_reports_not_recorded
    records = series("pay", %w[pass fail pass fail], steps: [])
    result = triage(records)

    assert_nil result.proposals.first.last_failing_step
    assert_includes result.to_markdown, "Last failing step: not recorded"
  end

  def test_bad_options_are_rejected
    [ { runs: 1 }, { runs: "x" }, { runs: nil }, { threshold: 0 }, { threshold: -3 } ].each do |options|
      assert_raises(ChangeFlakeTriage::Error) { triage([], **options) }
    end
  end

  def test_hostile_values_are_masked_and_truncated
    steps = [ { "index" => 0, "verb" => "fill", "label" => "login token=abc123SECRET\n#{'x' * 500}" } ]
    id = "pay|`#{'y' * 300}`"
    markdown = triage(series(id, %w[pass fail pass fail], steps: steps)).to_markdown

    refute_includes markdown, "abc123SECRET"
    refute_includes markdown, "x" * 100
    refute_includes markdown, "y" * 150
    refute_match(/\|`/, markdown.lines.grep(/^## /).join)
    assert_includes markdown, "[redacted]"
  end

  def test_patch_is_valid_yaml_for_the_suite_keys
    patch = YAML.safe_load(triage(series("pay", %w[pass fail pass fail])).to_h.dig("proposals", 0, "patch"), permitted_classes: [ Date ])

    assert_equal true, patch["quarantined"]
    assert_equal Date.new(2026, 11, 28), patch["quarantine_until"]
    assert_match(/flipped 3 times/, patch["quarantine_reason"])
  end

  def test_ledger_reader_skips_garbage_and_invalid_bytes
    Dir.mktmpdir do |dir|
      path = File.join(dir, "history.jsonl")
      File.binwrite(path, "#{record('a', 'pass', 'r1').to_json}\n\nnot json\n[1]\n7\n{\"status\":\"bogus\"}\n\xff\xfe\n#{record('b', 'fail', 'r1').to_json}\n")

      assert_equal %w[checkout/a checkout/b], ChangeFlakeTriage.read_ledger(path).map(&:key)
    end
  end

  def test_write_makes_both_files_and_edits_no_suite
    Dir.mktmpdir do |dir|
      suite = File.join(dir, "checkout.cf-testcases.yml")
      File.write(suite, "suite: checkout\n")
      paths = triage(series("pay", %w[pass fail pass fail])).write(File.join(dir, "out", "nested"))

      assert_equal 1, JSON.parse(File.read(paths[:json])).fetch("proposals").size
      assert_includes File.read(paths[:markdown]), "Proposals only: no suite was edited."
      assert_equal "suite: checkout\n", File.read(suite)
    end
  end

  def test_cli_writes_proposals_and_rejects_bad_arguments
    Dir.mktmpdir do |dir|
      ledger = File.join(dir, "history.jsonl")
      File.write(ledger, series("pay", %w[pass fail pass fail]).map { |entry| "#{entry.to_json}\n" }.join)
      out, status = Open3.capture2e(RbConfig.ruby, SCRIPT, "--ledger", ledger, "--out", dir)

      assert status.success?, out
      assert_match(/1 proposal/, out)
      assert File.exist?(File.join(dir, "flake-proposals.json"))
      _, bad = Open3.capture2e(RbConfig.ruby, SCRIPT, "--ledger", ledger, "--out", dir, "--runs", "0")
      assert_equal 2, bad.exitstatus
      _, missing = Open3.capture2e(RbConfig.ruby, SCRIPT, "--ledger", ledger)
      assert_equal 2, missing.exitstatus
    end
  end

  def test_report_writes_proposals_links_them_and_clears_stale_ones
    Dir.mktmpdir do |root|
      run_dir = File.join(root, "run")
      FileUtils.mkdir_p(run_dir)
      ledger = File.join(root, "ledger", "history.jsonl")
      FileUtils.mkdir_p(File.dirname(ledger))
      File.write(ledger, series("pay", %w[pass fail pass]).map { |entry| "#{entry.to_json}\n" }.join)
      report = ChangeTestcasesReport.new(run_dir: run_dir, ledger: ledger, records: [ record("pay", "fail", "r3") ])
      paths = report.write

      assert_equal File.join(run_dir, "flake-proposals.md"), paths[:flake_proposals]
      assert_includes File.read(paths[:html]), 'href="flake-proposals.md"'

      calm = ChangeTestcasesReport.new(run_dir: run_dir, ledger: File.join(root, "none.jsonl"), records: [ record("pay", "pass", "r1") ])
      assert_nil calm.write[:flake_proposals]
      refute File.exist?(File.join(run_dir, "flake-proposals.md"))
      refute_includes File.read(File.join(run_dir, "report.html")), "Flake proposals"
    end
  end

  def test_case_content_hash_ignores_tags_and_quarantine_but_not_steps
    base = { suite: "s", id: "a", acceptance: "ok", steps: [ { "goto" => "/" } ], tags: [ "x" ] }
    one = ChangeSuite::TestCase.new(**base)

    assert_equal one.content_hash, ChangeSuite::TestCase.new(**base, tags: [ "y" ]).content_hash
    refute_equal one.content_hash, ChangeSuite::TestCase.new(**base, steps: [ { "goto" => "/b" } ]).content_hash
    assert_equal 16, one.content_hash.size
  end
end
