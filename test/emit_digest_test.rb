# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/emit_digest"
require_relative "../scripts/walkthrough_cache"

# EmitDigest is the one content-identity hash: raw bytes for a string,
# canonical JSON for anything else.
class EmitDigestTest < Minitest::Test
  SAMPLE = { model: "m", brief: "b", round: 2, history: [ { z: 1, a: [ 3, 1 ] } ], nil_slot: nil }.freeze

  def test_string_is_hashed_raw_and_binary_safe
    assert_equal Digest::SHA256.hexdigest("abc"), EmitDigest.of("abc")
    bytes = "\xFF\x00\x89PNG".b
    assert_equal Digest::SHA256.hexdigest(bytes), EmitDigest.of(bytes)
    assert_equal EmitDigest.of("é".b), EmitDigest.of("é")
  end

  def test_hash_key_order_does_not_matter
    assert_equal EmitDigest.of({ "a" => 1, "b" => 2 }), EmitDigest.of({ "b" => 2, "a" => 1 })
  end

  def test_symbol_keys_equal_string_keys
    assert_equal EmitDigest.of({ a: { b: :c } }), EmitDigest.of({ "a" => { "b" => "c" } })
  end

  def test_nested_arrays_keep_order
    refute_equal EmitDigest.of({ a: [ 1, 2 ] }), EmitDigest.of({ a: [ 2, 1 ] })
  end

  def test_plain_lowercase_hex
    assert_match(/\A[0-9a-f]{64}\z/, EmitDigest.of(SAMPLE))
  end

  # Cache continuity: walkthrough cache keys must not move.
  def test_pinned_vector_matches_walkthrough_cache_key
    pinned = Digest::SHA256.hexdigest(
      '{"brief":"b","history":[{"a":[3,1],"z":1}],"model":"m","nil_slot":null,"round":2}'
    )
    assert_equal pinned, EmitDigest.of(SAMPLE)
    assert_equal pinned, WalkthroughCache.key(SAMPLE)
  end
end
