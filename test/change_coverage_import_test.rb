# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rexml/document"
require_relative "../scripts/change_coverage_import"

# Covers the five CI-file importers: exact counts per format, the Cobertura
# rates-only recompute, JaCoCo totals from report-level counters, lcov's
# fallback counting, JUnit and TestNG status mapping, staleness, the warn-and-
# skip paths, the caps, and the streaming path on a large Cobertura file.
class ChangeCoverageImportTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/coverage", __dir__)
  # Later than every fixture's embedded time, so they all read as stale.
  AFTER_FIXTURES = Time.utc(2026, 10, 13, 14, 30)

  def setup
    @tmp = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def import(paths, format, label: "unit", root: FIXTURES, head_time: nil)
    ChangeCoverageImport.read(paths:, format:, label:, repo_root: root, head_time:)
  end

  def write(name, text)
    path = File.join(@tmp, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  def counts(hash) = [ hash["covered"], hash["total"] ]

  def group(summary, name) = summary["groups"].find { |item| item["name"] == name }

  def test_cobertura_totals_come_from_root_counts
    summary = import("cobertura-basic.xml", "cobertura").summary

    assert_equal [ 6, 10 ], counts(summary["line"])
    assert_equal [ 2, 4 ], counts(summary["branch"])
    assert_equal "cobertura-basic.xml", summary["file"]
    assert_equal "2026-10-13T14:00:00Z", summary["timestamp"]
  end

  def test_cobertura_groups_count_class_lines_not_method_lines
    summary = import("cobertura-basic.xml", "cobertura").summary

    assert_equal [ 5, 6 ], counts(group(summary, "com.example.fixture")["line"])
    assert_equal [ 2, 4 ], counts(group(summary, "com.example.fixture")["branch"])
    assert_equal [ 1, 4 ], counts(group(summary, "com.example.fixture.util")["line"])
  end

  def test_cobertura_rates_only_is_recomputed_from_lines
    summary = import("cobertura-rates-only.xml", "cobertura").summary

    assert_equal [ 2, 4 ], counts(summary["line"])
    assert_equal [ 1, 4 ], counts(summary["branch"])
    # A timestamp below 10^11 is in seconds, not milliseconds.
    assert_equal "2026-10-13T14:00:00Z", summary["timestamp"]
  end

  def test_cobertura_without_branch_data_reports_null_branch
    write("cov.xml", '<coverage><packages><package name="p"><classes><class name="C"><lines>' \
                     '<line number="1" hits="1"/><line number="2" hits="0"/></lines></class></classes>' \
                     "</package></packages></coverage>")
    summary = import("cov.xml", "cobertura", root: @tmp).summary

    assert_equal [ 1, 2 ], counts(summary["line"])
    assert_nil summary["branch"]
    assert_nil summary["groups"].first["branch"]
  end

  def test_jacoco_totals_are_report_level_counters_not_summed_packages
    summary = import("jacoco-basic.xml", "jacoco").summary

    assert_equal [ 9, 14 ], counts(summary["line"])
    assert_equal [ 3, 7 ], counts(summary["branch"])
    package_lines = summary["groups"].sum { |item| item["line"]["total"] }
    refute_equal package_lines, summary["line"]["total"]
    assert_equal [ 7, 8 ], counts(group(summary, "com/example/fixture")["line"])
    assert_equal [ 0, 2 ], counts(group(summary, "com/example/fixture/util")["branch"])
    assert_equal "2026-10-13T14:00:00Z", summary["timestamp"], "latest sessioninfo dump"
  end

  def test_lcov_uses_summary_lines
    summary = import("lcov-basic.info", "lcov").summary

    assert_equal [ 4, 6 ], counts(summary["line"])
    assert_equal [ 1, 2 ], counts(summary["branch"])
    assert_equal [ 3, 4 ], counts(group(summary, "web/src/claims")["line"])
    assert_equal [ 1, 2 ], counts(group(summary, "web/src/util")["line"])
  end

  def test_lcov_falls_back_to_counting_da_and_brda
    summary = import("lcov-no-summary.info", "lcov").summary

    assert_equal [ 2, 5 ], counts(summary["line"])
    assert_equal [ 1, 3 ], counts(summary["branch"]), "a taken of - counts as not taken"
    assert_equal [ "web/src/claims" ], summary["groups"].map { |item| item["name"] }
  end

  def test_lcov_absolute_source_paths_group_relative_to_repo_root
    write("lcov.info", "SF:#{@tmp}/app/models/a.rb\nDA:1,1\nend_of_record\nSF:#{@tmp}/b.rb\nDA:1,0\nend_of_record\n")
    summary = import("lcov.info", "lcov", root: @tmp).summary

    assert_equal [ ".", "app/models" ], summary["groups"].map { |item| item["name"] }
    assert_nil summary["branch"], "no BRDA and BRF 0 means no branch data"
  end

  def test_junit_status_mapping_and_flaky
    summary = import("junit-surefire.xml", "junit").summary
    by_name = summary["items"].to_h { |item| [ item["id"].split("#").last, item ] }

    assert_equal({ "pass" => 2, "fail" => 1, "error" => 1, "skip" => 1, "flaky" => 1 }, summary["counts"])
    assert_equal "pass", by_name["submitsAClaim"]["status"]
    assert_equal "fail", by_name["rejectsAnEmptyForm"]["status"]
    assert_equal "expected:<400> but was:<200>", by_name["rejectsAnEmptyForm"]["message"]
    assert_equal "error", by_name["loadsTheList"]["status"]
    assert_equal "skip", by_name["exportsAPdf"]["status"]
    flaky = by_name["retriesTheUpload"]
    assert_equal [ "pass", true, 3 ], [ flaky["status"], flaky["flaky"], flaky["attempts"] ]
    assert_equal "com.example.fixture.ClaimsTest#submitsAClaim", by_name["submitsAClaim"]["id"]
    assert_equal 250, by_name["submitsAClaim"]["duration_ms"]
    assert_equal "2026-10-13T13:58:40Z", summary["timestamp"]
  end

  def test_junit_files_under_one_entry_aggregate
    summary = import("junit-*.xml", "junit").summary

    assert_equal [ "junit-surefire.xml", "junit-testsuites.xml" ], summary["files"]
    assert_equal 8, summary["items"].size
    assert_equal 4, summary["counts"]["pass"]
    nested = summary["items"].find { |item| item["id"] == "claims.form#validates the date" }
    assert_equal "claims form", nested["suite"]
    assert_equal 'Expected "2026-01-01" to equal "2026-01-02"', nested["message"], "whitespace collapsed"
  end

  def test_testng_maps_status_and_excludes_config_methods
    summary = import("testng-results.xml", "testng").summary
    ids = summary["items"].map { |item| item["id"] }

    assert_equal({ "pass" => 2, "fail" => 1, "error" => 0, "skip" => 1, "flaky" => 0 }, summary["counts"])
    refute(ids.any? { |id| id.end_with?("#setUp", "#tearDown") })
    opens = summary["items"].find { |item| item["id"] == "com.example.fixture.ui.ClaimsUiTest#opensTheForm" }
    assert_equal [ "smoke" ], opens["tags"]
    assert_equal 1200, opens["duration_ms"]
    failed = summary["items"].find { |item| item["status"] == "fail" }
    assert_equal "no such element: #submit", failed["message"]
    assert_equal "2026-10-13T13:55:00Z", summary["timestamp"]
  end

  def test_case_records_carry_exactly_the_schema_case_keys
    keys = ChangeCoverageSchema::CASE_FIELDS.map { |field| field.split(".").first }.uniq
    %w[junit-surefire.xml:junit testng-results.xml:testng].each do |spec|
      file, format = spec.split(":")
      import(file, format).summary["items"].each do |item|
        assert_equal keys, item.keys
        assert_nil item["gated"]
        assert_nil item["quarantine"]
      end
    end
  end

  def test_staleness_against_head_time
    stale = import("cobertura-basic.xml", "cobertura", head_time: AFTER_FIXTURES)
    fresh = import("cobertura-basic.xml", "cobertura", head_time: Time.utc(2026, 10, 13, 13))

    assert stale.summary["stale"]
    assert_equal [ "unit: cobertura-basic.xml predates HEAD" ], stale.warnings
    assert_equal [ 6, 10 ], counts(stale.summary["line"]), "stale data is kept"
    refute fresh.summary["stale"]
    assert_empty fresh.warnings
  end

  def test_lcov_staleness_uses_file_mtime
    path = write("lcov.info", "SF:a.js\nDA:1,1\nend_of_record\n")
    File.utime(Time.utc(2026, 1, 1), Time.utc(2026, 1, 1), path)

    result = import("lcov.info", "lcov", root: @tmp, head_time: Time.utc(2026, 2, 1))
    assert result.summary["stale"]
    assert_equal "2026-01-01T00:00:00Z", result.summary["timestamp"]
  end

  def test_malformed_file_warns_and_returns_no_data
    %w[cobertura jacoco junit testng].each do |format|
      result = import("malformed.xml", format)

      assert_nil result.summary, format
      assert_equal 1, result.warnings.size, format
      assert_match(/unit: malformed.xml/, result.warnings.first)
    end
  end

  def test_unknown_root_element_warns_and_skips
    result = import("jacoco-basic.xml", "cobertura")

    assert_nil result.summary
    assert_equal [ "unit: jacoco-basic.xml skipped, unknown root element <report>" ], result.warnings
  end

  def test_file_that_is_not_lcov_warns
    result = import("junit-surefire.xml", "lcov")

    assert_nil result.summary
    assert_match(/not an lcov tracefile/, result.warnings.first)
  end

  def test_missing_glob_is_silent
    result = import([ "target/surefire-reports/TEST-*.xml", "nope.xml" ], "junit")

    assert_nil result.summary
    assert_empty result.warnings
  end

  def test_unknown_format_warns
    result = import("cobertura-basic.xml", "clover")

    assert_nil result.summary
    assert_match(/unknown import format/, result.warnings.first)
  end

  def test_message_is_truncated_to_300_chars
    long = "x" * 200 + "   \n  " + "y" * 200
    write("junit.xml", %(<testsuite name="s"><testcase classname="c" name="n"><failure message="#{long}"/></testcase></testsuite>))
    message = import("junit.xml", "junit", root: @tmp).summary["items"].first["message"]

    assert_equal 300, message.length
    assert_equal "#{'x' * 200} #{'y' * 99}", message
  end

  def test_case_items_cap_at_5000_with_complete_counts
    cases = Array.new(5001) { |i| %(<testcase classname="c" name="n#{i}"/>) }.join
    write("junit.xml", "<testsuite name=\"s\">#{cases}</testsuite>")
    summary = import("junit.xml", "junit", root: @tmp).summary

    assert_equal 5000, summary["items"].size
    assert summary["truncated"]
    assert_equal 5001, summary["counts"]["pass"]
  end

  def test_groups_cap_at_500_lowest_line_percentage_first
    records = Array.new(600) do |i|
      # Directory dNNN covers NNN of its 600 lines.
      "SF:d#{format('%03d', i)}/f.js\nLF:600\nLH:#{i}\nend_of_record\n"
    end
    write("lcov.info", records.join)
    summary = import("lcov.info", "lcov", root: @tmp).summary

    assert_equal 500, summary["groups"].size
    assert summary["groups_truncated"]
    assert_equal "d000", summary["groups"].first["name"]
    assert_equal "d499", summary["groups"].last["name"]
    assert_equal [ 600 * 599 / 2, 600 * 600 ], counts(summary["line"]), "totals stay complete"
  end

  def test_large_cobertura_streams_without_a_dom
    path = File.join(@tmp, "big.xml")
    package = 0
    File.open(path, "w") do |file|
      file << %(<?xml version="1.0"?>\n<coverage timestamp="1791900000000"><packages>\n)
      while file.size < 20 * 1024 * 1024
        file << %(<package name="com.example.fixture.p#{package}"><classes><class name="C"><lines>\n)
        200.times { |i| file << %(<line number="#{i}" hits="#{i % 3}" branch="false"/>\n) }
        file << "</lines></class></classes></package>\n"
        package += 1
      end
      file << "</packages></coverage>\n"
    end

    summary = without_dom { import("big.xml", "cobertura", root: @tmp).summary }
    dom_guard = without_dom { import("junit-surefire.xml", "junit") }
    assert_match(/DOM built/, dom_guard.warnings.first, "the guard catches a DOM parse")

    assert_operator File.size(path), :>=, 20 * 1024 * 1024
    lines = package * 200
    assert_equal [ package * 133, lines ], counts(summary["line"])
    assert_equal 500, summary["groups"].size
  end

  def test_rexml_is_loadable
    assert_kind_of String, REXML::VERSION
  end

  private

  # Makes REXML::Document.new raise, so a DOM build fails the import.
  def without_dom
    eigen = REXML::Document.singleton_class
    eigen.send(:define_method, :new) { |*| raise "DOM built" }
    yield
  ensure
    eigen.send(:remove_method, :new)
  end
end
