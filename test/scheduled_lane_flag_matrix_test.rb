# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../scripts/scheduled_lane/command_runner"
require_relative "../scripts/scheduled_lane/flag_matrix"

class ScheduledLaneFlagMatrixTest < Minitest::Test
  Outcome = ScheduledLane::CommandRunner::Outcome
  Matrix = ScheduledLane::FlagMatrix

  # An in-memory flag system and ledger behind the adapter commands. Every
  # command is logged in order, so a test can assert the exact sequence.
  class FakeAdapter
    attr_reader :log, :flags, :ledger, :envs

    def initialize(flags: {}, seeded_on: [], ledger_rows: [])
      @flags = flags
      @seeded_on = seeded_on
      @ledger = { "rows" => ledger_rows }
      @log = []
      @envs = []
      @fail = {}
      @stuck = []
    end

    def fail_command(text) = @fail[text] = true

    # A flag that ignores revert commands, so a revert cannot confirm.
    def stick(key) = @stuck << key

    def call(cmd, env: {}, stdin: nil, timeout: nil)
      @envs << [ cmd, env ]
      verb, key = cmd.split
      entry = key ? "#{verb} #{key}" : verb
      entry = "ledger put" if cmd == "ledger put"
      entry = "ledger get" if cmd == "ledger get"
      @log << entry
      return failed if @fail[entry]

      dispatch(verb, key, cmd, stdin)
    end

    def dispatch(verb, key, cmd, stdin)
      case verb
      when "flip" then @flags[key] = "on"
      when "revert" then @flags[key] = "off" unless @stuck.include?(key)
      when "read" then return out(@flags.fetch(key, "off"))
      when "list" then return out(@flags.select { |name, state| state == "on" && !@seeded_on.include?(name) }.keys.join("\n"))
      when "ledger" then return ledger_call(cmd, stdin)
      end
      out("")
    end

    def ledger_call(cmd, stdin)
      return out(JSON.generate(@ledger)) if cmd.end_with?("get")

      @ledger = JSON.parse(stdin)
      out("")
    end

    def out(text) = Outcome.new(stdout: text, stderr: "", exit_code: 0, timed_out: false)
    def failed = Outcome.new(stdout: "", stderr: "boom", exit_code: 1, timed_out: false)
  end

  def lane(extra = {})
    matrix = { "mode" => "touched-one-at-a-time", "touched_cmd" => "touched", "flip_cmd" => "flip {flag}", "revert_cmd" => "revert {flag}",
               "read_cmd" => "read {flag}", "list_on_cmd" => "list", "ledger_cmd" => "ledger", "lock_group" => "grp",
               "settle_seconds" => 7, "revert_headroom_seconds" => 60, "max_flags" => 3 }.merge(extra)
    ScheduledLane::Lane.new({ "id" => "x", "run" => "lane", "result_file" => "r.json", "cadence" => "dispatch-only", "timeout_minutes" => 10,
                              "matrix" => matrix })
  end

  def verdict(status = "pass", failure_class = nil)
    ScheduledLane::Verdict.new(status: status, failure_class: failure_class, notes: [], cases: [])
  end

  def iteration(number, status = "pass", failure_class = nil)
    ScheduledLane::LaneRun::Iteration.new(iteration: number, run_id: "r-#{number}", verdict: verdict(status, failure_class), sha_moved: false,
                                          ref_mismatch: false)
  end

  # Builds a matrix over `adapter`; the lane callback logs into the adapter's log.
  def matrix_for(adapter, lane_def: lane, receipt: "rcpt-1", env: "staging", job: 120, sleeper: ->(_) { }, environ: {}, &lane_body)
    body = lane_body || ->(number) { iteration(number) }
    run_lane = lambda do |number|
      adapter.log << "lane #{number}"
      body.call(number)
    end
    Matrix.new(lane: lane_def, runner: adapter, env_name: env, run_lane: run_lane, receipt: receipt, job_timeout_minutes: job, run_id: "r",
               sleeper: sleeper, environ: environ)
  end

  def test_exact_command_sequence_for_one_key
    adapter = FakeAdapter.new(flags: { "a" => "off" })
    result = matrix_for(adapter).run([ "a" ])
    assert result.pass?, result.notes.inspect
    assert_equal [ "ledger get",                       # recovery sweep first
                  "list", "read a", "ledger get", "ledger put", # isolation read, seed read, ledger write
                  "flip a", "read a", "lane 1",
                  "revert a", "read a", "ledger get", "ledger put" ], adapter.log
    assert_equal "reverted", adapter.ledger["rows"].first["state"]
    assert_equal "off", adapter.flags["a"]
  end

  def test_ledger_row_exists_before_the_flip
    adapter = FakeAdapter.new(flags: { "a" => "off" })
    seen = nil
    adapter.define_singleton_method(:dispatch) do |verb, key, cmd, stdin|
      seen = @ledger["rows"].map { |row| [ row["key"], row["state"], row["seed_state"] ] } if verb == "flip"
      super(verb, key, cmd, stdin)
    end
    matrix_for(adapter).run([ "a" ])
    assert_equal [ [ "a", "flipping", "off" ] ], seen
  end

  def test_keys_run_strictly_one_at_a_time
    adapter = FakeAdapter.new(flags: { "a" => "off", "b" => "off" })
    result = matrix_for(adapter).run(%w[a b])
    assert result.pass?
    flips = adapter.log.each_index.select { |i| adapter.log[i].start_with?("flip") }
    reverts = adapter.log.each_index.select { |i| adapter.log[i].start_with?("revert") }
    assert_operator reverts.first, :<, flips.last, "the first key is reverted before the second is flipped"
    assert_equal %w[lane\ 1 lane\ 2], adapter.log.grep(/\Alane/)
    assert_equal 2, result.rows.length
  end

  def test_settle_seconds_is_waited_after_the_flip
    waits = []
    matrix_for(FakeAdapter.new(flags: { "a" => "off" }), sleeper: ->(seconds) { waits << seconds }).run([ "a" ])
    assert_equal [ 7 ], waits
  end

  def test_lane_failure_reverts_and_the_matrix_continues
    adapter = FakeAdapter.new(flags: { "a" => "off", "b" => "off" })
    result = matrix_for(adapter) { |number| number == 1 ? iteration(number, "fail", "app") : iteration(number) }.run(%w[a b])
    refute result.pass?
    assert_equal "app", result.failure_class
    assert_equal "off", adapter.flags["a"]
    assert_equal 2, adapter.log.count { |entry| entry.start_with?("flip") }
    assert_equal [ true, true ], result.rows.map { |row| row["revert_ok"] }
  end

  def test_raised_exception_reverts_and_stops
    adapter = FakeAdapter.new(flags: { "a" => "off", "b" => "off" })
    result = matrix_for(adapter) { raise "lane exploded" }.run(%w[a b])
    assert_equal "infra", result.failure_class
    assert_equal "off", adapter.flags["a"]
    assert_equal 1, adapter.log.count { |entry| entry.start_with?("flip") }, "b is never flipped"
    assert_includes result.notes.join, "lane exploded"
  end

  def test_stray_on_flag_aborts_before_any_flip
    adapter = FakeAdapter.new(flags: { "a" => "off", "stray" => "on" })
    result = matrix_for(adapter).run([ "a" ])
    assert_equal "infra", result.failure_class
    assert_includes result.notes.join, "stray"
    assert_empty adapter.log.grep(/\Aflip/)
    assert_empty adapter.ledger["rows"]
  end

  def test_production_is_refused_before_any_command
    adapter = FakeAdapter.new(flags: { "a" => "off" })
    result = matrix_for(adapter, env: "production").run([ "a" ])
    assert_equal "infra", result.failure_class
    assert_empty adapter.log
    assert_equal "infra", matrix_for(adapter, env: "Production").run([ "a" ]).failure_class
  end

  def test_an_env_in_forbid_envs_is_refused
    adapter = FakeAdapter.new
    result = matrix_for(adapter, lane_def: lane("forbid_envs" => %w[production demo]), env: "demo").run([ "a" ])
    assert_includes result.notes.join, "forbid_envs"
    assert_empty adapter.log
  end

  def test_pre_run_sweep_restores_an_unreverted_row_before_the_first_flip
    row = { "id" => "old:z", "key" => "z", "env" => "staging", "run_id" => "old", "seed_state" => "off", "state" => "flipping" }
    adapter = FakeAdapter.new(flags: { "a" => "off", "z" => "on" }, ledger_rows: [ row ])
    result = matrix_for(adapter).run([ "a" ])
    assert result.pass?, result.notes.inspect
    assert_operator adapter.log.index("revert z"), :<, adapter.log.index("flip a")
    assert_equal "reverted", adapter.ledger["rows"].find { |entry| entry["key"] == "z" }["state"]
    assert_equal "rcpt-1", adapter.ledger["rows"].find { |entry| entry["key"] == "z" }["receipt"]
  end

  def test_sweep_restores_a_seed_that_was_on_with_flip_not_revert
    row = { "id" => "old:z", "key" => "z", "env" => "staging", "run_id" => "old", "seed_state" => "on", "state" => "flipping" }
    adapter = FakeAdapter.new(flags: { "z" => "off" }, ledger_rows: [ row ])
    assert matrix_for(adapter).run([]).pass?
    assert_equal "on", adapter.flags["z"]
    assert_includes adapter.log, "flip z"
    refute_includes adapter.log, "revert z"
  end

  def test_sweep_runs_before_the_empty_set_return
    row = { "id" => "old:z", "key" => "z", "env" => "staging", "seed_state" => "off", "state" => "flipping" }
    adapter = FakeAdapter.new(flags: { "z" => "on" }, ledger_rows: [ row ])
    result = matrix_for(adapter).run([])
    assert result.pass?
    assert_includes result.notes, "no touched flags"
    assert_equal "off", adapter.flags["z"]
    assert_empty adapter.log.grep(/\Alane/)
  end

  def test_sweep_leaves_other_envs_rows_alone
    row = { "id" => "old:z", "key" => "z", "env" => "qa", "seed_state" => "off", "state" => "flipping" }
    adapter = FakeAdapter.new(flags: { "z" => "on" }, ledger_rows: [ row ])
    assert matrix_for(adapter).run([]).pass?
    assert_equal "on", adapter.flags["z"]
  end

  def test_sweep_that_cannot_restore_stops_everything
    row = { "id" => "old:z", "key" => "z", "env" => "staging", "seed_state" => "off", "state" => "flipping" }
    adapter = FakeAdapter.new(flags: { "z" => "on", "a" => "off" }, ledger_rows: [ row ])
    adapter.stick("z")
    result = matrix_for(adapter).run([ "a" ])
    assert_equal "z", result.stuck_flag
    assert_empty adapter.log.grep(/\Aflip/)
  end

  def test_no_revert_authority_refuses_the_run
    adapter = FakeAdapter.new(flags: { "a" => "off" })
    result = matrix_for(adapter, receipt: nil).run([ "a" ])
    assert_includes result.notes.join, "authority"
    assert_empty adapter.log
  end

  def test_a_revert_that_does_not_confirm_stops_the_matrix_and_names_the_flag
    adapter = FakeAdapter.new(flags: { "a" => "off", "b" => "off" })
    adapter.stick("a")
    result = matrix_for(adapter).run(%w[a b])
    assert_equal "infra", result.failure_class
    assert_equal "a", result.stuck_flag
    assert_includes result.notes.join, "a could not be restored"
    refute_includes adapter.log, "flip b"
    assert_equal false, result.rows.first["revert_ok"]
    assert_equal "flipping", adapter.ledger["rows"].first["state"], "an unconfirmed revert stays on the ledger for the next sweep"
  end

  def test_a_flip_that_does_not_read_on_is_restored_and_stops
    adapter = FakeAdapter.new(flags: { "a" => "off" })
    adapter.define_singleton_method(:dispatch) { |verb, key, *rest| verb == "flip" ? out("") : super(verb, key, *rest) }
    result = matrix_for(adapter).run([ "a" ])
    assert_equal "infra", result.failure_class
    assert_includes adapter.log, "revert a"
  end

  def test_ledger_write_failure_means_no_flip
    adapter = FakeAdapter.new(flags: { "a" => "off" })
    adapter.fail_command("ledger put")
    result = matrix_for(adapter).run([ "a" ])
    assert_equal "infra", result.failure_class
    assert_empty adapter.log.grep(/\Aflip/)
  end

  def test_max_flags_cap_refuses
    adapter = FakeAdapter.new(flags: {})
    result = matrix_for(adapter).run(%w[a b c d])
    assert_includes result.notes.join, "max_flags"
    assert_empty adapter.log.grep(/\Aflip/)
  end

  def test_time_budget_refuses_when_it_exceeds_the_job_minus_slack
    adapter = FakeAdapter.new(flags: { "a" => "off", "b" => "off" })
    # 2 keys x (7 + 600 + 60) = 1334s; a 30 minute job leaves 1200s.
    result = matrix_for(adapter, job: 30).run(%w[a b])
    assert_includes result.notes.join, "matrix needs 1334s"
    assert_empty adapter.log.grep(/\Aflip/)
    assert matrix_for(FakeAdapter.new(flags: { "a" => "off", "b" => "off" }), job: 33).run(%w[a b]).pass?
  end

  def test_unsafe_keys_are_refused
    adapter = FakeAdapter.new
    result = matrix_for(adapter).run([ "a; rm -rf /" ])
    assert_includes result.notes.join, "unsafe flag key"
    assert_empty adapter.log.grep(/\Aflip/)
  end

  def test_each_key_gets_its_own_iteration_number
    numbers = []
    matrix_for(FakeAdapter.new(flags: { "a" => "off", "b" => "off" })) { |number| numbers << number && iteration(number) }.run(%w[a b])
    assert_equal [ 1, 2 ], numbers
  end

  def test_a_trapped_term_reverts_before_the_process_goes
    adapter = FakeAdapter.new(flags: { "a" => "off", "b" => "off" })
    result = matrix_for(adapter) do
      Process.kill("TERM", Process.pid)
      sleep 1
      iteration(1)
    end.run(%w[a b])
    assert_equal "infra", result.failure_class
    assert_includes result.notes.join, "TERM"
    assert_equal "off", adapter.flags["a"], "the flag is restored after the signal"
    assert_equal "reverted", adapter.ledger["rows"].first["state"]
    refute_includes adapter.log, "flip b"
  end

  def test_signal_handlers_are_put_back
    before = Signal.trap("TERM", "DEFAULT")
    matrix_for(FakeAdapter.new).run([])
    assert_equal "DEFAULT", Signal.trap("TERM", before)
  end

  def test_the_ledger_credential_is_missing_refuses
    adapter = FakeAdapter.new(flags: { "a" => "off" })
    result = matrix_for(adapter, lane_def: lane("ledger_credential_env" => "LEDGER_TOKEN")).run([ "a" ])
    assert_includes result.notes.join, "LEDGER_TOKEN"
    assert_empty adapter.log
  end

  def test_only_the_ledger_command_sees_the_ledger_credential
    adapter = FakeAdapter.new(flags: { "a" => "off" })
    matrix_for(adapter, lane_def: lane("ledger_credential_env" => "LEDGER_TOKEN"), environ: { "LEDGER_TOKEN" => "x" }).run([ "a" ])
    adapter.envs.each do |cmd, env|
      if cmd.start_with?("ledger")
        refute env.key?("LEDGER_TOKEN"), "the ledger command inherits it untouched"
      else
        assert_equal({ "LEDGER_TOKEN" => nil }, env.slice("LEDGER_TOKEN"), cmd)
      end
    end
  end

  def test_detect_reports_unreverted_rows_and_never_flips
    row = { "id" => "old:z", "key" => "z", "env" => "staging", "seed_state" => "off", "state" => "flipping" }
    adapter = FakeAdapter.new(flags: { "z" => "on" }, ledger_rows: [ row ])
    result = matrix_for(adapter, receipt: nil).detect
    assert_equal "infra", result.failure_class
    assert_includes result.notes.join, "unreverted ledger rows: z"
    assert_includes result.notes.join, "flags on beyond the seeded defaults: z"
    assert_empty adapter.log.grep(/\A(flip|revert)/)
    assert_equal "flipping", adapter.ledger["rows"].first["state"]
  end

  def test_detect_passes_when_clean
    adapter = FakeAdapter.new(flags: { "a" => "on" }, seeded_on: [ "a" ])
    assert matrix_for(adapter, receipt: nil).detect.pass?
  end

  def test_detect_refuses_production
    adapter = FakeAdapter.new
    refute matrix_for(adapter, receipt: nil, env: "production").detect.pass?
    assert_empty adapter.log
  end

  def test_recover_restores_with_a_receipt_and_without_a_lane_run
    row = { "id" => "old:z", "key" => "z", "env" => "staging", "seed_state" => "off", "state" => "flipping" }
    adapter = FakeAdapter.new(flags: { "z" => "on" }, ledger_rows: [ row ])
    result = matrix_for(adapter).recover
    assert result.pass?, result.notes.inspect
    assert_equal "off", adapter.flags["z"]
    assert_empty adapter.log.grep(/\Alane/)
  end

  def test_recover_without_a_receipt_changes_nothing
    row = { "id" => "old:z", "key" => "z", "env" => "staging", "seed_state" => "off", "state" => "flipping" }
    adapter = FakeAdapter.new(flags: { "z" => "on" }, ledger_rows: [ row ])
    refute matrix_for(adapter, receipt: nil).recover.pass?
    assert_equal "on", adapter.flags["z"]
  end

  def test_recover_reports_a_stray_flag_the_ledger_does_not_explain
    adapter = FakeAdapter.new(flags: { "q" => "on" })
    result = matrix_for(adapter).recover
    assert_equal "infra", result.failure_class
    assert_includes result.notes.join, "q"
    assert_equal "on", adapter.flags["q"]
  end
end
