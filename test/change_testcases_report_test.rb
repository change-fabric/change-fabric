# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rexml/document"
require_relative "../scripts/change_testcases_report"

# report.html, junit.xml and the history ledger, all from case-result records.
class ChangeTestcasesReportTest < Minitest::Test
  def record(id, status, run, attempts: 1, evidence_dir: nil, suite: "checkout")
    ChangeCaseResult.new(key: "#{suite}/#{id}", suite: suite, id: id, persona: "default", status: status,
                         run_id: run, duration_ms: 1500, commit: "abc123def4567890",
                         attempts: Array.new(attempts) { |n| { "number" => n + 1, "outcome" => n + 1 == attempts ? status : "fail" } },
                         evidence_dir: evidence_dir, acceptance_verdict: status == "pass" ? "pass" : nil)
  end

  def with_run
    Dir.mktmpdir do |root|
      run_dir = File.join(root, "testcases-r3")
      FileUtils.mkdir_p(run_dir)
      yield run_dir, File.join(root, "ledger", "history.jsonl")
    end
  end

  def seed_ledger(ledger, records)
    FileUtils.mkdir_p(File.dirname(ledger))
    File.write(ledger, records.map { |entry| "#{entry.to_json}\n" }.join)
  end

  def current(run_dir)
    attempt = File.join(run_dir, "cases", "checkout", "pay", "attempt-1")
    FileUtils.mkdir_p(attempt)
    File.write(File.join(attempt, "failure.png"), "png")
    [ record("pay", "fail", "r3", evidence_dir: attempt), record("browse", "pass", "r3", attempts: 2),
      record("legacy", "skipped", "r3"), record("search", "partial_evidence", "r3", suite: "catalog") ]
  end

  def test_html_names_status_persona_history_and_links_evidence_relatively
    with_run do |run_dir, ledger|
      seed_ledger(ledger, [ record("pay", "pass", "r1"), record("gone", "pass", "r1"), record("pay", "skipped", "r2") ])
      html = ChangeTestcasesReport.new(run_dir: run_dir, ledger: ledger, records: current(run_dir)).render_html

      assert_includes html, "<title>Test cases r3</title>"
      assert_match %r{<td>checkout/pay</td><td><span class="fail">fail</span> <span class="tag">newly failing</span></td><td>default</td><td>1.5 s</td>}, html
      assert_includes html, '<img src="cases/checkout/pay/attempt-1/failure.png"'
      refute_includes html, run_dir
      assert_match(/Flaky.*checkout\/browse \(2 attempts\)/, html)
      assert_match %r{<h2>Skipped this run</h2><ul><li>checkout/legacy</li></ul>}, html
      assert_match %r{<h2>Not run this time</h2><ul><li>checkout/gone</li></ul>}, html
      assert_includes html, '<span class="tag">no history</span>'
      assert_equal 3, html[%r{<td>checkout/pay</td>.*?</tr>}m].scan(/class="h-/).size, "two past runs plus this one"
    end
  end

  def test_junit_is_valid_with_one_suite_per_suite_and_failure_text
    with_run do |run_dir, ledger|
      xml = ChangeTestcasesReport.new(run_dir: run_dir, ledger: ledger, records: current(run_dir)).render_junit
      doc = REXML::Document.new(xml)
      suites = doc.get_elements("testsuites/testsuite")
      assert_equal %w[checkout catalog], suites.map { |suite| suite.attributes["name"] }
      checkout = suites.first
      assert_equal [ "3", "1", "1" ], %w[tests failures skipped].map { |key| checkout.attributes[key] }
      pay = checkout.get_elements("testcase").find { |test| test.attributes["name"] == "pay" }
      assert_equal "1.500", pay.attributes["time"]
      assert_match(/checkout\/pay fail after 1 attempt/, pay.get_elements("failure").first.text)
      assert_equal 1, REXML::XPath.match(doc, "//testcase[@name='legacy']/skipped").size
      assert_equal "partial_evidence", REXML::XPath.first(doc, "//testcase[@name='search']/failure").attributes["type"]
    end
  end

  def test_write_appends_the_run_to_the_ledger_after_reading_it
    with_run do |run_dir, ledger|
      seed_ledger(ledger, [ record("pay", "pass", "r1") ])
      report = ChangeTestcasesReport.new(run_dir: run_dir, ledger: ledger, records: current(run_dir))
      paths = report.write

      assert File.exist?(paths[:html])
      assert File.exist?(paths[:junit])
      lines = File.readlines(ledger).map { |line| ChangeCaseResult.from_h(JSON.parse(line)) }
      assert_equal %w[r1 r3 r3 r3 r3], lines.map(&:run_id)
      assert_equal :newly_failing, report.records.first.trend(report.history)
      again = ChangeTestcasesReport.new(run_dir: run_dir, ledger: ledger, records: [ record("pay", "fail", "r4") ])
      assert_equal :failing, again.records.first.trend(again.history)
    end
  end

  def test_records_default_to_the_run_dirs_case_results
    with_run do |run_dir, ledger|
      File.write(File.join(run_dir, "case-results.jsonl"), "#{record('pay', 'pass', 'r3').to_json}\n")
      assert_equal [ "checkout/pay" ], ChangeTestcasesReport.new(run_dir: run_dir, ledger: ledger).records.map(&:key)
    end
  end

  def test_the_ledger_lives_outside_the_repo_per_project
    assert_equal File.join(Dir.home, ".claude", "cf", "testcases", "my-app", "history.jsonl"),
                 ChangeTestcasesReport.ledger_path("My App")
    portal = ChangeTestcasesReport.ledger_path("app", repo: "/code/a", app: "portal")
    admin = ChangeTestcasesReport.ledger_path("app", repo: "/code/a", app: "admin")
    other_repo = ChangeTestcasesReport.ledger_path("app", repo: "/code/b", app: "portal")
    assert_equal 3, [ portal, admin, other_repo ].uniq.size
  end
end
