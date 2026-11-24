# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require "stringio"
require_relative "git_fixture"
require_relative "support/phone_console"
require_relative "../scripts/approval_console"
require_relative "../scripts/change_autopilot"
require_relative "../scripts/change_prod_autopilot_ref"

# Publishing an autopilot to the prod runner, and telling the runner it ended.
class ChangeProdAutopilotRefTest < Minitest::Test
  include PhoneConsole

  Ref = ChangeProdAutopilotRef
  ID = "a" * 64
  PROOF = { "body" => "{}", "kind" => "webauthn+totp" }.freeze
  FIXTURE = File.expand_path("fixtures/prod/runner.yml", __dir__)

  def setup
    @origin = Dir.mktmpdir
    @dir = Dir.mktmpdir
    GitFixture.git_init(@origin, "--bare", "-b", "main")
    GitFixture.git_init(@dir, "-b", "main")
    GitFixture.git(@dir, "remote", "add", "origin", @origin)
  end

  def teardown = [ @origin, @dir ].each { |path| FileUtils.remove_entry(path) }

  def with_runner_config
    File.write(File.join(@dir, "CHANGE.md"), "---\n#{File.read(FIXTURE).sub(/\A---\n/, '')}---\n\n# CHANGE\n")
  end

  def test_prod_runner_is_detected_from_change_md
    refute Ref.prod_runner?(@dir)
    File.write(File.join(@dir, "CHANGE.md"), "---\nchange_config: {}\n---\n")
    refute Ref.prod_runner?(@dir)
    with_runner_config
    assert Ref.prod_runner?(@dir)
  end

  def test_nothing_is_published_without_prod_in_scope_or_a_prod_runner
    with_runner_config
    assert_nil Ref.publish(root: @dir, proof: PROOF, expected: { "scope_list" => %w[review] })
    FileUtils.rm(File.join(@dir, "CHANGE.md"))
    assert_nil Ref.publish(root: @dir, proof: PROOF, expected: { "scope_list" => %w[prod review] })
    assert_empty ChangeProdStore.new(@dir).list("autopilots")
  end

  def test_a_prod_autopilot_is_published_under_its_body_hash_once
    with_runner_config
    id = ApprovalConsole::Canonical.body_sha256(PROOF["body"])
    note = Ref.publish(root: @dir, proof: PROOF, expected: { "scope_list" => %w[prod review] })
    assert_match(/published to the prod runner/, note)
    store = ChangeProdStore.new(@dir)
    assert_equal [ id ], store.list("autopilots")
    record = store.read("autopilots", id)
    assert_equal({ "protocol" => "cf.prod.autopilot/1", "autopilot_id" => id, "proof" => PROOF }, record)
    assert_equal "already published to the prod runner", Ref.publish(root: @dir, proof: PROOF, expected: { "scope_list" => %w[prod] })
    # The ref reached the remote too.
    assert_match(/autopilots\/#{id}/, GitFixture.git(@origin, "for-each-ref", "refs/cf-prod/autopilots/"))
  end

  def test_a_failed_publish_says_so_without_raising
    with_runner_config
    GitFixture.git(@dir, "remote", "set-url", "origin", File.join(@dir, "no-such-remote"))
    note = Ref.publish(root: @dir, proof: PROOF, expected: { "scope_list" => %w[prod] })
    assert_match(/NOT published to the prod runner/, note)
    assert_empty ChangeProdStore.new(@dir).list("autopilots")
  end

  def test_end_writes_the_marker_only_where_a_runner_exists
    assert_predicate Ref.publish_end(root: @dir, id: ID, by: "agent", reason: "x"), :ok?
    assert_empty ChangeProdStore.new(@dir).list("autopilot-ends")
    with_runner_config
    outcome = Ref.publish_end(root: @dir, id: ID, by: "agent", reason: "done")
    assert_predicate outcome, :ok?
    assert_equal [ ID ], ChangeProdStore.new(@dir).list("autopilot-ends")
    assert_equal "done", ChangeProdStore.new(@dir).read("autopilot-ends", ID)["reason"]
    assert_match(/already told/, Ref.publish_end(root: @dir, id: ID, by: "agent", reason: "again").note)
  end

  def test_a_failed_end_publish_is_not_ok_and_loud
    with_runner_config
    GitFixture.git(@dir, "remote", "set-url", "origin", File.join(@dir, "no-such-remote"))
    outcome = Ref.publish_end(root: @dir, id: ID, by: "agent", reason: "x")
    refute_predicate outcome, :ok?
    assert_match(/NOT told and honors the autopilot until its signed end/, outcome.note)
  end
end

# The end verb tells the runner after the local tombstone, and exits 1 when it could not.
class ChangeAutopilotEndPublishTest < Minitest::Test
  Outcome = ChangeProdAutopilotRef::Outcome

  # Stands in for ChangeAutopilot: `end!` moves active ids to pending, `told!` clears them.
  class FakeAutopilot
    attr_reader :pending

    def initialize(active = [], pending = [])
      @active = active
      @pending = pending.map { |id| { "id" => id, "by" => "earlier", "reason" => "earlier reason" } }
    end

    def end!(by:, reason:)
      ended = @active
      @pending += ended.map { |id| { "id" => id, "by" => by, "reason" => reason } }
      @active = []
      ended
    end

    def active = @active.map { |id| Struct.new(:id, :scope_list, :expires_at).new(id, %w[prod], Time.utc(2026, 11, 24, 23)) }
    def rejected = {}
    def unannounced = @pending
    def told!(id) = @pending = @pending.reject { |row| row["id"] == id }
  end

  def fake_autopilot(ids) = FakeAutopilot.new(ids)

  def finish(ids, ender)
    out = StringIO.new
    err = StringIO.new
    code = ChangeAutopilotCLI.run(%w[end --reason done], out: out, err: err, autopilot: fake_autopilot(ids), root: "/r", ender: ender, by: "me")
    [ code, out.string, err.string ]
  end

  def test_each_ended_autopilot_is_announced_to_the_runner
    calls = []
    ender = ->(root:, id:, by:, reason:) { calls << [ root, id, by, reason ]; Outcome.new(ok: true, note: "told") }
    code, out, = finish([ "a" * 64, "b" * 64 ], ender)
    assert_equal 0, code
    assert_equal [ [ "/r", "a" * 64, "me", "done" ], [ "/r", "b" * 64, "me", "done" ] ], calls
    assert_match(/ended autopilot/, out)
  end

  def test_a_runner_that_could_not_be_told_makes_end_exit_nonzero
    ender = ->(**) { Outcome.new(ok: false, note: "the prod runner was NOT told") }
    code, _, err = finish([ "a" * 64 ], ender)
    assert_equal 1, code
    assert_match(/NOT told/, err)
  end

  def test_a_failed_publish_is_retried_by_the_next_end_until_the_runner_is_told
    fake = FakeAutopilot.new([ "a" * 64 ])
    results = [ Outcome.new(ok: false, note: "NOT told"), Outcome.new(ok: true, note: "told") ]
    calls = []
    ender = ->(root:, id:, by:, reason:) { calls << [ id, by, reason ]; results.shift }
    run = -> { ChangeAutopilotCLI.run(%w[end --reason done], out: StringIO.new, err: StringIO.new, autopilot: fake, root: "/r", ender: ender, by: "me") }
    assert_equal 1, run.call
    assert_equal [ "a" * 64 ], fake.unannounced.map { |row| row["id"] }
    # Nothing is active now, yet the retry still publishes, with the original by and reason.
    assert_equal 0, run.call
    assert_empty fake.unannounced
    assert_equal [ [ "a" * 64, "me", "done" ], [ "a" * 64, "me", "done" ] ], calls
    assert_equal 0, run.call
    assert_equal 2, calls.size
  end

  def test_an_earlier_pending_end_is_retried_even_when_nothing_is_active
    fake = FakeAutopilot.new([], [ "b" * 64 ])
    calls = []
    ender = ->(root:, id:, by:, reason:) { calls << [ id, by, reason ]; Outcome.new(ok: false, note: "still down") }
    code = ChangeAutopilotCLI.run(%w[end], out: StringIO.new, err: StringIO.new, autopilot: fake, root: "/r", ender: ender)
    assert_equal 1, code
    assert_equal [ [ "b" * 64, "earlier", "earlier reason" ] ], calls
    assert_equal 1, fake.unannounced.size
  end

  def test_status_says_when_the_runner_has_not_been_told
    fake = FakeAutopilot.new([], [ "c" * 64 ])
    out = StringIO.new
    ChangeAutopilotCLI.run(%w[status], out: out, autopilot: fake)
    assert_match(/autopilot cccccccccccc: ended locally, runner not yet told/, out.string)
    json = StringIO.new
    ChangeAutopilotCLI.run(%w[status --json], out: json, autopilot: fake)
    assert_equal [ "c" * 64 ], JSON.parse(json.string)["ended_runner_not_told"]
  end

  def test_ending_nothing_announces_nothing
    ender = ->(**) { flunk "no autopilot was active" }
    code, out, = finish([], ender)
    assert_equal 0, code
    assert_match(/no autopilot was active/, out)
  end
end
