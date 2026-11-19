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
    assert Canonical.build(base.merge(type: "carve-out", summary: "merge", pr_url: "https://github.com/a/b/pull/1"))
    assert_raises(Canonical::Invalid) { Canonical.build(base.merge(type: "carve-out", summary: "merge", pr_url: "http://x")) }
    assert_raises(Canonical::Invalid) { Canonical.build(base.merge(type: "override")) }
  end

  def test_refuses_unexpected_fields
    assert_raises(Canonical::Invalid) { Canonical.build(step_attrs(extra: 1)) }
    assert_raises(Canonical::Invalid) { Canonical.build(step_attrs(reason: "also")) }
  end
end
