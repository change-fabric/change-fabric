# frozen_string_literal: true

require "minitest/autorun"
require "delegate"
require "tmpdir"
require "fileutils"
require "json"
require "stringio"
require_relative "support/phone_console"
require_relative "../scripts/approval_console"
require_relative "../scripts/change_autopilot"

# Autopilot receipts are real console receipts from the in-process console,
# recorded by the one Recorder and re-verified by ChangeAutopilot on every read.
class ChangeAutopilotTest < Minitest::Test
  include PhoneConsole

  SHA = "b" * 40
  T0 = Time.utc(2026, 11, 24, 15, 0, 0)
  ALL = %w[carve_out host_daemon review run_script sensitive_term].freeze

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

  def attrs(scope: ALL, ends: T0 + 7200, repo: @repo)
    { "type" => "autopilot", "repo" => repo, "sha" => SHA, "profile" => nil, "summary" => "pilot",
      "scope_list" => scope, "autopilot_expires_at" => ends.utc.iso8601 }
  end

  def record(body = attrs)
    proof = phone_proof(body)
    result = ApprovalConsole::Recorder.new(authority: authority, store: @store, clock: -> { @now }, recorded_by: "t")
                                      .record(proof, expected: ApprovalConsole::Remote.expected(body, mid))
    assert result.ok?, result.error
    ApprovalConsole::Canonical.body_sha256(proof["body"])
  end

  def record_with(publisher, body = attrs)
    proof = phone_proof(body)
    ApprovalConsole::Recorder.new(authority: authority, store: @store, clock: -> { @now }, recorded_by: "t", autopilot_publisher: publisher)
                             .record(proof, expected: ApprovalConsole::Remote.expected(body, mid))
  end

  def test_the_recorder_hands_a_recorded_autopilot_to_the_publisher_and_reports_its_note
    seen = []
    result = record_with(->(proof, expected) { seen << [ proof["kind"], expected["scope_list"] ]; "published somewhere" })
    assert result.ok?, result.error
    assert_equal [ [ "webauthn+totp", ALL ] ], seen
    assert_match(/autopilot for .* \(published somewhere\)\z/, result.summary)
  end

  def test_a_refused_autopilot_is_never_published
    seen = []
    late = attrs(ends: T0 + 1000)
    proof = phone_proof(late)
    @now += 2000
    result = ApprovalConsole::Recorder.new(authority: authority, store: @store, clock: -> { @now }, recorded_by: "t", autopilot_publisher: ->(*) { seen << true })
                                      .record(proof, expected: ApprovalConsole::Remote.expected(late, mid))
    refute result.ok?
    assert_empty seen
  end

  def autopilot(at: @now, pins: authoritative_pins, store: @store, autopilots: ChangeAutopilotStore.new)
    ChangeAutopilot.new(project: @project, store: store, now: at, pins: pins, autopilots: autopilots)
  end

  def stored_file = Dir.glob(File.join(@home, ".claude", "cf", "change", "autopilot", "*.json")).first

  def rewrite_stored
    record = JSON.parse(File.read(stored_file))
    yield record
    File.write(stored_file, JSON.generate(record))
  end

  def test_a_valid_autopilot_covers_each_listed_gate
    record
    ALL.each { |gate| assert autopilot.covers?(gate), gate }
  end

  def test_an_unlisted_gate_is_not_covered
    record(attrs(scope: %w[review]))
    assert autopilot.covers?("review")
    refute autopilot.covers?("carve_out")
    refute autopilot.covers?("prod")
  end

  def test_the_autopilot_lands_under_the_autopilot_dir
    record
    assert_match %r{/\.claude/cf/change/autopilot/}, stored_file
  end

  def test_another_repo_is_not_covered
    record(attrs(repo: "repo:github.com/acme/other"))
    reader = autopilot
    refute reader.covers?("review")
    assert_includes reader.rejected.values, "wrong-project"
  end

  def test_another_machine_is_not_covered
    record
    other = SimpleDelegator.new(@store)
    other.define_singleton_method(:machine_id) { "00000000-0000-4000-8000-000000000000" }
    refute autopilot(store: other).covers?("review")
  end

  def test_a_file_copied_under_another_id_is_not_covered
    record
    rewrite_stored { |rec| rec["autopilot_id"] = "0" * 64 }
    refute autopilot.covers?("review")
  end

  def test_widening_the_stored_body_breaks_the_receipt
    record(attrs(scope: %w[review]))
    rewrite_stored do |rec|
      body = JSON.parse(rec["proof"]["body"])
      body["scope_list"] = ALL
      rec["proof"]["body"] = ApprovalConsole::Canonical.serialize(body)
      rec["autopilot_id"] = ApprovalConsole::Canonical.body_sha256(rec["proof"]["body"])
    end
    refute autopilot.covers?("carve_out")
    refute autopilot.covers?("review")
  end

  def test_bad_or_missing_pins_cover_nothing
    record
    refute autopilot(pins: authoritative_pins.merge("receipt_key_fingerprint" => "0" * 64)).covers?("review")
    refute autopilot(pins: nil).covers?("review")
  end

  def test_expiry_is_lazy_and_exact
    record
    assert autopilot(at: T0 + 7199).covers?("review")
    refute autopilot(at: T0 + 7200).covers?("review")
  end

  def test_a_receipt_outside_the_request_window_is_not_covered
    record
    refute autopilot(at: T0 - 600).covers?("review")
  end

  def test_a_tombstone_ends_every_gate
    id = record
    reader = autopilot
    assert_equal [ id ], reader.end!(by: "agent", reason: "pilot")
    ALL.each { |gate| refute autopilot.covers?(gate), gate }
    assert_includes autopilot.tap(&:active).rejected.values, "ended"
  end

  def test_the_end_cli_ends_it_with_no_mfa
    record
    out = StringIO.new
    assert_equal 0, ChangeAutopilotCLI.run(%w[end --reason pilot], out: out, autopilot: autopilot)
    assert_match(/ended autopilot/, out.string)
    ALL.each { |gate| refute autopilot.covers?(gate), gate }
  end

  def test_status_cli_lists_gates_and_end
    record
    out = StringIO.new
    ChangeAutopilotCLI.run(%w[status --json], out: out, autopilot: autopilot)
    row = JSON.parse(out.string)["autopilot"].first
    assert_equal ALL, row["gates"]
    assert_equal (T0 + 7200).utc.iso8601, row["ends_at"]
  end

  def test_waive_writes_a_ledger_row_and_returns_the_id
    id = record
    assert_equal id, autopilot.waive!("review", guard: "review_gate", detail: "2 files", command: "git push", session: "s1")
    row = autopilot.ledger(id).first
    assert_equal %w[review review_gate s1], row.values_at("gate", "guard", "session")
    assert_equal Digest::SHA256.hexdigest("git push"), row["command_sha256"]
    assert_nil autopilot.waive!("prod", guard: "x")
  end

  def test_an_unreadable_store_or_a_raise_is_not_covered
    record
    broken = Object.new
    broken.define_singleton_method(:all) { raise Errno::EACCES, "nope" }
    refute autopilot(autopilots: broken).covers?("review")
    assert_nil ChangeAutopilot.waive!("review", project: "/nonexistent/x", guard: "g")
    raising = Class.new(ChangeAutopilot) { def covers?(_gate) = raise("boom") }
    refute raising.covers?("review")
  end

  def test_a_forged_file_with_no_valid_proof_covers_nothing
    store = ChangeAutopilotStore.new
    store.record(repo: @repo, autopilot_id: "a" * 64, proof: { "kind" => "webauthn+totp", "body" => "{}" }, policy_sha: "x", recorded_by: "agent")
    store.record(repo: @repo, autopilot_id: "b" * 64, proof: nil, policy_sha: "x", recorded_by: "agent")
    refute autopilot.covers?("review")
  end

  def test_locked_paths
    %w[CHANGE.md install.rb scripts/change_merge_guard.rb scripts/change_autopilot.rb scripts/change_autopilot_store.rb
       scripts/approval_console/canonical.rb approval_console/infra/lambda/pages.rb .github/workflows/release-skills.yml].each do |path|
      assert ChangeAutopilot.locked_path?(path), path
    end
    %w[PRINCIPLES.md AGENTS.md skills/ctx/SKILL.md scripts/pulse_watch.rb].each { |path| refute ChangeAutopilot.locked_path?(path), path }
  end

  def test_an_already_ended_autopilot_is_never_recorded
    late = attrs(ends: T0 + 1000)
    proof = phone_proof(late)
    @now += 2000
    result = ApprovalConsole::Recorder.new(authority: authority, store: @store, clock: -> { @now }, recorded_by: "t")
                                      .record(proof, expected: ApprovalConsole::Remote.expected(late, mid))
    refute result.ok?
    assert_nil stored_file
  end

  def request(*args)
    guard = File.join(@home, ApprovalConsole::HostHealth::GUARD)
    FileUtils.mkdir_p(File.dirname(guard))
    File.write(guard, "")
    err = StringIO.new
    status = ApprovalConsoleCli.run(%w[request --type autopilot --summary x --no-wait --sha] + [ SHA, "--repo", @project ] + args,
                                    stdin: StringIO.new, stdout: StringIO.new, stderr: err, env: {}, store: @store,
                                    parents: -> { [] }, io: { client: client, clock: -> { @now } })
    [ status, err.string ]
  end

  def test_request_needs_known_gates_and_an_end_within_72h
    assert_match(/needs --scope/, request("--expires", "2h").last)
    assert_match(/must be among/, request("--scope", "review,secrets", "--expires", "2h").last)
    assert_match(/needs --expires/, request("--scope", "review").last)
    assert_match(/over 72 hours/, request("--scope", "review", "--expires", "73h").last)
    status, err = request("--scope", "review,carve_out", "--expires", "2h")
    assert_equal 0, status, err
    body = ApprovalConsole::Canonical.parse(pending_request_body)
    assert_equal %w[carve_out review], body["scope_list"]
    assert_nil stored_file, "a request alone never writes an autopilot"
  end
end
