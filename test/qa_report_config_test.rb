# frozen_string_literal: true

require_relative "test_helpers"
require_relative "../scripts/qa_report_config"
require_relative "../scripts/change_apps"

class QaReportConfigTest < Minitest::Test
  include SkillTempHome

  FULL = <<~YAML
    ---
    change_config:
      project: fixture-app
    qa_report:
      title: Example Co QA coverage
      trunk: main
      brand:
        name: Example Co
        logo: docs/brand/logo.svg
        logo_dark: docs/brand/logo-dark.svg
        font:
          family: "Source Sans 3, Arial"
        colors:
          light: { ground: "#ffffff", ink: "#1b1f24", accent: "#2B6CB0" }
          dark:  { ground: "#121417", ink: "#e9ecef", accent: "#7fb0e8" }
      imports:
        coverage:
          - { path: "target/site/jacoco/jacoco.xml", format: jacoco, label: unit }
          - { path: "web/coverage/lcov.info", format: lcov }
        test_results:
          - { path: "target/surefire-reports/TEST-*.xml", format: junit, label: unit }
          - { path: "target/testng-results.xml", format: testng, label: ui }
      repo_copy:
        dir: docs/qa-coverage
      history:
        max_runs: 300
    ---

    # Change management
  YAML

  def setup
    super
    @repo = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@repo)
    super
  end

  def write_change_md(text) = File.write(File.join(@repo, "CHANGE.md"), text)

  # Writes a CHANGE.md whose qa_report block is the given hash, beside a
  # minimal change_config naming the project.
  def write_qa_report(block)
    front = { "change_config" => { "project" => "fixture-app" }, "qa_report" => block }
    write_change_md("#{front.to_yaml}---\n\n# Change management\n")
  end

  def load = QaReportConfig.load(@repo)

  def assert_warned(settings, field)
    assert settings.warnings.any? { |w| w.start_with?("#{field}:") },
           "expected a warning naming #{field}, got #{settings.warnings.inspect}"
  end

  def test_missing_change_md_yields_defaults
    settings = load
    refute settings.declared
    assert_equal File.basename(@repo), settings.brand.name
    assert_equal "#{File.basename(@repo)} QA coverage", settings.title
    assert_nil settings.trunk
    assert_nil settings.brand.light
    assert_nil settings.repo_copy_dir
    assert_equal 200, settings.max_runs
    assert_empty settings.imports.coverage
    assert_empty settings.warnings
  end

  def test_no_key_yields_defaults_named_for_the_project
    write_change_md("---\nchange_config:\n  project: fixture-app\n---\n")
    settings = load
    refute settings.declared
    assert_equal "fixture-app", settings.brand.name
    assert_equal "fixture-app QA coverage", settings.title
    assert_empty settings.warnings
    assert_equal [ "qa_report: (not declared, neutral brand)" ], QaReportConfig.doctor_lines(@repo)
  end

  def test_full_valid_block
    write_change_md(FULL)
    settings = load
    assert settings.declared
    assert_empty settings.warnings
    assert_equal "Example Co QA coverage", settings.title
    assert_equal "main", settings.trunk
    brand = settings.brand
    assert_equal "Example Co", brand.name
    assert_equal "docs/brand/logo.svg", brand.logo
    assert_equal "docs/brand/logo-dark.svg", brand.logo_dark
    assert_equal "Source Sans 3, Arial", brand.font_family
    assert_equal({ ground: "#ffffff", ink: "#1b1f24", accent: "#2b6cb0" }, brand.light)
    assert_equal({ ground: "#121417", ink: "#e9ecef", accent: "#7fb0e8" }, brand.dark)
    assert_equal [ { path: "target/site/jacoco/jacoco.xml", format: "jacoco", label: "unit" },
                   { path: "web/coverage/lcov.info", format: "lcov", label: "lcov" } ], settings.imports.coverage
    assert_equal %w[junit testng], settings.imports.test_results.map { |i| i[:format] }
    assert_equal "docs/qa-coverage", settings.repo_copy_dir
    assert_equal 300, settings.max_runs
  end

  def test_doctor_summary_for_a_declared_block
    write_change_md(FULL)
    assert_equal [ "qa_report: Example Co QA coverage, brand Example Co, 2 coverage import(s), " \
                   "2 test-result import(s), repo copy docs/qa-coverage, max_runs 300" ],
                 QaReportConfig.doctor_lines(@repo)
  end

  def write_registry
    apps = "  project: fixture-app\n  apps:\n    web: { config: web/CHANGE.md }\n    api: { config: api/CHANGE.md }\n"
    write_change_md(FULL.sub("  project: fixture-app\n", apps))
    %w[web api].each do |app|
      FileUtils.mkdir_p(File.join(@repo, app))
      File.write(File.join(@repo, app, "CHANGE.md"),
                 "---\nchange_config:\n  project: #{app}\n  lanes:\n    a11y:\n      enabled: true\n" \
                 "      base_url: http://localhost:3000\n      routes: [\"/\"]\n---\n")
    end
  end

  def test_registry_doctor_reports_qa_report_once_at_the_end
    write_registry
    File.write(File.join(@repo, ".gitattributes"), "docs/qa-coverage/report-data.js merge=union\n")
    summary = ChangeAppRegistry.doctor(File.join(@repo, "CHANGE.md"))
    assert_equal 1, summary.scan(/^qa_report: /).size
    assert summary.rstrip.end_with?("repo copy docs/qa-coverage, max_runs 300")
  end

  # The repo copy is rewritten whole, so without a union merge rule two
  # branches that each rebuilt it conflict; doctor prints the line to add.
  def test_registry_doctor_warns_when_the_repo_copy_has_no_union_merge_rule
    write_registry
    summary = ChangeAppRegistry.doctor(File.join(@repo, "CHANGE.md"))
    assert_includes summary, "qa_report.repo_copy.dir: .gitattributes does not union-merge the repo copy"
    assert summary.rstrip.end_with?("docs/qa-coverage/report-data.js merge=union")
  end

  def test_title_defaults_to_the_brand_name
    write_qa_report("brand" => { "name" => "Example Co" })
    assert_equal "Example Co QA coverage", load.title
  end

  def test_non_hex_color_drops_the_theme_with_a_warning
    write_qa_report("brand" => { "colors" => { "dark" => { "ground" => "#000", "ink" => "#fff", "accent" => "blue" } } })
    settings = load
    assert_nil settings.brand.dark
    assert_warned settings, "qa_report.brand.colors.dark.accent"
  end

  def test_partial_light_theme_falls_back_wholesale
    write_qa_report("brand" => { "colors" => { "light" => { "ground" => "#ffffff", "accent" => "#2b6cb0" },
                                               "dark" => { "ground" => "#121417", "ink" => "#e9ecef", "accent" => "#7fb0e8" } } })
    settings = load
    assert_nil settings.brand.light
    refute_nil settings.brand.dark
    assert_warned settings, "qa_report.brand.colors.light.ink"
    assert_warned settings, "qa_report.brand.colors.light"
  end

  def test_font_family_with_css_injection_is_rejected
    write_qa_report("brand" => { "font" => { "family" => "Arial;} body{display:none" } })
    settings = load
    assert_nil settings.brand.font_family
    assert_warned settings, "qa_report.brand.font.family"
  end

  def test_max_runs_below_range_falls_back
    write_qa_report("history" => { "max_runs" => 9 })
    settings = load
    assert_equal 200, settings.max_runs
    assert_warned settings, "qa_report.history.max_runs"
  end

  def test_max_runs_above_range_falls_back
    write_qa_report("history" => { "max_runs" => 5001 })
    settings = load
    assert_equal 200, settings.max_runs
    assert_warned settings, "qa_report.history.max_runs"
  end

  def test_max_runs_bounds_are_inclusive
    write_qa_report("history" => { "max_runs" => 10 })
    assert_equal 10, load.max_runs
    write_qa_report("history" => { "max_runs" => 5000 })
    assert_equal 5000, load.max_runs
  end

  def test_unknown_import_format_drops_the_import
    write_qa_report("imports" => { "coverage" => [ { "path" => "a.xml", "format" => "clover" },
                                                   { "path" => "b.xml", "format" => "cobertura" } ],
                                   "test_results" => [ { "path" => "c.xml", "format" => "jacoco" } ] })
    settings = load
    assert_equal [ "b.xml" ], settings.imports.coverage.map { |i| i[:path] }
    assert_empty settings.imports.test_results
    assert_warned settings, "qa_report.imports.coverage[0].format"
    assert_warned settings, "qa_report.imports.test_results[0].format"
  end

  def test_absolute_import_path_drops_the_import
    write_qa_report("imports" => { "test_results" => [ { "path" => "/var/ci/TEST-a.xml", "format" => "junit" },
                                                       { "path" => "../up/TEST-b.xml", "format" => "junit" } ] })
    settings = load
    assert_empty settings.imports.test_results
    assert_warned settings, "qa_report.imports.test_results[0].path"
    assert_warned settings, "qa_report.imports.test_results[1].path"
  end

  def test_import_label_too_long_defaults_to_the_format
    write_qa_report("imports" => { "coverage" => [ { "path" => "lcov.info", "format" => "lcov", "label" => "x" * 41 } ] })
    settings = load
    assert_equal "lcov", settings.imports.coverage.first[:label]
    assert_warned settings, "qa_report.imports.coverage[0].label"
  end

  def test_dotdot_in_repo_copy_dir_turns_the_copy_off
    write_qa_report("repo_copy" => { "dir" => "docs/../../elsewhere" })
    settings = load
    assert_nil settings.repo_copy_dir
    assert_warned settings, "qa_report.repo_copy.dir"
  end

  def test_repo_copy_dir_inside_git_is_refused
    write_qa_report("repo_copy" => { "dir" => ".git/qa" })
    settings = load
    assert_nil settings.repo_copy_dir
    assert_warned settings, "qa_report.repo_copy.dir"
  end

  def test_logo_symlink_outside_the_repo_is_refused
    outside = File.join(@home, "logo.svg")
    File.write(outside, "<svg/>")
    File.symlink(outside, File.join(@repo, "logo.svg"))
    write_qa_report("brand" => { "logo" => "logo.svg", "logo_dark" => "/etc/logo.svg" })
    settings = load
    assert_nil settings.brand.logo
    assert_nil settings.brand.logo_dark
    assert_warned settings, "qa_report.brand.logo"
    assert_warned settings, "qa_report.brand.logo_dark"
  end

  def test_bad_trunk_and_title_fall_back
    write_qa_report("trunk" => "bad branch..name", "title" => "x" * 121, "brand" => { "name" => "y" * 81 })
    settings = load
    assert_nil settings.trunk
    assert_equal "fixture-app", settings.brand.name
    assert_equal "fixture-app QA coverage", settings.title
    assert_warned settings, "qa_report.trunk"
    assert_warned settings, "qa_report.title"
    assert_warned settings, "qa_report.brand.name"
  end

  def test_unknown_keys_warn_and_are_ignored
    write_qa_report("colour" => "blue", "brand" => { "palette" => {} })
    settings = load
    assert_warned settings, "qa_report.colour"
    assert_warned settings, "qa_report.brand.palette"
  end

  def test_non_mapping_key_yields_defaults_with_a_warning
    write_qa_report("just a string")
    settings = load
    assert_equal 200, settings.max_runs
    assert_warned settings, "qa_report"
  end

  def test_broken_change_config_still_yields_a_valid_qa_report
    write_change_md(<<~YAML)
      ---
      change_config:
        lanes:
          nonsense: { enabled: maybe }
        boot: 42
      change_policy: [not, a, mapping]
      qa_report:
        title: Example Co QA coverage
        history:
          max_runs: 50
      ---
    YAML
    settings = load
    assert settings.declared
    assert_equal "Example Co QA coverage", settings.title
    assert_equal 50, settings.max_runs
    assert_empty settings.warnings
  end

  def test_unparseable_frontmatter_warns_and_never_raises
    write_change_md("---\nqa_report:\n  title: [unclosed\n---\n")
    settings = load
    refute settings.declared
    assert_equal 1, settings.warnings.size
    assert_warned settings, "qa_report"
    lines = QaReportConfig.doctor_lines(@repo)
    assert_equal "qa_report: (not declared, neutral brand)", lines.first
    assert lines[1].start_with?("warning: qa_report:")
  end

  def test_disallowed_yaml_value_never_raises
    write_change_md("---\nqa_report:\n  title: !ruby/object:Object {}\n---\n")
    settings = load
    assert_equal 1, settings.warnings.size
    assert_warned settings, "qa_report"
  end
end
