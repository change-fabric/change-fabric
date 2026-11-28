# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require_relative "git_fixture"
require_relative "../scripts/suite_pass_cache"
require_relative "../scripts/review_stage1"

class SuitePassCacheTest < Minitest::Test
  def setup
    GitFixture.scrub_env! if GitFixture.respond_to?(:scrub_env!)
    @repo = Dir.mktmpdir("spc-repo")
    @store = Dir.mktmpdir("spc-store")
    @saved = ENV.fetch("CF_SUITE_PASS_DIR", nil)
    ENV["CF_SUITE_PASS_DIR"] = @store
    git("init", "-q")
    git("config", "user.email", "t@example.com")
    git("config", "user.name", "t")
    File.write(File.join(@repo, "Gemfile"), "source 'https://rubygems.org'\n")
    File.write(File.join(@repo, "Rakefile"), "require 'rake/testtask'\nRake::TestTask.new\n")
    git("add", "-A")
    git("commit", "-qm", "init")
  end

  def teardown
    ENV["CF_SUITE_PASS_DIR"] = @saved
    FileUtils.rm_rf([ @repo, @store ])
  end

  def git(*args)
    out, status = Open3.capture2e("git", "-C", @repo, *args)
    raise out unless status.success?

    out.strip
  end

  def head_tree = git("rev-parse", "HEAD^{tree}")

  def test_records_and_hits_a_clean_tree
    refute SuitePassCache.hit?(@repo, head_tree)
    assert SuitePassCache.record(@repo, head_tree)
    assert SuitePassCache.hit?(@repo, head_tree)
  end

  def test_a_dirty_working_tree_never_records
    File.write(File.join(@repo, "Gemfile"), "# edited\n")
    refute SuitePassCache.record(@repo, head_tree)
    refute SuitePassCache.hit?(@repo, head_tree)
  end

  def test_an_untracked_file_never_records
    File.write(File.join(@repo, "extra.rb"), "1\n")
    refute SuitePassCache.record(@repo, head_tree)
  end

  def test_a_hit_ignores_the_dirty_working_tree
    SuitePassCache.record(@repo, head_tree)
    File.write(File.join(@repo, "Gemfile"), "# edited\n")
    assert SuitePassCache.hit?(@repo, head_tree)
  end

  def test_staged_tree_keys_differ_from_head
    SuitePassCache.record(@repo, head_tree)
    File.write(File.join(@repo, "a.rb"), "1\n")
    git("add", "a.rb")
    refute SuitePassCache.hit?(@repo, git("write-tree"))
  end

  def test_rejects_a_non_tree_argument
    refute SuitePassCache.hit?(@repo, "HEAD")
    refute SuitePassCache.record(@repo, "")
  end

  # Stage 1 runs the rake suite once, records it, then skips it for the same tree.
  def test_stage1_skips_the_rake_suite_for_a_passed_tree
    calls = []
    runner = lambda do |command, _root, _timeout, _env = nil|
      calls << command
      ChangeProcess::Result.new(status: :pass, output: "", exit_code: 0, timed_out: false)
    end
    run = -> { ReviewStage1.run(@repo, runner: runner, cache: SuitePassCache, files: []) }
    run.call
    assert_equal 1, calls.count("bundle exec rake test")
    report = run.call
    assert_equal 1, calls.count("bundle exec rake test")
    row = report.results.find { |r| r.id == "tests" }
    assert_equal "passed", row.status
  end

  def test_stage1_without_a_cache_always_runs
    calls = []
    runner = lambda do |command, _root, _timeout, _env = nil|
      calls << command
      ChangeProcess::Result.new(status: :pass, output: "", exit_code: 0, timed_out: false)
    end
    SuitePassCache.record(@repo, head_tree)
    ReviewStage1.run(@repo, runner: runner, files: [])
    assert_equal 1, calls.count("bundle exec rake test")
  end

  def test_a_sharded_run_neither_records_nor_hits
    SuitePassCache.record(@repo, head_tree)
    ENV["TEST_SHARD"] = "1/4"
    refute SuitePassCache.hit?(@repo, head_tree)
    FileUtils.rm_rf(Dir.glob(File.join(@store, "*")))
    refute SuitePassCache.record(@repo, head_tree)
  ensure
    ENV.delete("TEST_SHARD")
  end

  def test_a_lane_entry_named_rake_never_uses_the_cache
    run = ReviewStage1::Run.new(@repo, cache: SuitePassCache)
    lane = { name: "rake", run: "bundle exec rake test", env: {} }
    manifest = { name: "rake", run: "bundle exec rake test" }
    refute run.send(:manifest_rake?, lane)
    refute run.send(:manifest_rake?, { name: "rake", run: "make check" })
    assert run.send(:manifest_rake?, manifest)
  end
end
