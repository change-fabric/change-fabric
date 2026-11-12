# frozen_string_literal: true

require "zlib"

# Builds small real PNGs for tests: a flat RGB image of any size, with an
# optional pHYs chunk carrying a pixel aspect (x and y pixels per unit).
module PngFixture
  module_function

  def chunk(type, data)
    [ data.bytesize ].pack("N") + type + data + [ Zlib.crc32(type + data) ].pack("N")
  end

  def png(width, height, rgb: [ 40, 120, 200 ], phys: nil)
    row = "\x00".b + rgb.pack("C*") * width
    out = "\x89PNG\r\n\x1a\n".b
    out << chunk("IHDR", [ width, height, 8, 2, 0, 0, 0 ].pack("NNCCCCC"))
    out << chunk("pHYs", [ phys[0], phys[1], 0 ].pack("NNC")) if phys
    out << chunk("IDAT", Zlib::Deflate.deflate(row * height))
    out << chunk("IEND", "".b)
  end

  # The [x, y] of a PNG's pHYs chunk, or nil without one.
  def phys(bytes)
    data = bytes.b
    at = 8
    while at + 8 <= data.bytesize
      len = data.byteslice(at, 4).unpack1("N")
      type = data.byteslice(at + 4, 4)
      return data.byteslice(at + 8, 8).unpack("NN") if type == "pHYs"

      at += 12 + len
    end
    nil
  end
end
