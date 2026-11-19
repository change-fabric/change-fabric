# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/approval_console/cbor"

class ApprovalConsoleCborTest < Minitest::Test
  Cbor = ApprovalConsole::Cbor

  def hex(text) = [ text.delete(" ") ].pack("H*")

  # RFC 8949 Appendix A vectors.
  def test_unsigned_integers
    assert_equal 0, Cbor.decode(hex("00"))
    assert_equal 23, Cbor.decode(hex("17"))
    assert_equal 24, Cbor.decode(hex("18 18"))
    assert_equal 1000, Cbor.decode(hex("19 03e8"))
    assert_equal 1_000_000, Cbor.decode(hex("1a 000f4240"))
    assert_equal 1_000_000_000_000, Cbor.decode(hex("1b 000000e8d4a51000"))
  end

  def test_negative_integers
    assert_equal(-1, Cbor.decode(hex("20")))
    assert_equal(-7, Cbor.decode(hex("26")))
    assert_equal(-100, Cbor.decode(hex("38 63")))
    assert_equal(-1000, Cbor.decode(hex("39 03e7")))
  end

  def test_strings
    assert_equal "", Cbor.decode(hex("60"))
    assert_equal "IETF", Cbor.decode(hex("64 49455446"))
    assert_equal "ü", Cbor.decode(hex("62 c3bc"))
    assert_equal "\x01\x02\x03\x04".b, Cbor.decode(hex("44 01020304"))
  end

  def test_array_and_map
    assert_equal [ 1, [ 2, 3 ], [ 4, 5 ] ], Cbor.decode(hex("83 01 82 02 03 82 04 05"))
    assert_equal({ 1 => 2, 3 => 4 }, Cbor.decode(hex("a2 01 02 03 04")))
    assert_equal({ "a" => 1, "b" => [ 2, 3 ] }, Cbor.decode(hex("a2 61 61 01 61 62 82 02 03")))
  end

  def test_refuses_unsupported_and_malformed_input
    refuse = lambda do |text, why|
      assert_raises(Cbor::Error, why) { Cbor.decode(hex(text)) }
    end
    refuse.call("c1 1a514b67b0", "tag")
    refuse.call("f9 3c00", "float")
    refuse.call("f4", "simple value")
    refuse.call("5f 41 01 ff", "indefinite byte string")
    refuse.call("9f 01 ff", "indefinite array")
    refuse.call("19 03", "truncated argument")
    refuse.call("44 010203", "truncated byte string")
    refuse.call("62 c328", "invalid UTF-8")
    refuse.call("a2 01 02 01 03", "duplicate key")
    refuse.call("01 02", "trailing bytes")
    refuse.call("", "empty")
    refuse.call("1c", "reserved length")
  end

  def test_refuses_deep_nesting
    assert_raises(Cbor::Error) { Cbor.decode(hex("81" * 20 + "00")) }
  end
end
