# frozen_string_literal: true

# Square pixels on ingest. A PNG can carry pHYs pixel-aspect metadata (an
# FFmpeg scale to a slightly different aspect writes one, for example
# 7839:7807), and FFmpeg reads it as the stream's sample aspect ratio.
# concat and xfade reject inputs whose SAR differs, so every chain that
# takes captured frames or stills into a filter graph, and every chain that
# writes PNGs back out, ends its scale on setsar=1 through this one helper.
module FfmpegSquare
  SETSAR = 'setsar=1'

  module_function

  # A lanczos scale to w x h that leaves square pixels behind.
  def scale(width, height) = "scale=#{width}:#{height}:flags=lanczos,#{SETSAR}"
end
