# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "digest"
require "stringio"
require_relative "../scripts/change_coverage_store"

# Covers the per-run QA coverage store: exclusive create with suffix retry,
# skipping partial and temp files, retention, summarized older runs in the
# bundle, real concurrent writers, the origin-mismatch directory, and the
# one-time split of a format version 1 data file.
class ChangeCoverageStoreTest < Minitest::Test
  ORIGIN = "git@example.invalid:org/fixture-app.git"

  def setup
    @root = Dir.mktmpdir
    @dir = File.join(@root, "store")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def store(max_runs: 200, origin: ORIGIN, page_writer: ChangeCoverageStore::NO_PAGE)
    ChangeCoverageStore.new(@dir, max_runs:, origin:, project: "Example Co", page_writer:)
  end

  def run_record(id, at = "2026-10-13T14:15:00Z", **extra)
    { "schema" => 1, "id" => id, "recorded_at" => at, "source" => "change_run" }.merge(extra.transform_keys(&:to_s))
  end

  def quiet_list = ChangeCoverageStore.list(@dir, warn_to: StringIO.new)
  def ids = quiet_list.map { |run| run["id"] }
  def bundle = ChangeCoverageStore.read_bundle(File.join(@dir, "report-data.js"))

  def test_write_run_creates_the_file_and_round_trips
    run = run_record("a", nested: { "list" => [ 1, nil, "</x>" ] })
    path = ChangeCoverageStore.write_run(@dir, run)

    assert_equal File.join(@dir, "runs", "a.json"), path
    assert_equal run, JSON.parse(File.read(path))
    assert_equal [ "a.json" ], Dir.children(File.join(@dir, "runs"))
  end

  def test_a_taken_id_gets_a_suffix_and_past_nine_raises
    paths = (1..9).map { ChangeCoverageStore.write_run(@dir, run_record("a")) }

    assert_equal "a-2.json", File.basename(paths[1])
    assert_equal "a-9.json", File.basename(paths[8])
    assert_equal "a", JSON.parse(File.read(paths[1]))["id"]
    assert_includes ids, "a-2"
    assert_raises(Errno::EEXIST) { ChangeCoverageStore.write_run(@dir, run_record("a")) }
    assert_equal 9, Dir.children(File.join(@dir, "runs")).size
  end

  def test_write_run_rejects_a_run_without_an_id
    assert_raises(ArgumentError) { ChangeCoverageStore.write_run(@dir, { "schema" => 1 }) }
  end

  def test_list_skips_a_truncated_file_and_a_temp_file
    ChangeCoverageStore.write_run(@dir, run_record("good"))
    File.write(File.join(@dir, "runs", "broken.json"), '{"schema":1,"id":"bro')
    File.write(File.join(@dir, "runs", ".x.123.tmp"), JSON.generate(run_record("tmp")))
    File.write(File.join(@dir, "runs", "newer.json"), JSON.generate(run_record("newer").merge("schema" => 99)))
    log = StringIO.new

    assert_equal [ "good" ], ChangeCoverageStore.list(@dir, warn_to: log).map { |run| run["id"] }
    assert_includes log.string, "broken.json"
    assert_includes log.string, "newer.json"
  end

  def test_list_sorts_by_recorded_at_then_id
    ChangeCoverageStore.write_run(@dir, run_record("b", "2026-10-13T14:00:00Z"))
    ChangeCoverageStore.write_run(@dir, run_record("a", "2026-10-13T15:00:00Z"))
    ChangeCoverageStore.write_run(@dir, run_record("c", "2026-10-13T14:00:00Z"))

    assert_equal %w[b c a], ids
  end

  def test_prune_keeps_exactly_the_newest_max_runs
    (1..12).each { |n| ChangeCoverageStore.write_run(@dir, run_record(format("r%02d", n), format("2026-10-%02dT00:00:00Z", n))) }

    assert_equal 2, ChangeCoverageStore.prune(@dir, 10).size
    assert_equal (3..12).map { |n| format("r%02d", n) }, ids
  end

  def test_prune_to_zero_empties_the_store
    3.times { |n| ChangeCoverageStore.write_run(@dir, run_record("r#{n}")) }
    ChangeCoverageStore.prune(@dir, 0)

    assert_empty ids
  end

  def test_max_runs_zero_records_nothing
    lines = store(max_runs: 0).record([ run_record("a") ])

    assert_empty ids
    assert_includes lines.last, "nothing recorded"
  end

  def test_bundle_keeps_twenty_full_and_summarizes_older_runs
    case_item = { "id" => "s/c", "status" => "pass" }
    test_result = { "label" => "unit", "counts" => { "pass" => 1 }, "items" => [ case_item ] }
    runs = (1..25).map do |n|
      run_record(format("r%02d", n), format("2026-10-%02dT00:00:00Z", n),
                 cases: { "counts" => { "pass" => 1 }, "items" => [ case_item ] },
                 imports: { "test_results" => [ test_result ] })
    end
    built = ChangeCoverageStore.bundle(runs, meta: { "project" => "example-co" })

    assert_equal 2, built["meta"]["format_version"]
    full, old = built["runs"].partition { |run| run["summary"].nil? }
    assert_equal 20, full.size
    assert_equal 5, old.size
    assert(full.all? { |run| run["cases"]["items"] == [ case_item ] })
    assert(old.all? { |run| run["summary"] == true && !run["cases"].key?("items") && run["cases"]["counts"] == { "pass" => 1 } })
    assert(old.none? { |run| run["imports"]["test_results"].first.key?("items") })
    assert_equal (1..5).map { |n| format("r%02d", n) }, old.map { |run| run["id"] }
  end

  def test_record_writes_runs_and_a_script_safe_bundle
    seen = []
    store(page_writer: ->(dir) { seen << dir }).record([ run_record("x", subject: "</script> ") ])
    text = File.read(File.join(@dir, "report-data.js"))

    assert text.start_with?(ChangeCoverageSchema::BUNDLE_PREFIX)
    refute_includes text, "</"
    refute_includes text, " "
    assert_equal "</script> ", bundle["runs"].first["subject"]
    assert_equal({ "format_version" => 2, "project" => "example-co", "origin" => ORIGIN }, bundle["meta"])
    assert_equal [ @dir ], seen
    assert_equal [ "report-data.js", "runs" ], Dir.children(@dir).sort
  end

  def test_manual_escaping_fallback_is_equally_safe
    data = { "s" => "</script>     ok" }
    escaped = ChangeCoverageStore.escape_for_script(JSON.generate(data))

    refute_match(%r{</| | }, escaped)
    assert_equal data, JSON.parse(escaped)
  end

  def test_runs_without_an_id_are_skipped_with_a_warning
    lines = store.record([ run_record("a"), { "schema" => 1 } ])

    assert_equal [ "a" ], ids
    assert_includes lines.first, "skipped 1 run(s) without an id"
  end

  # Eight real processes write the same id at once: each lands its own file.
  def test_concurrent_writers_with_one_id_all_land
    skip "fork unavailable" unless Process.respond_to?(:fork)

    pids = 8.times.map do
      fork do
        ChangeCoverageStore.write_run(@dir, run_record("same"))
        exit!(0)
      rescue StandardError
        exit!(1)
      end
    end
    statuses = pids.map { |pid| Process.wait2(pid).last }

    assert(statuses.all?(&:success?))
    files = Dir.children(File.join(@dir, "runs")).sort
    assert_equal 8, files.size
    assert_equal [ "same.json", *(2..8).map { |n| "same-#{n}.json" } ].sort, files
  end

  def test_merge_file_copies_run_files_from_another_store
    artifact = File.join(@root, "artifact")
    ChangeCoverageStore.new(artifact, max_runs: 200, origin: ORIGIN, project: "Example Co").record([ run_record("ci") ])
    store.record([ run_record("local") ])

    lines = store.merge_file(artifact)
    again = store.merge_file(File.join(artifact, "report-data.js"))

    assert_equal %w[ci local], ids.sort
    assert_includes lines.last, "merged 1 run(s)"
    assert_includes again.last, "merged 0 run(s)"
    assert_equal %w[ci local], bundle["runs"].map { |run| run["id"] }.sort
    assert_includes store.merge_file(File.join(@root, "missing")).first, "not found"
  end

  def test_a_version_one_data_file_is_split_into_run_files_once
    FileUtils.mkdir_p(@dir)
    File.write(File.join(@dir, "report-data.js"), <<~JS)
      window.CF_QA_COVERAGE = window.CF_QA_COVERAGE || { runs: [] };
      window.CF_QA_COVERAGE.meta = {"format_version":1,"project":"example-co","origin":null};
      window.CF_QA_COVERAGE.runs.push(#{JSON.generate(run_record('old', '2026-10-01T00:00:00Z'))});
      window.CF_QA_COVERAGE.runs.push({broken);
    JS

    store.record([ run_record("new") ])

    assert_equal %w[old new], ids
    assert_equal 2, bundle["meta"]["format_version"]
  end

  def test_dir_for_keys_on_the_project_slug_under_home
    assert_equal File.join(@root, ".claude", "cf", "coverage", "example-co"),
                 ChangeCoverageStore.dir_for(project: "Example Co", origin: ORIGIN, home: @root)
  end

  def test_origin_mismatch_suffixes_the_directory
    base = File.join(@root, ".claude", "cf", "coverage", "example-co")
    ChangeCoverageStore.new(base, max_runs: 200, origin: ORIGIN, project: "Example Co").record([ run_record("a") ])
    other = "https://example.invalid/other/app.git"

    same_dir, same_lines = ChangeCoverageStore.locate(project: "Example Co", origin: ORIGIN, home: @root)
    dir, lines = ChangeCoverageStore.locate(project: "Example Co", origin: "https://u:t@example.invalid/other/app.git",
                                            home: @root)

    assert_equal [ base, [] ], [ same_dir, same_lines ]
    assert_equal "#{base}-#{Digest::SHA256.hexdigest(other)[0, 8]}", dir
    assert_equal 1, lines.size
    refute_includes lines.first, "u:t@"
  end

  def test_nil_origin_matches_nil_origin
    base = File.join(@root, ".claude", "cf", "coverage", "example-co")
    ChangeCoverageStore.new(base, max_runs: 200, origin: nil, project: "Example Co").record([ run_record("a") ])

    assert_equal base, ChangeCoverageStore.dir_for(project: "Example Co", origin: nil, home: @root)
  end

  def test_meta_keeps_the_origin_of_the_repo_that_created_the_directory
    store.record([ run_record("a") ])
    store(origin: "https://example.invalid/elsewhere.git").record([ run_record("b") ])

    assert_equal ORIGIN, bundle["meta"]["origin"]
  end
end
