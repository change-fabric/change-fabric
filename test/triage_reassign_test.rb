# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "shellwords"
require_relative "support/triage_world"
require_relative "../scripts/triage/answer"
require_relative "../scripts/triage"

# C8 quiesced, versioned reassignment, and C3 decision write-back.
class TriageReassignTest < Minitest::Test
  NOW = TriageFakes::NOW

  def setup
    @world = TriageWorld.new(repos: { "acme/api" => "mini", "acme/web" => "vm" })
    @revoked = []
  end

  def teardown = @world.close

  def reassign(host: "mini", liveness: @world.liveness, revoke: ->(repo, _path) { @revoked << repo })
    Triage::Reassign.new(root: @world.root, host: host, journal: @world.journal, liveness: liveness, revoke: revoke, now: NOW)
  end

  def entry(repo = "acme/api") = Triage::HostMap.load(File.join(@world.root, "hosts.yml")).entry_for(repo)

  def live_action
    @world.journal.append("type" => "dispatch", "action_id" => "live", "host" => "mini", "repo" => "acme/api", "unit" => "u",
                          "verb" => "start_next", "session_id" => "s", "path" => @world.path("acme/api"))
    @world.journal.append("type" => "handshake", "action_id" => "live", "pid" => 1, "pid_start" => "T0", "boot_id" => "boot-1",
                          "session_id" => "s", "host" => "h", "fence" => 1)
  end

  def test_a_quiet_repo_moves_with_the_version_bumped_and_the_old_grant_revoked
    result = reassign.call("acme/api", "vm")
    assert result.ok, result.message
    assert_equal 2, result.version
    assert_equal "vm", entry.host
    assert_equal 2, entry.version
    assert_equal [ "acme/api" ], @revoked
    refute File.exist?(Triage::Reassign.marker("acme/api", @world.root)), "dispatch stays off only while quiescing"
    assert_equal "vm", entry("acme/web").host, "other repos are untouched"
  end

  def test_a_reassign_during_a_live_action_is_refused_and_the_old_assignment_stays
    live_action
    live = @world.liveness(boot: "boot-1", pid_start: ->(_pid) { "T0" })
    result = reassign(liveness: live).call("acme/api", "vm")
    refute result.ok
    assert_match(/not provably dead/, result.message)
    assert_equal "mini", entry.host
    assert_equal 1, entry.version
    assert_empty @revoked
    refute File.exist?(Triage::Reassign.marker("acme/api", @world.root))
  end

  def test_an_unknown_owner_also_refuses
    live_action
    unknown = @world.liveness(boot: "boot-1", pid_start: ->(_pid) { nil })
    refute reassign(liveness: unknown).call("acme/api", "vm").ok
    assert_equal "mini", entry.host
  end

  def test_a_proven_dead_action_does_not_block
    live_action
    assert reassign(liveness: @world.liveness(boot: "boot-2")).call("acme/api", "vm").ok
  end

  def test_a_failed_revocation_aborts_with_the_old_assignment_intact
    result = reassign(revoke: ->(_repo, _path) { raise "approval store down" }).call("acme/api", "vm")
    refute result.ok
    assert_match(/revoking/, result.message)
    assert_equal [ "mini", 1 ], [ entry.host, entry.version ]
    refute File.exist?(Triage::Reassign.marker("acme/api", @world.root))
  end

  def test_a_failed_write_leaves_the_old_assignment_and_re_enables_dispatch
    bad = ->(_repo, _path) { File.write(File.join(@world.root, "hosts.yml"), ": not yaml [") && true }
    result = reassign(revoke: bad).call("acme/api", "vm")
    refute result.ok
    refute File.exist?(Triage::Reassign.marker("acme/api", @world.root))
  end

  def test_only_the_old_host_may_run_it
    result = reassign(host: "vm").call("acme/api", "vm")
    refute result.ok
    assert_equal "mini", entry.host
  end

  def test_bad_arguments_are_refused
    refute reassign.call("acme/nope", "vm").ok
    refute reassign.call("acme/api", "laptop").ok
    refute reassign.call("acme/api", "mini").ok
  end

  def test_the_cli_reports_the_result
    ENV["CF_TRIAGE_ROOT"] = @world.root
    ENV["CF_TRIAGE_HOST"] = "mini"
    out = StringIO.new
    err = StringIO.new
    code = Triage::CLI.run([ "reassign", "acme/nope", "--to", "vm" ], out: out, err: err)
    assert_equal 1, code
    assert_match(/not in hosts.yml/, err.string)
    assert_equal 2, Triage::CLI.run([ "reassign", "acme/api" ], out: out, err: err)
  ensure
    ENV.delete("CF_TRIAGE_ROOT")
    ENV.delete("CF_TRIAGE_HOST")
  end

  # --- answer ------------------------------------------------------------

  def item(key = "triage_decision|acme/api#u|pick")
    @world.inbox.upsert(kind: "triage_decision", key: key, title: "Pick one")
    key
  end

  def test_answer_records_the_text_and_resolves_a_local_item
    key = item
    result = Triage::Answer.new(inbox: @world.inbox, root: @world.root, host: "mini").call(key, "use B")
    assert result.ok, result.message
    stored = @world.inbox.fetch(key)
    assert_equal "resolved", stored["state"]
    assert_equal "use B", stored["data"]["answer"]
  end

  def test_answer_refuses_an_unknown_or_resolved_item_or_blank_text
    answer = Triage::Answer.new(inbox: @world.inbox, root: @world.root, host: "mini")
    refute answer.call("nope", "x").ok
    refute answer.call(item, " ").ok
    key = item("k2")
    assert answer.call(key, "yes").ok
    refute answer.call(key, "again").ok
    refute answer.call("inbox:abc", "x").ok
  end

  def test_answering_a_remote_host_item_writes_back_over_ssh_with_escaping
    calls = []
    runner = lambda do |argv, timeout|
      calls << [ argv, timeout ]
      Triage::Command::Result.new(out: "", err: "", ok: true, timed_out: false)
    end
    answer = Triage::Answer.new(inbox: @world.inbox, root: @world.root, host: "mini", runner: runner)
    assert answer.call("triage_decision|acme/web#u|pick", "use B; rm -rf /", host: "vm").ok
    argv, timeout = calls.first
    assert_equal "ssh", argv.first
    assert_equal 10, timeout
    remote = argv.last
    assert_includes remote, "answer"
    assert_includes remote, Shellwords.escape("use B; rm -rf /"), "the answer is shell-escaped for the remote shell"
  end

  def test_a_failed_ssh_write_back_is_reported
    runner = ->(_argv, _timeout) { Triage::Command::Result.new(out: "", err: "Permission denied", ok: false, timed_out: false) }
    result = Triage::Answer.new(inbox: @world.inbox, root: @world.root, host: "mini", runner: runner).call("k", "x", host: "vm")
    refute result.ok
    assert_match(/could not reach vm/, result.message)
  end
end
