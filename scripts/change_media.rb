#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'fileutils'

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

  # One captured screenshot: the route and viewport it belongs to, plus the
  # bundle-relative path the artifact page and the PDFs both reference.
  Screenshot = Struct.new(:viewport, :route, :path, keyword_init: true)

  # One viewport's recording of the whole route walk at that viewport.
  Video = Struct.new(:viewport, :path, :bytes, :error, keyword_init: true)

  attr_reader :root, :video_fps

  # The capture preferences ride on the sink rather than being read from the
  # config by the lane: the lane's only dependency stays "there is somewhere to
  # put media, and here is what it wants", so the artifacts config never has to
  # be threaded through the run context.
  def initialize(root, screenshots: true, video: true, video_fps: 6)
    @root = root
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

  # Writes one viewport's recording and records it. `data` is base64 WebM. An
  # `error` instead of data is kept as a recorded, reportable gap rather than
  # dropped: a recording that failed is worth saying so on the artifact page,
  # since a silently missing video reads as "this viewport was not tested".
  def add_video(viewport:, data: nil, error: nil)
    if data.to_s.empty?
      @videos << Video.new(viewport: viewport, path: nil, bytes: 0, error: error || 'no recording produced')
      return nil
    end

    relative = File.join(VIDEO_DIR, "#{slug(viewport)}.webm")
    bytes = write(relative, data)
    @videos << Video.new(viewport: viewport, path: relative, bytes: bytes, error: nil)
  end

  # Every file written under the bundle root, bundle-relative, for the uploader.
  def files
    Dir.glob(File.join(@root, '**', '*')).select { |path| File.file?(path) }
           .map { |path| path.delete_prefix("#{@root}/") }.sort
  end

  def empty? = @screenshots.empty? && @videos.none?(&:path)

  private

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
