# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "open3"
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

  def seed(target = store)
    target.claim(source: "stack")
    target.init(repo: "acme/web", source: "plan", mode: "merge_ready", plan_dir: "/p",
               prs: [ { number: 12, url: "#{URL}12", head: "a" }, { number: 13, url: "#{URL}13", head: "b" } ])
  end

  def test_init_writes_record_under_repo_and_slug
    seed
    assert_match %r{/\.claude/cf/stack/github\.com-acme-web-\h{12}/demo\.json\z}, store.path
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
    assert_equal [ "ACTIVE", "demo.json" ], Dir.children(File.dirname(store.path)).sort
  end

  def test_repo_ids_that_slug_alike_do_not_collide
    a = StackStore.new("github.com/acme-tools/web", "demo")
    b = StackStore.new("github.com/acme/tools-web", "demo")
    refute_equal a.path, b.path
    a.claim
    a.init(repo: "acme-tools/web", source: "plan", mode: "yolo", prs: [ { number: 1 } ])
    assert_nil b.read
  end

  def test_bad_mode_and_state_are_rejected
    assert_raises(StackStore::Invalid) { store.init(repo: "a/b", source: "plan", mode: "nope", prs: []) }
    seed
    assert_raises(StackStore::Invalid) { store.set_pr(12, state: "bogus") }
    assert_raises(StackStore::Invalid) { store.set_pr(99, state: "merged") }
  end

  def test_phase_field_is_optional_and_persisted
    store.claim
    store.init(repo: "acme/web", source: "plan", mode: "merge_ready",
               prs: [ { number: 12, phase: "demo-area/widget-plan#Phase 1" }, { number: 13 } ])
    assert_equal [ "demo-area/widget-plan#Phase 1", nil ], store.read["prs"].map { |pr| pr["phase"] }
    store.set_pr(13, phase: "demo-area/widget-plan#Phase 2")
    assert_equal "demo-area/widget-plan#Phase 2", store.read["prs"][1]["phase"]
    store.set_pr(13, phase: nil)
    assert_nil store.read["prs"][1]["phase"]
  end

  def test_old_record_without_phase_still_loads_and_updates
    FileUtils.mkdir_p(File.dirname(store.path))
    old = { "slug" => "demo", "repo" => "acme/web", "source" => "plan", "mode" => "merge_ready",
            "prs" => [ { "number" => 12, "url" => "#{URL}12", "head" => "a", "old_head_sha" => nil,
                         "state" => "pending", "pause_reason" => nil } ], "current" => 0, "judged" => [] }
    File.write(store.path, JSON.generate(old))
    record = store.read
    refute record["prs"].first.key?("phase")
    store.set_pr(12, state: "handed_off")
    assert_equal "handed_off", store.read["prs"].first["state"]
  end

  def test_bad_phase_is_rejected
    [ "widget-plan#Phase 1", "demo-area/widget-plan#Phase 0", "demo-area/widget-plan Phase 2", 7 ].each do |bad|
      assert_raises(StackStore::Invalid) do
        store.init(repo: "a/b", source: "plan", mode: "yolo", prs: [ { number: 1, phase: bad } ])
      end
    end
    seed
    assert_raises(StackStore::Invalid) { store.set_pr(12, phase: "nope") }
    out = StringIO.new
    StackStore::CLI.run([ "set-pr", "demo", "12", "phase=bad" ], out:, dir: @repo)
    assert_match(/phase must read/, JSON.parse(out.string)["error"])
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
    store.claim
    StackStore::CLI.run([ "init", "demo", "--repo", "acme/web", "--source", "list", "--mode", "yolo",
                          "--pr", "12:#{URL}12:feat-a:abc123" ], out:, dir: @repo, ctx: ->(*a) { calls << a })
    pr = JSON.parse(out.string)["prs"].first
    assert_equal [ 12, "#{URL}12", "feat-a", "abc123" ], pr.values_at("number", "url", "head", "old_head_sha")
    assert_equal [ [ @repo, "demo", :capture ] ], calls
  end

  def test_cli_retires_ctx_pointer_when_finished_or_cleared
    calls = []
    ctx = ->(*a) { calls << a }
    seed
    StackStore::CLI.run([ "advance", "demo" ], out: StringIO.new, dir: @repo, ctx:)
    assert_empty calls
    StackStore::CLI.run([ "advance", "demo" ], out: StringIO.new, dir: @repo, ctx:)
    assert_equal [ [ @repo, "demo", :retire ] ], calls
    StackStore::CLI.run([ "clear", "demo" ], out: StringIO.new, dir: @repo, ctx:)
    assert_equal 2, calls.size
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

  # Head of line guard.

  def test_non_current_pr_cannot_start_preparing_or_be_handed_off
    seed
    error = assert_raises(StackStore::Invalid) { store.set_pr(13, state: "preparing") }
    assert_equal "PR #13 is not head of line (current is #12)", error.message
    assert_raises(StackStore::Invalid) { store.set_pr(13, state: "handed_off") }
    assert_equal "pending", store.read["prs"][1]["state"]
  end

  def test_current_pr_may_start_preparing
    seed
    store.set_pr(12, state: "preparing")
    assert_equal "preparing", store.read["prs"][0]["state"]
  end

  def test_non_current_pr_may_still_be_escalated_or_annotated
    seed
    store.set_pr(13, state: "escalated", pause_reason: "author")
    store.set_pr(13, head: "renamed")
    assert_equal %w[escalated renamed], store.read["prs"][1].values_at("state", "head")
  end

  def test_advance_moves_exactly_one_pr
    seed
    store.advance
    assert_equal %w[merged pending], store.read["prs"].map { |pr| pr["state"] }
    assert_equal 1, store.read["current"]
    store.set_pr(13, state: "preparing")
  end

  def test_advance_expect_refuses_wrong_or_duplicate
    seed
    assert_raises(StackStore::Invalid) { store.advance(expect: 13) }
    store.advance(expect: 12)
    error = assert_raises(StackStore::Invalid) { store.advance(expect: 12) }
    assert_match(/expected #12, current is #13/, error.message)
    assert_equal %w[merged pending], store.read["prs"].map { |pr| pr["state"] }
  end

  def test_cli_set_pr_off_head_exits_non_zero
    seed
    out = StringIO.new
    status = StackStore::CLI.run([ "set-pr", "demo", "13", "state=preparing" ], out:, dir: @repo)
    assert_equal 1, status
    assert_match(/not head of line/, JSON.parse(out.string)["error"])
    assert_equal 0, StackStore::CLI.run([ "set-pr", "demo", "12", "state=preparing" ], out: StringIO.new, dir: @repo)
  end

  def test_cli_exit_status_from_a_real_process
    seed
    script = File.expand_path("../scripts/stack_store.rb", __dir__)
    _, status = Open3.capture2e({ "HOME" => @home }, "ruby", script, "set-pr", "demo", "13", "state=preparing", chdir: @repo)
    refute status.success?
  end

  # Active-queue claim.

  def other(slug) = StackStore.for_dir(@repo, slug)

  def test_claim_creates_then_resumes_then_blocks_another_queue
    assert_equal "created", store.claim(source: "sweep")["claim"]
    assert_equal "resumed", store.claim(source: "sweep")["claim"]
    error = assert_raises(StackStore::Held) { other("sweep-10-14").claim }
    assert_equal "demo", error.holder["slug"]
  end

  def test_stack_and_loop_queues_block_each_other
    other("prs-1-3").claim(source: "stack")
    out = StringIO.new
    assert_equal 1, StackStore::CLI.run([ "claim", "sweep-10-14", "--source", "sweep" ], out:, dir: @repo)
    reply = JSON.parse(out.string)
    assert_equal [ "held", "prs-1-3" ], [ reply["error"], reply.dig("holder", "slug") ]
    other("prs-1-3").release
    other("sweep-10-14").claim(source: "sweep")
    assert_raises(StackStore::Held) { other("prs-1-3").claim(source: "stack") }
  end

  def test_release_by_non_holder_is_a_no_op_and_clear_releases
    seed
    assert_equal false, other("x").release["released"]
    assert store.claimed?
    store.clear
    refute File.exist?(store.active_path)
  end

  def test_init_requires_the_claim_and_accepts_sweep_source
    error = assert_raises(StackStore::Invalid) do
      store.init(repo: "acme/web", source: "sweep", mode: "merge_ready", prs: [ { number: 1 } ])
    end
    assert_match(/claim demo before init/, error.message)
    store.claim
    store.init(repo: "acme/web", source: "sweep", mode: "merge_ready", prs: [ { number: 1 } ])
    assert_equal "sweep", store.read["source"]
  end

  def test_finished_record_is_not_reinitialized
    seed
    store.advance
    store.advance
    assert_raises(StackStore::Invalid) { seed }
  end

  # Atomic publish.

  def test_empty_or_garbage_active_reads_as_held
    FileUtils.mkdir_p(File.dirname(store.active_path))
    [ "", "{not json" ].each do |body|
      File.write(store.active_path, body)
      error = assert_raises(StackStore::Held) { store.claim }
      assert_nil error.holder
      refute store.claimed?
    end
  end

  def test_concurrent_claims_have_one_winner_and_readers_never_see_partial_json
    seen = []
    reader = Thread.new { 200.times { seen << StackStore.holder(store.active_path) } }
    results = Array.new(8) { |i| Thread.new { other("q#{i}").claim rescue :held } }.map(&:value)
    reader.join
    assert_equal 1, results.count { |r| r.is_a?(Hash) }
    refute_includes seen, :incomplete
    assert_empty Dir.glob("#{File.dirname(store.active_path)}/*.tmp")
  end

  def test_release_stale_clears_an_interrupted_claim_only_when_holder_is_dead
    store.claim
    store.lease(session: "s1", pid: Process.pid)
    assert_raises(StackStore::Invalid) { store.release(stale: true) }
    File.write(store.lease_path, JSON.generate(JSON.parse(File.read(store.lease_path)).merge("pid" => dead_pid)))
    assert store.release(stale: true)["released"]
    seed
    assert_raises(StackStore::Invalid) { store.release(stale: true) }
  end

  # Executor lease.

  def dead_pid
    pid = Process.spawn("true")
    Process.wait(pid)
    pid
  end

  def test_second_run_of_the_same_slug_is_leased_out
    store.lease(session: "s1", pid: Process.pid)
    error = assert_raises(StackStore::Held) { store.lease(session: "s2", pid: Process.pid) }
    assert_equal "leased", error.kind
    assert_equal "s1", error.holder["session_id"]
    assert_equal "s1", store.lease(session: "s1")["session_id"]
  end

  def test_lease_takeover_on_dead_pid_or_stale_heartbeat_only
    store.lease(session: "s1", pid: dead_pid)
    assert_equal "s2", store.lease(session: "s2", pid: Process.pid)["session_id"]
    assert_raises(StackStore::Held) { store.lease(session: "s3") }
    later = Time.now.utc + StackStore::LEASE_TTL + 1
    assert_equal "s3", store.lease(session: "s3", now: later)["session_id"]
  end

  def test_concurrent_takeover_of_a_stale_lease_has_one_winner
    store.lease(session: "old", now: Time.now.utc - StackStore::LEASE_TTL - 5)
    results = Array.new(8) do |i|
      Thread.new do
        store.lease(session: "s#{i}")
      rescue StackStore::Held
        :held
      end
    end.map(&:value)
    assert_equal 1, results.count { |r| r.is_a?(Hash) }
  end

  def test_init_refuses_to_overwrite_an_unfinished_record
    seed
    store.set_pr(12, state: "handed_off", old_head_sha: "abc")
    assert_raises(StackStore::Invalid) { seed }
    assert_equal "abc", store.read["prs"][0]["old_head_sha"]
  end

  def test_heartbeat_keeps_the_lease_and_unlease_frees_it
    store.lease(session: "s1", pid: Process.pid, now: Time.now.utc - StackStore::LEASE_TTL - 5)
    store.heartbeat(session: "s1")
    assert_raises(StackStore::Held) { store.lease(session: "s2") }
    assert_raises(StackStore::Invalid) { store.heartbeat(session: "s2") }
    store.unlease(session: "s1")
    assert_equal "s2", store.lease(session: "s2")["session_id"]
  end

  def test_unlease_by_a_taken_over_session_keeps_the_successor_lease
    store.lease(session: "s1", now: Time.now.utc - StackStore::LEASE_TTL - 5)
    store.lease(session: "s2")
    assert_nil store.unlease(session: "s1")["unleased"]
    assert_raises(StackStore::Held) { store.lease(session: "s3") }
  end

  def test_resolve_resumes_a_sweep_whose_endpoints_shifted
    active = other("sweep-12-14")
    seed(active)
    active.advance
    assert_equal({ "action" => "resume", "slug" => "sweep-12-14" }, StackStore.resolve(@repo, "sweep-13-14"))
    active.release
    assert_equal({ "action" => "resume", "slug" => "sweep-12-14" }, StackStore.resolve(@repo, "sweep-13-14"))
  end

  def test_handed_off_head_with_a_new_live_head_is_prepared_again
    assert_equal "rewatch", StackStore.resume_action("handed_off", "OPEN", recorded_head: "abc", live_head: "abc")
    assert_equal "redrive", StackStore.resume_action("handed_off", "OPEN", recorded_head: "abc", live_head: "def")
  end

  # Queue resolution.

  def test_resolve_new_then_suffix_after_finish
    assert_equal({ "action" => "new", "slug" => "sweep-10-14" }, StackStore.resolve(@repo, "sweep-10-14"))
    base = other("sweep-10-14")
    seed(base)
    base.advance
    base.advance
    base.release
    assert_equal({ "action" => "new", "slug" => "sweep-10-14-2" }, StackStore.resolve(@repo, "sweep-10-14"))
  end

  def test_resolve_resumes_unfinished_suffix_over_finished_base
    base = other("sweep-10-14")
    seed(base)
    2.times { base.advance }
    base.release
    seed(other("sweep-10-14-2"))
    other("sweep-10-14-2").release
    assert_equal({ "action" => "resume", "slug" => "sweep-10-14-2" }, StackStore.resolve(@repo, "sweep-10-14"))
    other("sweep-10-14-2").claim
    assert_equal({ "action" => "resume", "slug" => "sweep-10-14-2" }, StackStore.resolve(@repo, "sweep-10-14"))
  end

  def test_resolve_stops_on_another_holder
    other("prs-1-3").claim
    assert_raises(StackStore::Held) { StackStore.resolve(@repo, "sweep-10-14") }
  end

  # Handoff boundary and resume table.

  def test_crash_after_handed_off_resumes_to_rewatch_not_redrive
    seed
    store.set_pr(12, state: "preparing")
    store.set_pr(12, state: "handed_off", old_head_sha: "abc")
    head = StackStore.current_pr(StackStore.for_dir(@repo, "demo").read)
    assert_equal "rewatch", StackStore.resume_action(head["state"], "OPEN")
    assert_equal "abc", head["old_head_sha"]
    store.set_pr(12, state: "preparing")
    assert_equal "redrive", StackStore.resume_action(store.read["prs"][0]["state"], "OPEN")
  end

  def test_resume_table
    assert_equal "advance", StackStore.resume_action("handed_off", "MERGED")
    assert_equal "escalate", StackStore.resume_action("pending", "CLOSED")
    assert_equal "drive", StackStore.resume_action("pending", "OPEN")
    assert_equal "report", StackStore.resume_action("paused", "OPEN")
    assert_equal "report", StackStore.resume_action("escalated", "OPEN")
  end

  def test_merge_commit_detection
    refute StackStore.merge_commit?("abc123 def456\n")
    assert StackStore.merge_commit?("abc123 def456 789abc\n")
  end

  def nudge(prompt, records)
    io = StringIO.new
    PruneRemind.new({ "prompt" => prompt }, records).emit(io)
    JSON.parse(io.string).dig("hookSpecificOutput", "additionalContext")
  end
end
