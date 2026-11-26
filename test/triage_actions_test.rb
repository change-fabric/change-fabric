# frozen_string_literal: true

require "minitest/autorun"
require_relative "support/triage_world"

# Phase 6 tick behavior: what launches, what only proposes or escalates, and
# the order of cap reservation, persistence and detached start (C1, C2, C4-C9).
class TriageActionsTest < Minitest::Test
  NOW = TriageFakes::NOW
  PARTIAL = File.join(TriageFakes::FIXTURES, "partial", "stacks")
  UNIT = "acme/api#launch/P2#Phase 1"

  def setup
    @world = TriageWorld.new
    @empty_stacks = Dir.mktmpdir("triage-no-stacks")
  end

  def teardown
    @world.close
    FileUtils.remove_entry(@empty_stacks)
  end

  def tick(**opts) = @world.tick(sources: @world.sources(stack_root: @empty_stacks), **opts)

  def launches(result) = result.summary["launched"]
  def kinds(result) = result.summary["actions"].map { |row| row["kind"] }

  def test_no_autopilot_window_means_propose_only_and_zero_launches
    @world.window(false)
    result = tick
    assert_equal [], launches(result)
    assert_equal [], @world.detached
    assert_includes kinds(result), "propose"
    assert_equal 0, @world.cap.used
    assert_empty @world.journal.rows
  end

  def test_an_open_window_starts_the_first_eligible_unit_detached
    result = tick
    assert_equal 1, launches(result).size
    assert_equal "start_next", launches(result).first["verb"]
    assert_equal UNIT, launches(result).first["unit"]
    assert_equal 1, @world.detached.size
    assert_equal "mini", @world.detached.first[:host]
  end

  def test_the_dispatch_and_cap_reservation_are_persisted_before_the_detached_job_starts
    seen = nil
    detach = lambda do |**args|
      seen = { rows: @world.journal.rows.map { |row| row["type"] }, used: @world.cap.used, id: args[:action_id] }
      true
    end
    Triage::Tick.new(root: @world.root, host: "mini", now: NOW, sources: @world.sources(stack_root: @empty_stacks), journal: @world.journal,
                     cap: @world.cap, inbox: @world.inbox, liveness: @world.liveness, grant: @world.grant, detach: detach,
                     expirer: ->(_dir) { TriageWorld::NoExpiry.new }).run
    assert_equal %w[dispatch], seen[:rows]
    assert_equal 1, seen[:used]
    row = @world.journal.rows.first
    assert_equal seen[:id], row["action_id"]
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, row["session_id"], "the session UUID is chosen before spawn")
    assert_equal 1, row["reservation"]["used"]
  end

  def test_the_grant_is_bound_to_receipt_repo_machine_unit_verb_and_expiry
    tick
    grant = @world.journal.rows.first["grant"]
    assert_equal({ "receipt_id" => "a" * 64, "repo" => "acme/api", "machine" => "mini", "unit" => UNIT, "verb" => "start_next",
                   "expires_at" => (NOW + 7200).iso8601 }, grant)
  end

  def test_one_active_unit_per_repo_a_second_tick_launches_nothing_new
    tick
    again = tick
    assert_equal [], launches(again)
    assert_includes kinds(again), "skip"
    assert_equal 1, @world.detached.size
  end

  def test_the_twenty_first_reservation_is_refused_and_nothing_launches
    cap = @world.cap(0)
    result = tick(cap: cap)
    assert_equal "cap_refused", launches(result).first["kind"]
    assert_equal [], @world.detached
    assert_empty @world.journal.rows
  end

  def test_a_refused_second_repo_when_the_cap_is_one
    world = TriageWorld.new(repos: { "acme/api" => "mini", "acme/web" => "mini" })
    result = world.tick(sources: world.sources(stack_root: @empty_stacks), cap: world.cap(1))
    assert_equal %w[start_next cap_refused], launches(result).map { |row| row["kind"] }
    assert_equal 1, world.detached.size
  ensure
    world.close
  end

  def test_the_vm_stays_report_only_and_never_launches
    world = TriageWorld.new(repos: { "acme/api" => "vm" })
    result = world.tick(host: "vm", sources: world.sources(stack_root: @empty_stacks))
    assert_equal [], launches(result)
    assert_equal [ "report_only" ], kinds(result)
    assert_equal [], world.detached
  ensure
    world.close
  end

  def test_another_hosts_repos_are_never_acted_on
    world = TriageWorld.new(repos: { "acme/api" => "vm" })
    result = world.tick(host: "mini", sources: world.sources(stack_root: @empty_stacks))
    assert_equal [], result.summary["actions"]
    assert_equal [], world.detached
  ensure
    world.close
  end

  def test_an_unset_host_is_report_only_everywhere
    result = @world.tick(host: nil, sources: @world.sources(stack_root: @empty_stacks))
    assert_equal [], result.summary["actions"]
    assert_equal [], @world.detached
  end

  def test_an_assignment_mismatch_refuses_and_escalates
    report = { "findings" => [ { "code" => "assignment_mismatch", "detail" => "acme/api: vm snapshot has version 2, map has mini v1" } ],
               "units" => [], "eligible" => [ UNIT ] }
    actions = Triage::Actions.new(host: "mini", report: report, map: Triage::HostMap.load(File.join(@world.root, "hosts.yml")),
                                  journal: @world.journal, liveness: @world.liveness, grant: @world.grant, now: NOW, stacks: []).plan
    assert_equal "escalate", actions.first.kind
    assert_equal "assignment_mismatch", actions.first.finding
  end

  def test_a_reassignment_marker_disables_dispatch_for_the_repo
    FileUtils.mkdir_p(Triage::Paths.disabled_dir(@world.root))
    File.write(Triage::Reassign.marker("acme/api", @world.root), "{}")
    result = tick
    assert_equal [], launches(result)
    assert_equal [ "report_only" ], kinds(result)
  end

  # --- recovery (C1) ---------------------------------------------------------

  def lease(session = "sess-1", heartbeat: NOW - 3600)
    holder = { "slug" => "s2", "session_id" => session, "pid" => 4242, "host" => "h", "heartbeat_at" => heartbeat.iso8601 }
    ->(_record) { holder }
  end

  def seed_owner(session = "sess-1")
    journal = @world.journal
    journal.append("type" => "dispatch", "action_id" => "old", "host" => "mini", "repo" => "acme/api", "unit" => "acme/api#stack/s2",
                   "verb" => "start_next", "session_id" => session, "path" => @world.path("acme/api"))
    journal.append("type" => "handshake", "action_id" => "old", "pid" => 4242, "pid_start" => "T0", "boot_id" => "boot-1",
                   "session_id" => session, "host" => "h", "fence" => 1)
  end

  def recover_tick(liveness:, lease_reader: lease)
    @world.tick(sources: @world.sources(stack_root: PARTIAL), liveness: liveness, lease_reader: lease_reader)
  end

  def test_a_dead_owner_is_recovered_with_a_reversible_verb_only
    seed_owner
    result = recover_tick(liveness: @world.liveness(boot: "boot-2"))
    action = launches(result).first
    assert_equal "recover", action["kind"]
    assert_equal "rewatch", action["verb"]
    assert_equal "acme/api#stack/s2", action["unit"]
    assert_includes Triage::Actions::RECOVER_VERBS.values, action["verb"]
    assert_equal({ "repo_id" => "acme/api", "slug" => "s2" }, @world.journal.dispatches.last.row["stack"])
  end

  def test_an_alive_owner_gives_zero_launches
    seed_owner
    live = @world.liveness(boot: "boot-1", pid_start: ->(_pid) { "T0" })
    result = recover_tick(liveness: live)
    assert_equal [], launches(result)
    assert_equal [], @world.detached
  end

  def test_an_unknown_owner_escalates_and_launches_nothing
    result = recover_tick(liveness: @world.liveness)
    assert_equal [], launches(result)
    assert_includes kinds(result), "escalate"
    item = @world.inbox.open_items.find { |row| row["kind"] == "triage_escalation" }
    assert_match(/owner is unknown/, item["title"])
  end

  def test_an_unknown_owner_from_a_failed_listing_never_acts
    seed_owner
    failing = Triage::Liveness::Agents.new(ok: false, complete: false, sessions: [])
    live = @world.liveness(boot: "boot-1", pid_start: ->(_pid) { :absent }, listing: failing)
    result = recover_tick(liveness: live)
    assert_equal [], launches(result)
    assert_equal "unknown", result.summary["reconciled"].first["decision"]
  end

  def test_a_fresh_lease_heartbeat_is_not_inspected_at_all
    result = recover_tick(liveness: @world.liveness, lease_reader: lease(heartbeat: NOW - 10))
    assert_equal [], launches(result)
    refute_includes kinds(result), "escalate"
  end

  def test_elapsed_time_alone_never_acts_even_with_a_very_old_heartbeat
    result = recover_tick(liveness: @world.liveness, lease_reader: lease("unregistered", heartbeat: NOW - 86_400 * 30))
    assert_equal [], launches(result)
    assert_equal [], @world.detached
  end

  def test_an_irreversible_resume_result_escalates_instead_of_acting
    seed_owner
    table = JSON.parse(File.read(File.join(TriageFakes::FIXTURES, "partial", "gh.json")))
    table["acme/api#12"]["state"] = "CLOSED"
    result = @world.tick(sources: @world.sources(stack_root: PARTIAL, gh: table), liveness: @world.liveness(boot: "boot-2"), lease_reader: lease)
    assert_equal [], launches(result)
    assert_includes kinds(result), "escalate"
  end

  def test_recovery_with_no_window_only_proposes
    seed_owner
    @world.window(false)
    result = recover_tick(liveness: @world.liveness(boot: "boot-2"))
    assert_equal [], launches(result)
    assert_includes kinds(result), "propose"
  end

  # --- grant binding (C6) ----------------------------------------------------

  def test_an_out_of_scope_repo_or_checkout_gets_no_grant
    grant = Triage::Grant.new(reader: ->(_path) { [] }, machine: "mini")
    assert_nil grant.for(repo: "acme/other", path: "/elsewhere", unit: "u", verb: "start_next", now: NOW)
  end

  def test_an_irreversible_verb_gets_no_grant
    %w[merge tag release carve_out].each do |verb|
      assert_nil @world.grant.for(repo: "acme/api", path: @world.path("acme/api"), unit: "u", verb: verb, now: NOW), verb
    end
  end

  def test_unreadable_approval_state_means_no_grant
    broken = Triage::Grant.new(reader: ->(_path) { raise "receipt store unreadable" }, machine: "mini")
    assert_nil broken.for(repo: "acme/api", path: "/x", unit: "u", verb: "start_next", now: NOW)
    refute broken.still_valid?(Triage::Grant::Value.new(receipt_id: "a" * 64, repo: "acme/api", machine: "mini", unit: "u",
                                                        verb: "start_next", expires_at: NOW + 60), path: "/x", now: NOW)
  end

  def test_a_window_that_expires_before_the_tick_gives_no_grant
    expired = Class.new(Struct.new(:id, :expires_at)).new("a" * 64, NOW - 1)
    grant = Triage::Grant.new(reader: ->(_path) { [ expired ] }, machine: "mini")
    assert_nil grant.for(repo: "acme/api", path: "/x", unit: "u", verb: "start_next", now: NOW)
  end

  def test_crossing_the_expiry_between_dispatch_and_spawn_parks_the_run
    tick
    later = NOW + 7201
    outcome = Triage::Launcher.run(@world.journal.dispatches.first.id, root: @world.root, journal: @world.journal, seeder: ->(_row) { },
                                                                       grant: @world.grant, clock: -> { later }, unlease: ->(_row) { })
    assert_equal "parked", outcome
  end

  # --- limits (C7) -----------------------------------------------------------

  def limit_until(time) = Triage::Limits::Store.new(root: @world.root).record(Triage::Limits::Outcome.new(klass: "quota_exhausted", limited_until: time), now: NOW)

  def test_a_multi_day_limit_blocks_dispatch_while_reports_keep_advancing_with_changing_pr_state
    limit_until(NOW + 86_400 * 3)
    first = @world.tick(now: NOW, sources: @world.sources(stack_root: PARTIAL), liveness: @world.liveness, lease_reader: lease("x"))
    table = JSON.parse(File.read(File.join(TriageFakes::FIXTURES, "partial", "gh.json")))
    table["acme/api#12"]["ci"] = "passed"
    table["acme/api#12"]["clean"] = true
    second = @world.tick(now: NOW + 86_400, sources: @world.sources(stack_root: PARTIAL, gh: table), liveness: @world.liveness, lease_reader: lease("x"))
    assert_equal [], launches(first) + launches(second)
    assert_equal [], @world.detached
    assert_equal first.summary["generation"] + 1, second.summary["generation"]
    changed = JSON.parse(File.read(File.join(@world.root, "report.json")))["changed"]
    assert(changed.any? { |row| row["unit"].include?("stack/s2") }, "the report reflects the new PR state")
    assert_equal "quota_exhausted", second.summary["limited"]["kind"]
    assert(@world.inbox.open_items.any? { |item| item["kind"] == "limited" })
  end

  def test_dispatch_resumes_after_the_limit_passes
    limit_until(NOW + 600)
    assert_equal [], launches(tick(now: NOW))
    assert_equal 1, launches(tick(now: NOW + 601)).size
  end

  # --- tick shape (C9) -------------------------------------------------------

  def test_a_dry_run_writes_nothing
    result = tick(dry_run: true)
    assert_equal [ true ], [ result.summary["dry_run"] ]
    assert_equal [ "hosts.yml" ], Dir.children(@world.root)
    assert_equal [], @world.detached
    assert_equal 1, result.summary["launched"].size
    assert result.summary["launched"].first["would_launch"]
    assert_empty Dir.children(@world.inbox_root)
  end

  def test_overlapping_ticks_the_second_does_nothing
    File.open(Triage::Paths.tick_lock_file(@world.root), File::RDWR | File::CREAT) do |held|
      held.flock(File::LOCK_EX)
      result = tick
      assert_equal "overlap", result.skipped
    end
    assert_equal [], @world.detached
  end

  def test_a_tick_over_its_time_budget_launches_nothing
    clock = [ 0, 100, 100, 100, 100, 100, 100, 100 ].each
    result = @world.tick(sources: @world.sources(stack_root: @empty_stacks), clock: -> { clock.next })
    assert result.summary["over_budget"]
    assert_equal [], @world.detached
  end

  def test_a_failed_detached_start_marks_the_dispatch_dead_and_keeps_the_reservation
    failing = ->(**_args) { false }
    result = @world.tick(sources: @world.sources(stack_root: @empty_stacks), detach: failing)
    assert_equal false, launches(result).first["started"]
    assert_equal "dead", @world.journal.dispatches.first.terminal["type"]
    assert_equal 1, @world.cap.used
  end

  def test_heartbeat_and_report_are_written_by_a_real_tick
    tick
    assert File.exist?(File.join(@world.root, "heartbeat", "mini.json"))
    assert_equal 1, JSON.parse(File.read(File.join(@world.root, "report.json")))["generation"]
  end
end
