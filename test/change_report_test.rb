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
