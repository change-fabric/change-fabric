# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require "base64"
require_relative "git_fixture"
require_relative "support/soft_authenticator"
require_relative "support/fake_claim_store"
require_relative "../scripts/change_prod_gate"

# The runner accepts an autopilot ref in place of a per-action approval ref.
# Proofs are real passkey assertions plus signed console receipts.
class ChangeProdGateAutopilotTest < Minitest::Test
  Gate = ChangeProdGate
  Canonical = ApprovalConsole::Canonical
  RP_ID = "abc123.lambda-url.us-east-1.on.aws"
  MACHINE = "11111111-2222-4333-8444-555555555555"
  REPO_ID = "repo:github.com/acme/app"
  NOW = Time.utc(2026, 11, 24, 15, 0, 0)
  FIXTURE = File.expand_path("fixtures/prod/runner.yml", __dir__)

  def setup
    @dir = Dir.mktmpdir
    GitFixture.git_init(@dir, "-b", "main")
    GitFixture.git(@dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "base")
    @sha = GitFixture.git(@dir, "rev-parse", "HEAD").strip
    @store = ChangeProdStore.new(@dir)
    @config = YAML.safe_load_file(FIXTURE)
    @passkey = SoftAuthenticator.new
    @signer = SoftReceiptSigner.new
    @envelope = ChangeProdEnvelope.build(config: @config, op: "rotate_tenant_key", params: { "tenant_id" => "t_101" },
                                         profile: "staging", version: @sha, requested_by: "agent:s1")
    @id = @envelope["request_id"]
    @store.create("requests", @id, @envelope, push: false)
  end

  def teardown = FileUtils.remove_entry(@dir)

  def credentials(overrides = {})
    { "rp_id" => RP_ID, "repo" => REPO_ID, "machine_ids" => [ MACHINE ], "credentials" => @passkey.pinned,
      "receipt_public_key" => @signer.public_pem }.merge(overrides)
  end

  def autopilot_body(created: "2026-11-24T14:00:00Z", ends: "2026-11-24T23:00:00Z", scope: %w[prod review], repo: REPO_ID, machine: MACHINE)
    Canonical.build("type" => "autopilot", "machine_id" => machine, "repo" => repo, "sha" => @sha, "profile" => nil,
                    "request_id" => SecureRandom.uuid, "created_at" => created, "expires_at" => (Time.iso8601(created) + 900).utc.iso8601,
                    "summary" => "autopilot", "scope_list" => scope, "autopilot_expires_at" => ends)
  end

  def passkey_proof(body, bare: false)
    proof = { "kind" => "webauthn+totp", "body" => body, "totp_step" => 7 }.merge(@passkey.assert(body, rp_id: RP_ID))
    return proof if bare

    assertion = Digest::SHA256.hexdigest(%w[authenticator_data client_data_json signature].map { |key| Base64.urlsafe_decode64(proof[key]) }.join)
    fields = { "v" => 1, "kind" => proof["kind"], "machine_id" => MACHINE, "request_id" => Canonical.parse(body)["request_id"],
               "body_sha256" => Canonical.body_sha256(body), "assertion_sha256" => assertion, "totp_step" => 7,
               "channel" => "console", "accepted_at" => "2026-11-24T14:05:00Z" }
    proof.merge("receipt" => @signer.receipt(fields))
  end

  def publish(proof = passkey_proof(autopilot_body), id: nil, **fields)
    id ||= Canonical.body_sha256(proof["body"])
    record = { "protocol" => "cf.prod.autopilot/1", "autopilot_id" => id, "proof" => proof }.merge(fields)
    @store.create("autopilots", id, record, push: false)
    id
  end

  def verify(now: NOW, config: @config, creds: credentials)
    Gate.verify(store: @store, request_id: @id, config: config, credentials: creds, allowed: %w[staging], now: now)
  end

  def assert_refused(result, pattern)
    refute_predicate result, :ok?, "expected a refusal"
    assert_match pattern, result.reason
  end

  def test_an_unexpired_autopilot_stands_in_for_the_approval_ref
    id = publish
    result = verify
    assert_predicate result, :ok?, result.reason
    assert_equal :autopilot, result.level
    assert_equal id, result.autopilot_id
    assert_equal @id, result.envelope["request_id"]
  end

  def test_with_neither_approval_nor_autopilot_it_refuses
    assert_refused verify, /no approval ref and no autopilot ref/
  end

  def test_an_expired_autopilot_is_refused_lazily_and_exactly
    publish
    assert_predicate verify(now: Time.utc(2026, 11, 24, 22, 59, 59)), :ok?
    assert_refused verify(now: Time.utc(2026, 11, 24, 23, 0, 0)), /has expired/
  end

  def test_an_ended_autopilot_is_refused
    id = publish
    @store.create("autopilot-ends", id, { "ended_by" => "agent", "reason" => "done" }, push: false)
    assert_refused verify, /ended/
  end

  def test_an_autopilot_for_another_repo_or_machine_is_refused
    publish(passkey_proof(autopilot_body(repo: "repo:github.com/acme/other")))
    assert_refused verify, /for another repo/
  end

  def test_an_unpinned_machine_is_refused
    publish(passkey_proof(autopilot_body(machine: "99999999-2222-4333-8444-555555555555")))
    assert_refused verify, /machine is not pinned/
  end

  def test_an_autopilot_without_prod_in_its_scope_is_refused
    publish(passkey_proof(autopilot_body(scope: %w[review])))
    assert_refused verify, /prod is not in its scope/
  end

  def test_a_lifetime_over_the_maximum_is_refused
    # Canonical.build refuses such a body, so sign one built by hand: the gate parses it and refuses.
    long = JSON.parse(autopilot_body).merge("created_at" => "2026-11-20T14:00:00Z", "expires_at" => "2026-11-20T14:15:00Z")
    publish(passkey_proof(Canonical.serialize(long), bare: true))
    assert_refused verify(now: NOW), /body is invalid.*lifetime exceeds/
  end

  def test_an_autopilot_dated_in_the_future_is_refused
    publish(passkey_proof(autopilot_body(created: "2026-11-24T16:00:00Z", ends: "2026-11-24T23:00:00Z")))
    assert_refused verify, /dated in the future/
  end

  def test_a_different_body_type_is_refused
    body = Canonical.build("type" => "grant", "machine_id" => MACHINE, "repo" => REPO_ID, "sha" => @sha, "profile" => nil,
                           "request_id" => SecureRandom.uuid, "created_at" => "2026-11-24T14:00:00Z", "expires_at" => "2026-11-24T14:15:00Z",
                           "summary" => "g", "scope_list" => %w[pulse], "grant_expires_at" => "2026-11-24T23:00:00Z")
    publish(passkey_proof(body))
    assert_refused verify, /not an autopilot body/
  end

  def test_a_forged_or_tampered_proof_is_refused
    proof = passkey_proof(autopilot_body(scope: %w[review]))
    widened = JSON.parse(proof["body"]).merge("scope_list" => %w[prod review])
    forged = proof.merge("body" => Canonical.serialize(widened))
    publish(forged)
    assert_refused verify, /refused/
  end

  def test_a_record_filed_under_another_id_is_refused
    proof = passkey_proof(autopilot_body)
    publish(proof, id: "0" * 64)
    assert_refused verify, /id is not the body hash/
  end

  def test_extra_keys_are_refused
    publish(passkey_proof(autopilot_body), extra: 1)
    assert_refused verify, /keys are not/
  end

  def test_the_wrong_protocol_is_refused
    publish(passkey_proof(autopilot_body), "protocol" => "cf.prod.autopilot/2")
    assert_refused verify, /protocol is not/
  end

  def test_a_bare_passkey_with_no_console_receipt_is_refused_under_the_remote_policy
    publish(passkey_proof(autopilot_body, bare: true))
    assert_refused verify, /needs a console receipt/
  end

  def test_a_proof_with_no_passkey_or_receipt_is_never_accepted
    body = autopilot_body
    publish({ "kind" => "totp-terminal", "body" => body, "totp_step" => 7, "receipt" => nil })
    assert_refused verify, /never accepted/
  end

  def test_an_approval_ref_keeps_todays_rules_even_when_an_autopilot_exists
    publish
    @store.create("approvals", @id, { "protocol" => "cf.prod.approval/2", "request_id" => @id, "digest" => @envelope["digest"], "proof" => {} }, push: false)
    assert_refused verify, /approval proof is not an object|approval body is invalid/
  end

  def test_one_usable_autopilot_among_bad_ones_is_enough
    publish(passkey_proof(autopilot_body(scope: %w[review])))
    good = publish
    result = verify
    assert_predicate result, :ok?, result.reason
    assert_equal good, result.autopilot_id
  end

  def test_the_cli_claims_and_exports_under_an_autopilot_with_no_approval_ref
    origin = Dir.mktmpdir
    GitFixture.git_init(origin, "--bare", "-b", "main")
    GitFixture.git(@dir, "remote", "add", "origin", origin)
    GitFixture.git(@dir, "push", "-q", "origin", "main")
    @store.publish(@store.ref("requests", @id))
    id = publish
    @store.publish(@store.ref("autopilots", id))
    clone = File.join(Dir.mktmpdir, "runner")
    GitFixture.git(origin, "clone", "-q", origin, clone)
    creds = File.join(clone, "creds.json")
    File.write(creds, JSON.generate(credentials))
    base = [ "--request-id", @id, "--repo", clone, "--config", FIXTURE, "--credentials", creds, "--allow-environments", "staging",
             "--version-root", clone ]
    env = { "GITHUB_REF" => "refs/heads/main", "GITHUB_RUN_ID" => "5", "GITHUB_RUN_ATTEMPT" => "1" }
    out = StringIO.new
    claims = FakeClaimStore.new
    assert_equal 0, Gate.run([ "verify" ] + base, env: env, stdout: out, stderr: StringIO.new, now: NOW, claim_store: claims)
    assert_match(/autopilot_id=#{id}/, out.string)
    assert_match(/proof level autopilot/, out.string)
    assert_equal 0, Gate.run([ "claim" ] + base, env: env, stdout: StringIO.new, stderr: StringIO.new, now: NOW, claim_store: claims)
    assert_equal 1, claims.items.size
    err = StringIO.new
    assert_equal 1, Gate.run([ "claim" ] + base, env: env, stdout: StringIO.new, stderr: err, now: NOW, claim_store: claims)
    assert_match(/already consumed/, err.string)

    # An end marker published after the fact stops it at the next verify.
    @store.create("autopilot-ends", id, { "reason" => "done" })
    GitFixture.git(clone, "fetch", "-q", "origin", "+refs/cf-prod/*:refs/cf-prod/*")
    err = StringIO.new
    assert_equal 1, Gate.run([ "verify" ] + base, env: env, stdout: StringIO.new, stderr: err, now: NOW, claim_store: claims)
    assert_match(/ended/, err.string)
  ensure
    FileUtils.remove_entry(origin) if origin
  end
end
