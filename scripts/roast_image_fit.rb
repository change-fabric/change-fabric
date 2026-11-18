# frozen_string_literal: true

require 'fileutils'
require 'open3'
require_relative 'change_docker'

# Fits a roast shot to the critic's image limit. A shot whose long edge passes
# MAX_EDGE is downscaled into a temp copy through the pinned ffmpeg container
# (lanczos, metadata stripped, bitexact), so the same original always yields the
# same copy. The original is never touched and stays the cache key's input.
module RoastImageFit
  MAX_EDGE = 2048
  WORK = '/work'
  DEFAULT_DOCKER = ->(argv) { Open3.capture2e(*argv) }

  class FitError < StandardError; end

  module_function

  # [width, height] read from the PNG, JPEG, or WebP header, or nil when the
  # header is not one of those (the shot is then sent as is).
  def dimensions(path)
    head = File.binread(path, 64 * 1024) || ''.b
    png(head) || webp(head) || jpeg(head)
  rescue SystemCallError
    nil
  end

  def png(head)
    return nil unless head.start_with?("\x89PNG\r\n\x1A\n".b) && head.bytesize >= 24

    head[16, 8].unpack('NN')
  end

  def webp(head)
    return nil unless head[0, 4] == 'RIFF' && head[8, 4] == 'WEBP' && head.bytesize >= 30

    case head[12, 4]
    when 'VP8X' then [ le24(head, 24) + 1, le24(head, 27) + 1 ]
    when 'VP8 ' then head[26, 4].unpack('vv').map { |v| v & 0x3fff }
    when 'VP8L'
      bits = head[21, 4].unpack1('V')
      [ (bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1 ]
    end
  end

  def le24(head, at) = head[at, 3].unpack('C3').each_with_index.sum { |b, i| b << (8 * i) }

  SOF = ([ 0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF ]).freeze

  def jpeg(head)
    return nil unless head.start_with?("\xFF\xD8".b)

    at = 2
    while at + 9 <= head.bytesize
      return nil unless head.getbyte(at) == 0xFF

      marker = head.getbyte(at + 1)
      return head[at + 5, 4].unpack('nn').reverse if SOF.include?(marker)

      at += 2 + head[at + 2, 2].unpack1('n')
    end
    nil
  end

  # The target size keeping the aspect ratio, even on both edges for the encoder.
  def target(width, height)
    scale = MAX_EDGE.to_f / [ width, height ].max
    [ even(width * scale), even(height * scale) ]
  end

  def even(value) = [ (value / 2.0).round * 2, 2 ].max

  # Returns the shots to send: each oversized one replaced by its downscaled
  # copy under tmp_dir, a note printed for each. Raises FitError when the
  # container fails, so an oversized image is never sent.
  def fit_all(shots, tmp_dir:, out: $stdout, docker: DEFAULT_DOCKER)
    shots.each_with_index.map do |shot, i|
      size = dimensions(shot)
      next shot unless size && size.max > MAX_EDGE

      fit(shot, size, File.join(tmp_dir, "fit-#{i}#{File.extname(shot).downcase}"), out, docker)
    end
  end

  def fit(shot, size, dest, out, docker)
    w, h = target(*size)
    src = File.dirname(File.expand_path(shot))
    work = File.dirname(File.expand_path(dest))
    FileUtils.mkdir_p(work)
    args = [ '-hide_banner', '-nostdin', '-y', '-i', "/src/#{File.basename(shot)}", '-vf', "scale=#{w}:#{h}:flags=lanczos",
             '-frames:v', '1', '-map_metadata', '-1', '-fflags', '+bitexact', '-flags:v', '+bitexact', "#{WORK}/#{File.basename(dest)}" ]
    argv = ChangeDocker.run_command(network: 'none', image: ChangeDocker::FFMPEG_IMAGE, args: args,
                                    mounts: { src => '/src', work => WORK }, workdir: WORK, user: :host)
    output, status = docker.call(argv)
    raise FitError, "roast image fit failed for #{File.basename(shot)} (#{size.join('x')}):\n#{output.to_s.lines.last(6).join}" unless status.success? && File.file?(dest)

    out.puts("roast: #{File.basename(shot)} is #{size.join('x')}, sending a #{w}x#{h} copy (long edge over #{MAX_EDGE}px)")
    dest
  end
end
