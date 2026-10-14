# frozen_string_literal: true

require_relative "test_helpers"
require "yaml"
require_relative "../scripts/change_coverage_step"

# ChangeCoverageStep: the coverage subcommand's build and import, and the
# best-effort per-sweep record, against a throwaway git repo and a temp HOME.
class ChangeCoverageStepTest < Minitest::Test
  include SkillTempHome

  FIXTURES = File.expand_path("fixtures/coverage", __dir__)
  COPY_DIR = "docs/qa-coverage"

  def setup
    super
    @repo = File.realpath(Dir.mktmpdir)
    GitFixture.git_init(@repo, "-b", "main")
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "Test")
    File.write(File.join(@repo, "app.txt"), "one")
    git("add", "app.txt")
    git("commit", "-q", "-m", "initial")
  end

  def teardown
    FileUtils.remove_entry(@repo)
    super
  end

  def git(*args) = GitFixture.git(@repo, *args)

  def write_change_md(qa_report = nil)
    front = { "change_config" => { "project" => "fixture-app", "lanes" => { "a11y" => { "enabled" => true } } } }
    front["qa_report"] = qa_report if qa_report
    File.write(File.join(@repo, "CHANGE.md"), "#{YAML.dump(front)}---\n\nbody\n")
  end

  def step(project: "fixture-app", env: {}) = ChangeCoverageStep.new(repo_root: @repo, project: project, toolkit: "test", env: env)

  def store_dir(project = "fixture-app") = File.join(@home, ".claude", "cf", "coverage", project)

  def runs_in(dir) = ChangeCoverageStore.parse(File.read(File.join(dir, "report-data.js"))).runs

  def run_record(id, recorded_at)
    { "schema" => 1, "id" => id, "recorded_at" => recorded_at, "source" => "import", "scope" => "import" }
  end

  # Writes a data file holding `runs` into `dir`, the way a CI artifact or a
  # committed repo copy would arrive.
  def seed(dir, runs)
    FileUtils.mkdir_p(dir)
    store = ChangeCoverageStore.new(dir, max_runs: 200, origin: nil, project: "fixture-app")
    File.write(File.join(dir, "report-data.js"), "#{store.write_lines(runs).join("\n")}\n")
  end

  def test_repo_copy_merges_the_store_and_the_committed_copy_by_id_both_ways_and_never_stages
    write_change_md("repo_copy" => { "dir" => COPY_DIR })
    git("add", "CHANGE.md")
    git("commit", "-q", "-m", "config")
    seed(store_dir, [ run_record("local-1", "2026-10-01T00:00:00Z"), run_record("shared", "2026-10-02T00:00:00Z") ])
    seed(File.join(@repo, COPY_DIR), [ run_record("committed-1", "2026-09-30T00:00:00Z"),
                                       run_record("shared", "2026-10-02T00:00:00Z") ])

    code, lines = step.build(repo_copy: true)

    assert_equal 0, code, lines.join("\n")
    expected = %w[committed-1 local-1 shared]
    assert_equal expected, runs_in(store_dir).map { |run| run["id"] }.sort
    assert_equal expected, runs_in(File.join(@repo, COPY_DIR)).map { |run| run["id"] }.sort
    assert File.file?(File.join(@repo, COPY_DIR, "index.html"))
    assert_equal "", git("diff", "--cached", "--name-only").strip
    refute File.exist?(File.join(@repo, ".gitattributes"))
    assert(lines.any? { |line| line.include?("#{COPY_DIR}/report-data.js merge=union") })
  end

  # The copy is committed, so the build must leave nothing else there: no
  # .lock, no temp file.
  def test_repo_copy_leaves_only_the_data_file_and_the_page_in_the_copy_dir
    write_change_md("repo_copy" => { "dir" => COPY_DIR })
    seed(store_dir, [ run_record("local-1", "2026-10-01T00:00:00Z") ])

    code, lines = step.build(repo_copy: true)

    assert_equal 0, code, lines.join("\n")
    assert_equal %w[index.html report-data.js], Dir.children(File.join(@repo, COPY_DIR)).sort
    assert_equal %w[local-1], runs_in(File.join(@repo, COPY_DIR)).map { |run| run["id"] }
  end

  def test_repo_copy_without_a_configured_dir_is_a_usage_error
    write_change_md
    code, lines = step.build(repo_copy: true)
    assert_equal 2, code
    assert_equal [ "set qa_report.repo_copy.dir in CHANGE.md" ], lines
  end

  def test_merge_folds_in_a_downloaded_ci_artifact_directory
    write_change_md
    artifact = File.join(@home, "ci-artifact")
    seed(artifact, [ run_record("ci-import", "2026-10-03T00:00:00Z") ])

    code, lines = step.build(merges: [ artifact ])

    assert_equal 0, code, lines.join("\n")
    assert_equal %w[ci-import], runs_in(store_dir).map { |run| run["id"] }
    assert File.file?(File.join(store_dir, "index.html"))
  end

  # A mistyped CI artifact path must not look like a successful merge; what
  # did merge is still written.
  def test_merge_of_a_missing_or_empty_path_exits_1_and_keeps_what_merged
    write_change_md
    artifact = File.join(@home, "ci-artifact")
    seed(artifact, [ run_record("ci-import", "2026-10-03T00:00:00Z") ])
    not_data = File.join(@home, "notes.txt")
    File.write(not_data, "hello\n")

    [ [ File.join(@home, "nonexistent"), "not found" ], [ not_data, "holds no coverage data" ] ].each do |bad, message|
      code, lines = step.build(merges: [ artifact, bad ])

      assert_equal 1, code, lines.join("\n")
      assert(lines.any? { |line| line.include?(message) }, lines.join("\n"))
      assert_equal %w[ci-import], runs_in(store_dir).map { |run| run["id"] }
    end
  end

  def test_out_writes_both_files_to_the_directory_and_merges_what_is_there
    write_change_md
    out = File.join(@home, "out")
    seed(out, [ run_record("earlier", "2026-10-01T00:00:00Z") ])

    code, lines = step.import(files: [ File.join(FIXTURES, "junit-surefire.xml") ], format: "junit", label: "unit",
                              out: out)

    assert_equal 0, code, lines.join("\n")
    assert File.file?(File.join(out, "index.html"))
    ids = runs_in(out).map { |run| run["id"] }
    assert_equal 2, ids.size
    assert_includes ids, "earlier"
    refute File.exist?(store_dir), "--out must not touch the local store"
  end

  def test_import_with_identity_flags_on_a_detached_checkout
    write_change_md
    git("checkout", "-q", "--detach")
    identity = { sha: "abcdef0123456789", branch: "main", pr: "42", profile: "ci", app: "web" }

    code, lines = step.import(files: [ File.join(FIXTURES, "junit-surefire.xml") ], format: "junit", label: "Unit Tests",
                              identity: identity)

    assert_equal 0, code, lines.join("\n")
    run = runs_in(store_dir).first
    assert_equal "import", run["source"]
    assert_equal "import", run["scope"]
    assert_equal({ "branch" => "main", "sha" => "abcdef0123456789", "short_sha" => "abcdef0", "subject" => "initial",
                   "pr" => { "number" => 42, "url" => nil }, "trunk" => true }, run["git"])
    assert_match(/\A\d{8}T\d{6}Z-abcdef0-import-junit-unit-tests\z/, run["id"])
    assert_equal %w[ci web], [ run["profile"], run["app"] ]
    assert_nil run["routes"]
    assert_equal 1, run.dig("imports", "test_results").size
  end

  def test_import_of_several_formats_records_one_run
    write_change_md
    entries = [ { paths: [ File.join(FIXTURES, "lcov-basic.info") ], format: "lcov", label: "web" },
                { paths: [ File.join(FIXTURES, "junit-surefire.xml") ], format: "junit", label: nil } ]

    code, lines = step.import(entries: entries)

    assert_equal 0, code, lines.join("\n")
    runs = runs_in(store_dir)
    assert_equal 1, runs.size
    assert_match(/-import-lcov-web-junit-junit\z/, runs.first["id"])
    assert_equal [ 1, 1 ], [ runs.first.dig("imports", "coverage").size, runs.first.dig("imports", "test_results").size ]
  end

  def test_an_unreadable_import_is_left_out_of_a_run_the_others_still_make
    write_change_md
    entries = [ { paths: [ File.join(FIXTURES, "malformed.xml") ], format: "junit", label: "broken" },
                { paths: [ File.join(FIXTURES, "lcov-basic.info") ], format: "lcov", label: "web" } ]

    code, lines = step.import(entries: entries)

    assert_equal 0, code, lines.join("\n")
    assert_includes lines, "broken: no junit file could be read; left out of the run"
    assert_match(/-import-lcov-web\z/, runs_in(store_dir).first["id"])
  end

  def test_import_of_unreadable_files_records_nothing
    write_change_md
    code, lines = step.import(files: [ File.join(FIXTURES, "malformed.xml") ], format: "junit")
    assert_equal 1, code
    assert(lines.any? { |line| line.include?("nothing recorded") })
    refute File.exist?(File.join(store_dir, "report-data.js"))
  end

  def test_import_of_an_unknown_format_is_a_usage_error
    code, = step.import(files: [ "x" ], format: "xunit")
    assert_equal 2, code
  end

  def test_build_without_change_md_uses_defaults_and_still_writes
    name = File.basename(@repo)
    code, lines = ChangeCoverageStep.new(repo_root: @repo, project: nil).build

    assert_equal 0, code, lines.join("\n")
    assert(lines.any? { |line| line.start_with?("warning: no CHANGE.md") })
    dir = store_dir(ChangeReport.slug_for(name))
    assert File.file?(File.join(dir, "report-data.js"))
    assert_includes File.read(File.join(dir, "index.html")), "#{name} QA coverage"
  end

  def test_record_sweep_reports_a_failure_as_one_skipped_line
    lines = step.record_sweep(registry_project: "fixture-app", repo_root: @repo, config: nil, app: nil, lanes_ran: [],
                              findings: [], instances: {}, ids: {}, toolkit: "t", selection: {}, scope: "all")
    assert_equal 1, lines.size
    assert_match(/\Askipped \(NoMethodError: /, lines.first)
  end

  def test_sweep_and_run_ids
    sweep = ChangeCoverageStep.sweep_ids(Time.utc(2026, 10, 13, 14, 15, 0), "1a2b3c4d5e")
    assert_equal "20261013T141500Z-1a2b3c4", sweep[:sweep_id]
    assert_equal "20261013T141500Z-1a2b3c4-run", ChangeCoverageStep.run_ids(sweep)[:id]
    assert_equal "20261013T141500Z-1a2b3c4-run-web-app", ChangeCoverageStep.run_ids(sweep, app: "Web App")[:id]
    assert_equal "20261013T141500Z-nosha", ChangeCoverageStep.sweep_ids(Time.utc(2026, 10, 13, 14, 15, 0), "")[:sweep_id]
  end

  def test_doctor_lines_flag_a_repo_copy_without_a_union_merge_rule
    assert_equal [], QaReportConfig.gitattributes_lines(@repo, nil)
    lines = QaReportConfig.gitattributes_lines(@repo, COPY_DIR)
    assert_equal "  #{COPY_DIR}/report-data.js merge=union", lines.last
    File.write(File.join(@repo, ".gitattributes"), "*.png binary\n#{COPY_DIR}/report-data.js   merge=union\n")
    assert_equal [], QaReportConfig.gitattributes_lines(@repo, COPY_DIR)
  end
end
