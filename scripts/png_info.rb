# frozen_string_literal: true

# Reads a PNG's pixel size from its IHDR chunk, without decoding it.
module PngInfo
  SIGNATURE = "\x89PNG\r\n\x1a\n".b

  module_function

  # [width, height] of PNG bytes, or nil when the bytes are not a PNG.
  def size(bytes)
    data = bytes.to_s.b
    return nil unless data.bytesize >= 24 && data.start_with?(SIGNATURE) && data.byteslice(12, 4) == 'IHDR'

    data.byteslice(16, 8).unpack('NN')
  end

  # [width, height] of a PNG file, or nil when it is missing or not a PNG.
  def file_size(path) = File.file?(path) ? size(File.binread(path, 24)) : nil
end
