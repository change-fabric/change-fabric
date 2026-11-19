# frozen_string_literal: true

module ApprovalConsole
  # A deliberately small, strict CBOR (RFC 8949) decoder: unsigned and negative
  # integers, byte strings, text strings, arrays and maps, which is everything
  # a COSE_Key for ES256 or EdDSA needs. Tags, floats, simple values and
  # indefinite lengths are refused rather than guessed at, as are duplicate
  # map keys, truncated input and trailing bytes.
  module Cbor
    class Error < StandardError; end

    MAX_DEPTH = 8
    MAX_ITEMS = 64

    module_function

    def decode(bytes)
      data = bytes.to_s.b
      value, offset = read(data, 0, 0)
      raise Error, 'trailing bytes after the CBOR item' unless offset == data.bytesize

      value
    end

    def read(data, offset, depth)
      raise Error, 'CBOR nested too deeply' if depth > MAX_DEPTH

      head = byte_at(data, offset)
      major = head >> 5
      info = head & 0x1f
      length, offset = argument(data, offset + 1, info)
      case major
      when 0 then [ length, offset ]
      when 1 then [ -1 - length, offset ]
      when 2 then take(data, offset, length)
      when 3 then text(data, offset, length)
      when 4 then array(data, offset, length, depth)
      when 5 then map(data, offset, length, depth)
      else raise Error, "unsupported CBOR major type #{major}"
      end
    end

    def argument(data, offset, info)
      return [ info, offset ] if info < 24

      width = { 24 => 1, 25 => 2, 26 => 4, 27 => 8 }[info]
      raise Error, 'indefinite or reserved CBOR length' unless width

      raw, next_offset = take(data, offset, width)
      [ raw.unpack1('H*').to_i(16), next_offset ]
    end

    def byte_at(data, offset)
      raise Error, 'truncated CBOR' if offset >= data.bytesize

      data.getbyte(offset)
    end

    def take(data, offset, length)
      raise Error, 'truncated CBOR' if length > data.bytesize - offset

      [ data.byteslice(offset, length), offset + length ]
    end

    def text(data, offset, length)
      raw, next_offset = take(data, offset, length)
      string = raw.force_encoding(Encoding::UTF_8)
      raise Error, 'CBOR text is not valid UTF-8' unless string.valid_encoding?

      [ string, next_offset ]
    end

    def array(data, offset, count, depth)
      raise Error, 'CBOR array too large' if count > MAX_ITEMS

      items = Array.new(count) do
        item, offset = read(data, offset, depth + 1)
        item
      end
      [ items, offset ]
    end

    def map(data, offset, count, depth)
      raise Error, 'CBOR map too large' if count > MAX_ITEMS

      result = {}
      count.times do
        key, offset = read(data, offset, depth + 1)
        raise Error, 'duplicate CBOR map key' if result.key?(key)

        result[key], offset = read(data, offset, depth + 1)
      end
      [ result, offset ]
    end
  end
end
