# frozen_string_literal: true

require "minitest/autorun"
require_relative "support/triage_world"

# The launcher runs one stubbed `claude -p` as a fresh, session-pinned run:
# handshake first, then a classified terminal row, and a stale owner is fenced.
class TriageLauncherTest < Minitest::Test
  NOW = TriageFakes::NOW

  def setup
    @world = TriageWorld.new
    @log = File.join(@world.root, "stub.log")
    @prior = ENV.to_h.slice("PATH", "STUB_LOG", "STUB_CLAUDE_MODE", "STUB_RESETS_AT")
    ENV["PATH"] = @world.stub_path
    ENV["STUB_LOG"] = @log
    ENV.delete("STUB_CLAUDE_MODE")
    @session = "11111111-2222-4333-8444-555555555555"
  end

  def teardown
    %w[PATH STUB_LOG STUB_CLAUDE_MODE STUB_RESETS_AT].each { |key| @prior.key?(key) ? ENV[key] = @prior[key] : ENV.delete(key) }
    @world.close
  end

  def dispatch(id = "a1", stack: nil)
    grant = Triage::Grant::Value.new(receipt_id: "a" * 64, repo: "acme/api", machine: "mini", unit: "acme/api#launch/P2#Phase 1",
                                     verb: "start_next", expires_at: NOW + 7200)
    @world.journal.append("type" => "dispatch", "action_id" => id, "host" => "mini", "repo" => "acme/api",
                          "unit" => grant.unit, "verb" => "start_next", "path" => @world.path("acme/api"), "stack" => stack,
                          "session_id" => @session, "grant" => grant.to_h)
  end

  def run_launcher(id = "a1", **overrides)
    seeded = []
    outcome = Triage::Launcher.run(id, root: @world.root, journal: @world.journal, seeder: ->(row) { seeded << row["session_id"] },
                                       grant: @world.grant, clock: -> { NOW }, unlease: ->(_row) { }, **overrides)
    [ outcome, seeded ]
  end

  def terminal(id = "a1") = @world.journal.find(id).terminal

  def test_a_clean_run_registers_the_handshake_then_records_an_ok_result
    dispatch
    outcome, seeded = run_launcher
    assert_equal "result", outcome
    assert_equal [ @session ], seeded
    dispatched = @world.journal.find("a1")
    assert dispatched.handshake["pid"].positive?
    assert_equal @session, dispatched.handshake["session_id"]
    assert_equal "ok", terminal["exit_class"]
    assert_equal @session, terminal["session_id"]
    order = @world.journal.rows.map { |row| row["type"] }
    assert_equal %w[dispatch handshake result], order
  end

  def test_the_cli_is_started_fresh_pinned_to_the_session_and_never_bare_or_resumed
    dispatch
    run_launcher
    argv = File.read(@log)
    assert_includes argv, "--session-id #{@session}"
    assert_includes argv, "--permission-mode acceptEdits"
    assert_includes argv, "--output-format stream-json"
    assert_includes argv, "--allowedTools"
    refute_includes argv, "--bare"
    refute_includes argv, "--resume"
  end

  def test_a_quota_exit_writes_limited_until_and_the_exit_class
    dispatch
    ENV["STUB_CLAUDE_MODE"] = "quota"
    ENV["STUB_RESETS_AT"] = (NOW + 86_400 * 2).to_i.to_s
    run_launcher
    assert_equal "quota_exhausted", terminal["exit_class"]
    assert_equal NOW + 86_400 * 2, Time.iso8601(terminal["limited_until"])
    assert_equal "quota_exhausted", Triage::Limits::Store.new(root: @world.root).active(now: NOW)["kind"]
  end

  def test_exit_zero_with_no_result_frame_is_recorded_as_a_failure
    dispatch
    ENV["STUB_CLAUDE_MODE"] = "empty"
    run_launcher
    assert_equal "no_result", terminal["exit_class"]
    assert_nil Triage::Limits::Store.new(root: @world.root).active(now: NOW)
  end

  def test_a_wall_clock_timeout_kills_the_child_and_fails_the_run
    dispatch
    ENV["STUB_CLAUDE_MODE"] = "hang"
    run_launcher(wall_clock: 0.3)
    assert_equal "no_result", terminal["exit_class"]
    assert_equal "wall clock timeout", terminal["detail"]
  end

  def test_an_expired_grant_parks_without_spawning
    dispatch
    @world.window(false)
    outcome, = run_launcher
    assert_equal "parked", outcome
    assert_equal "parked", terminal["type"]
    refute File.exist?(@log), "the CLI must not start without a valid grant"
  end

  def test_a_failed_seed_parks_without_spawning
    dispatch
    failing = ->(_row) { raise Triage::Launcher::Seeder::Failed, "stack lease held" }
    outcome = Triage::Launcher.run("a1", root: @world.root, journal: @world.journal, seeder: failing, grant: @world.grant,
                                         clock: -> { NOW }, unlease: ->(_row) { })
    assert_equal "parked", outcome
    assert_match(/lease held/, terminal["reason"])
    refute File.exist?(@log)
  end

  def test_a_dispatch_declared_dead_before_the_handshake_fences_the_late_launcher
    dispatch
    journal = @world.journal
    late = lambda do |argv, env, chdir, out|
      journal.append("type" => "dead", "action_id" => "a1", "reason" => "reconciled while the launcher was stuck")
      Triage::Launcher.spawn_child(argv, env, chdir, out)
    end
    outcome, = run_launcher(spawner: late, wall_clock: 5)
    assert_equal "fenced", outcome
    assert_equal "dead", terminal["type"], "the stale owner cannot overwrite the dead row"
    assert_nil @world.journal.find("a1").handshake
  end

  def test_a_finished_dispatch_is_not_run_twice
    dispatch
    run_launcher
    assert_equal "result", run_launcher.first
    assert_equal 1, File.readlines(@log).size
  end

  def test_seeding_sets_admin_bypass_then_away_for_the_session
    calls = []
    runner = lambda do |argv, _timeout|
      calls << argv
      Triage::Command::Result.new(out: "{}", err: "", ok: true, timed_out: false)
    end
    Triage::Launcher::Seeder.new(runner: runner, cli: "/x/cf_cli.rb").call({ "session_id" => @session, "path" => "/repo" })
    modes = calls.map { |argv| argv[argv.index("--mode") + 1] }
    assert_equal %w[admin-bypass away], modes
    assert(calls.all? { |argv| argv.include?(@session) && argv.include?("claude") })
  end

  def test_detached_commands_use_launchctl_on_the_mini_and_systemd_run_on_the_vm
    mini = Triage::Launcher::Detach.command(host: "mini", action_id: "mini-1", root: "/r", script: "/s/triage.rb", ruby: "/usr/bin/ruby")
    assert_equal %w[launchctl submit -l cf-triage-mini-1 --], mini.first(5)
    assert_equal %w[run-action mini-1], mini.last(2)
    vm = Triage::Launcher::Detach.command(host: "vm", action_id: "vm-1", root: "/r", script: "/s/triage.rb", ruby: "/usr/bin/ruby")
    assert_equal %w[systemd-run --user --unit cf-triage-vm-1], vm.first(4)
    assert_includes vm, "--setenv=CF_TRIAGE_HOST=vm"
  end
end
