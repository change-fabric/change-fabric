# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../scripts/change_findings"
require_relative "../scripts/change_report"

class ChangeReportTest < Minitest::Test
  def around_desktop
    Dir.mktmpdir do |dir|
      original = ChangeReport::DESKTOP
      ChangeReport.send(:remove_const, :DESKTOP)
      ChangeReport.const_set(:DESKTOP, dir)
      yield dir
    ensure
      ChangeReport.send(:remove_const, :DESKTOP)
      ChangeReport.const_set(:DESKTOP, original)
    end
  end

  def test_base_name_is_unchanged_without_an_app
    report = ChangeReport.new(project: "my-app", scope: "all", findings: Findings.new)
    assert_match(/\Achange-my-app-all-\d{8}T\d{6}Z\z/, report.base_name)
  end

  def test_base_name_carries_the_app_segment
    report = ChangeReport.new(project: "my-repo", scope: "all", findings: Findings.new, app: "portal")
    assert_match(/\Achange-my-repo-portal-all-\d{8}T\d{6}Z\z/, report.base_name)
  end

  def test_meta_lines_render_the_profile_and_target
    around_desktop do |_dir|
      report = ChangeReport.new(
        project: "my-app", scope: "all", findings: Findings.new,
        meta: { "profile" => "staging", "target" => "https://staging.example" }
      )
      paths = report.write
      markdown = File.read(paths[:markdown])
      assert_match(/- profile: staging/, markdown)
      assert_match(/- target: https:\/\/staging\.example/, markdown)
    end
  end

  # --- the run manifest ---------------------------------------------------------

  def test_the_manifest_is_rendered_as_its_own_table
    around_desktop do |_dir|
      report = ChangeReport.new(
        project: "my-app", scope: "all", findings: Findings.new,
        manifest: { "axe-core" => "4.10.2", "config digest" => "sha256:abc", "toolkit version" => "skills/v1.2.3" }
      )
      markdown = File.read(report.write[:markdown])
      assert_match(/## Run manifest/, markdown)
      assert_match(/\| axe-core \| 4\.10\.2 \|/, markdown)
      assert_match(/\| config digest \| sha256:abc \|/, markdown)
      assert_match(%r{\| toolkit version \| skills/v1\.2\.3 \|}, markdown)
    end
  end

  def test_no_manifest_block_when_there_is_nothing_to_record
    around_desktop do |_dir|
      report = ChangeReport.new(project: "my-app", scope: "all", findings: Findings.new)
      refute_match(/## Run manifest/, File.read(report.write[:markdown]))
    end
  end

  # --- the findings table -------------------------------------------------------

  def finding(lane:, status:, **rest)
    Finding.new(lane: lane, status: status, check: rest.delete(:check) || "check", **rest)
  end

  # The old key was the single fail?/not-fail bit, so anything sharing that bit
  # was left unordered and sort_by (unstable) could render it differently every
  # time. Two Findings built in opposite orders must now render identically.
  def test_the_findings_table_is_ordered_the_same_whatever_order_findings_arrived_in
    rows = [
      { lane: "zap", status: "warn", severity: "low", check: "csp" },
      { lane: "a11y", status: "pass", severity: "info", check: "no violations" },
      { lane: "a11y", status: "pass", severity: "info", check: "aria" },
      { lane: "zap", status: "fail", severity: "high", check: "sqli" },
      { lane: "a11y", status: "fail", severity: "high", check: "contrast" }
    ]
    forward = Findings.new
    rows.each { |row| forward.add(finding(**row)) }
    backward = Findings.new
    rows.reverse_each { |row| backward.add(finding(**row)) }

    around_desktop do |_dir|
      a = File.read(ChangeReport.new(project: "p", scope: "all", findings: forward).write[:markdown])
      b = File.read(ChangeReport.new(project: "p", scope: "all", findings: backward).write[:markdown])
      assert_equal table_rows(a), table_rows(b)
      # Failures still lead, and within them the order is by lane then check.
      assert_equal [ "a11y", "zap", "a11y", "a11y", "zap" ], table_rows(a).map { |row| row.split(" | ").first.delete("| ") }
    end
  end

  # Just the findings table's own data rows: the lane-results summary above it
  # is a different table with its own ordering rule.
  def table_rows(markdown)
    markdown.split("## Findings").last.lines.map(&:chomp)
            .select { |line| line.start_with?("| ") }
            .reject { |line| line.start_with?("| ---", "| Lane |") }
  end

  def test_a_flaky_finding_is_labeled_beside_its_attempt_count
    findings = Findings.new
    findings.add(finding(lane: "browserless", status: "pass", check: "desktop").with_attempt(attempts: 2, flaky: true))
    findings.add(finding(lane: "k6", status: "pass", check: "p95"))

    around_desktop do |_dir|
      markdown = File.read(ChangeReport.new(project: "p", scope: "all", findings: findings).write[:markdown])
      assert_match(/\| 2 \(flaky\) \|/, markdown)
      assert_match(/\| p95 \|  \|  \| 1 \|/, markdown)
    end
  end

  def test_the_csv_carries_the_attempts_and_flaky_columns
    findings = Findings.new
    findings.add(finding(lane: "k6", status: "pass", check: "p95").with_attempt(attempts: 2, flaky: true))

    around_desktop do |_dir|
      csv = File.read(ChangeReport.new(project: "p", scope: "all", findings: findings).write[:csv])
      assert_equal "lane,status,severity,target,check,location,detail,help,attempts,flaky", csv.lines.first.chomp
      assert_match(/,2,true$/, csv.lines[1].chomp)
    end
  end

  def test_rollup_writes_one_row_per_app
    around_desktop do |_dir|
      rows = [
        { app: "portal", passed: true, failing: 0, report: "portal.md" },
        { app: "scattergram", passed: false, failing: 2, report: "scattergram.md" }
      ]
      result = ChangeReport.rollup(project: "my-repo", scope: "all", rows: rows)
      markdown = File.read(result[:markdown])
      assert_match(/\| portal \| PASS \| 0 \| portal\.md \|/, markdown)
      assert_match(/\| scattergram \| FAIL \| 2 \| scattergram\.md \|/, markdown)
    end
  end
end
