# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "support/triage_fakes"
require_relative "../scripts/triage/publisher"
require_relative "../scripts/triage"

# publish is the tick body: it advances the generation by one, writes the
# report, its baseline and the snapshot atomically, and a failure keeps the
# previous valid report. report and every status read never touch the baseline.
class TriagePublishTest < Minitest::Test
  FIX = File.join(TriageFakes::FIXTURES, "partial")

  def setup
    @root = Dir.mktmpdir
    @prev_host = ENV["CF_TRIAGE_HOST"]
    @prev_root = ENV["CF_TRIAGE_ROOT"]
    ENV["CF_TRIAGE_HOST"] = "mini"
    ENV["CF_TRIAGE_ROOT"] = @root
    File.write(File.join(@root, "hosts.yml"), "repos:\n  acme/api: {host: mini, assignment_version: 1}\n")
  end

  def teardown
    @prev_host ? ENV["CF_TRIAGE_HOST"] = @prev_host : ENV.delete("CF_TRIAGE_HOST")
    @prev_root ? ENV["CF_TRIAGE_ROOT"] = @prev_root : ENV.delete("CF_TRIAGE_ROOT")
    FileUtils.remove_entry(@root)
  end

  def sources(table = nil)
    table ||= JSON.parse(File.read(File.join(FIX, "gh.json")))
    { gh: TriageFakes::Gh.new(table), epic_gh: TriageFakes::EpicGh.new({}), decisions: [],
      plans_root: File.join(FIX, "plans"), stack_root: File.join(FIX, "stacks"), pull: ->(_) { raise "must not pull in this test" } }
  end

  def publish(table = nil, now: TriageFakes::NOW) = Triage::Publisher.publish(root: @root, now: now, **sources(table))
  def read(name) = JSON.parse(File.read(File.join(@root, name)))

  def test_each_publish_advances_the_generation_by_exactly_one
    assert_equal [ 1, 2, 3 ], Array.new(3) { publish.generation }
    assert_equal 3, read("report.json")["generation"]
    assert_equal 3, read("snapshot.json")["generation"]
    assert_equal 2, read("report.prev.json")["generation"], "the baseline is the previous published report"
  end

  def test_the_first_publish_has_no_baseline
    publish
    refute File.exist?(File.join(@root, "report.prev.json"))
    assert_equal 1, read("report.json")["generation"]
  end

  def test_a_publish_leaves_no_staging_files_and_writes_the_heartbeat
    publish
    assert_equal [], Dir.glob(File.join(@root, "**", "*.next")) + Dir.glob(File.join(@root, "**", "*.tmp"))
    beat = read("heartbeat/mini.json")
    assert_equal "mini", beat["host"]
    assert_equal 1, beat["generation"]
  end

  def test_changed_diffs_against_the_previous_published_tick
    publish
    merged = JSON.parse(File.read(File.join(FIX, "gh.json"))).merge("acme/api#12" => { "state" => "MERGED" })
    second = publish(merged, now: TriageFakes::NOW + 900)
    assert(second.report["changed"].any? { |row| row["field"] == "percent_label" && row["to"] == "66%" })
  end

  def test_a_failed_publication_keeps_the_previous_valid_report_and_baseline
    publish
    publish
    before = %w[report.json report.prev.json snapshot.json].to_h { |name| [ name, File.read(File.join(@root, name)) ] }
    assert_raises(Triage::GhLive::QueryError) { publish({}) }
    after = %w[report.json report.prev.json snapshot.json].to_h { |name| [ name, File.read(File.join(@root, name)) ] }
    assert_equal before, after
    assert_equal 3, publish.generation, "a failed attempt does not consume a generation"
  end

  def test_a_staging_failure_renames_nothing
    publish
    before = File.read(File.join(@root, "report.json"))
    File.write(File.join(@root, "snapshot.json.next"), "") # a stray file is simply overwritten
    FileUtils.mkdir_p(File.join(@root, "report.json.next")) # a directory in the way makes staging the report fail
    assert_raises(SystemCallError) { publish }
    assert_equal before, File.read(File.join(@root, "report.json"))
  end

  def test_the_snapshot_carries_only_this_hosts_repos_and_its_decisions
    publish
    snap = read("snapshot.json")
    assert_equal "mini", snap["host"]
    assert_equal [ "acme/api" ], snap["repos"].map { |row| row["repo"] }
    assert_equal 1, snap["repos"].first["assignment_version"]
    assert_equal [ "acme/api#stack/s2" ], snap["repos"].first["units"].map { |row| row["unit"] }
    assert Triage::Snapshot.valid?(snap)
  end

  def test_report_is_a_pure_read_and_never_moves_the_baseline
    publish
    files = Dir.glob(File.join(@root, "**", "*")).select { |f| File.file?(f) }.to_h { |f| [ f, File.read(f) ] }
    inputs = Triage::Sources.collect(root: @root, now: TriageFakes::NOW + 60, **sources.except(:now))
    3.times { Triage::Report.new(**inputs).build }
    after = Dir.glob(File.join(@root, "**", "*")).select { |f| File.file?(f) }.to_h { |f| [ f, File.read(f) ] }
    assert_equal files, after
  end

  def test_the_report_command_writes_nothing
    out = StringIO.new
    status = Triage::CLI.run([ "report", "--json" ], out: out, now: TriageFakes::NOW, sources: sources)
    assert_equal 0, status
    assert_equal 1, JSON.parse(out.string)["units"].size
    assert_equal [ "hosts.yml" ], Dir.children(@root)
  end

  def test_the_publish_command_prints_a_summary_and_advances
    out = StringIO.new
    assert_equal 0, Triage::CLI.run([ "publish", "--json" ], out: out, now: TriageFakes::NOW, sources: sources)
    summary = JSON.parse(out.string)
    assert_equal true, summary["published"]
    assert_equal 1, summary["generation"]
  end

  def test_the_cli_rejects_unknown_commands_with_usage
    err = StringIO.new
    assert_equal 2, Triage::CLI.run([ "bogus" ], out: StringIO.new, err: err)
    assert_includes err.string, "usage"
    assert_equal 2, Triage::CLI.run([ "report", "--wat" ], out: StringIO.new, err: err)
  end

  def test_a_query_error_exits_nonzero_from_the_cli
    err = StringIO.new
    assert_equal 1, Triage::CLI.run([ "report" ], out: StringIO.new, err: err, now: TriageFakes::NOW, sources: sources({}))
    assert_includes err.string, "no fixture"
  end
end
