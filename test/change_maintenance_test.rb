# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require "json"
require "tmpdir"
require "stringio"
require "open3"
require_relative "../scripts/change_maintenance"

# Maintenance windows, the op runner and the reconciler (spec 0.31.0). Commands
# go through a scripted fake executor and the journal lives in a temp git repo.
class ChangeMaintenanceTest < Minitest::Test
  M = ChangeMaintenance
  FIXTURE = File.expand_path("fixtures/prod/valid.yml", __dir__)
  UUID = "0b9c3f0e-3a55-4c0a-9d5e-6f3a0b1c2d3e"
  # A Monday, 03:10 UTC: inside weekday_night (0 3 * * 1-5, 60 minutes).
  OPEN = Time.utc(2026, 11, 23, 3, 10, 0)
  # Budget for rotate_tenant_key: enter 60 + verify 30 twice + exit 60 + op 900 + op verify 120.
  BUDGET = 1200

  class FakeExecutor
    attr_reader :calls

    def initialize(&decide)
      @decide = decide || ->(_argv) { {} }
      @calls = []
    end

    def call(argv, env: {}, timeout: nil, chdir: nil)
      @calls << argv.join(" ")
      answer = @decide.call(argv)
      ChangeBackup::Outcome.new(ok: answer.fetch(:ok, true), stdout: "", stderr: "", timed_out: answer[:timed_out] || false, spawn_failed: answer[:spawn_failed])
    end

    def ran?(text) = @calls.any? { |call| call.include?(text) }
  end

  def config = YAML.safe_load_file(FIXTURE)

  def with_journal
    Dir.mktmpdir do |root|
      system("git", "init", "-q", root)
      yield M::Journal.new(root, push: false)
    end
  end

  # Maintenance reads "on" until the exit command has run.
  def maintenance_executor(fail_on: nil, timeout_on: nil)
    on = false
    FakeExecutor.new do |argv|
      line = argv.join(" ")
      on = true if line.include?("maint on")
      on = false if line.include?("maint off")
      next { ok: on } if line.include?("maint status")
      next { ok: false, timed_out: true } if timeout_on && line.include?(timeout_on)

      { ok: !(fail_on && line.include?(fail_on)) }
    end
  end

  def runner(journal, executor, now: OPEN, cfg: config, sleeper: ->(_seconds) { }, clock: nil)
    M::Runner.new(config: cfg, journal: journal, executor: executor, request_id: UUID, environment: "production", run_id: "42",
                  clock: clock || -> { now }, sleeper: sleeper)
  end

  def states(journal) = journal.entries(UUID).map { |entry| entry["state"] }

  # --- window evaluation -------------------------------------------------------------

  def window = config.dig("change_config", "maintenance", "windows", "weekday_night")

  def test_an_open_window_reports_its_remaining_time
    state = M.window_state(window, OPEN)
    assert state[:open]
    assert_equal 3000, state[:remaining_s]
    assert_equal Time.utc(2026, 11, 23, 4, 0, 0), state[:ends_at].utc
  end

  def test_a_closed_window_reports_the_next_start_and_skips_the_weekend
    friday_after = Time.utc(2026, 11, 27, 4, 30, 0)
    state = M.window_state(window, friday_after)
    refute state[:open]
    assert_equal Time.utc(2026, 11, 30, 3, 0, 0), state[:next_start].utc
  end

  def test_the_window_edges_are_start_inclusive_and_end_exclusive
    assert M.window_state(window, Time.utc(2026, 11, 23, 3, 0, 0))[:open]
    refute M.window_state(window, Time.utc(2026, 11, 23, 4, 0, 0))[:open]
  end

  def test_a_window_that_crosses_midnight_is_open_after_it
    night = { "cron" => "30 23 * * *", "duration_minutes" => 120, "tz" => "UTC" }
    state = M.window_state(night, Time.utc(2026, 11, 24, 0, 45, 0))
    assert state[:open]
    assert_equal 2700, state[:remaining_s]
  end

  def test_the_time_zone_moves_the_window
    zoned = window.merge("tz" => "America/Chicago")
    refute M.window_state(zoned, OPEN)[:open] # 03:10 UTC is 21:10 CST the day before
    assert M.window_state(zoned, Time.utc(2026, 11, 23, 9, 10, 0))[:open] # 03:10 CST
    assert_nil ENV["TZ"], "TZ must be restored"
  end

  def test_cron_lists_ranges_and_steps
    cron = M.parse_cron("*/20 1-2,5 * * 1,3")
    assert_equal [ 0, 20, 40 ], cron.minutes.sort
    assert_equal [ 1, 2, 5 ], cron.hours.sort
    assert_equal [ 1, 3 ], cron.dows.sort
  end

  def test_cron_day_of_month_or_day_of_week_when_both_are_restricted
    cron = M.parse_cron("0 0 13 * 5")
    assert cron.day?(Date.new(2026, 11, 13)) # Friday the 13th
    assert cron.day?(Date.new(2026, 11, 20)) # a Friday
    assert cron.day?(Date.new(2026, 12, 13)) # the 13th, a Sunday
    refute cron.day?(Date.new(2026, 11, 21))
  end

  def test_a_bad_cron_is_an_error
    assert_raises(M::Error) { M.parse_cron("0 3 * *") }
    assert_raises(M::Error) { M.parse_cron("61 3 * * *") }
    assert_raises(M::Error) { M.parse_cron("x 3 * * *") }
  end

  # --- budget and plan ----------------------------------------------------------------

  def test_the_budget_sums_enter_verify_op_op_verify_and_exit_and_ignores_the_estimate
    assert_equal BUDGET, M.budget_s(config, "rotate_tenant_key")
    cfg = config
    cfg["change_config"]["operations"]["rotate_tenant_key"]["estimate"] = { "minutes" => 9999 }
    assert_equal BUDGET, M.budget_s(cfg, "rotate_tenant_key")
  end

  def test_the_maintenance_verify_timeout_counts_twice_since_it_confirms_enter_and_exit
    cfg = config
    cfg["change_config"]["maintenance"]["verify"]["timeout_s"] = 100
    assert_equal BUDGET + 140, M.budget_s(cfg, "rotate_tenant_key")
  end

  def test_an_open_window_that_holds_the_budget_runs
    assert_equal :run, M.plan(config, "rotate_tenant_key", OPEN)[:action]
  end

  def test_an_open_window_without_room_refuses
    late = Time.utc(2026, 11, 23, 3, 50, 0) # 600s left, budget 1200
    decision = M.plan(config, "rotate_tenant_key", late)
    assert_equal :refuse, decision[:action]
    assert_match(/600s left.*1200s budget/, decision[:reason])
  end

  def test_a_closed_window_waits_for_the_next_start
    decision = M.plan(config, "rotate_tenant_key", Time.utc(2026, 11, 23, 1, 0, 0))
    assert_equal :wait, decision[:action]
    assert_equal 7200, decision[:wait_s]
  end

  def test_a_window_too_short_for_the_budget_refuses_even_before_it_opens
    cfg = config
    cfg["change_config"]["maintenance"]["windows"]["weekday_night"]["duration_minutes"] = 10
    decision = M.plan(cfg, "rotate_tenant_key", Time.utc(2026, 11, 23, 1, 0, 0))
    assert_equal :refuse, decision[:action]
    assert_match(/exceeds the whole/, decision[:reason])
  end

  def test_a_wait_past_the_limit_refuses
    decision = M.plan(config, "rotate_tenant_key", Time.utc(2026, 11, 27, 4, 30, 0))
    assert_equal :refuse, decision[:action]
    assert_match(/wait limit/, decision[:reason])
  end

  def test_an_online_safe_op_needs_no_window_and_carries_its_reason
    decision = M.plan(config, "redeploy_previous", Time.utc(2026, 11, 22, 12, 0, 0))
    assert_equal :online_safe, decision[:action]
    assert_equal "redeploys an already-released build", decision[:reason]
  end

  def test_argv_placeholders_come_only_from_declared_checked_params
    op = config.dig("change_config", "operations", "rotate_tenant_key")
    assert_equal %w[pnpm app ops rotate-key t_101], M.render_argv(op["argv"], op["params"], "tenant_id" => "t_101")
    assert_raises(M::Error) { M.render_argv(op["argv"], op["params"], "tenant_id" => "t_1; rm -rf /") }
    assert_raises(M::Error) { M.render_argv([ "{other}" ], op["params"], "other" => "x") }
  end

  # --- the runner ------------------------------------------------------------------------

  def test_a_good_run_enters_runs_verifies_and_exits
    with_journal do |journal|
      executor = maintenance_executor
      result = runner(journal, executor).execute("rotate_tenant_key", { "tenant_id" => "t_101" })
      assert result.ok?
      assert_equal "observed_complete", result.state
      assert_equal %w[maintenance_entered launching observed_complete maintenance_exited], states(journal)
      order = executor.calls.reject { |call| call.include?("maint status") }
      assert_equal [ "pnpm app maint on", "pnpm app ops rotate-key t_101", "pnpm app ops verify-key t_101", "pnpm app maint off" ], order
    end
  end

  def test_the_lease_expires_at_the_window_end
    with_journal do |journal|
      runner(journal, maintenance_executor).execute("rotate_tenant_key", { "tenant_id" => "t_101" })
      lease = journal.entries(UUID).find { |entry| entry["state"] == "maintenance_entered" }
      assert_equal "2026-11-23T04:00:00Z", lease["expires_at"]
    end
  end

  def test_exit_runs_after_a_failed_op_and_the_journal_goes_uncertain
    with_journal do |journal|
      executor = maintenance_executor(fail_on: "rotate-key")
      result = runner(journal, executor).execute("rotate_tenant_key", { "tenant_id" => "t_101" })
      refute result.ok?
      assert_equal "uncertain", result.state
      assert result.page
      assert executor.ran?("maint off"), "exit must run after a failed op"
      assert_equal %w[maintenance_entered launching uncertain maintenance_exited], states(journal)
    end
  end

  def test_a_timed_out_op_is_uncertain_not_killed_blindly
    with_journal do |journal|
      executor = maintenance_executor(timeout_on: "rotate-key")
      result = runner(journal, executor).execute("rotate_tenant_key", { "tenant_id" => "t_101" })
      assert_equal "uncertain", result.state
      assert_equal "op timed out", result.reason
      assert executor.ran?("maint off")
    end
  end

  def test_a_failed_op_verify_is_uncertain
    with_journal do |journal|
      result = runner(journal, maintenance_executor(fail_on: "verify-key")).execute("rotate_tenant_key", { "tenant_id" => "t_101" })
      assert_equal "uncertain", result.state
      assert_equal "op verify failed", result.reason
    end
  end

  def test_a_failed_enter_still_exits_and_never_launches
    with_journal do |journal|
      executor = maintenance_executor(fail_on: "maint on")
      result = runner(journal, executor).execute("rotate_tenant_key", { "tenant_id" => "t_101" })
      assert_equal "refused", result.state
      refute executor.ran?("rotate-key")
      assert executor.ran?("maint off")
      refute_includes states(journal), "launching"
    end
  end

  def test_maintenance_that_does_not_verify_on_never_launches
    with_journal do |journal|
      executor = FakeExecutor.new { |argv| argv.join(" ").include?("maint status") ? { ok: false } : {} }
      result = runner(journal, executor).execute("rotate_tenant_key", { "tenant_id" => "t_101" })
      assert_equal "refused", result.state
      refute executor.ran?("rotate-key")
    end
  end

  def test_an_exit_that_is_not_confirmed_pages_and_keeps_the_lease
    with_journal do |journal|
      executor = FakeExecutor.new { |argv| argv.join(" ").include?("maint off") ? { ok: false } : {} }
      result = runner(journal, executor).execute("rotate_tenant_key", { "tenant_id" => "t_101" })
      assert result.page
      assert_match(/exit was not confirmed/, result.reason)
      assert_equal "exit_failed", states(journal).last
      assert M.lease_of(journal.entries(UUID))
    end
  end

  def test_an_exit_whose_verify_still_reads_on_is_not_confirmed
    with_journal do |journal|
      executor = FakeExecutor.new
      result = runner(journal, executor).execute("rotate_tenant_key", { "tenant_id" => "t_101" }) # verify always ok: still "on"
      assert result.page
      assert_equal "exit_failed", states(journal).last
    end
  end

  def test_a_window_without_room_refuses_before_any_command
    with_journal do |journal|
      executor = maintenance_executor
      result = runner(journal, executor, now: Time.utc(2026, 11, 23, 3, 50, 0)).execute("rotate_tenant_key", { "tenant_id" => "t_101" })
      assert_equal "refused", result.state
      assert_empty executor.calls
    end
  end

  def test_the_runner_waits_for_the_window_then_checks_the_budget_again
    with_journal do |journal|
      times = [ Time.utc(2026, 11, 23, 2, 0, 0) ]
      clock = -> { times.last }
      slept = []
      sleeper = ->(seconds) { slept << seconds; times << Time.utc(2026, 11, 23, 3, 0, 5) }
      result = runner(journal, maintenance_executor, clock: clock, sleeper: sleeper).execute("rotate_tenant_key", { "tenant_id" => "t_101" })
      assert result.ok?
      assert_equal [ 3600 ], slept
      assert_equal "waiting", states(journal).first
    end
  end

  def test_the_budget_is_rechecked_after_the_pre_mutation_check_eats_the_window
    with_journal do |journal|
      times = [ OPEN ]
      clock = -> { times.last }
      before = lambda do
        times << Time.utc(2026, 11, 23, 3, 55, 0) # the snapshot took 45 minutes
        M::Result.new(ok: true)
      end
      executor = maintenance_executor
      result = runner(journal, executor, clock: clock).execute("rotate_tenant_key", { "tenant_id" => "t_101" }, before: before)
      assert_equal "refused", result.state
      assert_empty executor.calls
    end
  end

  def test_a_failed_pre_mutation_check_refuses_before_maintenance
    with_journal do |journal|
      executor = maintenance_executor
      before = -> { M::Result.new(ok: false, reason: "PITR is 12h") }
      result = runner(journal, executor).execute("rotate_tenant_key", { "tenant_id" => "t_101" }, before: before)
      assert_equal "refused", result.state
      assert_match(/PITR is 12h/, result.reason)
      assert_empty executor.calls
    end
  end

  def test_an_online_safe_op_runs_with_no_window_lease_or_exit
    with_journal do |journal|
      executor = FakeExecutor.new
      result = runner(journal, executor, now: Time.utc(2026, 11, 22, 12, 0, 0)).execute("redeploy_previous", { "previous_release" => "v1.2.3" })
      assert result.ok?
      assert_equal %w[online_safe launching observed_complete], states(journal)
      refute executor.ran?("maint")
      assert_equal "redeploys an already-released build", journal.entries(UUID).first["reason"]
    end
  end

  def test_a_request_that_reached_launching_is_never_run_again
    with_journal do |journal|
      journal.append(UUID, { "state" => "launching", "at" => OPEN.iso8601 })
      executor = maintenance_executor
      result = runner(journal, executor).execute("rotate_tenant_key", { "tenant_id" => "t_101" })
      assert result.page
      assert_equal "uncertain", result.state
      assert_empty executor.calls
    end
  end

  def test_a_bad_param_refuses_before_any_lease_or_maintenance_command
    with_journal do |journal|
      executor = maintenance_executor
      result = runner(journal, executor).execute("rotate_tenant_key", { "tenant_id" => "nope" })
      assert_equal "refused", result.state
      assert_empty executor.calls
      assert_equal %w[refused], states(journal)
    end
  end

  # --- journal ----------------------------------------------------------------------------

  def test_the_journal_is_an_append_only_chain
    with_journal do |journal|
      journal.append(UUID, { "state" => "claimed" })
      journal.append(UUID, { "state" => "launching" })
      assert_equal %w[claimed launching], states(journal)
      assert_equal [ UUID ], journal.ids
      out, = Open3.capture2("git", "-C", journal.instance_variable_get(:@root), "rev-list", "--count", "#{M::JOURNAL_PREFIX}/#{UUID}")
      assert_equal 2, out.to_i
    end
  end

  def test_a_journal_name_must_be_a_uuid
    with_journal { |journal| assert_raises(M::Error) { journal.append("../x", {}) } }
  end

  # --- the reconciler -----------------------------------------------------------------------

  def seed(journal, *states, expires: "2026-11-23T04:00:00Z")
    states.each do |state|
      entry = { "state" => state, "at" => OPEN.iso8601, "environment" => "production" }
      entry["expires_at"] = expires if state == "maintenance_entered"
      journal.append(UUID, entry)
    end
  end

  AFTER = Time.utc(2026, 11, 23, 5, 0, 0)

  def reconcile(journal, executor, now: AFTER) = M.reconcile(config: config, journal: journal, executor: executor, now: now)

  def test_it_leaves_a_lease_inside_its_window_alone
    with_journal do |journal|
      seed(journal, "maintenance_entered", "launching")
      executor = FakeExecutor.new
      assert_empty reconcile(journal, executor, now: Time.utc(2026, 11, 23, 3, 30, 0))
      assert_empty executor.calls
    end
  end

  def test_runner_loss_after_maintenance_entry_is_exited
    with_journal do |journal|
      seed(journal, "maintenance_entered")
      executor = maintenance_executor
      executor.call([ "pnpm", "app", "maint", "on" ]) # the lost runner left it on
      actions = reconcile(journal, executor)
      assert_equal [ :exit ], actions.map(&:kind)
      assert executor.ran?("maint off")
      assert_equal "maintenance_exited", states(journal).last
      assert_equal "reconciler", journal.entries(UUID).last["by"]
    end
  end

  def test_an_observed_complete_op_whose_exit_failed_is_exited
    with_journal do |journal|
      seed(journal, "maintenance_entered", "launching", "observed_complete", "exit_failed")
      executor = maintenance_executor
      executor.call([ "pnpm", "app", "maint", "on" ])
      assert_equal [ :exit ], reconcile(journal, executor).map(&:kind)
    end
  end

  def test_runner_loss_after_launching_pages_and_never_exits
    with_journal do |journal|
      seed(journal, "maintenance_entered", "launching")
      executor = FakeExecutor.new
      actions = reconcile(journal, executor)
      assert_equal [ :page ], actions.map(&:kind)
      assert_match(/lost after launching/, actions.first.reason)
      assert_empty executor.calls
      assert M.lease_of(journal.entries(UUID))
    end
  end

  def test_an_uncertain_op_is_never_exited_by_the_reconciler
    with_journal do |journal|
      seed(journal, "maintenance_entered", "launching", "uncertain")
      executor = FakeExecutor.new
      assert_equal [ :page ], reconcile(journal, executor).map(&:kind)
      refute executor.ran?("maint off")
    end
  end

  def test_an_exit_that_does_not_confirm_pages
    with_journal do |journal|
      seed(journal, "maintenance_entered")
      executor = FakeExecutor.new { |argv| argv.join(" ").include?("maint off") ? { ok: false } : {} }
      assert_equal [ :page ], reconcile(journal, executor).map(&:kind)
      assert M.lease_of(journal.entries(UUID))
    end
  end

  def test_a_lease_already_exited_is_skipped
    with_journal do |journal|
      seed(journal, "maintenance_entered", "launching", "observed_complete", "maintenance_exited")
      assert_empty reconcile(journal, FakeExecutor.new)
    end
  end

  def test_a_lease_whose_maintenance_is_already_off_is_just_recorded
    with_journal do |journal|
      seed(journal, "maintenance_entered", "refused")
      executor = FakeExecutor.new { |argv| argv.join(" ").include?("maint status") ? { ok: false } : {} }
      assert_equal [ :exit ], reconcile(journal, executor).map(&:kind)
      refute executor.ran?("maint off")
      assert_equal "maintenance_exited", states(journal).last
    end
  end

  OTHER = "1c2d3e4f-0000-4000-8000-000000000001"

  def test_it_does_not_exit_maintenance_under_another_live_lease
    with_journal do |journal|
      seed(journal, "maintenance_entered", "launching", "observed_complete") # expired, safe
      journal.append(OTHER, { "state" => "maintenance_entered", "expires_at" => "2026-11-23T06:00:00Z", "environment" => "production" })
      journal.append(OTHER, { "state" => "launching" })
      executor = FakeExecutor.new
      actions = reconcile(journal, executor)
      assert_equal [ :hold ], actions.map(&:kind)
      assert_match(/#{OTHER}/, actions.first.reason)
      assert_empty executor.calls
      assert M.lease_of(journal.entries(UUID))
    end
  end

  def test_a_lease_in_another_environment_does_not_block_the_exit
    with_journal do |journal|
      seed(journal, "maintenance_entered")
      journal.append(OTHER, { "state" => "maintenance_entered", "expires_at" => "2026-11-23T06:00:00Z", "environment" => "staging" })
      executor = maintenance_executor
      executor.call([ "pnpm", "app", "maint", "on" ])
      assert_equal [ :exit ], reconcile(journal, executor).map(&:kind)
    end
  end

  def test_it_does_not_exit_maintenance_under_a_paged_lease
    with_journal do |journal|
      seed(journal, "maintenance_entered")
      journal.append(OTHER, { "state" => "maintenance_entered", "expires_at" => "2026-11-23T04:00:00Z", "environment" => "production" })
      journal.append(OTHER, { "state" => "launching" })
      assert_equal %i[hold page], reconcile(journal, FakeExecutor.new).map(&:kind).sort
    end
  end

  def test_a_verify_timeout_in_the_reconciler_is_unknown_not_off
    with_journal do |journal|
      seed(journal, "maintenance_entered")
      executor = FakeExecutor.new { |argv| argv.join(" ").include?("maint status") ? { ok: false, timed_out: true } : {} }
      assert_equal [ :page ], reconcile(journal, executor).map(&:kind)
      refute executor.ran?("maint off")
      assert M.lease_of(journal.entries(UUID)), "the lease must survive an unknown state"
    end
  end

  def test_a_post_exit_verify_timeout_keeps_the_lease_and_pages
    with_journal do |journal|
      seed(journal, "maintenance_entered")
      statuses = [ { ok: true }, { ok: false, timed_out: true } ].each
      executor = FakeExecutor.new { |argv| argv.join(" ").include?("maint status") ? statuses.next : {} }
      assert_equal [ :page ], reconcile(journal, executor).map(&:kind)
      assert executor.ran?("maint off")
      assert M.lease_of(journal.entries(UUID))
    end
  end

  def test_a_verify_that_never_started_is_unknown
    assert_equal :unknown, M.maintenance_state(ChangeBackup::Outcome.new(ok: false, timed_out: false, spawn_failed: true))
    assert_equal :off, M.maintenance_state(ChangeBackup::Outcome.new(ok: false, timed_out: false))
    assert_equal :on, M.maintenance_state(ChangeBackup::Outcome.new(ok: true))
  end

  def test_the_runner_does_not_take_a_verify_timeout_as_a_confirmed_exit
    with_journal do |journal|
      on = false
      executor = FakeExecutor.new do |argv|
        line = argv.join(" ")
        on = true if line.include?("maint on")
        next({ ok: false, timed_out: true }) if line.include?("maint status") && !on
        { ok: true }
      end
      result = runner(journal, executor).execute("rotate_tenant_key", { "tenant_id" => "t_101" })
      assert result.page
      assert_equal "exit_failed", states(journal).last
    end
  end

  # A journal whose append fails once it reaches the given state.
  class FlakyJournal < ChangeMaintenance::Journal
    def initialize(root, fail_on:)
      super(root, push: false)
      @fail_on = fail_on
    end

    def append(request_id, entry)
      raise ChangeMaintenance::Error, "push refused" if entry["state"] == @fail_on

      super
    end
  end

  def with_flaky(fail_on)
    Dir.mktmpdir do |root|
      system("git", "init", "-q", root)
      yield FlakyJournal.new(root, fail_on: fail_on)
    end
  end

  def test_exit_still_runs_when_the_observed_complete_write_fails
    with_flaky("observed_complete") do |journal|
      executor = maintenance_executor
      result = runner(journal, executor).execute("rotate_tenant_key", { "tenant_id" => "t_101" })
      assert result.page
      assert_equal "uncertain", result.state
      assert_match(/journal write failed/, result.reason)
      assert executor.ran?("maint off")
    end
  end

  def test_exit_still_runs_and_pages_when_the_launching_write_fails
    with_flaky("launching") do |journal|
      executor = maintenance_executor
      result = runner(journal, executor).execute("rotate_tenant_key", { "tenant_id" => "t_101" })
      assert result.page
      refute executor.ran?("rotate-key"), "the op must not run unrecorded"
      assert executor.ran?("maint off")
    end
  end

  def test_a_failed_exit_record_pages
    with_flaky("maintenance_exited") do |journal|
      result = runner(journal, maintenance_executor).execute("rotate_tenant_key", { "tenant_id" => "t_101" })
      assert result.page
      assert_match(/journal write failed/, result.reason)
    end
  end

  def test_the_reconciler_staleness_threshold_is_thirty_minutes
    now = Time.utc(2026, 11, 23, 5, 0, 0)
    refute M.reconciler_stale?(now - 29 * 60, now: now)
    assert M.reconciler_stale?(now - 31 * 60, now: now)
    assert M.reconciler_stale?(nil, now: now)
  end

  # --- CLI ------------------------------------------------------------------------------------

  def test_the_plan_verb_prints_the_decision_and_refuses_with_a_nonzero_exit
    out = StringIO.new
    assert_equal 0, M.run([ "plan", "--config", FIXTURE, "--op", "rotate_tenant_key" ], stdout: out, stderr: StringIO.new, now: OPEN)
    assert_match(/action=run/, out.string)
    err = StringIO.new
    assert_equal 1, M.run([ "plan", "--config", FIXTURE, "--op", "rotate_tenant_key" ], stdout: StringIO.new, stderr: err, now: Time.utc(2026, 11, 23, 3, 50, 0))
    assert_match(/cannot hold/, err.string)
  end

  def test_the_reconcile_verb_fails_the_job_when_something_needs_a_human
    Dir.mktmpdir do |root|
      system("git", "init", "-q", root)
      system("git", "-C", root, "remote", "add", "origin", root)
      journal = M::Journal.new(root, push: false)
      journal.append(UUID, { "state" => "maintenance_entered", "expires_at" => "2026-11-23T04:00:00Z", "environment" => "production" })
      journal.append(UUID, { "state" => "launching" })
      err = StringIO.new
      code = M.run([ "reconcile", "--config", FIXTURE, "--repo", root ], stdout: StringIO.new, stderr: err, executor: FakeExecutor.new, now: AFTER)
      assert_equal 1, code
      assert_match(/::error::cf-prod #{UUID} needs a human/, err.string)
    end
  end

  def test_an_unknown_verb_prints_usage
    err = StringIO.new
    assert_equal 2, M.run([ "bogus", "--config", FIXTURE ], stdout: StringIO.new, stderr: err)
    assert_match(/usage/, err.string)
  end
end
