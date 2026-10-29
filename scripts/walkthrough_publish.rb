#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require_relative 'change_docker'
require_relative 'change_screenshot_upload'
require_relative 'prototype_flats'

# Publishes a rendered walkthrough MP4 to GitHub the way cf:screenshot publishes
# images: through ChangeScreenshotUpload (the toolkit's one raw HTTPS call, so
# none is duplicated here), then splices the returned url into the artifact the
# request is about.
#
# Target, in order: an explicit flag (--pr N, --issue N, --none); else the open
# pull request of the current branch; else nothing. With no target, no upload
# happens at all and the file on disk is the deliverable.
#
# GitHub rejects an attachment over MAX_BYTES. A larger MP4 is transcoded to a
# smaller PR copy beside it in the pinned FFMPEG_IMAGE container; the original
# is never touched. Every failure degrades to leaving the file on disk.
module WalkthroughPublish
  # GitHub's user-attachments size limit for video on a free or pro repo.
  MAX_BYTES = 10 * 1024 * 1024
  START_MARK = '<!-- cf:walkthrough:start -->'
  END_MARK = '<!-- cf:walkthrough:end -->'
  HEADING = '## Walkthrough'
  WORK = '/work'
  # Progressively smaller PR copies; each rung is tried until one fits.
  Rung = Struct.new(:crf, :scale)
  LADDER = [ Rung.new(28, nil), Rung.new(32, nil), Rung.new(36, 960) ].freeze

  Target = Struct.new(:kind, :number, :comment, keyword_init: true)
  Outcome = Struct.new(:path, :url, :target, :message, keyword_init: true)

  module_function

  # The marker-delimited section. The bare url on its own line is what GitHub
  # renders as an inline player.
  def section(url, boards: []) = "#{START_MARK}\n#{block(url, boards: boards)}\n#{END_MARK}"

  # The overview boards (cf:prototype flats) sit under the video as images.
  def block(url, boards: [])
    images = boards.map { |label, board_url| "![Flats overview, #{label}](#{board_url})" }
    [ "#{HEADING}\n\n#{url}", *images ].join("\n\n")
  end

  # Idempotent: replaces an existing section in place, else appends one.
  def splice(body, url, boards: [])
    body = body.to_s
    block = section(url, boards: boards)
    pattern = /#{Regexp.escape(START_MARK)}.*?#{Regexp.escape(END_MARK)}/m
    return body.sub(pattern) { block } if body.match?(pattern)

    body.strip.empty? ? "#{block}\n" : "#{body.rstrip}\n\n#{block}\n"
  end

  def target(kind, number, comment) = Target.new(kind: kind, number: number, comment: comment)

  # `--pr`/`--issue` win, `--none` forces no target, else the branch's open PR.
  def resolve_target(argv, gh:)
    return nil if argv.include?('--none')

    comment = argv.include?('--comment')
    pr = flag_value(argv, '--pr')
    return target(:pr, pr, comment) if pr

    issue = flag_value(argv, '--issue')
    return target(:issue, issue, comment) if issue

    current_branch_pr(gh, comment)
  end

  def current_branch_pr(gh, comment)
    branch, ok = gh.call('git', 'branch', '--show-current')
    return nil unless ok && !branch.empty?

    out, ok = gh.call('gh', 'pr', 'list', '--head', branch, '--state', 'open', '--json', 'number', '--jq',
                      '.[0].number')
    ok && out.match?(/\A\d+\z/) ? target(:pr, out, comment) : nil
  end

  def flag_value(argv, flag)
    i = argv.index(flag)
    return nil unless i

    value = argv[i + 1].to_s
    raise ArgumentError, "#{flag} needs a number" unless value.match?(/\A\d+\z/)

    value
  end

  # Returns [path, note]. Under the limit the original is the PR copy; over it,
  # a smaller sibling is made, or a nil path when no rung fits.
  def shrink(mp4, runner: method(:docker_run), max_bytes: MAX_BYTES)
    return [ mp4, nil ] if File.size(mp4) <= max_bytes

    out = "#{mp4.delete_suffix('.mp4')}.pr.mp4"
    fit = LADDER.find do |rung|
      _out, status = runner.call(transcode_argv(mp4, out, rung))
      status.success? && File.exist?(out) && File.size(out) <= max_bytes
    end
    return [ out, "transcoded a PR copy at crf #{fit.crf}" ] if fit

    FileUtils.rm_f(out)
    [ nil, "no transcode fit under #{max_bytes} bytes; left on disk" ]
  end

  def docker_run(argv) = Open3.capture2e(*argv)

  def transcode_argv(mp4, out, rung)
    vf = rung.scale ? [ '-vf', "scale=#{rung.scale}:-2" ] : []
    args = [ '-y', '-i', work_path(mp4) ] + vf +
           [ '-c:v', 'libx264', '-preset', 'medium', '-crf', rung.crf.to_s, '-pix_fmt', 'yuv420p',
             '-c:a', 'aac', '-b:a', '96k', '-movflags', '+faststart', work_path(out) ]
    ChangeDocker.run_command(network: 'none', image: ChangeDocker::FFMPEG_IMAGE, args: args,
                             mounts: { File.dirname(File.expand_path(mp4)) => WORK }, workdir: WORK)
  end

  def work_path(path) = "#{WORK}/#{File.basename(path)}"

  # Runs a command, optionally feeding stdin. Returns [output, ok?].
  def default_gh
    lambda do |*argv, stdin: nil|
      out, status = Open3.capture2e(*argv.map(&:to_s), stdin_data: stdin.to_s)
      [ out.strip, status.success? ]
    end
  end

  # Attaches the url to the target. Returns an error string or nil.
  def attach(target, url, gh:, boards: [])
    sub = target.kind == :pr ? 'pr' : 'issue'
    return attach_comment(sub, target.number, url, gh, boards) if target.comment

    n = target.number
    body, ok = gh.call('gh', sub, 'view', n, '--json', 'body', '--jq', '.body')
    return failure(sub, 'view', body) unless ok

    out, ok = gh.call('gh', sub, 'edit', n, '--body-file', '-', stdin: splice(body, url, boards: boards))
    ok ? nil : failure(sub, 'edit', out)
  end

  def attach_comment(sub, number, url, gh, boards = [])
    out, ok = gh.call('gh', sub, 'comment', number, '--body-file', '-', stdin: "#{block(url, boards: boards)}\n")
    ok ? nil : failure(sub, 'comment', out)
  end

  def failure(sub, verb, out) = "gh #{sub} #{verb} failed: #{out}"

  # The whole step. Never raises; the MP4 stays on disk whatever happens.
  def publish(mp4, argv: [], gh: default_gh, uploader: nil, shrink: method(:shrink), boards: {})
    target = resolve_target(argv, gh: gh)
    return Outcome.new(path: mp4, message: 'no GitHub target; left on disk') unless target

    copy, note = shrink.call(mp4)
    return Outcome.new(path: mp4, target: target, message: note) unless copy

    uploader ||= ChangeScreenshotUpload.new
    result = uploader.upload(copy)
    return Outcome.new(path: mp4, target: target, message: "upload skipped: #{result.error}") unless result.uploaded?

    error = attach(target, result.url, gh: gh, boards: upload_boards(uploader, boards))
    Outcome.new(path: mp4, url: result.url, target: target, message: error || note)
  rescue StandardError => e
    Outcome.new(path: mp4, message: "publish failed: #{e.class}: #{e.message}")
  end

  # Uploads each existing board PNG; one that fails to upload is skipped, never
  # fatal. Returns [[label, url], ...] in the order given.
  def upload_boards(uploader, boards)
    boards.filter_map do |label, path|
      next unless File.file?(path)

      result = uploader.upload(path)
      [ label, result.url ] if result.uploaded?
    end
  end

  # The flats overview PNGs for a walkthrough dir or a rendered MP4 under its
  # .cache/render/<hash>/. Only boards that exist are returned.
  def locate_boards(arg)
    root = File.directory?(arg) ? arg : File.expand_path("../../..", File.dirname(arg))
    PrototypeFlats::THEMES.to_h { |theme| [ theme, PrototypeFlats.overview_path(root, theme) ] }
                          .select { |_theme, path| File.file?(path) }
  end

  # Accepts an MP4 or a walkthrough/<slug> dir (newest rendered MP4 in it).
  def locate(arg)
    return arg if File.file?(arg)

    Dir.glob(File.join(arg, '.cache', 'render', '*', 'walkthrough.mp4')).max_by { |f| File.mtime(f) }
  end
end

if __FILE__ == $PROGRAM_NAME
  usage = 'usage: walkthrough_publish.rb <walkthrough.mp4 | walkthrough/<slug>> ' \
          '[--pr N | --issue N | --none] [--comment]'
  arg = ARGV.first
  abort(usage) if arg.nil? || arg.start_with?('--')
  mp4 = WalkthroughPublish.locate(arg) || abort("no rendered MP4 under #{arg}")
  out = WalkthroughPublish.publish(File.expand_path(mp4), argv: ARGV.drop(1),
                                 boards: WalkthroughPublish.locate_boards(File.expand_path(arg)))
  target = out.target
  puts "mp4 #{out.path}"
  puts "url #{out.url}" if out.url
  puts "target #{target.kind} ##{target.number}" if target && out.url
  puts out.message if out.message
end
