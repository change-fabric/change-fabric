# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "digest"
require_relative "../scripts/change_coverage_store"

# Covers the QA coverage data file: its line shape, script-safe JSON, merge by
# id, retention, the corrupt-line backup, the lock under real contention, the
# origin-mismatch directory, and the atomic rewrite.
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

  def data_lines = File.read(File.join(@dir, "report-data.js"), encoding: "UTF-8").lines(chomp: true)

  def test_header_meta_and_one_line_per_run
    store.record([ run_record("b", "2026-10-13T14:00:00Z"), run_record("a", "2026-10-13T15:00:00Z") ])

    lines = data_lines
    assert_equal ChangeCoverageSchema::HEADER, lines[0]
    assert lines[1].start_with?(ChangeCoverageSchema::META_PREFIX)
    assert_equal({ "format_version" => 1, "project" => "example-co", "origin" => ORIGIN },
                 ChangeCoverageStore.parse(lines[1]).meta)
    assert_equal 4, lines.size
    assert(lines[2..].all? { |line| line.start_with?(ChangeCoverageSchema::RUN_PREFIX) && line.end_with?(");") })
    assert_equal %w[b a], store.runs.map { |run| run["id"] }
  end

  def test_run_fields_cannot_end_the_script
    store.record([ run_record("x", subject: "</script><script>alert(1)</script>", note: "a b c") ])

    line = data_lines[2]
    refute_includes line, "</"
    refute_includes line, " "
    refute_includes line, " "
    assert_equal "a b c", store.runs.first["note"]
    assert_equal "</script><script>alert(1)</script>", store.runs.first["subject"]
  end

  # The fallback a json gem without script_safe would take, held to the same
  # promise: nothing that ends a script, and the same data back.
  def test_manual_escaping_fallback_is_equally_safe
    data = { "s" => "</script>   ok" }
    escaped = ChangeCoverageStore.escape_for_script(JSON.generate(data))

    refute_match(%r{</| | }, escaped)
    assert_equal data, JSON.parse(escaped)
  end

  def test_merge_by_id_replaces_the_existing_run
    store.record([ run_record("a", status: "old"), run_record("b") ])
    lines = store.record([ run_record("a", status: "new") ])

    assert_equal 2, store.runs.size
    assert_equal "new", store.runs.find { |run| run["id"] == "a" }["status"]
    assert_includes lines.last, "recorded 1 run(s)"
  end

  def test_retention_keeps_the_newest_runs
    runs = (1..12).map { |n| run_record(format("r%02d", n), format("2026-10-%02dT00:00:00Z", n)) }
    store(max_runs: 10).record(runs)

    assert_equal (3..12).map { |n| format("r%02d", n) }, store.runs.map { |run| run["id"] }
  end

  def test_runs_without_an_id_are_skipped_with_a_warning
    lines = store.record([ run_record("a"), { "schema" => 1 } ])

    assert_equal [ "a" ], store.runs.map { |run| run["id"] }
    assert_includes lines.first, "skipped 1 run(s) without an id"
  end

  def test_corrupt_line_is_backed_up_and_reported
    store.record([ run_record("a") ])
    path = File.join(@dir, "report-data.js")
    File.write(path, "#{File.read(path)}garbage line\nwindow.CF_QA_COVERAGE.runs.push({not json});\n")
    original = File.read(path)

    lines = store.record([ run_record("b") ])

    backups = Dir.glob(File.join(@dir, "report-data.js.corrupt-*"))
    assert_equal 1, backups.size
    assert_equal original, File.read(backups.first)
    assert(lines.any? { |line| line.include?("line 4 is not a coverage line") })
    assert(lines.any? { |line| line.include?("line 5 is not a coverage line") })
    assert_equal %w[a b], store.runs.map { |run| run["id"] }
    assert_empty ChangeCoverageStore.parse(File.read(path)).bad_lines
  end

  # Two real processes record at the same moment. Each holds the lock while
  # its page writer sleeps, so without the lock one would read before the
  # other wrote and drop that run.
  def test_concurrent_processes_both_land_their_runs
    skip "fork unavailable" unless Process.respond_to?(:fork)

    pids = %w[one two].map do |id|
      fork do
        slow = ->(_dir) { sleep 0.3 }
        store(page_writer: slow).record([ run_record(id) ])
        exit!(0)
      end
    end
    statuses = pids.map { |pid| Process.wait2(pid).last }

    assert(statuses.all?(&:success?))
    assert_equal %w[one two], store.runs.map { |run| run["id"] }.sort
  end

  def test_page_writer_is_called_with_the_directory
    seen = []
    store(page_writer: ->(dir) { seen << dir }).record([ run_record("a") ])

    assert_equal [ @dir ], seen
  end

  def test_atomic_write_leaves_no_temp_file
    store.record([ run_record("a") ])

    assert_equal [ ".lock", "report-data.js" ], Dir.children(@dir).sort
  end

  def test_parse_round_trips_write_lines
    subject = store
    runs = [ run_record("a", nested: { "list" => [ 1, nil, "</x>" ] }), run_record("b", "2026-10-14T00:00:00Z") ]
    parsed = ChangeCoverageStore.parse(subject.write_lines(runs).join("\n"))

    assert_equal runs, parsed.runs
    assert_equal({ "format_version" => 1, "project" => "example-co", "origin" => ORIGIN }, parsed.meta)
    assert_empty parsed.bad_lines
  end

  def test_parse_ignores_blank_lines_and_flags_others
    text = "#{ChangeCoverageSchema::HEADER}\n\n// note\nwindow.CF_QA_COVERAGE.runs.push([1]);\n"

    assert_equal [ 3, 4 ], ChangeCoverageStore.parse(text).bad_lines
  end

  def test_merge_file_reads_a_directory_holding_a_data_file
    artifact = File.join(@root, "artifact")
    ChangeCoverageStore.new(artifact, max_runs: 200, origin: ORIGIN, project: "Example Co").record([ run_record("ci") ])
    store.record([ run_record("local") ])

    lines = store.merge_file(artifact)

    assert_equal %w[ci local], store.runs.map { |run| run["id"] }.sort
    assert_includes lines.last, "merged 1 run(s)"
    assert_equal [ "merge: #{File.join(@root, 'missing', 'report-data.js')} not found" ],
                 store.merge_file(File.join(@root, "missing", "report-data.js"))
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

    assert_equal ORIGIN, ChangeCoverageStore.parse(File.read(File.join(@dir, "report-data.js"))).meta["origin"]
  end
end
