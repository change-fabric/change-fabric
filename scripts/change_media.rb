#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'tmpdir'
require_relative 'frame_video'

# The on-disk media a run captured, and the sink lanes hand it to.
#
# A browser lane returns its screenshots and per-viewport recordings as base64
# inside the one JSON payload its browserless /function call resolves with (the
# browserless container shares no filesystem with the host, so base64 over the
# same HTTP response is the only path the media has), and this class is where
# that payload stops being a string in memory and becomes a file. Keeping the
# decode-and-write here means a lane never learns where the artifact bundle
# lives, and the bundle builder never learns how a lane encoded anything.
#
# Nothing here is created unless the repo carries a `contributors_team.artifacts:`
# block: `ChangeRun` passes a sink only then, and a lane with no sink captures
# nothing, which is byte for byte the pre-0.32.0 behavior.
class ChangeMedia
  SCREENSHOT_DIR = 'screenshots'
  VIDEO_DIR = 'video'
  COMMAND_DIR = 'commands'

  # One captured screenshot: the route and viewport it belongs to, plus the
  # bundle-relative path the artifact page and the PDFs both reference.
  Screenshot = Struct.new(:viewport, :route, :path, keyword_init: true)

  # One viewport's recording of the whole route walk at that viewport.
  # `dropped` counts the sampled frames the lane's budget trimmed from the end.
  Video = Struct.new(:viewport, :path, :bytes, :error, :dropped, keyword_init: true)

  attr_reader :root, :video_fps

  # The capture preferences ride on the sink rather than being read from the
  # config by the lane: the lane's only dependency stays "there is somewhere to
  # put media, and here is what it wants", so the artifacts config never has to
  # be threaded through the run context.
  # `encoder` takes (dir, fps:, out:) and turns dir's JPEG sequence into out,
  # raising on failure; tests swap it for a fake so no FFmpeg is needed.
  def initialize(root, screenshots: true, video: true, video_fps: 6,
                 encoder: ->(dir, fps:, out:) { FrameVideo.encode(dir, fps: fps, out: out) })
    @root = root
    @encoder = encoder
    @screenshots_wanted = screenshots
    @video_wanted = video
    @video_fps = video_fps
    @screenshots = []
    @videos = []
  end

  def screenshots? = @screenshots_wanted
  def video? = @video_wanted

  def screenshots = @screenshots.dup
  def videos = @videos.dup

  def screenshots_for(viewport) = @screenshots.select { |shot| shot.viewport == viewport }
  def video_for(viewport) = @videos.find { |video| video.viewport == viewport && video.path }

  # Writes one route/viewport screenshot and records it. `data` is base64 JPEG:
  # the lane asks Chromium for JPEG rather than PNG because these are full-page
  # captures of real pages across every viewport, and a lossless PNG set for a
  # multi-route matrix is large enough to dominate both the /function response
  # and the upload for no review value a quality-72 JPEG does not already give.
  def add_screenshot(viewport:, route:, data:)
    return nil if data.to_s.empty?

    name = "#{slug(viewport)}--#{slug(route)}.jpg"
    write(File.join(SCREENSHOT_DIR, name), data)
    @screenshots << Screenshot.new(viewport: viewport, route: route, path: File.join(SCREENSHOT_DIR, name))
  end

  # Encodes one viewport's sampled frames to `video/<slug>.mp4` and records
  # it. `frames` are base64 JPEGs and `ticks` index into them, one per output
  # frame (the ScreencastSampler result). No frames, a missing FFmpeg image,
  # or a failed encode is kept as a recorded, reportable gap rather than
  # raised: a recording that failed is worth saying so on the artifact page,
  # since a silently missing video reads as "this viewport was not tested".
  def add_video(viewport:, frames: nil, ticks: nil, dropped: 0, error: nil)
    return record_gap(viewport, error || 'no recording produced', dropped) if Array(frames).empty? || Array(ticks).empty?

    relative = File.join(VIDEO_DIR, "#{slug(viewport)}.mp4")
    out = File.join(@root, relative)
    Dir.mktmpdir('cf-frames') do |dir|
      FrameVideo.write_jpgs(dir, frames, ticks)
      @encoder.call(dir, fps: @video_fps, out: out)
    end
    video = Video.new(viewport: viewport, path: relative, bytes: File.size(out), error: nil, dropped: dropped)
    @videos << video
    video
  rescue StandardError => e
    record_gap(viewport, "encode failed: #{e.message}", dropped)
  end

  # Copies one command lane file (0.17.0: a masked transcript or a collected
  # artifact) into `commands/<command>/<relative>`, so the uploader publishes it
  # with the rest of the bundle.
  def add_command_file(command:, relative:, source:)
    dest = File.join(@root, COMMAND_DIR, slug(command), relative)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp(source, dest)
    dest
  end

  # Every file written under the bundle root, bundle-relative, for the uploader.
  def files
    Dir.glob(File.join(@root, '**', '*')).select { |path| File.file?(path) }
           .map { |path| path.delete_prefix("#{@root}/") }.sort
  end

  def empty? = @screenshots.empty? && @videos.none?(&:path)

  private

  def record_gap(viewport, error, dropped)
    video = Video.new(viewport: viewport, path: nil, bytes: 0, error: error, dropped: dropped)
    @videos << video
    video
  end

  def write(relative, base64)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    bytes = Base64.decode64(base64.to_s)
    File.binwrite(path, bytes)
    bytes.bytesize
  end

  # Route paths and viewport names both become one filename segment, so `/` and
  # anything else awkward in a url (or an S3 key) collapses the same way for
  # both. The site root becomes `root` rather than an empty segment.
  def slug(text)
    cleaned = text.to_s.downcase.gsub(%r{[^a-z0-9]+}, '-').gsub(/-+/, '-').gsub(/\A-|-\z/, '')
    cleaned.empty? ? 'root' : cleaned
  end
end
