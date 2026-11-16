# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "git_fixture"
require_relative "../scripts/simplicity_signals"

# The ts-prune parser runs on a captured synthetic output string, always. The
# container path runs real ts-prune only with CF_DOCKER_TESTS=1, since it
# pulls a node image and fetches ts-prune over the network.
class SimplicitySignalsTsTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/simplicity/ts", __dir__)
  ROOT = File.expand_path("..", __dir__)

  CAPTURED = <<~OUT
    src/format.ts:5 - formatLegacyTotal
    src/format.ts:9 - roundCents (used in module)
    src/other.ts:2 - untouchedExport
    npm notice New major version of npm available!
  OUT

  def setup
    @dirs = []
  end

  def teardown
    @dirs.each { |dir| FileUtils.remove_entry(dir) }
  end

  def test_parser_keeps_unused_exports_in_changed_files_only
    hits = SimplicitySignals.parse_ts_prune(CAPTURED, [ "src/format.ts" ])

    assert_equal [ { "name" => "formatLegacyTotal", "file" => "src/format.ts", "line" => 5 } ], hits
  end

  def test_versions_are_pinned
    assert_equal "0.10.3", SimplicitySignals::TS_PRUNE_VERSION
    assert_match(/\Anode:22\.18-alpine@sha256:\h{64}\z/, SimplicitySignals::TS_PRUNE_IMAGE)
  end

  def test_ts_prune_is_never_a_package_dependency
    path = File.join(ROOT, "package.json")
    skip "no package.json" unless File.exist?(path)

    json = JSON.parse(File.read(path))
    deps = %w[dependencies devDependencies optionalDependencies].flat_map { |key| json.fetch(key, {}).keys }
    refute_includes deps, "ts-prune"
  end

  def test_range_without_ts_leaves_unused_ts_null_without_note
    report = SimplicitySignals.run(repo: repo_with(ts: false), base: "HEAD~1", head: "HEAD")

    assert_nil report["unused_ts"]
    refute report["notes"].any? { |note| note.start_with?("unused_ts") }
  end

  def test_missing_tsconfig_nulls_unused_ts_with_note
    dir = repo_with(ts: true) { |root| FileUtils.rm(File.join(root, "tsconfig.json")) }
    report = SimplicitySignals.run(repo: dir, base: "HEAD~1", head: "HEAD")

    assert_nil report["unused_ts"]
    assert report["notes"].any? { |note| note.include?("unused_ts unavailable: no tsconfig.json") }
  end

  def test_container_reports_the_unused_export
    skip "set CF_DOCKER_TESTS=1 to run ts-prune in its container" unless ENV["CF_DOCKER_TESTS"] == "1"

    report = SimplicitySignals.run(repo: repo_with(ts: true), base: "HEAD~1", head: "HEAD")

    assert_equal [ { "name" => "formatLegacyTotal", "file" => "src/format.ts", "line" => 5 } ], report["unused_ts"]
  end

  def test_container_reads_head_not_the_working_tree
    skip "set CF_DOCKER_TESTS=1 to run ts-prune in its container" unless ENV["CF_DOCKER_TESTS"] == "1"

    dir = repo_with(ts: true)
    FileUtils.rm(File.join(dir, "tsconfig.json"))
    File.write(File.join(dir, "src/format.ts"), "export const formatTotal = 1;\n")
    report = SimplicitySignals.run(repo: dir, base: "HEAD~1", head: "HEAD")

    assert_equal [ { "name" => "formatLegacyTotal", "file" => "src/format.ts", "line" => 5 } ], report["unused_ts"]
  end

  private

  # Commits a README as base, then the TS fixture (or a Ruby file) as head.
  def repo_with(ts:)
    dir = Dir.mktmpdir
    @dirs << dir
    GitFixture.git_init(dir, "-b", "main")
    GitFixture.git(dir, "config", "user.email", "fixture@example.com")
    GitFixture.git(dir, "config", "user.name", "Fixture")
    File.write(File.join(dir, "README.md"), "fixture\n")
    commit(dir, "base")
    ts ? FileUtils.cp_r("#{FIXTURE}/.", dir) : File.write(File.join(dir, "app.rb"), "puts 1\n")
    yield dir if block_given?
    commit(dir, "head")
    dir
  end

  def commit(dir, message)
    GitFixture.git(dir, "add", "-A")
    GitFixture.git(dir, "commit", "-q", "-m", message)
  end
end
