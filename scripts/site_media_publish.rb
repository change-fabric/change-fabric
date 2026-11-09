#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'tmpdir'
require_relative 'change_docker'
require_relative 'walkthrough_captions'

# Publishes one site media slot: hashes each file, derives the WebVTT
# captions and the follow-along word spans from the narration's SRT and
# alignment, probes the main file in the pinned ffprobe container, enforces
# the size guards, uploads every file to s3://<site bucket>/media/<hash>.<ext>
# with its content type and a one-year immutable cache, and only then
# rewrites site/media/manifest.json. Uploading is outward-facing, so a human
# runs this; --dry-run prints the planned keys and the manifest change and
# touches nothing.
#
#   ruby scripts/site_media_publish.rb --slot walkthrough-self --video final.mp4 \
#     --poster poster.jpg --srt narration.srt --title "..." [--dry-run]
#   ruby scripts/site_media_publish.rb --slot narrate-sample --audio key.mp3 \
#     --alignment key.alignment.json --srt key.srt --title "..." [--dry-run]
module SiteMediaPublish
  class Error < StandardError; end

  ROOT = File.expand_path('..', __dir__)
  MANIFEST = File.join(ROOT, 'site', 'media', 'manifest.json')
  INFRA = File.join(ROOT, 'site', 'infra')

  MB = 1024 * 1024
  LIMITS = { video: 8 * MB, audio: 1 * MB, poster: 60 * 1024 }.freeze
  CACHE_CONTROL = 'public, max-age=31536000, immutable'
  CONTENT_TYPES = {
    '.mp4' => 'video/mp4',
    '.mp3' => 'audio/mpeg',
    '.vtt' => 'text/vtt; charset=utf-8',
    '.json' => 'application/json',
    '.jpg' => 'image/jpeg',
    '.webp' => 'image/webp'
  }.freeze
  DEFAULT_RUNNER = ->(argv, env = {}) { Open3.capture2e(env, *argv) }

  module_function

  def hashed_name(path)
    "#{Digest::SHA256.file(path).hexdigest[0, 12]}#{extension(path)}"
  end

  def extension(path)
    ext = File.extname(path).downcase
    ext = '.jpg' if ext == '.jpeg'
    raise Error, "unsupported media file type: #{path}" unless CONTENT_TYPES.key?(ext)

    ext
  end

  def guard_size!(path, role)
    limit = LIMITS.fetch(role)
    size = File.size(path)
    return if size <= limit

    raise Error, "#{role} #{path} is #{size} bytes, over the #{limit} byte guard; re-encode or trim it"
  end

  # The bucket comes from exactly where infra/deploy.sh reads it: SITE_BUCKET
  # when set (CI), else the Terraform output (local use).
  def bucket(env: ENV, runner: DEFAULT_RUNNER)
    return env['SITE_BUCKET'] unless env['SITE_BUCKET'].to_s.empty?

    out, status = runner.call([ 'terraform', "-chdir=#{INFRA}", 'output', '-raw', 'site_bucket' ], aws_env(env))
    raise Error, "could not read the site_bucket Terraform output:\n#{out}" unless status.success?

    out.strip
  end

  # The profile every AWS call runs under, defaulted like infra/deploy.sh.
  def aws_env(env = ENV)
    { 'AWS_PROFILE' => env['AWS_PROFILE'] || 'personal' }
  end

  # Probes duration and dimensions with the pinned ffprobe image.
  def probe(path, runner: DEFAULT_RUNNER)
    work = '/work'
    argv = ChangeDocker.run_command(
      network: 'none', image: ChangeDocker::FFMPEG_IMAGE, entrypoint: 'ffprobe',
      mounts: { File.dirname(File.expand_path(path)) => { target: work, readonly: true } }, workdir: work,
      args: %w[-v error -print_format json -show_streams -show_format] + [ File.join(work, File.basename(path)) ]
    )
    out, status = runner.call(argv)
    raise Error, "ffprobe failed on #{path}:\n#{out}" unless status.success?

    info = JSON.parse(json_object(out))
    stream = Array(info['streams']).find { |s| s['codec_type'] == 'video' }
    { duration_ms: (info.dig('format', 'duration').to_f * 1000).round,
      width: stream && stream['width'], height: stream && stream['height'] }
  rescue JSON::ParserError
    raise Error, "ffprobe output for #{path} was not JSON"
  end

  # The runner merges stderr into stdout, so docker's own notices (an amd64
  # image on an arm64 host prints a platform WARNING) can precede ffprobe's
  # JSON. Keep only the outermost object.
  def json_object(out)
    first = out.index('{')
    last = out.rindex('}')
    first && last && last > first ? out[first..last] : out
  end

  # Cue text only, in order: the plain transcript every slot carries. Parsed
  # by cue block, so only a header index before the timing line is dropped
  # and a numeric caption line ("42") survives.
  def transcript(srt)
    srt.gsub("\r\n", "\n").split(/\n\s*\n/).flat_map do |block|
      lines = block.lines.map(&:strip).reject(&:empty?)
      lines.shift if lines.first&.match?(/\A\d+\z/) && lines[1]&.include?('-->')
      lines.shift if lines.first&.include?('-->')
      lines
    end.join(' ')
  end

  # Writes the derived files into `work` and returns the slot's files as
  # { field => local path }, plus the manifest entry.
  def plan(opts, work:, prober:)
    kind = opts[:video] ? 'video' : 'audio'
    main = opts[:video] || opts[:audio]
    raise Error, 'pass exactly one of --video or --audio' if main.nil? || (opts[:video] && opts[:audio])
    raise Error, '--poster is required for a video' if kind == 'video' && opts[:poster].nil?

    guard_size!(main, kind.to_sym)
    guard_size!(opts[:poster], :poster) if opts[:poster]

    srt = File.read(opts.fetch(:srt))
    files = { 'src' => main, 'vtt' => write(work, 'captions.vtt', WalkthroughCaptions.vtt(srt)) }
    files['poster'] = opts[:poster] if opts[:poster]
    if opts[:alignment]
      spans = WalkthroughCaptions.word_spans(JSON.parse(File.read(opts[:alignment])))
      files['words'] = write(work, 'words.json', "#{JSON.generate(spans)}\n")
    end

    names = files.transform_values { |path| hashed_name(path) }
    probed = prober.call(main)
    entry = {
      'kind' => kind, 'title' => opts.fetch(:title),
      'src' => names['src'], 'poster' => names['poster'], 'vtt' => names['vtt'], 'words' => names['words'],
      'duration_ms' => probed[:duration_ms],
      'width' => kind == 'video' ? probed[:width] : nil, 'height' => kind == 'video' ? probed[:height] : nil,
      'bytes' => File.size(main), 'alt' => opts[:alt] || opts.fetch(:title), 'transcript' => transcript(srt)
    }
    [ files.to_h { |field, path| [ names[field], path ] }, entry ]
  end

  def write(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    path
  end

  def read_manifest(path)
    return { 'version' => 1, 'base' => '/media/', 'slots' => {} } unless File.exist?(path)

    JSON.parse(File.read(path))
  end

  # uploader responds to exists?(key) and put(path, key, content_type:, cache_control:).
  def publish(opts, uploader:, prober:, manifest_path: MANIFEST, io: $stdout)
    slot = opts.fetch(:slot)
    Dir.mktmpdir('site-media') do |work|
      files, entry = plan(opts, work: work, prober: prober)
      manifest = read_manifest(manifest_path)
      before = manifest['slots'][slot]
      files.each_key { |name| io.puts "#{opts[:dry_run] ? 'would upload' : 'upload'} media/#{name}" }
      io.puts "manifest slot #{slot}:"
      io.puts "  - #{JSON.generate(before)}" if before
      io.puts "  + #{JSON.generate(entry)}"
      return entry if opts[:dry_run]

      files.each do |name, path|
        key = "media/#{name}"
        next io.puts("skip #{key} (already in the bucket)") if uploader.exists?(key)

        uploader.put(path, key, content_type: CONTENT_TYPES.fetch(File.extname(name)), cache_control: CACHE_CONTROL)
      end
      manifest['slots'] = manifest['slots'].merge(slot => entry).sort.to_h
      File.write(manifest_path, "#{JSON.pretty_generate(manifest)}\n")
      entry
    end
  end

  # The real S3 side, through the aws CLI.
  class AwsUploader
    def initialize(bucket:, runner: DEFAULT_RUNNER, env: SiteMediaPublish.aws_env)
      @bucket = bucket
      @runner = runner
      @env = env
    end

    def exists?(key)
      _out, status = @runner.call([ 'aws', 's3api', 'head-object', '--bucket', @bucket, '--key', key ], @env)
      status.success?
    end

    def put(path, key, content_type:, cache_control:)
      out, status = @runner.call([ 'aws', 's3', 'cp', path, "s3://#{@bucket}/#{key}",
                                   '--content-type', content_type, '--cache-control', cache_control ], @env)
      raise Error, "upload of #{key} failed:\n#{out}" unless status.success?
    end
  end

  def parse(argv)
    opts = {}
    OptionParser.new do |o|
      o.banner = 'usage: site_media_publish.rb --slot NAME (--video FILE --poster FILE | --audio FILE ' \
                 '[--alignment FILE]) --srt FILE --title TEXT [--alt TEXT] [--dry-run]'
      %i[slot video audio poster srt alignment title alt].each do |flag|
        o.on("--#{flag} VALUE") { |v| opts[flag] = v }
      end
      o.on('--dry-run') { opts[:dry_run] = true }
    end.parse!(argv)
    %i[slot srt title].each { |flag| raise Error, "--#{flag} is required" unless opts[flag] }
    opts
  end

  def main(argv)
    opts = parse(argv)
    uploader = opts[:dry_run] ? nil : AwsUploader.new(bucket: bucket)
    publish(opts, uploader: uploader, prober: ->(path) { probe(path) })
    0
  rescue Error, OptionParser::ParseError, KeyError, Errno::ENOENT => e
    warn "site_media_publish: #{e.message}"
    1
  end
end

exit SiteMediaPublish.main(ARGV) if $PROGRAM_NAME == __FILE__
