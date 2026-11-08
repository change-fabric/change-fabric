# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'open3'
require_relative 'change_docker'

# Turns sampled screencast frames into a video, shared by cf:walkthrough and
# the cf:change browserless lane. The sampler (ScreencastSampler in
# browserless_js.rb) returns base64 JPEG frames plus ticks, one per output
# frame, each an index into frames. write_jpgs lays the ticks out as a
# numbered JPEG sequence; encode turns that sequence into an H.264 mp4 in
# the pinned FFmpeg image with no network.
module FrameVideo
  class EncodeError < StandardError; end

  OUT_NAME = 'out.mp4'

  module_function

  # Writes 000001.jpg onward, one per tick, and returns how many it wrote.
  # Empty ticks (a sampler that never saw a frame) write nothing and return 0.
  # A negative index (a tick before the first frame) reads frame 0.
  def write_jpgs(dir, frames, ticks)
    FileUtils.mkdir_p(dir)
    ticks = Array(ticks)
    ticks.each_with_index do |idx, i|
      File.binwrite(File.join(dir, format('%06d.jpg', i + 1)), Base64.decode64(frames[[ idx, 0 ].max]))
    end
    ticks.size
  end

  # `size` ([w, h]) fits every frame into one even-sized canvas, letterboxed.
  # FFmpeg sizes the whole video from the first frame, and libx264 refuses an
  # odd dimension, so without it one stray frame of another size (Chromium can
  # paint one before a new viewport takes effect) squashed the whole video or
  # failed the encode outright.
  def encode_argv(dir, fps:, crf: 18, size: nil)
    ChangeDocker.run_command(
      network: "none", image: ChangeDocker::FFMPEG_IMAGE, mounts: { dir => "/work" },
      args: [ "-y", "-v", "error", "-framerate", fps.to_s, "-i", "/work/%06d.jpg", "-r", fps.to_s,
              *fit_filter(size),
              "-c:v", "libx264", "-crf", crf.to_s, "-pix_fmt", "yuv420p",
              "-flags", "+bitexact", "-fflags", "+bitexact", "-movflags", "+faststart", "/work/#{OUT_NAME}" ]
    )
  end

  def fit_filter(size)
    return [] unless size

    w, h = size.map { |n| [ n.to_i - (n.to_i % 2), 2 ].max }
    [ "-vf", "scale=#{w}:#{h}:force_original_aspect_ratio=decrease,pad=#{w}:#{h}:(ow-iw)/2:(oh-ih)/2:white,setsar=1" ]
  end

  # The most common [width, height] among dir's JPEGs, or nil when none
  # parses: the size the walk was actually recorded at.
  def dominant_size(dir)
    sizes = Dir.glob(File.join(dir, "*.jpg")).filter_map { |path| jpeg_size(path) }
    sizes.tally.max_by { |_, count| count }&.first
  end

  # [width, height] from a JPEG's start-of-frame marker, or nil.
  def jpeg_size(path)
    data = File.binread(path, 65_536)
    pos = 2
    while pos + 9 < data.bytesize && data.getbyte(pos) == 0xFF
      marker = data.getbyte(pos + 1)
      return data[pos + 5, 4].unpack("nn").reverse if (0xC0..0xCF).cover?(marker) && ![ 0xC4, 0xC8, 0xCC ].include?(marker)

      pos += 2 + data[pos + 2, 2].unpack1("n")
    end
    nil
  end

  # Encodes dir's JPEG sequence to out. The runner takes the argv and returns
  # [output, status] (Open3.capture2e's shape). Raises EncodeError when there
  # is nothing to encode or FFmpeg fails, so a caller can warn and move on.
  def encode(dir, fps:, out:, crf: 18, runner: ->(argv) { Open3.capture2e(*argv) })
    raise EncodeError, 'no frames to encode' if Dir.glob(File.join(dir, '*.jpg')).empty?

    output, status = runner.call(encode_argv(dir, fps: fps, crf: crf, size: dominant_size(dir)))
    produced = File.join(dir, OUT_NAME)
    raise EncodeError, "ffmpeg failed: #{output.to_s.strip.chars.last(500).join}" unless status.success? && File.file?(produced)

    FileUtils.mkdir_p(File.dirname(out))
    FileUtils.mv(produced, out)
    out
  end
end
