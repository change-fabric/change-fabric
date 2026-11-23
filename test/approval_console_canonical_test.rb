# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/approval_console/canonical"
require_relative "../scripts/emit_digest"

class ApprovalConsoleCanonicalTest < Minitest::Test
  Canonical = ApprovalConsole::Canonical

  MACHINE = "11111111-2222-4333-8444-555555555555"
  REQUEST = "99999999-8888-4777-8666-555555555555"
  SHA = "a" * 40

  def step_attrs(overrides = {})
    { type: "step", machine_id: MACHINE, repo: "github.com/acme/app", sha: SHA, profile: nil,
      request_id: REQUEST, created_at: "2026-11-18T12:00:00Z", expires_at: "2026-11-18T12:30:00Z",
      items: [ { step: "boot.up", fields: { "command" => "make up", "args" => [ "a", "b" ] } } ] }.merge(overrides)
  end

  def test_build_is_sorted_compact_and_deterministic
    body = Canonical.build(step_attrs)
    assert_equal body, Canonical.build(step_attrs.to_a.reverse.to_h)
    refute_match(/\s(?=")|: /, body.sub(/"command":"make up"/, ""))
    assert_operator body.index('"created_at"'), :<, body.index('"expires_at"')
    assert_operator body.index('"expires_at"'), :<, body.index('"items"')
  end

  def test_build_parse_round_trip
    body = Canonical.build(step_attrs)
    parsed = Canonical.parse(body)
    assert_equal 1, parsed["v"]
    assert_equal "boot.up", parsed["items"].first["step"]
    assert_nil parsed["items"].first["base_fields"]
  end

  def test_item_digest_matches_the_change_trust_digest
    fields = { "command" => "make up", "args" => [ "a" ] }
    assert_equal EmitDigest.of(fields), Canonical.step_digest(fields)
    assert_equal "unverified-#{EmitDigest.of({ 'files_error' => 'x' })}", Canonical.step_digest({ "files_error" => "x" })
  end

  def test_digest_is_recomputed_not_supplied
    body = JSON.parse(Canonical.build(step_attrs))
    body["items"][0]["fields"]["command"] = "make evil"
    error = assert_raises(Canonical::Invalid) { Canonical.parse(Canonical.serialize(body)) }
    assert_match(/digest does not match/, error.message)
  end

  def test_challenge_is_raw_sha256_of_the_body
    body = Canonical.build(step_attrs)
    assert_equal Digest::SHA256.digest(body), Canonical.challenge(body)
    refute_equal Canonical.challenge(body), Canonical.challenge(body.sub("make up", "make uq"))
  end

  def test_parse_refuses_a_non_canonical_rendering
    body = Canonical.build(step_attrs)
    assert_raises(Canonical::Invalid) { Canonical.parse(JSON.pretty_generate(JSON.parse(body))) }
    assert_raises(Canonical::Invalid) { Canonical.parse(body + " ") }
    assert_raises(Canonical::Invalid) { Canonical.parse("not json") }
    assert_raises(Canonical::Invalid) { Canonical.parse("[]") }
  end

  def test_refuses_an_expiry_not_after_creation
    assert_raises(Canonical::Invalid) { Canonical.build(step_attrs(expires_at: "2026-11-18T12:00:00Z")) }
    assert_raises(Canonical::Invalid) { Canonical.build(step_attrs(expires_at: "2026-11-18T11:00:00Z")) }
  end

  def test_refuses_a_lifetime_over_one_hour_but_allows_exactly_one
    assert_raises(Canonical::Invalid) { Canonical.build(step_attrs(expires_at: "2026-11-18T13:00:01Z")) }
    assert Canonical.build(step_attrs(expires_at: "2026-11-18T13:00:00Z"))
  end

  def test_refuses_bad_timestamps_and_ids
    assert_raises(Canonical::Invalid) { Canonical.build(step_attrs(created_at: "2026-11-18 12:00:00")) }
    assert_raises(Canonical::Invalid) { Canonical.build(step_attrs(created_at: "2026-11-18T12:00:00+01:00")) }
    assert_raises(Canonical::Invalid) { Canonical.build(step_attrs(created_at: "2026-13-45T12:00:00Z")) }
    assert_raises(Canonical::Invalid) { Canonical.build(step_attrs(machine_id: "nope")) }
    assert_raises(Canonical::Invalid) { Canonical.build(step_attrs(sha: "abc")) }
    assert_raises(Canonical::Invalid) { Canonical.build(step_attrs(type: "bogus")) }
  end

  def test_each_type_needs_its_own_payload
    base = step_attrs.reject { |key, _| key == :items }
    assert Canonical.build(base.merge(type: "override", reason: "CI is down"))
    assert_raises(Canonical::Invalid) { Canonical.build(base.merge(type: "override", reason: " ")) }
    assert Canonical.build(base.merge(type: "prod-op", summary: "rotate", argv: [ "ruby", "rotate.rb" ]))
    assert Canonical.build(base.merge(type: "money", summary: "charge", argv: [ "bin/charge" ]))
    assert_raises(Canonical::Invalid) { Canonical.build(base.merge(type: "prod-op", summary: "x", argv: [])) }
    assert Canonical.build(base.merge(carve_out_attrs))
    assert_raises(Canonical::Invalid) { Canonical.build(base.merge(carve_out_attrs(pr_url: "http://x"))) }
    assert_raises(Canonical::Invalid) { Canonical.build(base.merge(type: "override")) }
  end

  def carve_out_attrs(**over)
    { type: "carve-out", summary: "merge", pr_url: "https://github.com/a/b/pull/1", pr_title: "Add a thing", base: "main",
      files: [ "README.md", "scripts/x.rb" ] }.merge(over)
  end

  def test_carve_out_signs_the_title_base_and_a_sorted_unique_file_list
    base = step_attrs.reject { |key, _| key == :items }
    body = Canonical.parse(Canonical.build(base.merge(carve_out_attrs)))
    assert_equal [ "README.md", "scripts/x.rb" ], body["files"]
    assert_equal "main", body["base"]
    assert_equal "Add a thing", body["pr_title"]
    [ { files: [ "b", "a" ] }, { files: [ "a", "a" ] }, { files: [ "" ] }, { files: "a" }, { base: " " }, { pr_title: "" } ].each do |bad|
      assert_raises(Canonical::Invalid, bad.inspect) { Canonical.build(base.merge(carve_out_attrs(**bad))) }
    end
    assert_raises(Canonical::Invalid) { Canonical.build(base.merge(carve_out_attrs.except(:files))) }
  end

  def run_script_attrs(text: "echo hi\n", **over)
    { type: "run-script", script_text: text, script_sha256: Digest::SHA256.hexdigest(text.b), script_path: "/q/0001-x.sh", title: "x", account: nil,
      expires_at: "2026-11-18T12:15:00Z" }.merge(over)
  end

  def test_run_script_signs_the_hash_the_text_the_path_and_the_account
    base = step_attrs.reject { |key, _| key == :items }
    body = Canonical.parse(Canonical.build(base.merge(run_script_attrs(account: "123456789012"))))
    assert_equal [ "123456789012", "/q/0001-x.sh", "echo hi\n" ], body.values_at("account", "script_path", "script_text")
    assert_nil Canonical.parse(Canonical.build(base.merge(run_script_attrs)))["account"]
    [ { script_sha256: "0" * 64 }, { account: "12345" }, { title: " " }, { script_path: "" }, { script_text: " ", script_sha256: Digest::SHA256.hexdigest(" ") } ].each do |bad|
      assert_raises(Canonical::Invalid, bad.inspect) { Canonical.build(base.merge(run_script_attrs.merge(bad))) }
    end
  end

  def test_run_script_lifetime_is_capped_at_fifteen_minutes
    base = step_attrs.reject { |key, _| key == :items }
    assert_raises(Canonical::Invalid) { Canonical.build(base.merge(run_script_attrs(expires_at: "2026-11-18T12:15:01Z"))) }
    assert Canonical.build(base.merge(run_script_attrs))
  end

  def grant_attrs(**over)
    { type: "grant", summary: "overnight", scope_list: %w[nudge_worker stop_runaway], grant_expires_at: "2026-11-18T20:00:00Z", expires_at: "2026-11-18T12:15:00Z" }.merge(over)
  end

  def test_a_grant_signs_a_sorted_scope_list_and_an_expiry_past_the_request_window
    base = step_attrs.reject { |key, _| key == :items }
    body = Canonical.parse(Canonical.build(base.merge(grant_attrs)))
    assert_equal [ %w[nudge_worker stop_runaway], "2026-11-18T20:00:00Z" ], body.values_at("scope_list", "grant_expires_at")
    [ { scope_list: %w[stop_runaway nudge_worker] }, { scope_list: %w[a a] }, { scope_list: [] }, { scope_list: [ "Bad" ] }, { scope_list: "nudge_worker" },
      { grant_expires_at: "2026-11-18T12:15:00Z" }, { grant_expires_at: "2026-11-21T12:00:01Z" }, { grant_expires_at: "later" }, { summary: " " } ].each do |bad|
      assert_raises(Canonical::Invalid, bad.inspect) { Canonical.build(base.merge(grant_attrs(**bad))) }
    end
    assert_raises(Canonical::Invalid) { Canonical.build(base.merge(grant_attrs.except(:grant_expires_at))) }
    assert Canonical.build(base.merge(grant_attrs(grant_expires_at: "2026-11-21T12:00:00Z")))
  end

  def test_release_signs_the_tag_and_the_commit_it_points_at
    base = step_attrs.reject { |key, _| key == :items }
    body = Canonical.parse(Canonical.build(base.merge(type: "release", tag: "skills/v1.2.3", commit: base[:sha])))
    assert_equal "skills/v1.2.3", body["tag"]
    assert_equal body["sha"], body["commit"]
    assert_raises(Canonical::Invalid) { Canonical.build(base.merge(type: "release", tag: "v1", commit: "b" * 40)) }
    assert_raises(Canonical::Invalid) { Canonical.build(base.merge(type: "release", tag: " ", commit: base[:sha])) }
    assert_raises(Canonical::Invalid) { Canonical.build(base.merge(type: "release", commit: base[:sha])) }
  end

  def test_override_scope_is_optional_and_limited_to_merge_or_tag
    base = step_attrs.reject { |key, _| key == :items }.merge(type: "override", reason: "CI is down")
    refute Canonical.parse(Canonical.build(base)).key?("scope")
    %w[merge tag].each { |scope| assert_equal scope, Canonical.parse(Canonical.build(base.merge(scope: scope)))["scope"] }
    assert_raises(Canonical::Invalid) { Canonical.build(base.merge(scope: "deploy")) }
    assert_raises(Canonical::Invalid) { Canonical.build(base.merge(scope: nil)) }
  end

  def test_refuses_unexpected_fields
    assert_raises(Canonical::Invalid) { Canonical.build(step_attrs(extra: 1)) }
    assert_raises(Canonical::Invalid) { Canonical.build(step_attrs(reason: "also")) }
  end

  def test_parse_refuses_invalid_utf8_instead_of_raising
    [ "{\"repo\":\"\xff\"}".b, "{\"repo\":\"\xc3\"}".b, "\xff".b ].each do |raw|
      error = assert_raises(Canonical::Invalid) { Canonical.parse(raw) }
      assert_match(/UTF-8|JSON/, error.message)
    end
  end

  def test_utf8_predicate
    assert Canonical.utf8?("caf\u00e9")
    refute Canonical.utf8?("\xff".b)
    refute Canonical.utf8?(nil)
  end
end
