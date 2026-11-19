# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require "base64"
require_relative "git_fixture"
require_relative "support/soft_authenticator"
require_relative "../scripts/change_prod_gate"

class ChangeProdGateTest < Minitest::Test
  Gate = ChangeProdGate
  Canonical = ApprovalConsole::Canonical
  RP_ID = "abc123.lambda-url.us-east-1.on.aws"
  MACHINE = "11111111-2222-4333-8444-555555555555"
  REPO_ID = "repo:github.com/acme/app"
  NOW = Time.utc(2026, 11, 18, 12, 10, 0)
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
  end

  def teardown = FileUtils.remove_entry(@dir)

  def credentials(overrides = {})
    { "rp_id" => RP_ID, "repo" => REPO_ID, "machine_ids" => [ MACHINE ], "credentials" => @passkey.pinned,
      "receipt_public_key" => @signer.public_pem }.merge(overrides)
  end

  def body_for(envelope, created: "2026-11-18T12:00:00Z", expires: "2026-11-18T12:30:00Z", **overrides)
    context = ChangeProdEnvelope.approval_context(envelope, repo: REPO_ID, machine_id: MACHINE)
    Canonical.build(context.merge("request_id" => SecureRandom.uuid, "created_at" => created, "expires_at" => expires).merge(overrides))
  end

  def bare_passkey_proof(body) = { "kind" => "webauthn+totp", "body" => body, "totp_step" => 7 }.merge(@passkey.assert(body, rp_id: RP_ID))

  # A passkey proof countersigned by the console, as the remote policy requires.
  def passkey_proof(body)
    proof = bare_passkey_proof(body)
    assertion = Digest::SHA256.hexdigest(%w[authenticator_data client_data_json signature].map { |key| Base64.urlsafe_decode64(proof[key]) }.join)
    fields = { "v" => 1, "kind" => proof["kind"], "machine_id" => MACHINE, "request_id" => Canonical.parse(body)["request_id"],
               "body_sha256" => Canonical.body_sha256(body), "assertion_sha256" => assertion, "totp_step" => 7,
               "channel" => "console", "accepted_at" => "2026-11-18T12:05:00Z" }
    proof.merge("receipt" => @signer.receipt(fields))
  end

  def local_proof(body) = { "kind" => "totp-terminal", "body" => body, "totp_step" => 7, "receipt" => nil }

  def approve(proof, envelope: @envelope, **fields)
    record = { "protocol" => "cf.prod.approval/2", "request_id" => @id, "digest" => envelope["digest"], "proof" => proof }.merge(fields)
    @store.create("approvals", @id, record, push: false)
  end

  def request(envelope = @envelope) = @store.create("requests", @id, envelope, push: false)

  def verify(allowed: %w[staging], now: NOW, config: @config, creds: credentials)
    Gate.verify(store: @store, request_id: @id, config: config, credentials: creds, allowed: allowed, now: now)
  end

  def assert_refused(result, pattern)
    refute_predicate result, :ok?, "expected a refusal"
    assert_match pattern, result.reason
  end

  def ready(proof: nil)
    request
    approve(proof || passkey_proof(body_for(@envelope)))
  end

  def test_accepts_a_passkey_proof_for_staging
    ready
    result = verify
    assert_predicate result, :ok?, result.reason
    assert_equal :receipt, result.level
    assert_equal "staging", result.envelope["environment"]
  end

  def test_never_accepts_a_proof_with_no_passkey_or_receipt_for_any_profile
    %w[staging production].each do |profile|
      @store = ChangeProdStore.new(@dir)
      envelope = ChangeProdEnvelope.build(config: @config, op: "rotate_tenant_key", params: { "tenant_id" => "t_101" },
                                          profile: profile, version: @sha, requested_by: "agent:s1", request_id: @id)
      request(envelope)
      approve(local_proof(body_for(envelope)), envelope: envelope)
      assert_refused verify(allowed: [ profile ]), /never accepted; staging waits for the console receipt phase/
      GitFixture.git(@dir, "update-ref", "-d", @store.ref("requests", @id))
      GitFixture.git(@dir, "update-ref", "-d", @store.ref("approvals", @id))
    end
  end

  def test_refuses_a_forged_terminal_proof_even_with_a_public_machine_id
    # No TOTP secret and no signature: only the (public) machine id and digest.
    forged = { "kind" => "totp-terminal", "body" => body_for(@envelope), "totp_step" => 1 }
    ready(proof: forged)
    assert_refused verify, /never accepted/
  end

  def test_a_terminal_proof_with_a_receipt_from_an_unpinned_key_is_refused
    body = body_for(@envelope)
    proof = local_proof(body).merge("receipt" => @signer.receipt({ "v" => 1 }, key: OpenSSL::PKey::EC.generate("prime256v1")))
    ready(proof: proof)
    assert_refused verify, /receipt/
  end

  def test_remote_policy_refuses_a_passkey_without_a_console_receipt
    ready(proof: bare_passkey_proof(body_for(@envelope)))
    assert_refused verify, /needs a console receipt/
  end

  def test_a_default_policy_is_remote
    config = YAML.safe_load_file(FIXTURE)
    config["change_policy"].delete("prod_guard")
    envelope = ChangeProdEnvelope.build(config: config, op: "rotate_tenant_key", params: { "tenant_id" => "t_101" },
                                        profile: "staging", version: @sha, requested_by: "agent:s1", request_id: @id)
    request(envelope)
    approve(bare_passkey_proof(body_for(envelope)), envelope: envelope)
    assert_refused verify(config: config), /needs a console receipt/
  end

  def test_passkey_policy_accepts_a_bare_passkey_and_unknown_policies_refuse
    %w[passkey bogus].each do |mode|
      @store = ChangeProdStore.new(@dir)
      config = YAML.safe_load_file(FIXTURE)
      config["change_policy"]["prod_guard"]["approval"]["proof"] = mode
      envelope = ChangeProdEnvelope.build(config: config, op: "rotate_tenant_key", params: { "tenant_id" => "t_101" },
                                          profile: "staging", version: @sha, requested_by: "agent:s1", request_id: @id)
      request(envelope)
      approve(bare_passkey_proof(body_for(envelope)), envelope: envelope)
      result = verify(config: config)
      if mode == "passkey"
        assert_equal :passkey, result.level
      else
        assert_refused result, /must be remote or passkey/
      end
      GitFixture.git(@dir, "update-ref", "-d", @store.ref("requests", @id))
      GitFixture.git(@dir, "update-ref", "-d", @store.ref("approvals", @id))
    end
  end

  def test_accepts_a_passkey_proof_and_a_receipted_terminal_proof_for_production
    production = ChangeProdEnvelope.build(config: @config, op: "rotate_tenant_key", params: { "tenant_id" => "t_101" },
                                          profile: "production", version: @sha, requested_by: "agent:s1", request_id: @id)
    request(production)
    approve(passkey_proof(body_for(production)), envelope: production)
    assert_predicate verify(allowed: %w[production]), :ok?
  end

  def test_refuses_without_a_request_or_an_approval
    assert_refused verify, /no request ref/
    request
    assert_refused verify, /no approval ref/
  end

  def test_refuses_a_request_that_does_not_match_its_ref_or_digest
    other = ChangeProdEnvelope.build(config: @config, op: "rotate_tenant_key", params: { "tenant_id" => "t_101" },
                                     profile: "staging", version: @sha, requested_by: "agent:s1")
    request(other)
    assert_refused verify, /request_id does not match its ref/
  end

  def test_refuses_a_tampered_request
    request(@envelope.merge("params" => { "tenant_id" => "t_999" }))
    assert_refused verify, /digest does not match the envelope/
  end

  def test_refuses_when_the_base_config_changed_after_the_request
    ready
    changed = YAML.safe_load_file(FIXTURE)
    changed["change_config"]["operations"]["rotate_tenant_key"]["timeout_s"] = 5
    assert_refused verify(config: changed), /config_digest does not match/
  end

  def test_refuses_an_environment_without_a_job
    ready
    assert_refused verify(allowed: %w[production]), /environment staging has no job/
    assert_refused verify(allowed: []), /no job/
  end

  def test_refuses_a_malformed_approval_record
    request
    approve(passkey_proof(body_for(@envelope)), "protocol" => "cf.prod.approval/1")
    assert_refused verify, /approval protocol is not cf.prod.approval\/2/
  end

  def test_refuses_an_approval_for_another_request_or_digest
    request
    approve(passkey_proof(body_for(@envelope)), "request_id" => SecureRandom.uuid)
    assert_refused verify, /approval request_id does not match/
  end

  def test_refuses_an_approval_digest_that_is_not_the_request_digest
    request
    approve(passkey_proof(body_for(@envelope)), "digest" => "sha256:#{'0' * 64}")
    assert_refused verify, /approval digest does not match/
  end

  def test_refuses_extra_approval_keys
    request
    approve(passkey_proof(body_for(@envelope)), "extra" => true)
    assert_refused verify, /approval keys are not/
  end

  def test_refuses_a_proof_bound_to_a_different_digest
    other = @envelope.merge("params" => { "tenant_id" => "t_102" })
    other["digest"] = ChangeProdEnvelope.digest(other)
    ready(proof: passkey_proof(body_for(other)))
    assert_refused verify, /approval proof refused: summary does not match/
  end

  def test_refuses_a_proof_for_another_commit_repo_or_profile
    request
    approve(passkey_proof(body_for(@envelope, sha: "b" * 40)))
    assert_refused verify, /sha does not match/
  end

  def test_refuses_a_proof_for_another_repo
    ready(proof: passkey_proof(body_for(@envelope, repo: "repo:github.com/evil/app")))
    assert_refused verify, /repo does not match/
  end

  def test_refuses_an_unpinned_machine_credential_or_signer
    ready
    assert_refused verify(creds: credentials("machine_ids" => [ "99999999-8888-4777-8666-555555555555" ])), /machine is not pinned/
    assert_refused verify(creds: credentials("credentials" => SoftAuthenticator.new.pinned)), /credential is not pinned/
    assert_refused verify(creds: credentials("rp_id" => "evil.example")), /origin|rpIdHash/
  end

  def test_refuses_incomplete_pinned_credentials
    ready
    assert_refused verify(creds: credentials("repo" => "")), /pinned credentials need/
    assert_refused verify(creds: credentials("machine_ids" => [])), /pinned credentials need/
    assert_refused verify(creds: credentials("credentials" => nil)), /pinned credentials need/
    assert_refused verify(creds: nil), /pinned credentials are missing/
  end

  def test_refuses_a_passkey_without_user_verification
    body = body_for(@envelope)
    proof = { "kind" => "webauthn+totp", "body" => body, "totp_step" => 7 }.merge(@passkey.assert(body, rp_id: RP_ID, uv: false))
    ready(proof: proof)
    assert_refused verify, /user verification/
  end

  def test_refuses_a_forged_receipt
    body = body_for(@envelope)
    proof = passkey_proof(body).merge("receipt" => @signer.receipt({ "v" => 1 }, key: OpenSSL::PKey::EC.generate("prime256v1")))
    ready(proof: proof)
    assert_refused verify, /receipt/
  end

  def test_refuses_an_unparseable_body_and_a_non_object_proof
    ready(proof: { "kind" => "totp-terminal", "body" => "{}", "totp_step" => 1 })
    assert_refused verify, /approval body is invalid/
  end

  def test_refuses_a_non_object_proof
    ready(proof: "approved")
    assert_refused verify, /proof is not an object/
  end

  def test_refuses_an_expired_approval
    ready
    assert_refused verify(now: Time.utc(2026, 11, 18, 12, 31, 0)), /approval has expired/
  end

  def test_refuses_a_lifetime_over_the_policy_ttl
    ready(proof: passkey_proof(body_for(@envelope, expires: "2026-11-18T12:45:00Z")))
    assert_refused verify, /exceeds the 30 minute policy ttl/
  end

  def test_policy_ttl_is_bounded
    config = YAML.safe_load_file(FIXTURE)
    config["change_policy"]["prod_guard"]["approval"]["ttl_minutes"] = 600
    envelope = ChangeProdEnvelope.build(config: config, op: "rotate_tenant_key", params: { "tenant_id" => "t_101" },
                                        profile: "staging", version: @sha, requested_by: "agent:s1", request_id: @id)
    request(envelope)
    approve(passkey_proof(body_for(envelope)), envelope: envelope)
    assert_refused verify(config: config), /ttl_minutes must be an integer/
  end

  def test_refuses_an_approval_dated_in_the_future
    ready(proof: passkey_proof(body_for(@envelope, created: "2026-11-18T13:00:00Z", expires: "2026-11-18T13:20:00Z")))
    assert_refused verify, /dated in the future/
  end

  def test_claim_is_single_use
    first = Gate.claim(store: @store, request_id: @id, run_id: 7, now: NOW, push: false)
    assert_predicate first, :ok?
    again = Gate.claim(store: @store, request_id: @id, run_id: 8, now: NOW, push: false)
    assert_refused again, /already consumed/
    assert_equal "7", @store.read("claims", @id)["run_id"]
  end

  def test_claim_refuses_a_malformed_request_id
    assert_refused Gate.claim(store: @store, request_id: "x", run_id: 1, push: false), /not a uuid/
  end

  def test_provenance_requires_default_branch_exact_checkout_and_reachability
    ready
    envelope = @envelope
    assert_equal true, Gate.provenance(root: @dir, envelope: envelope, github_ref: "refs/heads/main", default_branch: "main", base_ref: "main")
    assert_refused Gate.provenance(root: @dir, envelope: envelope, github_ref: "refs/heads/feature", default_branch: "main", base_ref: "main"), /not refs\/heads\/main/
    assert_refused Gate.provenance(root: @dir, envelope: envelope.merge("version" => "b" * 40), github_ref: "refs/heads/main", default_branch: "main", base_ref: "main"), /not the approved version/
    GitFixture.git(@dir, "checkout", "-q", "-b", "side")
    GitFixture.git(@dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "side")
    side = GitFixture.git(@dir, "rev-parse", "HEAD").strip
    assert_refused Gate.provenance(root: @dir, envelope: envelope.merge("version" => side), github_ref: "refs/heads/main", default_branch: "main", base_ref: "main"), /not reachable/
  end

  def test_the_run_verb_refuses_in_this_release
    err = StringIO.new
    assert_equal 1, Gate.run([ "run" ], stderr: err)
    assert_match(/no op executor/, err.string)
  end

  def test_cli_refuses_when_the_remote_cannot_be_fetched
    ready
    err = StringIO.new
    argv = [ "verify", "--request-id", @id, "--repo", @dir, "--config", FIXTURE, "--credentials", File.join(@dir, "none.json"), "--remote", "none" ]
    assert_equal 1, Gate.run(argv, stderr: err)
    assert_match(/fetching refs\/cf-prod failed/, err.string)
    assert_equal 2, Gate.run([ "bogus" ], stderr: StringIO.new)
    assert_equal 1, Gate.run([ "verify", "--bogus" ], stderr: StringIO.new)
    assert_equal 1, Gate.run([ "verify" ], stderr: StringIO.new)
  end

  def test_cli_verifies_and_claims_through_a_real_remote_once
    origin = Dir.mktmpdir
    clone = File.join(Dir.mktmpdir, "runner")
    GitFixture.git_init(origin, "--bare", "-b", "main")
    GitFixture.git(@dir, "remote", "add", "origin", origin)
    GitFixture.git(@dir, "push", "-q", "origin", "main")
    @store.create("requests", @id, @envelope)
    @store.create("approvals", @id, { "protocol" => "cf.prod.approval/2", "request_id" => @id, "digest" => @envelope["digest"],
                                      "proof" => passkey_proof(body_for(@envelope)) })
    GitFixture.git(origin, "clone", "-q", origin, clone)
    creds = File.join(clone, "creds.json")
    File.write(creds, JSON.generate(credentials))
    out = File.join(clone, "out")
    base = [ "--request-id", @id, "--repo", clone, "--config", FIXTURE, "--credentials", creds, "--allow-environments", "staging",
             "--version-root", clone ]
    env = { "GITHUB_OUTPUT" => out, "GITHUB_REF" => "refs/heads/main", "GITHUB_RUN_ID" => "5" }
    assert_equal 0, Gate.run([ "verify" ] + base, env: env, stdout: StringIO.new, now: NOW)
    assert_equal "environment=staging\nversion=#{@sha}\n", File.read(out)
    assert_equal 0, Gate.run([ "claim" ] + base, env: env, stdout: StringIO.new, now: NOW)
    err = StringIO.new
    assert_equal 1, Gate.run([ "claim" ] + base, env: env, stdout: StringIO.new, stderr: err, now: NOW)
    assert_match(/already consumed/, err.string)
    err = StringIO.new
    assert_equal 1, Gate.run([ "verify" ] + base, env: env.merge("GITHUB_REF" => "refs/heads/evil"), stderr: err, now: NOW)
    assert_match(/not refs\/heads\/main/, err.string)
    assert_equal 1, Gate.run([ "verify" ] + base, env: env, stderr: err, now: Time.utc(2026, 12, 1))
  ensure
    FileUtils.remove_entry(origin) if origin
  end

  def test_claim_through_a_real_remote_is_single_use
    origin = Dir.mktmpdir
    GitFixture.git_init(origin, "--bare", "-b", "main")
    GitFixture.git(@dir, "remote", "add", "origin", origin)
    first = Gate.claim(store: @store, request_id: @id, run_id: 1, now: NOW)
    assert_predicate first, :ok?
    second = ChangeProdStore.new(clone_of(origin))
    assert_refused Gate.claim(store: second, request_id: @id, run_id: 2, now: NOW), /already consumed/
  ensure
    FileUtils.remove_entry(origin) if origin
  end

  def clone_of(origin)
    dir = Dir.mktmpdir
    GitFixture.git(dir, "init", "-q")
    GitFixture.git(dir, "remote", "add", "origin", origin)
    dir
  end
end
