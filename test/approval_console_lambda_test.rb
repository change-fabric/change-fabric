# frozen_string_literal: true

require "minitest/autorun"
require "securerandom"
require_relative "../approval_console/infra/lambda/console"
require_relative "../approval_console/infra/lambda/clients"
require_relative "support/soft_authenticator"
require_relative "../scripts/change_pr_facts"
require_relative "support/console_fakes"

class ApprovalConsoleLambdaTest < Minitest::Test
  Canonical = ApprovalConsole::Canonical
  Totp = ApprovalConsole::Totp

  HOST = "abc123.lambda-url.us-east-1.on.aws"
  MID = "11111111-2222-4333-8444-555555555555"
  OTHER_MID = "21111111-2222-4333-8444-555555555555"
  SHA = "a" * 40
  NOW = Time.utc(2026, 11, 19, 12, 0, 0)
  SEED = "0123456789abcdefghij"

  def setup
    @now = NOW
    @store = MemoryStore.new
    @signer = SoftReceiptSigner.new
    @kms = FakeKms.new(@signer)
    @dm = FakeDm.new
    @app = build_app
    @passkey = SoftAuthenticator.new
    @machine_key = OpenSSL::PKey::EC.generate("prime256v1")
    @counter = 0
    seed_machine(MID)
    @store.seed("pk" => "CRED", "sk" => @passkey.credential_id, "cose" => SoftAuthenticator.b64(@passkey.cose_public_key), "sign_count" => 0)
  end

  def build_app(qr: ->(_uri) { "<svg/>" })
    ApprovalConsoleApp.new(store: @store, kms: @kms, dm: @dm, clock: -> { @now }, qr: qr)
  end

  def seed_machine(mid, label: "mac-mini")
    @store.seed("pk" => "M##{mid}", "sk" => "META", "label" => label, "machine_key" => @machine_key.public_to_pem, "failures" => 0, "version" => 0)
    @store.seed("pk" => "M##{mid}", "sk" => "SEED", "ciphertext" => SoftAuthenticator.b64(@kms.encrypt(SEED, "machine_id" => mid)))
  end

  # ----- helpers ---------------------------------------------------------

  def event(method, path, body = nil, headers = {}, host: HOST)
    raw = body.nil? || body.is_a?(String) ? body : JSON.generate(body)
    { "requestContext" => { "http" => { "method" => method, "path" => path }, "domainName" => host }, "rawPath" => path, "headers" => headers, "body" => raw }
  end

  def call(*args, **kwargs)
    response = @app.call(event(*args, **kwargs))
    [ response[:statusCode], parse(response), response ]
  end

  def parse(response)
    JSON.parse(response[:body])
  rescue JSON::ParserError
    response[:body]
  end

  def signed_headers(method, path, body, key: @machine_key, at: @now.to_i)
    message = [ method, path, Digest::SHA256.hexdigest(body.to_s.b), at.to_s ].join("\n")
    { "x-cf-timestamp" => at.to_s, "x-cf-signature" => SoftAuthenticator.b64(key.sign("SHA256", message)) }
  end

  def signed(method, path, body = nil, **opts)
    raw = body.nil? || body.is_a?(String) ? body : JSON.generate(body)
    call(method, path, raw, signed_headers(method, path, raw, **opts))
  end

  def request_body(rid: SecureRandom.uuid, mid: MID, type: "carve-out", summary: "merge PR 9", created: "2026-11-19T11:55:00Z", expires: "2026-11-19T12:10:00Z")
    Canonical.build(type: type, machine_id: mid, repo: "repo:github.com/acme/app", sha: SHA, profile: nil, request_id: rid,
                    created_at: created, expires_at: expires, summary: summary, pr_url: "https://github.com/acme/app/pull/9",
                    pr_title: "Add a thing", base: "main", files: [ "scripts/a.rb", "scripts/b.rb" ])
  end

  def create_request(body = request_body)
    signed("POST", "/m/#{MID}/requests", { "body" => body })
  end

  def totp(offset = 0, now: @now) = Totp.code(SEED, Totp.step_for(now) + offset)

  def assertion(body, counter: nil, **opts)
    @counter += 1
    @passkey.assert(body, rp_id: HOST, counter: counter || @counter, **opts)
  end

  def approve(body, rid, code: totp, fields: nil)
    fields ||= assertion(body)
    call("POST", "/m/#{MID}/r/#{rid}/approve", fields.merge("totp" => code))
  end

  def pending_request(**opts)
    body = request_body(**opts)
    status, = create_request(body)
    assert_equal 201, status
    [ body, Canonical.parse(body)["request_id"] ]
  end

  def meta = @store.get("M##{MID}", "META")

  def verifier = ApprovalConsole::Verifier.new(rp_id: HOST, credentials: @passkey.pinned, receipt_public_key: @signer.public_pem)

  def expected_for(body)
    parsed = Canonical.parse(body)
    { type: parsed["type"], machine_id: MID, repo: parsed["repo"], sha: SHA, profile: nil, summary: parsed["summary"], pr_url: parsed["pr_url"],
      pr_title: parsed["pr_title"], base: parsed["base"], files: parsed["files"] }
  end

  # ----- requests --------------------------------------------------------

  def test_create_request_stores_it_sends_a_dm_and_is_idempotent
    body = request_body
    rid = Canonical.parse(body)["request_id"]
    status, data = create_request(body)
    assert_equal [ 201, "pending" ], [ status, data["status"] ]
    assert_equal "https://#{HOST}/m/#{MID}/r/#{rid}", data["url"]
    assert_equal 1, @dm.sent.size
    assert_includes @dm.sent.first, "carve-out"
    refute_includes @dm.sent.first, "merge PR 9", "the DM carries type, repo and short sha only"
    status, = create_request(body)
    assert_equal 200, status
    assert_equal 1, @dm.sent.size, "a retried create sends no second DM"
  end

  def test_create_request_with_a_different_body_for_the_same_id_conflicts
    body = request_body
    rid = Canonical.parse(body)["request_id"]
    create_request(body)
    status, data = create_request(request_body(rid: rid, summary: "something else"))
    assert_equal [ 409, "request_conflict" ], [ status, data["error"] ]
  end

  def test_create_request_rejects_unsigned_badly_signed_stale_and_unknown_machines
    body = JSON.generate("body" => request_body)
    path = "/m/#{MID}/requests"
    assert_equal 401, call("POST", path, body)[0]
    assert_equal 401, call("POST", path, body, signed_headers("POST", path, body, key: OpenSSL::PKey::EC.generate("prime256v1")))[0]
    assert_equal 401, call("POST", path, body, signed_headers("POST", path, body, at: @now.to_i - 301))[0]
    assert_equal 401, call("POST", path, body, signed_headers("POST", path, body).merge("x-cf-signature" => "!!"))[0]
    other = "/m/#{OTHER_MID}/requests"
    assert_equal 401, call("POST", other, body, signed_headers("POST", other, body))[0]
    assert_empty(@store.items.keys.grep(/REQ#/))
  end

  def test_a_signature_does_not_cover_a_different_body_or_path
    path = "/m/#{MID}/requests"
    headers = signed_headers("POST", path, JSON.generate("body" => request_body))
    assert_equal 401, call("POST", path, JSON.generate("body" => request_body(summary: "swapped")), headers)[0]
  end

  def test_create_request_rejects_bad_bodies
    assert_equal "invalid_body", signed("POST", "/m/#{MID}/requests", { "body" => "{}" })[1]["error"]
    assert_equal "bad_json", signed("POST", "/m/#{MID}/requests", "not json")[1]["error"]
    assert_equal "wrong_machine", signed("POST", "/m/#{MID}/requests", { "body" => request_body(mid: OTHER_MID) })[1]["error"]
    assert_equal "bad_window", create_request(request_body(created: "2026-11-19T11:00:00Z", expires: "2026-11-19T11:30:00Z"))[1]["error"]
    assert_equal "bad_window", create_request(request_body(created: "2026-11-19T13:00:00Z", expires: "2026-11-19T13:30:00Z"))[1]["error"]
  end

  def test_create_request_rejects_oversize_bodies_before_any_work
    status, data = call("POST", "/m/#{MID}/requests", "x" * (ApprovalConsoleApp::MAX_BODY + 1))
    assert_equal [ 413, "too_large" ], [ status, data["error"] ]
  end

  def carve_out_body(count, width: 60)
    files = Array.new(count) { |i| format("%<i>04d/", i: i) + ("d" * (width - 8)) + ".rb" }.sort
    [ files, {
      type: "carve-out", machine_id: MID, repo: "repo:github.com/acme/app", sha: SHA, profile: nil,
      request_id: SecureRandom.uuid, created_at: "2026-11-19T11:55:00Z", expires_at: "2026-11-19T12:10:00Z",
      summary: "merge PR 9", pr_url: "https://github.com/acme/app/pull/9", pr_title: "Big", base: "main", files: files
    } ]
  end

  def carve_out_with_files(count, width: 60) = Canonical.build(carve_out_body(count, width: width).last)

  def test_a_3000_file_carve_out_with_60_character_paths_is_accepted
    body = carve_out_with_files(Canonical::MAX_FILES)
    raw = JSON.generate("body" => body)
    assert_operator raw.bytesize, :>, 32 * 1024
    assert_operator raw.bytesize, :<, ApprovalConsoleApp::MAX_BODY
    assert_equal 201, create_request(body)[0]
  end

  def test_a_body_of_about_290_kb_passes_and_about_500_kb_is_refused_at_build_time
    assert carve_out_with_files(1430, width: 200).bytesize.between?(280_000, Canonical::MAX_CANONICAL_BYTES)
    _, attrs = carve_out_body(2500, width: 200)
    error = assert_raises(Canonical::Invalid) { Canonical.build(attrs) }
    assert_match(/body is \d{6} bytes \(2500 files\), over the 300000-byte limit/, error.message)
  end

  def test_the_server_refuses_an_oversize_body_before_any_store_write
    files, attrs = carve_out_body(2500, width: 200)
    oversize = Canonical.serialize(attrs.merge(v: 1))
    assert_operator oversize.bytesize, :>, 450_000
    assert_equal 2500, files.size
    before = @store.items.dup
    status, data = signed("POST", "/m/#{MID}/requests", { "body" => oversize })
    assert_includes [ 400, 413 ], status
    assert_equal "invalid_body", data["error"] if status == 400
    assert_equal before, @store.items, "nothing was written"
    assert_empty @dm.sent
  end

  def test_a_request_one_byte_over_the_limit_is_still_413
    over = "x" * (ApprovalConsoleApp::MAX_BODY + 1)
    assert_equal 413, call("POST", "/m/#{MID}/requests", over)[0]
    exact = "x" * ApprovalConsoleApp::MAX_BODY
    refute_equal 413, call("POST", "/m/#{MID}/requests", exact)[0]
  end

  def test_the_file_count_and_body_limits_are_shared_between_client_and_server
    assert_equal ApprovalConsole::Canonical::MAX_REQUEST_BYTES, ApprovalConsoleApp::MAX_BODY
    assert_equal ApprovalConsole::Canonical::MAX_FILES, ChangePrFacts::MAX_FILES
    assert_operator ApprovalConsoleApp::MAX_BODY, :<, 6 * 1024 * 1024
  end

  def test_more_than_the_file_limit_is_not_a_valid_body
    assert_raises(Canonical::Invalid) { carve_out_with_files(Canonical::MAX_FILES + 1) }
  end

  def test_requests_are_limited_per_machine_per_hour
    20.times { assert_equal 201, create_request(request_body)[0] }
    status, data = create_request(request_body)
    assert_equal [ 429, "rate_limited" ], [ status, data["error"] ]
    assert_equal 20, @dm.sent.size, "the refused request sent no DM"
    @now += 3600
    assert_equal 201, create_request(request_body(created: "2026-11-19T12:55:00Z", expires: "2026-11-19T13:10:00Z"))[0]
  end

  # ----- the approval page -----------------------------------------------

  def test_page_renders_every_field_with_a_strict_csp_and_no_store
    _, rid = pending_request(summary: "<script>alert(1)</script> & more")
    status, html, response = call("GET", "/m/#{MID}/r/#{rid}")
    headers = response[:headers]
    assert_equal 200, status
    assert_equal "no-store", headers["cache-control"]
    csp = headers["content-security-policy"]
    nonce = csp[/script-src 'nonce-([^']+)'/, 1]
    assert_includes csp, "default-src 'none'"
    assert_includes csp, "frame-ancestors 'none'"
    refute_match(/unsafe-inline|unsafe-eval|\*|https?:/, csp)
    assert_includes html, "&lt;script&gt;alert(1)&lt;/script&gt; &amp; more"
    refute_includes html, "<script>alert(1)"
    refute_match(/<script[^>]*\ssrc=/i, html, "no external or same-origin script files")
    refute_match(%r{src="https?://}i, html)
    assert(html.scan(/href="([^"]*)"/).flatten.all? { |url| url.start_with?("https://github.com/acme/app/") }, "links only point at the signed repo")
    tags = html.scan(/<(?:script|style)\b[^>]*>/)
    refute_empty tags
    assert(tags.all? { |tag| tag.include?(%(nonce="#{nonce}")) }, "every script and style carries the response nonce")
    %w[type machine_id repo sha request_id created_at expires_at summary pr_url].each { |field| assert_includes html, %(data-field="#{field}") }
    assert_includes html, SHA
    assert_includes html, "userVerification:'required'"
  end

  def test_page_for_an_unknown_request_is_a_404_and_an_expired_one_offers_no_button
    assert_equal 404, call("GET", "/m/#{MID}/r/#{SecureRandom.uuid}")[0]
    _, rid = pending_request
    @now += 3600
    _, html, = call("GET", "/m/#{MID}/r/#{rid}")
    assert_includes html, "This request expired at"
    refute_includes html, 'id="go"'
  end

  # ----- the phone page shows only signed fields --------------------------

  def page_html(body)
    _, rid = [ body, Canonical.parse(body)["request_id"] ]
    create_request(body)
    _, _, response = call("GET", "/m/#{MID}/r/#{rid}")
    response[:body]
  end

  def test_the_page_lists_the_signed_files_base_and_title_with_links_from_signed_fields
    html = page_html(request_body)
    assert_includes html, %(<li><code data-field="files.0">scripts/a.rb</code></li>)
    assert_includes html, %(<li><code data-field="files.1">scripts/b.rb</code></li>)
    assert_includes html, %(<code data-field="base">main</code>)
    assert_includes html, %(<q data-field="pr_title">Add a thing</q>)
    assert_includes html, 'href="https://github.com/acme/app/commit/' + SHA + '"'
    assert_includes html, 'href="https://github.com/acme/app/pull/9"'
  end

  def test_a_release_page_links_the_tag_and_the_commit
    body = Canonical.build(type: "release", machine_id: MID, repo: "repo:github.com/acme/app", sha: SHA, profile: nil,
                           request_id: SecureRandom.uuid, created_at: "2026-11-19T11:55:00Z", expires_at: "2026-11-19T12:10:00Z",
                           tag: "skills/v1.2.3 beta", commit: SHA)
    html = page_html(body)
    assert_includes html, 'href="https://github.com/acme/app/releases/tag/skills%2Fv1.2.3%20beta"'
    assert_includes html, 'href="https://github.com/acme/app/commit/' + SHA + '"'
  end

  def test_no_link_is_built_from_a_pr_url_for_another_repo_or_host_or_a_non_github_repo
    ConsolePages.links("repo" => "repo:github.com/acme/app", "sha" => SHA, "pr_url" => "https://github.com/evil/app/pull/9").tap do |links|
      refute(links.any? { |_, url| url.include?("evil") })
      assert_equal [ "Commit on GitHub" ], links.map(&:first)
    end
    assert_empty ConsolePages.links("repo" => "repo:gitlab.com/acme/app", "sha" => SHA)
    assert_empty ConsolePages.links("repo" => "repo:github.com/acme/app/../x", "sha" => SHA)
    assert_empty ConsolePages.links("repo" => "not a repo", "sha" => SHA)
    refute(ConsolePages.links("repo" => "repo:github.com/a/b", "sha" => "zz").any? { |label, _| label == "Commit on GitHub" })
  end

  def test_agent_text_never_reaches_a_link_or_the_markup_unescaped
    body = request_body(summary: '<a href="https://evil.example">click</a>')
    html = page_html(body)
    refute_includes html, 'href="https://evil.example"'
    assert_includes html, "&lt;a href=&quot;https://evil.example&quot;&gt;"
    assert_equal 2, html.scan('rel="noopener noreferrer"').size
  end

  # ----- approve ---------------------------------------------------------

  def test_approve_commits_one_transaction_and_returns_a_proof_that_verifies_offline
    body, rid = pending_request
    status, data = approve(body, rid)
    assert_equal 200, status
    proof = data["proof"]
    result = verifier.verify(proof, expected: expected_for(body), require_receipt: true)
    assert result.ok?, result.reason
    assert_equal :receipt, result.level
    assert_equal "approved", @store.get("M##{MID}", "REQ##{rid}")["status"]
    assert_equal Totp.step_for(@now), meta["last_step"]
    assert_equal 1, meta["version"]
    assert_equal proof, @store.get("M##{MID}", "REC##{rid}")["proof"]
    assert_equal @counter, @store.get("CRED", @passkey.credential_id)["sign_count"]
    channel = JSON.parse(proof["receipt"]["payload"])["channel"]
    assert_equal "console", channel
  end

  def test_the_receipt_is_a_kms_signature_over_the_canonical_payload
    body, rid = pending_request
    proof = approve(body, rid)[1]["proof"]
    payload = proof["receipt"]["payload"]
    assert_equal Canonical.serialize(JSON.parse(payload)), payload
    signature = Base64.urlsafe_decode64(proof["receipt"]["sig"])
    assert OpenSSL::PKey.read(@signer.public_pem).verify("SHA256", signature, payload)
    refute OpenSSL::PKey.read(@signer.public_pem).verify("SHA256", signature, payload.sub("console", "terminal"))
    assert_equal "arn:aws:kms:test:key/receipts", proof["receipt"]["key_id"]
  end

  def test_approve_with_a_wrong_code_fails_counts_a_failure_and_commits_nothing
    body, rid = pending_request
    status, data = approve(body, rid, code: "000000")
    assert_equal [ 401, "totp_invalid" ], [ status, data["error"] ]
    assert_equal 1, meta["failures"]
    assert_equal "pending", @store.get("M##{MID}", "REQ##{rid}")["status"]
    assert_nil @store.get("M##{MID}", "REC##{rid}")
    assert_equal 0, @kms.signs, "no receipt is signed for a refused approval"
  end

  def test_approve_rejects_a_malformed_code
    body, rid = pending_request
    assert_equal "totp_invalid", approve(body, rid, code: "12ab")[1]["error"]
    assert_equal "totp_invalid", approve(body, rid, code: nil)[1]["error"]
  end

  def test_a_replayed_step_is_refused_across_requests
    body, rid = pending_request
    assert_equal 200, approve(body, rid)[0]
    body2, rid2 = pending_request
    status, data = approve(body2, rid2)
    assert_equal [ 409, "replay" ], [ status, data["error"] ]
    @now += 30
    assert_equal 200, approve(body2, rid2, code: totp)[0], "the next step is accepted"
  end

  def test_five_failures_lock_the_machine_and_doubling_applies
    body, rid = pending_request(expires: "2026-11-19T12:50:00Z")
    4.times { assert_equal 401, approve(body, rid, code: "000000")[0] }
    assert_equal 401, approve(body, rid, code: "000000")[0]
    assert_equal "2026-11-19T12:15:00Z", meta["locked_until"]
    status, data = approve(body, rid)
    assert_equal [ 423, "locked" ], [ status, data["error"] ]
    assert_equal "2026-11-19T12:15:00Z", data["locked_until"]
    @now += 901
    assert_equal 200, approve(body, rid)[0]
    assert_equal 0, meta["failures"]
    assert_nil meta["locked_until"]
  end

  def test_a_second_lockout_doubles_the_wait_and_a_machine_without_a_seed_is_refused
    body, rid = pending_request(expires: "2026-11-19T12:50:00Z")
    5.times { approve(body, rid, code: "000000") }
    @now += 901
    5.times { approve(body, rid, code: "000000") }
    assert_equal "2026-11-19T12:45:01Z", meta["locked_until"]
    @store.items.delete([ "M##{MID}", "SEED" ])
    @now += 1801
    status, data = approve(body, rid)
    assert_equal [ 409, "no_seed" ], [ status, data["error"] ]
  end

  def test_late_submission_after_the_server_clock_passes_expiry_is_refused
    body, rid = pending_request
    @now = Time.utc(2026, 11, 19, 12, 10, 1)
    status, data = approve(body, rid)
    assert_equal [ 410, "expired" ], [ status, data["error"] ]
    assert_equal "pending", @store.get("M##{MID}", "REQ##{rid}")["status"], "TTL is cleanup, the deadline is the clock"
  end

  def test_a_request_not_yet_valid_is_refused
    body, rid = pending_request(created: "2026-11-19T12:03:00Z", expires: "2026-11-19T12:20:00Z")
    assert_equal 410, approve(body, rid)[0]
  end

  def test_approve_rejects_every_bad_assertion
    body, rid = pending_request
    other = SoftAuthenticator.new
    cases = {
      "uv clear" => assertion(body, uv: false),
      "up clear" => assertion(body, up: false),
      "wrong challenge" => assertion(body, challenge: Digest::SHA256.digest("other")),
      "wrong origin" => assertion(body, origin: "https://evil.example"),
      "wrong rp id hash" => assertion(body, hash_rp_id: "evil.example"),
      "wrong type" => assertion(body, type: "webauthn.create"),
      "signed with another key" => assertion(body, sign_key: other.key),
      "other body" => assertion(request_body)
    }
    cases.each do |name, fields|
      @store.seed(meta.merge("failures" => 0, "locked_until" => nil))
      status, data = approve(body, rid, fields: fields)
      assert_equal [ 401, "assertion_invalid" ], [ status, data["error"] ], name
      assert_equal 1, meta["failures"], "#{name} counts one failure"
    end
    assert_equal "pending", @store.get("M##{MID}", "REQ##{rid}")["status"]
  end

  def test_approve_rejects_an_unpinned_credential_and_a_counter_regression
    body, rid = pending_request
    stranger = SoftAuthenticator.new
    forged = stranger.assert(body, rp_id: HOST)
    assert_equal 401, approve(body, rid, fields: forged)[0]
    assert_equal 200, approve(body, rid, fields: assertion(body, counter: 5))[0]
    body2, rid2 = pending_request
    @now += 30
    status, data = approve(body2, rid2, fields: assertion(body2, counter: 5), code: totp)
    assert_equal [ 401, "assertion_invalid" ], [ status, data["error"] ]
    assert_equal 200, approve(body2, rid2, fields: assertion(body2, counter: 6), code: totp)[0]
  end

  def test_a_zero_counter_is_accepted_when_the_credential_never_counts
    body, rid = pending_request
    assert_equal 200, approve(body, rid, fields: @passkey.assert(body, rp_id: HOST, counter: 0))[0]
  end

  def test_approve_unknown_request_and_bad_json
    assert_equal 404, call("POST", "/m/#{MID}/r/#{SecureRandom.uuid}/approve", "{}")[0]
    _, rid = pending_request
    assert_equal 400, call("POST", "/m/#{MID}/r/#{rid}/approve", "nope")[0]
    assert_equal 404, call("POST", "/m/#{OTHER_MID}/r/#{rid}/approve", "{}")[0]
  end

  def test_a_retry_of_an_approved_request_returns_the_stored_record_to_the_same_assertion_only
    body, rid = pending_request
    fields = assertion(body)
    first = approve(body, rid, fields: fields)[1]["proof"]
    again = approve(body, rid, fields: fields, code: "000000")
    assert_equal [ 200, first ], [ again[0], again[1]["proof"] ]
    assert_equal 1, @kms.signs
    status, data = approve(body, rid, fields: assertion(body))
    assert_equal [ 409, "not_pending" ], [ status, data["error"] ]
  end

  # ----- fault injection and the cross-channel fence ---------------------

  def test_a_crash_before_commit_leaves_nothing_and_the_retry_succeeds
    body, rid = pending_request
    @store.before_commit = true
    assert_raises(RuntimeError) { approve(body, rid) }
    assert_nil @store.get("M##{MID}", "REC##{rid}")
    assert_nil meta["last_step"], "the step is not consumed"
    assert_equal 200, approve(body, rid)[0]
  end

  def test_a_crash_after_commit_but_before_the_response_is_recovered_by_a_retry
    body, rid = pending_request
    fields = assertion(body)
    @store.after_commit = true
    assert_raises(RuntimeError) { approve(body, rid, fields: fields) }
    stored = @store.get("M##{MID}", "REC##{rid}")["proof"]
    status, data = approve(body, rid, fields: fields)
    assert_equal [ 200, stored ], [ status, data["proof"] ]
    assert_equal 1, meta["version"], "committed exactly once"
  end

  def test_duplicate_submissions_yield_one_approval
    body, rid = pending_request
    fields = assertion(body)
    results = Array.new(4) { Thread.new { approve(body, rid, fields: fields) } }.map(&:value)
    assert(results.all? { |status, _| status == 200 })
    assert_equal 1, results.map { |_, data| data["proof"]["receipt"]["payload"] }.uniq.size
    assert_equal 1, meta["version"]
  end

  def test_concurrent_phone_and_terminal_approvals_at_one_step_yield_one_success
    @store.read_delay = 0.01
    body, rid = pending_request
    tbody = request_body
    code = totp
    fields = assertion(body)
    phone = Thread.new { approve(body, rid, fields: fields, code: code) }
    terminal = Thread.new { signed("POST", "/m/#{MID}/terminal-approve", { "body" => tbody, "code" => code }) }
    statuses = [ phone.value[0], terminal.value[0] ].sort
    assert_equal [ 200, 409 ], statuses
    assert_equal 1, @store.items.keys.count { |pk, sk| pk == "M##{MID}" && sk.start_with?("REC#") }
  end

  # ----- terminal approvals and sync -------------------------------------

  def test_terminal_approve_returns_a_terminal_receipt_that_verifies_offline
    carve = request_body
    status, data = signed("POST", "/m/#{MID}/terminal-approve", { "body" => carve, "code" => totp })
    assert_equal 200, status
    proof = data["proof"]
    assert_equal "totp-terminal", proof["kind"]
    assert_equal "terminal", JSON.parse(proof["receipt"]["payload"])["channel"]
    result = verifier.verify(proof, expected: expected_for(carve), require_receipt: true)
    assert result.ok?, result.reason
    assert_equal :receipt, result.level
  end

  def test_terminal_approve_is_idempotent_and_conflicts_on_a_different_body_for_the_same_id
    body = request_body
    rid = Canonical.parse(body)["request_id"]
    first = signed("POST", "/m/#{MID}/terminal-approve", { "body" => body, "code" => totp })
    again = signed("POST", "/m/#{MID}/terminal-approve", { "body" => body, "code" => "000000" })
    assert_equal [ 200, first[1]["proof"] ], [ again[0], again[1]["proof"] ]
    status, data = signed("POST", "/m/#{MID}/terminal-approve", { "body" => request_body(rid: rid, summary: "other"), "code" => totp })
    assert_equal [ 409, "request_conflict" ], [ status, data["error"] ]
  end

  def test_a_terminal_approval_closes_the_pending_request_for_the_phone
    body, rid = pending_request
    assert_equal 200, signed("POST", "/m/#{MID}/terminal-approve", { "body" => body, "code" => totp })[0]
    assert_equal "approved", @store.get("M##{MID}", "REQ##{rid}")["status"]
    assert_equal "terminal", @store.get("M##{MID}", "REQ##{rid}")["channel"]
    assert_includes call("GET", "/m/#{MID}/r/#{rid}")[1], "Already approved."
    @now += 30
    status, data = approve(body, rid)
    assert_equal [ 409, "not_pending" ], [ status, data["error"] ]
    assert_equal 409, call("POST", "/m/#{MID}/r/#{rid}/approve", { "totp" => totp }.to_json)[0], "an absent signature does not match a terminal proof"
    assert_equal "approved", signed("GET", "/m/#{MID}/r/#{rid}/proof")[1]["status"]
  end

  def test_a_terminal_approval_of_a_different_body_for_a_requested_id_is_refused
    body, rid = pending_request
    other = request_body(rid: rid, summary: "changed")
    status, data = signed("POST", "/m/#{MID}/terminal-approve", { "body" => other, "code" => totp })
    assert_equal [ 409, "request_conflict" ], [ status, data["error"] ]
    assert_equal "pending", @store.get("M##{MID}", "REQ##{rid}")["status"]
    assert_nil @store.get("M##{MID}", "REC##{rid}")
  end

  def test_sync_also_closes_a_pending_request
    body, rid = pending_request
    step = Totp.step_for(@now) - 2
    assert_equal 200, signed("POST", "/m/#{MID}/sync", { "body" => body, "code" => Totp.code(SEED, step), "step" => step })[0]
    assert_equal "approved", @store.get("M##{MID}", "REQ##{rid}")["status"]
  end

  def test_terminal_approve_refusals
    body = request_body
    path = "/m/#{MID}/terminal-approve"
    assert_equal 401, call("POST", path, JSON.generate("body" => body, "code" => totp))[0]
    assert_equal "totp_invalid", signed("POST", path, { "body" => body, "code" => "000000" })[1]["error"]
    assert_equal "wrong_machine", signed("POST", path, { "body" => request_body(mid: OTHER_MID), "code" => totp })[1]["error"]
    assert_equal "invalid_body", signed("POST", path, { "body" => "x", "code" => totp })[1]["error"]
    late = request_body(created: "2026-11-19T10:00:00Z", expires: "2026-11-19T10:30:00Z")
    assert_equal "expired", signed("POST", path, { "body" => late, "code" => totp })[1]["error"]
    assert_equal 1, meta["failures"]
    assert_equal 200, signed("POST", path, { "body" => body, "code" => totp })[0]
    assert_equal "replay", signed("POST", path, { "body" => request_body, "code" => totp })[1]["error"]
  end

  def test_terminal_approve_rechecks_the_lock_on_freshly_read_metadata
    count = 0
    original = @store.method(:get)
    locked = ->(store) { store.seed(meta.merge("locked_until" => "2026-11-19T12:30:00Z", "version" => 5)) }
    @store.define_singleton_method(:get) do |pk, sk|
      row = original.call(pk, sk)
      locked.call(self) if sk == "META" && (count += 1) == 1
      row
    end
    status, data = signed("POST", "/m/#{MID}/terminal-approve", { "body" => request_body, "code" => totp })
    assert_equal [ 423, "locked" ], [ status, data["error"] ]
    assert_equal "2026-11-19T12:30:00Z", meta["locked_until"], "the concurrent lockout is not cleared"
  end

  def test_terminal_failures_lock_the_machine_for_both_channels
    path = "/m/#{MID}/terminal-approve"
    5.times { signed("POST", path, { "body" => request_body, "code" => "000000" }) }
    assert_equal "locked", signed("POST", path, { "body" => request_body, "code" => totp })[1]["error"]
    body, rid = pending_request
    assert_equal 423, approve(body, rid)[0]
  end

  def test_sync_accepts_a_past_step_inside_the_grace_and_rejects_the_rest
    body = request_body
    step = Totp.step_for(@now) - 2
    code = Totp.code(SEED, step)
    path = "/m/#{MID}/sync"
    status, data = signed("POST", path, { "body" => body, "code" => code, "step" => step })
    assert_equal 200, status
    assert_equal step, data["proof"]["totp_step"]
    assert_equal step, meta["last_step"]
    older = Totp.step_for(@now) - 3
    status, data = signed("POST", path, { "body" => request_body, "code" => Totp.code(SEED, older), "step" => older })
    assert_equal [ 409, "conflict" ], [ status, data["error"] ]
    assert_equal 0, meta["failures"], "a sync conflict is not a guess"
    assert_equal "totp_invalid", signed("POST", path, { "body" => request_body, "code" => "000000", "step" => step + 1 })[1]["error"]
  end

  def test_sync_enforces_grace_window_and_step_shape
    path = "/m/#{MID}/sync"
    old = Totp.step_for(@now) - 3000
    assert_equal "outside_grace", signed("POST", path, { "body" => request_body, "code" => Totp.code(SEED, old), "step" => old })[1]["error"]
    future = Totp.step_for(@now) + 5
    assert_equal "outside_grace", signed("POST", path, { "body" => request_body, "code" => Totp.code(SEED, future), "step" => future })[1]["error"]
    step = Totp.step_for(@now) - 100
    outside = request_body(created: "2026-11-19T11:59:00Z", expires: "2026-11-19T12:09:00Z")
    assert_equal "outside_window", signed("POST", path, { "body" => outside, "code" => Totp.code(SEED, step), "step" => step })[1]["error"]
    assert_equal "bad_step", signed("POST", path, { "body" => request_body, "code" => "123456", "step" => "7" })[1]["error"]
    assert_equal "bad_step", signed("POST", path, { "body" => request_body, "code" => "123456" })[1]["error"]
  end

  # ----- proof polling ---------------------------------------------------

  def test_proof_route_reports_pending_approved_expired_and_requires_a_signature
    body, rid = pending_request
    path = "/m/#{MID}/r/#{rid}/proof"
    assert_equal 401, call("GET", path)[0]
    assert_equal({ "status" => "pending" }, signed("GET", path)[1])
    approve(body, rid)
    status, data = signed("GET", path)
    assert_equal [ 200, "approved" ], [ status, data["status"] ]
    assert_equal "webauthn+totp", data["proof"]["kind"]
    _, rid2 = pending_request
    @now += 3600
    assert_equal "expired", signed("GET", "/m/#{MID}/r/#{rid2}/proof")[1]["status"]
    assert_equal 404, signed("GET", "/m/#{MID}/r/#{SecureRandom.uuid}/proof")[0]
  end

  # ----- registration ----------------------------------------------------

  def boot(token = "t" * 32, machine: MID, valid_until: @now.to_i + 900)
    @store.seed("pk" => "BOOT##{Digest::SHA256.hexdigest(token)}", "sk" => "BOOT", "machine_id" => machine, "valid_until" => valid_until)
    token
  end

  def attestation(auth, challenge, fmt: "none", type: "webauthn.create", origin: "https://#{HOST}", rp: HOST, flags: 0x45, id: nil, cose: nil)
    cred_id = Base64.urlsafe_decode64(auth.credential_id + "=" * ((4 - (auth.credential_id.length % 4)) % 4))
    data = Digest::SHA256.digest(rp) + [ flags, 0 ].pack("CN") + ("\x00".b * 16) + [ cred_id.bytesize ].pack("n") + cred_id + (cose || auth.cose_public_key)
    client = JSON.generate("type" => type, "challenge" => challenge, "origin" => origin)
    object = auth.encode({ "fmt" => fmt, "attStmt" => {}, "authData" => data.b })
    { "id" => id || auth.credential_id, "client_data_json" => SoftAuthenticator.b64(client), "attestation_object" => SoftAuthenticator.b64(object) }
  end

  def options_for(token, extra = {})
    call("POST", "/register/options", { "token" => token }.merge(extra))
  end

  def test_first_registration_needs_only_the_token_and_consumes_it
    @store.items.delete([ "CRED", @passkey.credential_id ])
    token = boot
    status, options = options_for(token)
    assert_equal 200, status
    assert_equal HOST, options["publicKey"]["rp"]["id"]
    assert_equal "required", options["publicKey"]["authenticatorSelection"]["userVerification"]
    fresh = SoftAuthenticator.new
    status, data = call("POST", "/register/verify", { "token" => token, "label" => "phone" }.merge(attestation(fresh, options["publicKey"]["challenge"])))
    assert_equal [ 200, fresh.credential_id ], [ status, data["credential_id"] ]
    row = @store.get("CRED", fresh.credential_id)
    assert_equal SoftAuthenticator.b64(fresh.cose_public_key), row["cose"]
    assert_equal 401, options_for(token)[0], "the token is single use"
  end

  def test_two_tokens_issued_while_empty_cannot_both_register_a_first_credential
    @store.items.delete([ "CRED", @passkey.credential_id ])
    first = boot("a" * 32)
    second = boot("b" * 32)
    challenge_a = options_for(first)[1]["publicKey"]["challenge"]
    challenge_b = options_for(second)[1]["publicKey"]["challenge"]
    winner = SoftAuthenticator.new
    assert_equal 200, call("POST", "/register/verify", { "token" => first }.merge(attestation(winner, challenge_a)))[0]
    late = call("POST", "/register/verify", { "token" => second }.merge(attestation(SoftAuthenticator.new, challenge_b)))
    assert_equal [ 401, "assertion_required" ], [ late[0], late[1]["error"] ]
    assert_equal [ winner.credential_id ], @store.query("CRED").map { |row| row["sk"] }
    assert @store.get("BOOT##{Digest::SHA256.hexdigest('b' * 32)}", "BOOT"), "the refused token is not consumed"
  end

  def test_a_token_that_was_authorized_by_an_assertion_may_add_a_credential
    token = boot
    source = "cf-add-credential:#{options_for(token)[1]['token_hash']}"
    options = options_for(token, "assertion" => @passkey.assert(source, rp_id: HOST, counter: 1))[1]
    extra = SoftAuthenticator.new
    assert_equal 200, call("POST", "/register/verify", { "token" => token }.merge(attestation(extra, options["publicKey"]["challenge"])))[0]
    assert_equal 2, @store.query("CRED").size
  end

  def test_registration_rejects_unknown_or_expired_tokens
    assert_equal "invalid_token", options_for("z" * 32)[1]["error"]
    assert_equal "bad_token", options_for("short")[1]["error"]
    expired = boot("e" * 32, valid_until: @now.to_i - 1)
    assert_equal "invalid_token", options_for(expired)[1]["error"]
    assert_equal 401, call("POST", "/register/verify", { "token" => expired })[0]
  end

  def test_a_second_credential_needs_an_assertion_from_an_existing_one
    token = boot
    status, data = options_for(token)
    assert_equal [ 401, "assertion_required" ], [ status, data["error"] ]
    assert_equal [ @passkey.credential_id ], data["credentials"]
    source = "cf-add-credential:#{data['token_hash']}"
    bad = options_for(token, "assertion" => SoftAuthenticator.new.assert(source, rp_id: HOST))
    assert_equal [ 401, "assertion_invalid" ], [ bad[0], bad[1]["error"] ]
    good = options_for(token, "assertion" => @passkey.assert(source, rp_id: HOST, counter: 1))
    assert_equal 200, good[0]
    assert_includes good[1]["publicKey"]["excludeCredentials"].map { |c| c["id"] }, @passkey.credential_id
  end

  def test_registration_verify_rejects_every_bad_attestation
    @store.items.delete([ "CRED", @passkey.credential_id ])
    token = boot
    challenge = options_for(token)[1]["publicKey"]["challenge"]
    fresh = SoftAuthenticator.new
    bad_cose = fresh.encode({ 1 => 2, 3 => -7, -1 => 1, -2 => "x".b, -3 => "y".b })
    cases = {
      "wrong challenge" => attestation(fresh, "AAAA"),
      "wrong origin" => attestation(fresh, challenge, origin: "https://evil.example"),
      "wrong type" => attestation(fresh, challenge, type: "webauthn.get"),
      "wrong rp hash" => attestation(fresh, challenge, rp: "evil.example"),
      "no uv" => attestation(fresh, challenge, flags: 0x41),
      "no attested data" => attestation(fresh, challenge, flags: 0x05),
      "attestation not none" => attestation(fresh, challenge, fmt: "packed"),
      "id mismatch" => attestation(fresh, challenge, id: SoftAuthenticator.new.credential_id),
      "bad cose key" => attestation(fresh, challenge, cose: bad_cose)
    }
    cases.each do |name, fields|
      status, data = call("POST", "/register/verify", { "token" => token }.merge(fields))
      assert_equal [ 400, "registration_invalid" ], [ status, data["error"] ], name
    end
    assert_empty @store.query("CRED")
    assert_equal 400, call("POST", "/register/verify", { "token" => token, "id" => "x", "client_data_json" => "!", "attestation_object" => "!" })[0]
  end

  def test_verify_without_an_options_call_has_no_challenge
    token = boot
    assert_equal "no_challenge", call("POST", "/register/verify", { "token" => token })[1]["error"]
  end

  def test_the_register_page_is_served_under_the_same_page_rules
    status, html, response = call("GET", "/register")
    assert_equal 200, status
    assert_equal "no-store", response[:headers]["cache-control"]
    assert_includes html, "navigator.credentials.create"
  end

  # ----- the one-time TOTP reveal ----------------------------------------

  def enroll_challenge
    html = call("GET", "/m/#{MID}/totp-enroll")[1]
    JSON.parse(html[%r{<script type="application/json" id="d"[^>]*>(.*?)</script>}m, 1])
  end

  def reveal(challenge, fields = nil)
    source = "cf-totp-enroll:#{MID}:#{challenge}"
    fields ||= @passkey.assert(source, rp_id: HOST, counter: (@counter += 1))
    call("POST", "/m/#{MID}/totp-enroll", fields.merge("challenge_id" => challenge))
  end

  def test_the_seed_is_shown_once_after_a_passkey_assertion
    data = enroll_challenge
    refute_empty data["challenge_id"]
    status, secret = reveal(data["challenge_id"])
    assert_equal 200, status
    assert_equal ApprovalConsole::Base32.encode(SEED), secret["secret"]
    assert_equal "otpauth://totp/cf:mac-mini?secret=#{secret['secret']}&issuer=cf", secret["uri"]
    assert_equal Base64.strict_encode64("<svg/>"), secret["qr_svg_b64"]
    _, html, response = call("GET", "/m/#{MID}/totp-enroll")
    assert_includes html, "already shown once"
    assert_equal "no-store", response[:headers]["cache-control"]
    assert_equal 401, reveal(data["challenge_id"])[0], "the challenge is consumed"
  end

  def test_the_reveal_refuses_without_a_valid_assertion_or_challenge
    data = enroll_challenge
    cid = data["challenge_id"]
    assert_equal "challenge_invalid", call("POST", "/m/#{MID}/totp-enroll", { "challenge_id" => "f" * 32 })[1]["error"]
    assert_equal "challenge_invalid", call("POST", "/m/#{MID}/totp-enroll", {})[1]["error"]
    assert_equal "assertion_invalid", call("POST", "/m/#{MID}/totp-enroll", { "challenge_id" => cid })[1]["error"]
    wrong = SoftAuthenticator.new.assert("cf-totp-enroll:#{MID}:#{cid}", rp_id: HOST)
    assert_equal "assertion_invalid", reveal(cid, wrong)[1]["error"]
    other = @passkey.assert("cf-totp-enroll:#{MID}:#{'0' * 32}", rp_id: HOST, counter: 9)
    assert_equal "assertion_invalid", reveal(cid, other)[1]["error"]
    assert_nil @store.get("M##{MID}", "SEED")["shown_at"]
    @now += 301
    assert_equal "challenge_invalid", reveal(cid)[1]["error"]
  end

  def test_the_reveal_page_for_a_machine_without_a_seed_is_404
    assert_equal 404, call("GET", "/m/#{OTHER_MID}/totp-enroll")[0]
  end

  def test_decrypt_uses_the_machine_id_context
    seed_machine(OTHER_MID)
    @store.seed("pk" => "M##{OTHER_MID}", "sk" => "SEED", "ciphertext" => SoftAuthenticator.b64(@kms.encrypt(SEED, "machine_id" => MID)))
    cid = SecureRandom.hex(16)
    @store.seed("pk" => "M##{OTHER_MID}", "sk" => "ENR##{cid}", "valid_until" => @now.to_i + 60)
    fields = @passkey.assert("cf-totp-enroll:#{OTHER_MID}:#{cid}", rp_id: HOST, counter: 3)
    assert_raises(RuntimeError) { call("POST", "/m/#{OTHER_MID}/totp-enroll", fields.merge("challenge_id" => cid)) }
  end

  # ----- routing and wiring ----------------------------------------------

  def test_unknown_routes_and_methods_are_404
    assert_equal 404, call("GET", "/")[0]
    assert_equal 404, call("GET", "/m/not-a-uuid/r/x")[0]
    assert_equal 404, call("DELETE", "/m/#{MID}/requests")[0]
    assert_equal 404, call("GET", "/m/#{MID}/unknown")[0]
    assert_equal 404, call("PUT", "/m/#{MID}/r/#{SecureRandom.uuid}/approve")[0]
  end

  def test_events_without_a_host_are_refused
    assert_equal 400, @app.call({ "requestContext" => { "http" => { "method" => "GET", "path" => "/register" } } })[:statusCode]
  end

  def test_logs_carry_route_and_status_only
    lines = []
    app = ApprovalConsoleApp.new(store: @store, kms: @kms, dm: @dm, clock: -> { @now }, logger: ->(line) { lines << line })
    body = request_body
    path = "/m/#{MID}/requests"
    raw = JSON.generate("body" => body)
    app.call(event("POST", path, raw, signed_headers("POST", path, raw)))
    assert_equal [ { "route" => "/m/:id/requests", "status" => 201 } ], lines.map { |line| JSON.parse(line) }
    refute_match(/merge PR|#{SHA}/, lines.join)
  end

  def test_base64_bodies_are_decoded
    body = JSON.generate("body" => request_body)
    path = "/m/#{MID}/requests"
    ev = event("POST", path, Base64.strict_encode64(body), signed_headers("POST", path, body)).merge("isBase64Encoded" => true)
    assert_equal 201, @app.call(ev)[:statusCode]
  end

  def test_the_entry_point_self_tests_only_for_direct_invokes
    require_relative "../approval_console/infra/lambda/handler"
    $console_app = @app
    assert_equal 404, handler(event: event("GET", "/"), context: nil)[:statusCode]
    assert_equal 404, handler(event: event("GET", "/").merge("cf_selftest" => true), context: nil)[:statusCode], "a function URL event is never a self-test"
  ensure
    $console_app = nil
  end

  def test_selftest_decrypts_under_the_context_and_signs
    require_relative "../approval_console/infra/lambda/handler"
    mid = "00000000-0000-4000-8000-000000000000"
    blob = Base64.strict_encode64(@kms.encrypt("sixteen-bytes-ok!", "machine_id" => mid))
    event = { "cf_selftest" => true, "machine_id" => mid, "ciphertext" => blob, "expect" => Base64.strict_encode64("sixteen-bytes-ok!") }
    assert_equal({ ok: true, decrypt: true, sign: true }, selftest(event, kms: @kms))
    refute selftest(event.merge("expect" => Base64.strict_encode64("nope")), kms: @kms)[:ok]
    assert_raises(RuntimeError) { selftest(event.merge("machine_id" => OTHER_MID), kms: @kms) }
  end

  def test_qr_svg_is_nil_without_the_gem_and_renders_with_it
    svg = ConsoleQr.svg("otpauth://totp/cf:x?secret=ABC&issuer=cf")
    assert(svg.nil? || svg.start_with?("<svg"))
  end

  def test_the_package_never_reads_outside_its_shared_files
    assert File.file?(File.join(ConsoleShared::DIR, "verifier.rb"))
  end
end
