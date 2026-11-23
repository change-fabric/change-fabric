# frozen_string_literal: true

require "minitest/autorun"
require "delegate"
require "tmpdir"
require "fileutils"
require "json"
require_relative "support/phone_console"
require_relative "../scripts/approval_console"
require_relative "../scripts/pulse_grants"
require_relative "../scripts/pulse_act"
require_relative "../scripts/cf_state"

# Grants are phone receipts: real console receipts from the in-process console
# (support/phone_console), recorded by the one Recorder, read back by
# PulseGrants, which re-verifies every record. Pulse honors nothing else.
class PulseGrantsTest < Minitest::Test
  include PhoneConsole

  SHA = "b" * 40

  def setup
    @home = File.realpath(Dir.mktmpdir)
    @prev = ENV["HOME"]
    ENV["HOME"] = @home
    @project = File.join(@home, "proj")
    FileUtils.mkdir_p(@project)
    @repo = CfProjectIdentity.for(@project).id
    start_phone_console(now: T0)
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
  end

  T0 = Time.utc(2026, 11, 22, 12, 0, 0)

  def attrs(scope: %w[nudge_worker stop_runaway], expires: T0 + 7200, repo: @repo)
    { "type" => "grant", "repo" => repo, "sha" => SHA, "profile" => nil, "summary" => "overnight pulse",
      "scope_list" => scope, "grant_expires_at" => expires.utc.iso8601 }
  end

  def record(grant = attrs, proof: nil)
    proof ||= phone_proof(grant)
    result = ApprovalConsole::Recorder.new(authority: authority, store: @store, clock: -> { @now }, recorded_by: "t")
                                      .record(proof, expected: ApprovalConsole::Remote.expected(grant, mid))
    assert result.ok?, result.error
    proof
  end

  def grants(at: @now) = PulseGrants.new(project: @project, store: @store, now: at)

  def stored_files = Dir.glob(File.join(@home, ".claude", "cf", "change", "grants", "*.json"))

  def rewrite_stored
    file = stored_files.first
    record = JSON.parse(File.read(file))
    yield record
    File.write(file, JSON.generate(record))
  end

  def test_a_phone_receipt_makes_a_grant_with_its_scope_and_expiry
    record
    active = grants.active
    assert_equal 1, active.size
    assert_equal %w[nudge_worker stop_runaway], active.first.scope_list
    assert_equal T0 + 7200, active.first.expires_at
    assert grants.allows?("nudge_worker")
  end

  def test_an_action_outside_the_signed_scope_is_not_allowed
    record(attrs(scope: %w[nudge_worker]))
    assert grants.allows?("nudge_worker")
    refute grants.allows?("stop_runaway")
    refute grants.allows?("reorder_phase")
  end

  def test_an_expired_grant_is_refused_with_no_skew_allowance
    record
    assert grants(at: T0 + 7199).allows?("nudge_worker")
    expired = grants(at: T0 + 7200)
    refute expired.allows?("nudge_worker")
    assert_equal "expired", expired.refusal_for("nudge_worker")
  end

  def test_a_recorded_grant_already_expired_is_never_written
    late = attrs(expires: T0 + 1000)
    proof = phone_proof(late)
    @now += 2000
    result = ApprovalConsole::Recorder.new(authority: authority, store: @store, clock: -> { @now }, recorded_by: "t")
                                      .record(proof, expected: ApprovalConsole::Remote.expected(late, mid))
    refute result.ok?
    assert_empty stored_files
  end

  def test_widening_the_scope_or_the_expiry_in_the_stored_record_breaks_the_receipt
    record(attrs(scope: %w[nudge_worker]))
    rewrite_stored do |rec|
      body = JSON.parse(rec["proof"]["body"])
      body["scope_list"] = %w[nudge_worker stop_runaway]
      body["grant_expires_at"] = (T0 + 86_400).utc.iso8601
      rec["proof"]["body"] = ApprovalConsole::Canonical.serialize(body)
    end
    refute grants.allows?("stop_runaway")
    refute grants.allows?("nudge_worker")
  end

  def test_a_stored_file_with_a_forged_or_missing_proof_is_never_a_grant
    proof = phone_proof(attrs)
    FileUtils.mkdir_p(File.join(@home, ".claude", "cf", "change", "grants"))
    store = ChangeGrantStore.new
    id = ApprovalConsole::Canonical.body_sha256(proof["body"])
    store.record(repo: @repo, grant_id: id, proof: proof.merge("receipt" => nil), policy_sha: "x", recorded_by: "agent")
    store.record(repo: @repo, grant_id: "f" * 64, proof: { "kind" => "webauthn+totp", "body" => proof["body"] }, policy_sha: "x", recorded_by: "agent")
    store.record(repo: @repo, grant_id: "e" * 64, proof: nil, policy_sha: "x", recorded_by: "agent")
    refute grants.allows?("nudge_worker")
    checked = grants
    assert_empty checked.active
    assert_includes checked.rejected.values.map { |entry| entry[:reason] }, "malformed"
    assert_empty checked.rejected.values.map { |entry| entry[:reason] } - %w[malformed tampered unverified]
  end

  def test_a_terminal_proof_is_not_a_grant
    proof = phone_proof(attrs).merge("kind" => "totp-terminal")
    ChangeGrantStore.new.record(repo: @repo, grant_id: ApprovalConsole::Canonical.body_sha256(proof["body"]), proof: proof, policy_sha: "x", recorded_by: "t")
    refute grants.allows?("nudge_worker")
  end

  def test_a_grant_for_another_project_is_refused
    record(attrs(repo: "repo:github.com/acme/other"))
    other = grants
    refute other.allows?("nudge_worker")
    assert_equal "wrong-project", other.refusal_for("nudge_worker")
  end

  def test_a_grant_file_copied_under_another_id_is_refused
    record
    rewrite_stored { |rec| rec["grant_id"] = "0" * 64 }
    refute grants.allows?("nudge_worker")
  end

  def test_a_receipt_from_the_future_or_outside_its_window_is_refused
    record
    refute grants(at: T0 - 600).allows?("nudge_worker"), "a receipt dated over five minutes ahead of this clock"
  end

  def test_a_receipt_for_another_machine_is_refused
    record
    other = SimpleDelegator.new(@store)
    other.define_singleton_method(:machine_id) { "00000000-0000-4000-8000-000000000000" }
    refute PulseGrants.new(project: @project, store: other, now: @now).allows?("nudge_worker")
  end

  def test_no_request_path_writes_a_grant_without_the_phone
    guard = File.join(@home, ApprovalConsole::HostHealth::GUARD)
    FileUtils.mkdir_p(File.dirname(guard))
    File.write(guard, "")
    status = ApprovalConsoleCli.run(%w[request --type grant --scope nudge_worker --expires 2h --summary x --no-wait --sha] + [ SHA, "--repo", @project ],
                                    stdin: StringIO.new, stdout: StringIO.new, stderr: (err = StringIO.new), env: {}, store: @store,
                                    parents: -> { [] }, io: { client: client, clock: -> { @now } })
    assert_equal 0, status, err.string
    assert_equal 1, @db.items.values.count { |item| item["sk"].to_s.start_with?("REQ#") && item["status"] == "pending" }
    assert_empty stored_files
    refute grants.allows?("nudge_worker")
    refute_respond_to PulseGrants.new, :write
    refute_respond_to PulseGrants.new, :record
    assert_equal 2, PulseGrantsCLI.run(%w[record], out: StringIO.new)
  end

  def test_pulse_act_denies_without_a_grant_and_authorizes_with_a_real_receipt
    act = PulseActFixture.new(@home, @project, @store).prepare
    assert_equal "not-in-protocol", act.authorize("nudge_worker")["reason"]
    record
    assert_equal "authorized", act.authorize("nudge_worker")["state"]
    expired = PulseActFixture.new(@home, @project, @store, now: T0 + 7300).prepare
    assert_equal "grant-expired", expired.authorize("nudge_worker")["reason"]
  end

  def test_a_caller_set_clock_cannot_back_date_an_expiry_through_the_cli_path
    record
    fixture = PulseActFixture.new(@home, @project, @store).prepare
    assert_equal "authorized", fixture.authorize("nudge_worker")["state"]
    walled = PulseAct.new("s1", project: @project, now: T0 + 300, wall_clock: true)
    refute walled.send(:grants).allows?("nudge_worker"), "the real clock is far past the 2026-11-22 expiry"
  end

  # A pulse session with one stalled child and a plan that has no pulse-allow
  # line, so only a grant can authorize.
  class PulseActFixture
    def initialize(home, project, store, now: T0 + 300)
      @home = home
      @project = project
      @store = store
      @now = now
      @session = "s1"
      @dir = File.join(home, ".claude", "cf", "sessions", @session)
    end

    def prepare
      FileUtils.mkdir_p(@dir)
      plan = File.join(@home, "plan")
      FileUtils.mkdir_p(plan)
      File.write(File.join(plan, "goal.md"), "Land phase one.\n")
      File.write(File.join(plan, "plan.md"), "# Plan\n")
      sources = %w[goal plan].map { |name| { "role" => "run_#{name}", "source_path" => File.join(plan, "#{name}.md"), "revision" => Pulse.sha(File.read(File.join(plan, "#{name}.md"))) } }
      File.write(File.join(@dir, "pulse_scope.json"), JSON.generate("sources" => sources))
      File.write(File.join(@dir, "pulse_events.jsonl"), "#{JSON.generate(child_id: 'w1', state_digest: 'd1', at: T0.iso8601)}\n")
      CfState.new(host: "claude", project: @project, session_id: @session).update({ "mode" => "admin-bypass" })
      goal = sources.first
      @finding = PulseStore.new(@session).append("kind" => "stall", "severity" => "P2", "claim" => "w1 stalled", "evidence" => "no change", "anchor" => "w1 stall",
                                                  "action_class" => "auto", "serves" => { "source_path" => goal["source_path"], "revision" => goal["revision"],
                                                                                          "quote" => "Land phase one", "relevance" => "keeps it moving" })["id"]
      self
    end

    def authorize(action, target = "w1")
      PulseAct.new(@session, project: @project, now: @now).authorize(finding: @finding, action: action, target: target, observed_at: T0.iso8601, text: "report status")
    end
  end
end
