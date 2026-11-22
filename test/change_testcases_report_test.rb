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

  # The lane records an unclear or ungraded case as `fail`, never `pass`; the
  # report must show it as a failure in both outputs.
  def test_an_unclear_or_ungraded_case_renders_as_a_failure
    with_run do |run_dir, ledger|
      unclear = ChangeCaseResult.new(key: "checkout/pay", suite: "checkout", id: "pay", status: "fail", run_id: "r3",
                                     attempts: [ { "number" => 1, "outcome" => "pass" } ], acceptance_verdict: "unclear")
      ungraded = ChangeCaseResult.new(key: "checkout/ship", suite: "checkout", id: "ship", status: "fail", run_id: "r3",
                                      attempts: [ { "number" => 1, "outcome" => "pass" } ])
      report = ChangeTestcasesReport.new(run_dir: run_dir, ledger: ledger, records: [ unclear, ungraded ])
      assert_includes report.render_html, '<span class="fail">fail</span>'
      refute_includes report.render_html, '<span class="pass">'
      doc = REXML::Document.new(report.render_junit)
      assert_equal "2", doc.root.attributes["failures"]
      assert_equal 2, REXML::XPath.match(doc, "//testcase/failure").size
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
    underscored = ChangeTestcasesReport.ledger_path("app", repo: "/code/a", app: "customer_portal")
    dashed = ChangeTestcasesReport.ledger_path("app", repo: "/code/a", app: "customer-portal")
    refute_equal underscored, dashed
  end

  def test_quarantine_shows_in_the_report_and_as_a_junit_property
    held = ChangeCaseResult.new(key: "checkout/pay", suite: "checkout", id: "pay", status: "fail", run_id: "r3",
                                quarantined: true, quarantine_reason: "flaky font load")
    open_case = ChangeCaseResult.new(key: "checkout/browse", suite: "checkout", id: "browse", status: "pass", run_id: "r3")
    with_run do |run_dir, ledger|
      report = ChangeTestcasesReport.new(run_dir: run_dir, records: [ held, open_case ], ledger: ledger)
      paths = report.write
      html = File.read(paths[:html])
      doc = REXML::Document.new(File.read(paths[:junit]))

      assert_includes html, "<th>Quarantine</th>"
      assert_includes html, "flaky font load"
      props = REXML::XPath.match(doc, "//testcase[@name='pay']/properties/property")
      assert_equal [ [ "quarantined", "true" ], [ "quarantine_reason", "flaky font load" ] ],
                   props.map { |p| [ p.attributes["name"], p.attributes["value"] ] }
      assert_empty REXML::XPath.match(doc, "//testcase[@name='browse']/properties")
    end
  end
  def test_selector_suggestions_render_escaped_and_the_case_still_fails
    with_run do |run_dir, ledger|
      entry = { "step" => 1, "failed" => "#pay", "note" => "1 iframe(s) not searched",
                "candidates" => [ { "selector" => "[data-testid=\"<b>pay</b>\"]", "by" => "testid", "matches" => 1 } ] }
      failing = ChangeCaseResult.new(key: "checkout/pay", suite: "checkout", id: "pay", status: "fail", run_id: "r3",
                                     selector_suggestions: [ entry, "junk" ])
      other = record("browse", "fail", "r3")
      ChangeTestcasesReport.new(run_dir: run_dir, ledger: ledger, records: [ failing, other ]).write
      html = File.read(File.join(run_dir, "report.html"))

      assert_includes html, "Selector suggestions"
      assert_includes html, "&lt;b&gt;pay&lt;/b&gt;"
      refute_includes html, "<b>pay</b>"
      assert_includes html, "step 2"
      assert_includes html, "not searched"
      assert_equal 2, html.scan('class="fail"').size
    end
  end

  def test_no_suggestions_means_no_section
    with_run do |run_dir, ledger|
      ChangeTestcasesReport.new(run_dir: run_dir, ledger: ledger, records: [ record("pay", "fail", "r3") ]).write

      refute_includes File.read(File.join(run_dir, "report.html")), "Selector suggestions"
    end
  end

  def test_visual_results_render_escaped_with_images_and_the_promote_command
    with_run do |run_dir, ledger|
      attempt = File.join(run_dir, "cases", "checkout", "pay", "attempt-1")
      FileUtils.mkdir_p(attempt)
      entry = { "name" => "<i>hero</i>", "status" => "blocked", "note" => "no baseline <x>",
                "candidate" => "shot-0002-hero.png", "promote" => "mkdir -p /a && cp /b /a/hero.png" }
      failing = ChangeCaseResult.new(key: "checkout/pay", suite: "checkout", id: "pay", status: "fail", run_id: "r3",
                                     evidence_dir: attempt, visual_results: [ entry, "junk" ])
      ChangeTestcasesReport.new(run_dir: run_dir, ledger: ledger, records: [ failing ]).write
      html = File.read(File.join(run_dir, "report.html"))

      assert_includes html, "Visual baselines"
      assert_includes html, "&lt;i&gt;hero&lt;/i&gt;"
      assert_includes html, "cases/checkout/pay/attempt-1/shot-0002-hero.png"
      assert_includes html, "mkdir -p /a &amp;&amp; cp /b /a/hero.png"
    end
  end


  # --- suite_version 6: warn, blocked, figures ---------------------------------------

  DRIFT = { "label" => "expect_relation equal of badge, rows", "relation" => "equal", "status" => "warn", "drift" => true,
            "first_reads" => [ { "var" => "badge", "value" => 70, "read_at" => "2026-11-21T10:00:00.000Z" },
                               { "var" => "rows", "value" => 69, "read_at" => "2026-11-21T10:00:01.000Z" } ],
            "reads" => [ { "var" => "badge", "value" => 70, "read_at" => "2026-11-21T10:00:03.000Z" },
                         { "var" => "rows", "value" => 70, "read_at" => "2026-11-21T10:00:04.000Z" } ] }.freeze

  def v6_records
    figure = { "var" => "badge", "value" => 70, "url" => "https://app.test/admin", "read_at" => "2026-11-21T10:00:00.000Z",
               "freshness" => "10:00", "source" => "page" }
    [ ChangeCaseResult.new(key: "m/agree", suite: "m", id: "agree", status: "warn", run_id: "r9", vars: [ figure ], relations: [ DRIFT ]),
      ChangeCaseResult.new(key: "m/login", suite: "m", id: "login", status: "blocked_precondition", run_id: "r9",
                           blocked_reason: "precondition: expect_visible .user-menu: not visible"),
      ChangeCaseResult.new(key: "m/ok", suite: "m", id: "ok", status: "pass", run_id: "r9") ]
  end

  def test_junit_a_warn_case_passes_with_properties_and_a_blocked_case_is_skipped
    with_run do |run_dir, ledger|
      xml = ChangeTestcasesReport.new(run_dir: run_dir, ledger: ledger, records: v6_records).render_junit
      doc = REXML::Document.new(xml)
      warn_case = doc.elements["testsuites/testsuite/testcase[@name='agree']"]
      assert_nil warn_case.elements["failure"]
      props = warn_case.elements.to_a("properties/property").to_h { |node| [ node.attributes["name"], node.attributes["value"] ] }
      assert_equal({ "cf.verdict" => "warn", "cf.drift" => "true" }, props)
      blocked = doc.elements["testsuites/testsuite/testcase[@name='login']"]
      assert_nil blocked.elements["failure"]
      assert_match(/\Ablocked_precondition: precondition/, blocked.elements["skipped"].attributes["message"])
      assert_equal "0", doc.elements["testsuites"].attributes["failures"]
      assert_equal "1", doc.elements["testsuites"].attributes["skipped"]
    end
  end

  def test_a_quarantined_warn_case_keeps_one_properties_element
    with_run do |run_dir, ledger|
      held = ChangeCaseResult.new(key: "m/agree", suite: "m", id: "agree", status: "warn", relations: [ DRIFT ],
                                  quarantined: true, quarantine_reason: "flaky")
      doc = REXML::Document.new(ChangeTestcasesReport.new(run_dir: run_dir, ledger: ledger, records: [ held ]).render_junit)
      assert_equal 1, doc.get_elements("testsuites/testsuite/testcase/properties").size
      assert_equal 4, doc.get_elements("testsuites/testsuite/testcase/properties/property").size
    end
  end

  def test_html_puts_not_verified_first_then_warnings_figures_and_basis
    with_run do |run_dir, ledger|
      html = ChangeTestcasesReport.new(run_dir: run_dir, ledger: ledger, records: v6_records).render_html
      assert_operator html.index("<h2>Not verified</h2>"), :<, html.index("<h2>Cases</h2>")
      assert_includes html, "m/login: precondition: expect_visible .user-menu: not visible"
      assert_match %r{<h2>Warnings</h2>.*First read.*Re-read}m, html
      assert_includes html, "rows = 69"
      assert_includes html, "rows = 70"
      assert_match %r{<h2>Captured figures</h2>.*<td>badge</td><td>70</td><td>https://app.test/admin</td><td>2026-11-21T10:00:00.000Z</td><td>10:00</td><td>page</td>}m, html
      assert_match %r{<h2>Verification basis</h2><ul><li>m/agree \(warn\): reads badge; relations expect_relation equal of badge, rows: warn</li></ul>}, html
      assert_includes html, "Run status: blocked_precondition"
    end
  end

  def test_html_has_no_not_verified_section_when_everything_ran
    with_run do |run_dir, ledger|
      html = ChangeTestcasesReport.new(run_dir: run_dir, ledger: ledger, records: [ v6_records.last ]).render_html
      refute_includes html, "Not verified"
      refute_includes html, "<h2>Warnings</h2>"
      assert_includes html, "Run status: pass"
    end
  end
end
