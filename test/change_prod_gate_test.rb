# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require "base64"
require_relative "git_fixture"
require_relative "support/soft_authenticator"
require_relative "support/fake_claim_store"
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

  def config_with_runner(runner)
    cfg = YAML.safe_load_file(FIXTURE)
    other = { "kind" => "github_actions", "workflow" => ".github/workflows/other.yml",
              "environments" => { "staging" => "staging" }, "oidc_roles" => { "staging" => "arn:aws:iam::333333333333:role/other" } }
    cfg["change_config"]["runners"]["other"] = other
    op = cfg["change_config"]["operations"]["rotate_tenant_key"]
    runner.nil? ? op.delete("runner") : op["runner"] = runner
    cfg
  end

  def ready_with(config)
    envelope = ChangeProdEnvelope.build(config: config, op: "rotate_tenant_key", params: { "tenant_id" => "t_101" },
                                        profile: "staging", version: @sha, requested_by: "agent:s1", request_id: @id)
    request(envelope)
    approve(passkey_proof(body_for(envelope)), envelope: envelope)
  end

  def test_refuses_an_op_bound_to_a_second_runner_that_also_maps_staging
    config = config_with_runner("other")
    ChangeProdEnvelope.build(config: config, op: "rotate_tenant_key", params: { "tenant_id" => "t_101" },
                             profile: "staging", version: @sha, requested_by: "agent:s1")
    ready_with(config)
    assert_refused verify(config: config), /bound to runner "other", not prod/
  end

  def test_refuses_an_op_with_no_runner_and_one_with_an_undeclared_runner
    [ nil, "ghost" ].each do |runner|
      @store = ChangeProdStore.new(@dir)
      config = config_with_runner(runner)
      envelope = ChangeProdEnvelope.build(config: YAML.safe_load_file(FIXTURE), op: "rotate_tenant_key", params: { "tenant_id" => "t_101" },
                                          profile: "staging", version: @sha, requested_by: "agent:s1", request_id: @id)
      request(envelope)
      approve(passkey_proof(body_for(envelope)), envelope: envelope)
      result = verify(config: config)
      refute_predicate result, :ok?
      assert_match(/runner|config_digest/, result.reason)
      GitFixture.git(@dir, "update-ref", "-d", @store.ref("requests", @id))
      GitFixture.git(@dir, "update-ref", "-d", @store.ref("approvals", @id))
    end
  end

  def test_refuses_when_the_approved_runner_differs_from_the_current_config
    ready
    assert_refused verify(config: config_with_runner("other")), /config_digest does not match/
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

  def test_claim_is_a_conditional_put_with_the_run_identity
    claims = FakeClaimStore.new
    first = Gate.claim(claim_store: claims, envelope: @envelope, run_id: 7, attempt: 1, now: NOW)
    assert_predicate first, :ok?
    item = claims.items.fetch("CLAIM##{@id}")
    assert_equal [ @envelope["digest"], "7", "1" ], item.values_at("digest", "run_id", "run_attempt").map { |value| value["S"] }
    assert_equal "2026-11-18T12:10:00Z", item["claimed_at"]["S"]
    assert_equal (NOW.to_i + 7200).to_s, item["expires_at"]["N"]
    again = Gate.claim(claim_store: claims, envelope: @envelope, run_id: 8, attempt: 1, now: NOW)
    assert_refused again, /already consumed/
    assert_equal "7", claims.items.fetch("CLAIM##{@id}")["run_id"]["S"]
  end

  def test_deleting_a_git_ref_cannot_reopen_a_consumed_approval
    claims = FakeClaimStore.new
    Gate.claim(claim_store: claims, envelope: @envelope, run_id: 1, attempt: 1, now: NOW)
    assert_empty @store.send(:git, "for-each-ref", "refs/cf-prod/claims").first.to_s
    assert_raises(ChangeProdStore::Error) { @store.ref("claims", @id) }
    assert_refused Gate.claim(claim_store: claims, envelope: @envelope, run_id: 2, attempt: 1, now: NOW), /already consumed/
  end

  def test_claim_fails_closed_when_the_table_or_role_is_unavailable_or_the_identity_is_empty
    assert_refused Gate.claim(claim_store: FakeClaimStore.new(down: true), envelope: @envelope, run_id: 1, attempt: 1, now: NOW), /could not be written/
    claims = FakeClaimStore.new
    assert_refused Gate.claim(claim_store: claims, envelope: @envelope, run_id: "", attempt: 1, now: NOW), /required to claim/
    assert_refused Gate.claim(claim_store: claims, envelope: @envelope, run_id: 1, attempt: nil, now: NOW), /required to claim/
    assert_equal 0, claims.puts
  end

  def test_claim_settings_are_required_and_validated
    ok = ChangeProdClaim.settings(@config)
    assert_equal({ table: "cf-approval-console", role: "arn:aws:iam::333333333333:role/cf-prod-claim", region: "us-east-1" }, ok)
    [ [ "claim_table", nil ], [ "claim_table", "x" ], [ "claim_role", nil ], [ "claim_role", "arn:aws:iam::1:role/r" ], [ "region", "mars" ] ].each do |key, value|
      cfg = YAML.safe_load_file(FIXTURE)
      value.nil? ? cfg["change_config"]["runners"]["prod"].delete(key) : cfg["change_config"]["runners"]["prod"][key] = value
      assert_raises(ChangeProdClaim::Unavailable, key) { ChangeProdClaim.settings(cfg) }
    end
    assert_raises(ChangeProdClaim::Unavailable) { ChangeProdClaim.settings({}) }
  end

  def test_the_dynamo_store_puts_conditionally_and_maps_failures
    calls = []
    runner = lambda do |argv|
      calls << argv
      [ "", true ]
    end
    store = ChangeProdClaim::DynamoStore.new(table: "t-1", region: "us-east-1", runner: runner)
    store.put(ChangeProdClaim.item(request_id: @id, digest: "d", run_id: 1, attempt: 1, now: NOW))
    argv = calls.first
    assert_equal %w[aws dynamodb put-item], argv.first(3)
    assert_equal "attribute_not_exists(PK)", argv[argv.index("--condition-expression") + 1]
    assert_equal "t-1", argv[argv.index("--table-name") + 1]
    taken = ChangeProdClaim::DynamoStore.new(table: "t-1", region: "us-east-1", runner: ->(_) { [ "An error occurred (ConditionalCheckFailedException)", false ] })
    assert_raises(ChangeProdClaim::Exists) { taken.put({ "PK" => { "S" => "CLAIM#x" } }) }
    denied = ChangeProdClaim::DynamoStore.new(table: "t-1", region: "us-east-1", runner: ->(_) { [ "AccessDeniedException", false ] })
    assert_raises(ChangeProdClaim::Unavailable) { denied.put({ "PK" => { "S" => "CLAIM#x" } }) }
    missing = ChangeProdClaim::DynamoStore.new(table: "t-1", region: "us-east-1", runner: ->(_) { [ "aws: not found", false ] })
    assert_raises(ChangeProdClaim::Unavailable) { missing.put({ "PK" => { "S" => "CLAIM#x" } }) }
  end

  def test_issue_binds_credentials_to_the_claimed_attempt_and_digest
    claimed = { run_id: "5", attempt: "1", digest: @envelope["digest"] }
    assert_predicate Gate.issue(envelope: @envelope, run_id: "5", attempt: "1", claimed: claimed), :ok?
    assert_refused Gate.issue(envelope: @envelope, run_id: "5", attempt: "2", claimed: claimed), /did not claim this approval; a rerun needs a fresh approval/
    assert_refused Gate.issue(envelope: @envelope, run_id: "6", attempt: "1", claimed: claimed), /did not claim/
    assert_refused Gate.issue(envelope: @envelope, run_id: "5", attempt: "1", claimed: claimed.merge(digest: "sha256:#{'0' * 64}")), /did not claim/
    assert_refused Gate.issue(envelope: @envelope, run_id: "5", attempt: "1", claimed: claimed.merge(run_id: "")), /did not claim/
    assert_refused Gate.issue(envelope: @envelope, run_id: "5", attempt: "1", claimed: { run_id: nil, attempt: nil, digest: nil }), /did not claim/
    assert_refused Gate.issue(envelope: @envelope, run_id: "", attempt: "", claimed: { run_id: "", attempt: "", digest: "" }), /did not claim/
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

  def remote_runner(config_path: FIXTURE, envelope: @envelope)
    origin = Dir.mktmpdir
    @clone = File.join(Dir.mktmpdir, "runner")
    GitFixture.git_init(origin, "--bare", "-b", "main")
    GitFixture.git(@dir, "remote", "add", "origin", origin)
    GitFixture.git(@dir, "push", "-q", "origin", "main")
    @id = envelope["request_id"]
    @store.create("requests", @id, envelope)
    @store.create("approvals", @id, { "protocol" => "cf.prod.approval/2", "request_id" => @id, "digest" => envelope["digest"],
                                      "proof" => passkey_proof(body_for(envelope)) })
    GitFixture.git(origin, "clone", "-q", origin, @clone)
    creds = File.join(@clone, "creds.json")
    File.write(creds, JSON.generate(credentials))
    @origin = origin
    @claims = FakeClaimStore.new
    @base = [ "--request-id", @id, "--repo", @clone, "--config", config_path, "--credentials", creds, "--allow-environments", "staging",
              "--version-root", @clone ]
  end

  def cli(verb, run: "5", attempt: "1", now: NOW, claimed: nil, out: nil)
    err = StringIO.new
    env = { "GITHUB_REF" => "refs/heads/main", "GITHUB_RUN_ID" => run, "GITHUB_RUN_ATTEMPT" => attempt }
    env["GITHUB_OUTPUT"] = out if out
    extra = claimed ? [ "--claimed-run-id", claimed[0], "--claimed-attempt", claimed[1], "--claimed-digest", claimed[2] ] : []
    [ Gate.run([ verb ] + @base + extra, env: env, stdout: StringIO.new, stderr: err, now: now, claim_store: @claims), err.string ]
  end

  def claimed_identity(run: "5", attempt: "1") = [ run, attempt, @envelope["digest"] ]

  def test_cli_claim_puts_once_and_exports_the_identity
    remote_runner
    out = File.join(@clone, "out")
    assert_equal 0, cli("claim", out: out).first
    assert_equal "claim_run_id=5\nclaim_attempt=1\nclaim_digest=#{@envelope['digest']}\n", File.read(out)
    code, err = cli("claim")
    assert_equal 1, code
    assert_match(/already consumed/, err)
    assert_equal 1, @claims.items.size
  ensure
    FileUtils.remove_entry(@origin) if @origin
  end

  def test_cli_claim_and_recheck_fail_closed_without_claim_settings
    cfg = YAML.safe_load_file(FIXTURE)
    cfg["change_config"]["runners"]["prod"].delete("claim_table")
    envelope = ChangeProdEnvelope.build(config: cfg, op: "rotate_tenant_key", params: { "tenant_id" => "t_101" },
                                        profile: "staging", version: @sha, requested_by: "agent:s1")
    path = File.join(Dir.mktmpdir, "c.yml")
    File.write(path, YAML.dump(cfg))
    remote_runner(config_path: path, envelope: envelope)
    code, err = cli("claim")
    assert_equal 1, code
    assert_match(/claim_table is missing/, err)
    assert_equal 0, @claims.puts
  ensure
    FileUtils.remove_entry(@origin) if @origin
  end

  def test_cli_claim_refuses_when_the_table_is_down
    remote_runner
    @claims = FakeClaimStore.new(down: true)
    code, err = cli("claim")
    assert_equal 1, code
    assert_match(/could not be written/, err)
  ensure
    FileUtils.remove_entry(@origin) if @origin
  end

  def test_recheck_refuses_an_approval_that_expired_while_the_job_waited
    remote_runner
    assert_equal 0, cli("recheck", claimed: claimed_identity).first
    assert_equal 0, cli("recheck", claimed: claimed_identity).first, "recheck is read-only"
    code, err = cli("recheck", claimed: claimed_identity, now: Time.utc(2026, 11, 18, 12, 31, 0))
    assert_equal 1, code
    assert_match(/approval has expired/, err)
  ensure
    FileUtils.remove_entry(@origin) if @origin
  end

  def test_a_rerun_at_a_higher_attempt_is_refused
    remote_runner
    code, err = cli("recheck", attempt: "2", claimed: claimed_identity)
    assert_equal 1, code
    assert_match(/rerun needs a fresh approval/, err)
  ensure
    FileUtils.remove_entry(@origin) if @origin
  end

  def test_a_mismatched_run_id_and_missing_claim_outputs_are_refused
    remote_runner
    assert_equal 1, cli("recheck", run: "6", claimed: claimed_identity).first
    code, err = cli("recheck")
    assert_equal 1, code
    assert_match(/did not claim this approval/, err)
    assert_equal 1, cli("recheck", run: "", attempt: "", claimed: [ "", "", "" ]).first
    assert_equal 1, cli("claim", run: "", attempt: "").first
  ensure
    FileUtils.remove_entry(@origin) if @origin
  end

  def test_claim_and_recheck_refuse_a_second_runner_too
    config = config_with_runner("other")
    path = File.join(Dir.mktmpdir, "other.yml")
    File.write(path, YAML.dump(config))
    envelope = ChangeProdEnvelope.build(config: config, op: "rotate_tenant_key", params: { "tenant_id" => "t_101" },
                                        profile: "staging", version: @sha, requested_by: "agent:s1")
    remote_runner(config_path: path, envelope: envelope)
    %w[verify claim recheck].each do |verb|
      code, err = cli(verb, claimed: claimed_identity)
      assert_equal 1, code, verb
      assert_match(/bound to runner "other", not prod/, err, verb)
    end
    assert_equal 0, @claims.puts
  ensure
    FileUtils.remove_entry(@origin) if @origin
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
    remote_runner
    out = File.join(@clone, "out")
    assert_equal 0, cli("verify", out: out).first
    assert_equal "environment=staging\nversion=#{@sha}\n", File.read(out)
    assert_equal 0, cli("claim").first
    assert_equal 1, cli("claim").first
    code, err = cli("verify", now: Time.utc(2026, 12, 1))
    assert_equal 1, code
    assert_match(/approval has expired/, err)
    env = { "GITHUB_REF" => "refs/heads/evil", "GITHUB_RUN_ID" => "5", "GITHUB_RUN_ATTEMPT" => "1" }
    err = StringIO.new
    assert_equal 1, Gate.run([ "verify" ] + @base, env: env, stderr: err, now: NOW)
    assert_match(/not refs\/heads\/main/, err.string)
  ensure
    FileUtils.remove_entry(@origin) if @origin
  end
end
