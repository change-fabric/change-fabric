# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "git_fixture"
require_relative "../scripts/stack_store"
require_relative "../scripts/ctx_session_start"
require_relative "../scripts/prune_remind"

class StackStoreTest < Minitest::Test
  URL = "https://github.com/acme/web/pull/"

  def setup
    @home = Dir.mktmpdir
    @prev = Dir.home
    ENV["HOME"] = @home
    @repo = Dir.mktmpdir
    GitFixture.git_init(@repo)
    GitFixture.git(@repo, "config", "--local", "remote.origin.url", "git@github.com:acme/web.git")
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
    FileUtils.remove_entry(@repo)
  end

  def store = StackStore.for_dir(@repo, "demo")

  def seed
    store.init(repo: "acme/web", source: "plan", mode: "merge_ready", plan_dir: "/p",
               prs: [ { number: 12, url: "#{URL}12", head: "a" }, { number: 13, url: "#{URL}13", head: "b" } ])
  end

  def test_init_writes_record_under_repo_and_slug
    seed
    assert_match %r{/\.claude/cf/stack/github\.com-acme-web/demo\.json\z}, store.path
    record = store.read
    assert_equal [ 12, 13 ], record["prs"].map { |pr| pr["number"] }
    assert_equal "pending", record["prs"].first["state"]
    assert_equal 0, record["current"]
    assert_equal [], record["judged"]
  end

  def test_corrupt_file_reads_as_absent
    seed
    File.write(store.path, "{not json")
    assert_nil store.read
    assert_empty StackStore.all_for_dir(@repo)
  end

  def test_write_leaves_no_temp_file
    seed
    assert_equal [ "demo.json" ], Dir.children(File.dirname(store.path))
  end

  def test_bad_mode_and_state_are_rejected
    assert_raises(StackStore::Invalid) { store.init(repo: "a/b", source: "plan", mode: "nope", prs: []) }
    seed
    assert_raises(StackStore::Invalid) { store.set_pr(12, state: "bogus") }
    assert_raises(StackStore::Invalid) { store.set_pr(99, state: "merged") }
  end

  def test_advance_and_pause_track_the_current_pr
    seed
    store.set_pr(12, state: "handed_off", old_head_sha: "abc")
    store.advance
    record = store.read
    assert_equal "merged", record["prs"][0]["state"]
    assert_equal 1, record["current"]
    store.pause("plan_interview")
    assert_equal %w[paused plan_interview], store.read["prs"][1].values_at("state", "pause_reason")
    store.advance
    assert StackStore.finished?(store.read)
  end

  def test_cli_init_parses_pr_specs_and_writes_ctx_pointer
    calls = []
    out = StringIO.new
    StackStore::CLI.run([ "init", "demo", "--repo", "acme/web", "--source", "list", "--mode", "yolo",
                          "--pr", "12:#{URL}12:feat-a:abc123" ], out:, dir: @repo, ctx: ->(*a) { calls << a })
    pr = JSON.parse(out.string)["prs"].first
    assert_equal [ 12, "#{URL}12", "feat-a", "abc123" ], pr.values_at("number", "url", "head", "old_head_sha")
    assert_equal [ [ @repo, "demo" ] ], calls
  end

  def test_cli_set_pr_and_errors_print_json
    seed
    out = StringIO.new
    StackStore::CLI.run([ "set-pr", "demo", "13", "state=escalated", "pause_reason=null" ], out:, dir: @repo)
    assert_equal "escalated", JSON.parse(out.string)["prs"][1]["state"]
    out = StringIO.new
    StackStore::CLI.run([ "advance", "missing" ], out:, dir: @repo)
    assert_match(/no stack named missing/, JSON.parse(out.string)["error"])
  end

  def test_session_start_surfaces_unfinished_stack
    seed
    io = StringIO.new
    CtxSessionStart.run({ "cwd" => @repo }, io)
    text = JSON.parse(io.string).dig("hookSpecificOutput", "additionalContext")
    assert_includes text, "PR stack demo is paused at #12; run /cf:sweep stack resume"
  end

  def test_prune_remind_adds_resume_for_current_pr_only
    seed
    records = StackStore.all_for_dir(@repo)
    assert_includes nudge("merged #12", records), "/cf:sweep stack resume"
    refute_includes nudge("merged #13", records), "/cf:sweep stack resume"
  end

  def nudge(prompt, records)
    io = StringIO.new
    PruneRemind.new({ "prompt" => prompt }, records).emit(io)
    JSON.parse(io.string).dig("hookSpecificOutput", "additionalContext")
  end
end
