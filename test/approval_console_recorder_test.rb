# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "support/phone_console"
require_relative "../scripts/cf_project_identity"

# ApprovalConsole::Recorder, the one writer of every phone approval record,
# against the real console app in process (support/phone_console).
class ApprovalConsoleRecorderTest < Minitest::Test
  include PhoneConsole

  SHA = "b" * 40
  REASON = "hotfix for a broken release gate"
  REPO = "repo:github.com/acme/widgets"
  PR_URL = "https://github.com/acme/widgets/pull/612"

  def setup
    @home = File.realpath(Dir.mktmpdir)
    @prev = ENV["HOME"]
    ENV["HOME"] = @home
    start_phone_console
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
  end

  def recorder(at: @now, auth: authority) = ApprovalConsole::Recorder.new(authority: auth, store: @store, clock: -> { at }, recorded_by: "t")

  def step_attrs
    { "type" => "step", "repo" => REPO, "sha" => SHA, "profile" => nil,
      "items" => [ { "step" => "boot.up", "fields" => { "run" => "echo hi" }, "base_fields" => nil } ] }
  end

  def override_attrs(reason: REASON) = { "type" => "override", "repo" => REPO, "sha" => SHA, "profile" => "prod", "reason" => reason }

  def carve_out_attrs(pr_url: PR_URL, repo: REPO)
    { "type" => "carve-out", "repo" => repo, "sha" => SHA, "profile" => nil, "summary" => "merge #612", "pr_url" => pr_url }
  end

  def expected(attrs) = ApprovalConsole::Remote.expected(attrs, mid)

  def record(attrs, proof: phone_proof(attrs), **opts) = recorder(**opts).record(proof, expected: expected(attrs))

  def test_a_step_approval_routes_to_the_approval_store_with_the_policy_sha
    result = record(step_attrs)
    assert_predicate result, :ok?, result.error
    entry = ChangeApprovalStore.new(SHA).entries.first
    assert_equal [ "boot.up", ApprovalConsole::Canonical.step_digest("run" => "echo hi") ], [ entry["step"], entry["digest"] ]
    assert_equal POLICY_SHA, entry["policy_sha"]
    assert_equal "webauthn+totp", entry.dig("proof", "kind")
  end

  def test_an_override_routes_to_the_override_store_by_sha_and_profile
    result = record(override_attrs)
    assert_predicate result, :ok?, result.error
    stored = ChangeOverrideStore.new(SHA, profile: "prod").read
    assert_equal [ REASON, POLICY_SHA ], [ stored["reason"], stored["policy_sha"] ]
    assert_nil ChangeOverrideStore.new(SHA).read, "another profile's key stays empty"
  end

  def test_a_carve_out_routes_to_the_carve_out_store_by_repo_pr_and_head
    result = record(carve_out_attrs)
    assert_predicate result, :ok?, result.error
    assert_match(/PR #612/, result.summary)
    stored = ChangeCarveOutStore.new.lookup(repo: REPO, pr: "612", sha: SHA)
    assert_equal POLICY_SHA, stored["policy_sha"]
    assert_nil ChangeCarveOutStore.new.lookup(repo: REPO, pr: "612", sha: "d" * 40), "a new head needs a new approval"
  end

  # The console cannot sign a release body until the P3 redeploy, so the
  # receipt check is stubbed here to prove only the routing and its claims.
  class TrustingRecorder < ApprovalConsole::Recorder
    private

    def receipt_problem(_proof, _expected) = nil
    def stale(_proof) = nil
  end

  def test_a_release_routes_to_the_release_store_by_repo_tag_and_sha
    trusting = TrustingRecorder.new(authority: authority, store: @store, recorded_by: "t")
    result = trusting.record({ "kind" => "webauthn+totp" }, expected: { "type" => "release", "repo" => REPO, "sha" => SHA, "tag" => "skills/v1.2.3" })
    assert_predicate result, :ok?, result.error
    assert_equal POLICY_SHA, ChangeReleaseStore.new.lookup(repo: REPO, tag: "skills/v1.2.3", sha: SHA)["policy_sha"]
    refute_predicate trusting.record({}, expected: { "type" => "release", "repo" => REPO, "sha" => SHA }), :ok?
  end

  def test_a_real_release_receipt_is_refused_until_the_console_signs_the_type
    result = recorder.record({ "kind" => "webauthn+totp", "body" => "{}" }, expected: { "type" => "release", "repo" => REPO, "sha" => SHA, "tag" => "v1" })
    refute_predicate result, :ok?
    assert_nil ChangeReleaseStore.new.lookup(repo: REPO, tag: "v1", sha: SHA)
  end

  # Records what was flushed before the first poll, as a pipe reader sees it.
  class PipeOut < StringIO
    attr_reader :seen

    def flush = (@seen = string.dup) && self
  end

  def test_the_link_is_flushed_before_the_first_poll
    out = PipeOut.new
    seen_at_poll = nil
    sleeper = lambda do |_s|
      seen_at_poll ||= out.seen.to_s
      phone_approve(pending_request_body)
      @now += 3
    end
    @now += 30
    ApprovalConsole::Remote.approve(override_attrs, store: @store, client: client, out: out, sleeper: sleeper, clock: -> { @now })
    assert_match(/Approve on your phone: https:.*record [0-9a-f-]{36}/m, seen_at_poll)
  end

  def test_a_stale_or_future_receipt_is_refused_and_nothing_is_written
    proof = phone_proof(override_attrs)
    assert_match(/24h old/, record(override_attrs, proof: proof, at: @now + 86_400).error)
    assert_match(/24h old/, record(override_attrs, proof: proof, at: @now - 600).error)
    assert_nil ChangeOverrideStore.new(SHA, profile: "prod").read
  end

  def test_a_receipt_for_another_type_is_refused
    proof = phone_proof(step_attrs)
    result = recorder.record(proof, expected: expected(override_attrs))
    assert_match(/receipt is refused/, result.error)
    assert_nil ChangeOverrideStore.new(SHA, profile: "prod").read
  end

  def test_a_receipt_for_another_claim_is_refused
    proof = phone_proof(carve_out_attrs)
    result = recorder.record(proof, expected: expected(carve_out_attrs(pr_url: "https://github.com/acme/widgets/pull/613")))
    assert_match(/pr_url does not match/, result.error)
    other = phone_proof(step_attrs)
    assert_match(/sha does not match/, recorder.record(other, expected: expected(step_attrs.merge("sha" => "d" * 40))).error)
  end

  def test_carve_out_repo_must_be_the_pr_urls_repo
    result = record(carve_out_attrs(repo: "repo:github.com/acme/other"))
    assert_match(/not the PR's acme\/widgets/, result.error)
  end

  def test_a_short_override_reason_is_refused_before_the_receipt
    assert_match(/under 20 characters/, record(override_attrs(reason: "hotfix")).error)
  end

  def test_pins_that_differ_from_the_authoritative_pins_are_refused
    proof = phone_proof(override_attrs)
    wrong = authority(pins: authoritative_pins.merge("rp_id" => "evil.example.com"))
    assert_match(/rpId pin/, recorder(auth: wrong).record(proof, expected: expected(override_attrs)).error)
    assert_match(/no approval_pins/, recorder(auth: authority(pins: nil)).record(proof, expected: expected(override_attrs)).error)
  end

  def test_a_terminal_minted_proof_and_an_unknown_type_are_refused
    proof = phone_proof(override_attrs).merge("kind" => "totp-terminal")
    assert_match(/not a phone passkey approval/, record(override_attrs, proof: proof).error)
    assert_match(/not a recordable/, recorder.record({}, expected: { "type" => "prod-op" }).error)
    assert_match(/no authoritative/, recorder(auth: nil).record({}, expected: override_attrs).error)
  end
end
