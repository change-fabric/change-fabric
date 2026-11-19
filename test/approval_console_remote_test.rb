# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require "uri"
require_relative "../approval_console/infra/lambda/console"
require_relative "support/soft_authenticator"
require_relative "support/console_fakes"
require_relative "support/totp_enrollment"
require_relative "../scripts/approval_console"
require_relative "../scripts/approval_console/terminal_prompt"
require_relative "../scripts/change_gate_check"

# Phase 6 end to end: the CLI side (Client, Remote, TerminalPrompt, Sync,
# ProofCheck, enroll) against the real console app, in process, over the
# in-memory store and KMS fakes. Nothing touches the network or AWS.
class ApprovalConsoleRemoteTest < Minitest::Test
  include TotpEnrollment

  Canonical = ApprovalConsole::Canonical
  Totp = ApprovalConsole::Totp
  HOST = "abc123.lambda-url.us-east-1.on.aws"
  SHA = "b" * 40

  def setup
    @home = File.realpath(Dir.mktmpdir)
    @prev = ENV["HOME"]
    ENV["HOME"] = @home
    @repo = File.join(@home, "repo")
    FileUtils.mkdir_p(@repo)
    @now = Time.utc(2026, 11, 19, 12, 0, 0)
    @store = enroll_totp(@home)
    @db = MemoryStore.new
    @signer = SoftReceiptSigner.new
    @kms = FakeKms.new(@signer)
    @app = ApprovalConsoleApp.new(store: @db, kms: @kms, dm: FakeDm.new, clock: -> { @now }, qr: ->(_uri) { "<svg/>" })
    @passkey = SoftAuthenticator.new
    @counter = 0
    @up = true
    register_machine
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
  end

  # ----- fixtures --------------------------------------------------------

  def mid = @store.machine_id

  def register_machine
    key = @store.ensure_machine_key!
    @db.seed("pk" => "M##{mid}", "sk" => "META", "label" => "test", "machine_key" => key.public_to_pem, "failures" => 0, "version" => 0)
    @db.seed("pk" => "M##{mid}", "sk" => "SEED", "ciphertext" => SoftAuthenticator.b64(@kms.encrypt(@store.seed, "machine_id" => mid)))
    @db.seed("pk" => "CRED", "sk" => @passkey.credential_id, "cose" => SoftAuthenticator.b64(@passkey.cose_public_key), "sign_count" => 0)
    @store.pin!(base_url: "https://#{HOST}/", rp_id: HOST, credentials: @passkey.pinned,
                receipt_public_key: @signer.public_pem, receipt_key_id: "arn:aws:kms:test:key/receipts")
  end

  def transport
    lambda do |method, url, headers, body|
      raise Errno::ECONNREFUSED, "console down" unless @up

      path = URI(url).path
      event = { "requestContext" => { "http" => { "method" => method, "path" => path }, "domainName" => HOST },
                "rawPath" => path, "headers" => headers, "body" => method == "GET" ? nil : body }
      response = @app.call(event)
      [ response[:statusCode], response[:body] ]
    end
  end

  def client = ApprovalConsole::Client.for(@store, transport: transport, clock: -> { @now })

  def code(offset = 0) = Totp.code(@store.seed, Totp.step_for(@now) + offset)

  def repo_id = CfProjectIdentity.for(@repo).id

  def override_attrs(reason: "hotfix") = { "type" => "override", "repo" => repo_id, "sha" => SHA, "profile" => nil, "reason" => reason }

  def step_attrs
    { "type" => "step", "repo" => repo_id, "sha" => SHA, "profile" => nil,
      "items" => [ { "step" => "boot.up", "fields" => { "run" => "echo hi" }, "base_fields" => nil } ] }
  end

  def phone_approve(body, totp: code)
    @counter += 1
    rid = Canonical.parse(body)["request_id"]
    fields = @passkey.assert(body, rp_id: HOST, counter: @counter)
    response = @app.call("requestContext" => { "http" => { "method" => "POST", "path" => "/m/#{mid}/r/#{rid}/approve" }, "domainName" => HOST },
                         "headers" => {}, "body" => JSON.generate(fields.merge("totp" => totp)))
    response[:statusCode]
  end

  # Waits through Remote.approve, approving on the "phone" at the first poll.
  def remote_approve(attrs, totp: code)
    out = StringIO.new
    status = nil
    sleeper = lambda do |_s|
      body = pending_request_body
      status ||= phone_approve(body, totp: totp)
      @now += 3
    end
    result = ApprovalConsole::Remote.approve(attrs, store: @store, client: client, out: out, sleeper: sleeper, clock: -> { @now })
    [ result, out.string, status ]
  end

  def pending_request_body = @db.items.values.find { |item| item["sk"].to_s.start_with?("REQ#") }["body"]

  def terminal(attrs, typed: code)
    stdin = StringIO.new("#{typed}\n")
    ApprovalConsole::TerminalPrompt.approve(attrs, stdin: stdin, stdout: StringIO.new, store: @store, now: @now, client: client)
  end

  def gate(level) = ChangeGateCheck.new(sha: SHA, profile: nil, root: @repo, proof_level: level, proof_store: @store)

  def record_override(proof, reason: "hotfix")
    ChangeOverrideStore.new(SHA).record(reason: reason, recorded_by: "t", proof: proof)
  end

  # ----- the phone path --------------------------------------------------

  def test_remote_approval_returns_a_verified_passkey_proof_with_a_receipt
    result, out, status = remote_approve(step_attrs)
    assert_equal 200, status
    assert_predicate result, :ok?, result.error
    assert_match %r{https://#{HOST}/m/#{mid}/r/}, out
    assert_equal "webauthn+totp", result.proof["kind"]
    assert result.proof["receipt"]
    assert_equal Totp.step_for(@now - 3), @store.status[:last_step], "the local fence mirrors the console's"
  end

  def test_remote_wait_reports_an_expired_request
    sleeper = ->(_s) { @now += 1000 }
    result = ApprovalConsole::Remote.approve(step_attrs, store: @store, client: client, out: StringIO.new, sleeper: sleeper, clock: -> { @now })
    refute_predicate result, :ok?
    assert_match(/expired|timed out/, result.error)
  end

  def test_a_proof_for_another_context_is_refused_by_the_verifier
    result, = remote_approve(step_attrs)
    other = ApprovalConsole::Remote.expected(step_attrs.merge("repo" => "github.com/else/where"), mid)
    problem = ApprovalConsole::Remote.check(result.proof, result.proof["body"], other, @store, kind: "webauthn+totp")
    assert_match(/repo does not match/, problem)
  end

  def test_remote_approve_reports_an_unreachable_console
    @up = false
    result = ApprovalConsole::Remote.approve(step_attrs, store: @store, client: client, out: StringIO.new, sleeper: ->(_) { }, clock: -> { @now })
    assert_match(/unreachable/, result.error)
  end

  # ----- the terminal path online and offline ----------------------------

  def test_terminal_approval_online_carries_a_console_receipt
    result = terminal(override_attrs)
    assert_predicate result, :ok?, result.error
    assert_equal "terminal", JSON.parse(result.proof["receipt"]["payload"])["channel"]
    assert_empty @store.pending, "an online approval queues nothing"
  end

  def test_phone_and_terminal_at_one_step_accept_exactly_once
    first = terminal(override_attrs)
    assert_predicate first, :ok?
    result, = remote_approve(step_attrs, totp: code)
    refute_predicate result, :ok?, "the phone cannot reuse the step the terminal spent"
  end

  def test_a_refusing_console_is_final_with_no_local_fallback
    result = terminal(override_attrs, typed: "000000")
    refute_predicate result, :ok?
    assert_match(/not valid/, result.error)
    assert_empty @store.pending
  end

  def test_offline_terminal_approval_queues_and_sync_attaches_the_receipt
    @up = false
    result = terminal(override_attrs)
    assert_predicate result, :ok?
    assert_nil result.proof["receipt"]
    record_override(result.proof)
    assert_equal 1, @store.unsynced.size
    refute gate("remote").overridden?, "no receipt yet, so remote refuses it"
    assert gate("local").overridden?

    @up = true
    @now += 60
    report = ApprovalConsole::Sync.run(store: @store, client: client)
    assert_equal [ 1, 0 ], [ report.synced, report.conflicts ]
    assert_empty @store.pending
    assert ChangeOverrideStore.new(SHA).read.dig("proof", "receipt")
    assert gate("remote").overridden?, "the synced terminal proof passes remote"
  end

  def test_the_local_mirror_refuses_an_offline_step_below_the_console_fence
    @up = false
    offline = terminal(override_attrs)
    record_override(offline.proof)
    @up = true
    @now += 30
    online = terminal(override_attrs(reason: "later"))
    assert_predicate online, :ok?
    assert_empty @store.unsynced

    @up = false
    @now -= 60
    stale = terminal(override_attrs(reason: "stale"))
    refute_predicate stale, :ok?, "the local mirror already sits above this step"
  end

  def test_sync_marks_a_rejected_entry_as_conflict_and_the_gate_refuses_it
    @up = false
    result = terminal(override_attrs)
    record_override(result.proof)
    @up = true
    step = result.proof["totp_step"]
    meta = @db.get("M##{mid}", "META")
    @db.seed(meta.merge("last_step" => step))
    report = ApprovalConsole::Sync.run(store: @store, client: client)
    assert_equal 1, report.conflicts
    assert_equal 1, @store.conflicts.size
    refute @store.conflicts.first.key?("code"), "a settled entry drops its spent code"
    assert ChangeOverrideStore.new(SHA).read.dig("proof", "conflict")
    refute gate(nil).overridden?, "a conflicted proof is refused even in the compatibility window"
  end

  def test_the_ten_entry_bound_refuses_new_offline_approvals
    @up = false
    10.times do |i|
      assert_predicate terminal(override_attrs(reason: "r#{i}")), :ok?, i
      @now += 30
    end
    refute_predicate terminal(override_attrs(reason: "eleventh")), :ok?
  end

  # ----- the gate --------------------------------------------------------

  def test_queued_offline_approvals_sync_before_a_phone_request
    @up = false
    offline = terminal(override_attrs)
    record_override(offline.proof)
    @up = true
    @now += 30
    result, = remote_approve(step_attrs)
    assert_predicate result, :ok?, result.error
    assert_empty @store.pending, "the queued approval synced, not conflicted"
    assert ChangeOverrideStore.new(SHA).read.dig("proof", "receipt")
  end

  def test_malformed_step_proofs_are_refused_not_skipped
    check = ApprovalConsole::ProofCheck.new(level: nil, store: @store)
    [ "not an object", { "kind" => "totp-terminal" } ].each do |proof|
      entries = [ { "step" => "boot.up", "digest" => "a" * 64, "proof" => proof } ]
      assert_match(/malformed/, check.approvals_problem(entries, repo: repo_id, sha: SHA), proof.inspect)
    end
    assert_nil check.approvals_problem([ { "step" => "boot.up", "digest" => "a" * 64 } ], repo: repo_id, sha: SHA)
  end

  def test_a_missing_proof_warns_unset_and_is_refused_under_local
    ChangeOverrideStore.new(SHA).record(reason: "hotfix", recorded_by: "t")
    check = gate(nil)
    assert check.overridden?
    assert_match(/unproven/, check.proof_warnings.join)
    refute gate("local").overridden?
    assert_match(/no approval proof/, gate("local").trust_clause)
  end

  def test_a_hand_fabricated_terminal_proof_passes_local_only
    body = ApprovalConsole::Remote.build_body(override_attrs, @store, now: @now)
    record_override({ "kind" => "totp-terminal", "body" => body, "totp_step" => 1, "receipt" => nil })
    assert gate("local").overridden?, "local accepts a terminal proof the CLI could have written"
    refute gate("remote").overridden?
  end

  def test_a_forged_receipt_or_tampered_body_is_refused_at_every_level
    result = terminal(override_attrs)
    forged = result.proof.merge("receipt" => result.proof["receipt"].merge("sig" => SoftAuthenticator.b64("x" * 64)))
    record_override(forged)
    [ nil, "local", "remote" ].each { |level| refute gate(level).overridden?, level.inspect }

    record_override(result.proof.merge("body" => result.proof["body"].sub("hotfix", "hotfiX")))
    refute gate(nil).overridden?
  end

  def test_an_override_proof_for_another_reason_is_refused
    result = terminal(override_attrs(reason: "something else"))
    record_override(result.proof, reason: "hotfix")
    refute gate(nil).overridden?, "the proof signs another reason than the record states"
  end

  def test_step_approvals_are_verified_as_a_group
    result, = remote_approve(step_attrs)
    digest = Canonical.step_digest("run" => "echo hi")
    ChangeApprovalStore.new(SHA).record(steps: [ [ "boot.up", digest ] ], by: "t", proof: result.proof)
    check = ApprovalConsole::ProofCheck.new(level: "remote", store: @store)
    assert_nil check.approvals_problem(ChangeApprovalStore.new(SHA).entries, repo: repo_id, sha: SHA)

    ChangeApprovalStore.new(SHA).record(steps: [ [ "boot.down", "f" * 64 ] ], by: "t", proof: result.proof)
    problem = check.approvals_problem(ChangeApprovalStore.new(SHA).entries, repo: repo_id, sha: SHA)
    assert_match(/items do not match/, problem, "an entry riding on another approval's proof is refused")
  end

  FakeStdin = Struct.new(:tty?)

  # ----- CLI verbs -------------------------------------------------------

  def cli(argv, tty: true, env: {}, io: {}, reveal: StringIO.new)
    out = StringIO.new
    err = StringIO.new
    stdin = FakeStdin.new(tty)
    status = ApprovalConsoleCli.run(argv, stdin: stdin, stdout: out, stderr: err, env: env, store: @store, tty_open: -> { reveal },
                                          parents: -> { [] }, io: { client: client, clock: -> { @now } }.merge(io))
    [ status, out.string, err.string ]
  end

  def test_request_for_a_carve_out_waits_and_prints_the_verified_proof
    sleeper = lambda do |_s|
      body = pending_request_body
      phone_approve(body)
      @now += 3
    end
    status, out, err = cli(%W[request --type carve-out --summary merge --pr-url https://github.com/a/b/pull/1 --sha #{SHA} --repo #{@repo}],
                           io: { sleeper: sleeper })
    assert_equal 0, status, err
    assert_equal "webauthn+totp", JSON.parse(out)["kind"]
    assert_match(/approve on your phone/, err)
  end

  def test_request_needs_the_command_for_prod_op_and_a_console
    status, _, err = cli(%W[request --type prod-op --summary deploy --sha #{SHA}])
    assert_equal 2, status
    assert_match(/needs the command/, err)
    status, _, err = cli(%W[request --type money --summary x --sha #{SHA} -- echo], io: { client: nil })
    assert_equal 2, status
    assert_match(/no console/, err)
  end

  def test_request_no_wait_then_wait
    status, out, = cli(%W[request --type prod-op --summary deploy --sha #{SHA} --repo #{@repo} --no-wait -- terraform apply])
    assert_equal 0, status
    rid = JSON.parse(out)["request_id"]
    body = @store.saved_request(rid)
    assert_equal 200, phone_approve(body)
    status, out, err = cli(%W[wait #{rid}])
    assert_equal 0, status, err
    assert_equal %w[terraform apply], Canonical.parse(JSON.parse(out)["body"])["argv"]
  end

  def test_verify_reports_each_level
    @up = false
    record_override(terminal(override_attrs).proof)
    @up = true
    Dir.chdir(@repo) do
      status, out, = cli(%W[verify #{SHA}])
      assert_equal 0, status
      assert_match(/remote: override proof is refused: a console receipt is required/, out)
      assert_match(/local: pass/, out)
    end
  end

  # ----- enroll ----------------------------------------------------------

  class FakeOperator
    attr_reader :puts_made

    def initialize(receipt_pem:, creds: {}, url: "https://#{HOST}/")
      @receipt_pem = receipt_pem
      @creds = creds
      @url = url
      @puts_made = []
      @calls = 0
    end

    def function_url(_name) = @url
    def function_env(_name) = { "TABLE_NAME" => "t", "SEED_KEY_ID" => "seed", "RECEIPT_KEY_ID" => "receipt" }
    def encrypt_seed(_key, _seed, _mid, dir:) = "cipher"
    def receipt_public_pem(_key) = @receipt_pem

    def put_new(_table, item)
      @puts_made << item
      :created
    end

    def credentials(_table)
      @calls += 1
      @calls > 1 ? @creds.merge("new-cred" => "cose") : @creds
    end
  end

  def test_enroll_seeds_rows_shows_the_token_on_the_tty_only_and_pins
    operator = FakeOperator.new(receipt_pem: @signer.public_pem)
    reveal = StringIO.new
    status, out, err = cli(%W[enroll --url https://#{HOST}/ --profile personal], reveal: reveal,
                                                                                io: { operator: ->(**) { operator }, sleeper: ->(_) { } })
    assert_equal 0, status, err
    boot = operator.puts_made.find { |item| item["pk"].start_with?("BOOT#") }
    token = reveal.string[/token \(valid 15 minutes\): (\S+)/, 1]
    assert_equal "BOOT##{Digest::SHA256.hexdigest(token)}", boot["pk"]
    refute_includes out + err, token
    assert_equal %w[META SEED BOOT], operator.puts_made.map { |item| item["sk"] }
    assert_includes @store.pins["credentials"].keys, "new-cred"
  end

  def test_enroll_skips_the_token_when_a_passkey_exists_and_refuses_agents_and_bad_urls
    operator = FakeOperator.new(receipt_pem: @signer.public_pem, creds: @passkey.pinned)
    status, = cli(%W[enroll --url https://#{HOST}/ --profile personal], io: { operator: ->(**) { operator } })
    assert_equal 0, status
    assert_equal %w[META SEED], operator.puts_made.map { |item| item["sk"] }

    status, _, err = cli(%W[enroll --url https://#{HOST}/ --profile personal], env: { "CLAUDECODE" => "1" })
    assert_equal 2, status
    assert_match(/agent harness/, err)
    status, = cli(%w[enroll --url https://example.com/ --profile personal])
    assert_equal 1, status
  end

  def test_enroll_refuses_when_the_function_answers_on_another_url
    operator = FakeOperator.new(receipt_pem: @signer.public_pem, url: "https://other.lambda-url.us-east-1.on.aws/")
    status, _, err = cli(%W[enroll --url https://#{HOST}/ --profile personal], io: { operator: ->(**) { operator } })
    assert_equal 2, status
    assert_match(/answers on/, err)
    assert_empty operator.puts_made
  end
end
