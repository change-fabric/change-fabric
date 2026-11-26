# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../scripts/triage"

# Phase 7: the one-shot scheduler entry, rendered against golden files.
class TriageSchedulerTest < Minitest::Test
  OPTS = { home: "/home/example", ruby: "/usr/bin/ruby" }.freeze
  GOLDEN = File.expand_path("fixtures/triage/scheduler", __dir__)

  def golden(name) = File.read(File.join(GOLDEN, name))

  def test_mini_plist_matches_golden
    plan = Triage::Scheduler.render("mini", **OPTS)
    assert_equal golden("mini.plist"), plan.files.values.first
    assert_equal "/home/example/Library/LaunchAgents/org.change-fabric.triage.plist", plan.files.keys.first
  end

  def test_vm_units_match_golden
    plan = Triage::Scheduler.render("vm", **OPTS)
    assert_equal [ golden("cf-triage-tick.service"), golden("cf-triage-tick.timer") ], plan.files.values
  end

  def test_units_are_one_shot_not_daemons
    texts = %w[mini vm].flat_map { |host| Triage::Scheduler.render(host, **OPTS).files.values }.join("\n")
    refute_match(/KeepAlive|Restart\s*=|RunAtLoad<\/key><true/, texts)
  end

  def test_timer_fires_every_fifteen_minutes_and_catches_up
    timer = Triage::Scheduler.timer_text
    assert_includes timer, "OnCalendar=*:0/15"
    assert_includes timer, "Persistent=true"
    assert_equal [ 0, 15, 30, 45 ], Triage::Scheduler.plist_text("/h", "r", "s", "/h/t").scan(/Minute<\/key><integer>(\d+)/).flatten.map(&:to_i)
  end

  def test_runs_only_the_bounded_tick
    plan = Triage::Scheduler.render("vm", **OPTS)
    exec = plan.files.values.first[/^ExecStart=.*$/]
    assert_equal "ExecStart=/usr/bin/ruby /home/example/.claude/cf/bin/triage.rb tick --max-seconds 60", exec
    assert_includes plan.files.values.first, "TimeoutStartSec=60"
    assert_includes Triage::Scheduler.render("mini", **OPTS).files.values.first, "<string>tick</string>"
  end

  def test_rendered_install_commands_pass_the_doctrine_guard
    require_relative "../scripts/docker_doctrine_guard"
    %w[mini vm].each do |host|
      Triage::Scheduler.render(host, **OPTS).commands.each do |command|
        assert_nil DockerDoctrineGuard.match(command.join(" ")), command.join(" ")
      end
    end
  end

  def test_install_writes_files_and_runs_commands
    Dir.mktmpdir do |home|
      ran = []
      plan = Triage::Scheduler.install("vm", platform: "linux", runner: ->(c) { ran << c && true }, home: home, ruby: "/usr/bin/ruby")
      plan.files.each_key { |path| assert File.file?(path) }
      assert_equal plan.commands, ran
    end
  end

  def test_install_refuses_the_wrong_platform
    assert_raises(ArgumentError) { Triage::Scheduler.install("mini", platform: "linux-gnu", runner: ->(_) { true }, home: "/nope") }
    assert_raises(ArgumentError) { Triage::Scheduler.install("vm", platform: "darwin25", runner: ->(_) { true }, home: "/nope") }
  end

  def test_install_fails_when_a_load_command_fails_but_not_bootout
    Dir.mktmpdir do |home|
      assert_raises(RuntimeError) { Triage::Scheduler.install("vm", platform: "linux", runner: ->(_) { false }, home: home) }
      Triage::Scheduler.install("mini", platform: "darwin25", runner: ->(c) { c[1] == "bootout" ? false : true }, home: home)
    end
  end

  def test_watchdog_exits_124_after_the_budget
    code = nil
    Triage::Scheduler::Watchdog.arm(0, exiter: ->(c) { code = c }).join
    assert_equal 124, code
  end

  def test_cli_print_renders_both_hosts_without_writing
    out = StringIO.new
    assert_equal 0, Triage::CLI.run([ "install", "--print" ], out: out)
    assert_includes out.string, "org.change-fabric.triage.plist"
    assert_includes out.string, "cf-triage-tick.timer"
  end

  def test_cli_install_needs_print_or_host
    assert_equal 2, Triage::CLI.run([ "install" ], err: StringIO.new)
    assert_equal 2, Triage::CLI.run([ "install", "--host", "laptop", "--print" ], err: StringIO.new)
  end

  def test_tick_rejects_a_bad_max_seconds
    assert_equal 2, Triage::CLI.run([ "tick", "--max-seconds", "abc" ], err: StringIO.new)
  end
end
