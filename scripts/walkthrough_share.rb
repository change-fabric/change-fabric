# frozen_string_literal: true

require 'fileutils'

# Chat-sized share copies of walkthrough deliverables. A 1080p draft can
# exceed a chat upload cap (SendUserFile takes at most 30 MiB), so beside
# each <name>.mp4 the renderer writes <name>-share.mp4: libx264 crf 26 with a
# capped bitrate, aac 128k, +faststart. A copy still over the cap is
# re-encoded down the bitrate ladder; past the last rung it is reported as
# too big. The full-quality file stays the deliverable.
#
# Each share copy prints one machine-readable line, in its own fenced block:
#
#   walkthrough-share: <absolute path>
module WalkthroughShare
  LINE_PREFIX = 'walkthrough-share:'
  LIMIT_BYTES = 30 * 1024 * 1024
  LADDER_K = [ 1800, 1200, 800, 500 ].freeze

  module_function

  def path_for(mp4) = mp4.sub(/\.mp4\z/, '-share.mp4')

  # FFmpeg args, paths as the container sees them under the work mount.
  def args(src, out, maxrate_k)
    # The optional maps keep the soft mov_text captions, which MP4 output
    # would otherwise drop, so a muted viewer still reads them.
    [ '-hide_banner', '-y', '-i', src, '-map', '0:v', '-map', '0:a?', '-map', '0:s?', '-c:s', 'copy', '-c:v', 'libx264', '-crf', '26', '-preset', 'medium',
      '-maxrate', "#{maxrate_k}k", '-bufsize', "#{maxrate_k * 2}k", '-pix_fmt', 'yuv420p',
      '-c:a', 'aac', '-b:a', '128k', '-movflags', '+faststart', out ]
  end

  # Encodes down the ladder until the copy fits. encode takes the args array
  # and returns truthy on success. Returns { path:, maxrate_k: }, or
  # { error: } when the encode fails or no rung fits.
  def make(root, mp4, encode:, work: '/work', limit: LIMIT_BYTES)
    out = path_for(mp4)
    src_in = inside(root, mp4, work)
    out_in = inside(root, out, work)
    LADDER_K.each do |rate|
      ok = encode.call(args(src_in, out_in, rate)) && File.file?(out)
      return { error: "share encode failed at #{rate}k" } unless ok
      return { path: out, maxrate_k: rate } if File.size(out) <= limit
    end
    FileUtils.rm_f(out)
    { error: "share copy over #{limit / 1024 / 1024} MiB even at #{LADDER_K.last}k" }
  end

  def inside(root, path, work)
    File.join(work, File.expand_path(path).delete_prefix("#{File.expand_path(root)}/"))
  end

  def line(path) = "#{LINE_PREFIX} #{File.expand_path(path)}"
end
