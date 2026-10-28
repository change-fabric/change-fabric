#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require_relative 'change_docker'
require_relative 'change_screenshot_upload'

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
  LADDER = [
    { crf: 28, scale: nil }, { crf: 32, scale: nil }, { crf: 36, scale: 960 }
  ].freeze

  Target = Struct.new(:kind, :number, :comment, keyword_init: true)
  Outcome = Struct.new(:path, :url, :target, :message, keyword_init: true)

  module_function

  # The marker-delimited section. The bare url on its own line is what GitHub
  # renders as an inline player.
  def section(url) = "#{START_MARK}\n#{HEADING}\n\n#{url}\n#{END_MARK}"

  # Idempotent: replaces an existing section in place, else appends one.
  def splice(body, url)
    body = body.to_s
    block = section(url)
    pattern = /#{Regexp.escape(START_MARK)}.*?#{Regexp.escape(END_MARK)}/m
    return body.sub(pattern) { block } if body.match?(pattern)

    body.strip.empty? ? "#{block}\n" : "#{body.rstrip}\n\n#{block}\n"
  end

  # `--pr`/`--issue` win, `--none` forces no target, else the branch's open PR.
  def resolve_target(argv, gh:)
    return nil if argv.include?('--none')

    comment = argv.include?('--comment')
    pr = flag_value(argv, '--pr')
    return Target.new(kind: :pr, number: pr, comment: comment) if pr

    issue = flag_value(argv, '--issue')
    return Target.new(kind: :issue, number: issue, comment: comment) if issue

    current_branch_pr(gh, comment)
  end

  def current_branch_pr(gh, comment)
    branch, ok = gh.call('git', 'branch', '--show-current')
    return nil unless ok && !branch.empty?

    out, ok = gh.call('gh', 'pr', 'list', '--head', branch, '--state', 'open', '--json', 'number', '--jq',
                      '.[0].number')
    ok && out.match?(/\A\d+\z/) ? Target.new(kind: :pr, number: out, comment: comment) : nil
  end

  def flag_value(argv, flag)
    i = argv.index(flag)
    i ? (argv[i + 1] || abort("#{flag} needs a number")) : nil
  end

  # Returns [path, note]. Under the limit the original is the PR copy; over it,
  # a smaller sibling is made, or a nil path when no rung fits.
  def shrink(mp4, runner: method(:docker_run), max_bytes: MAX_BYTES)
    return [ mp4, nil ] if File.size(mp4) <= max_bytes

    out = "#{mp4.delete_suffix('.mp4')}.pr.mp4"
    LADDER.each do |rung|
      _out, status = runner.call(transcode_argv(mp4, out, rung))
      fits = status.success? && File.exist?(out) && File.size(out) <= max_bytes
      return [ out, "transcoded a PR copy at crf #{rung[:crf]}" ] if fits
    end
    FileUtils.rm_f(out)
    [ nil, "no transcode fit under #{max_bytes} bytes; left on disk" ]
  end

  def docker_run(argv) = Open3.capture2e(*argv)

  def transcode_argv(mp4, out, rung)
    vf = rung[:scale] ? [ '-vf', "scale=#{rung[:scale]}:-2" ] : []
    args = [ '-y', '-i', "#{WORK}/#{File.basename(mp4)}" ] + vf +
           [ '-c:v', 'libx264', '-preset', 'medium', '-crf', rung[:crf].to_s, '-pix_fmt', 'yuv420p',
             '-c:a', 'aac', '-b:a', '96k', '-movflags', '+faststart', "#{WORK}/#{File.basename(out)}" ]
    ChangeDocker.run_command(network: 'none', image: ChangeDocker::FFMPEG_IMAGE, args: args,
                             mounts: { File.dirname(File.expand_path(mp4)) => WORK }, workdir: WORK)
  end

  # Runs a command, optionally feeding stdin. Returns [output, ok?].
  def default_gh
    lambda do |*argv, stdin: nil|
      out, status = Open3.capture2e(*argv.map(&:to_s), stdin_data: stdin.to_s)
      [ out.strip, status.success? ]
    end
  end

  # Attaches the url to the target. Returns an error string or nil.
  def attach(target, url, gh:)
    sub = target.kind == :pr ? 'pr' : 'issue'
    n = target.number
    if target.comment
      out, ok = gh.call('gh', sub, 'comment', n, '--body-file', '-', stdin: "#{HEADING}\n\n#{url}\n")
      return ok ? nil : "gh #{sub} comment failed: #{out}"
    end

    body, ok = gh.call('gh', sub, 'view', n, '--json', 'body', '--jq', '.body')
    return "gh #{sub} view failed: #{body}" unless ok

    out, ok = gh.call('gh', sub, 'edit', n, '--body-file', '-', stdin: splice(body, url))
    ok ? nil : "gh #{sub} edit failed: #{out}"
  end

  # The whole step. Never raises; the MP4 stays on disk whatever happens.
  def publish(mp4, argv: [], gh: default_gh, uploader: nil, runner: nil, max_bytes: MAX_BYTES)
    target = resolve_target(argv, gh: gh)
    return Outcome.new(path: mp4, message: 'no GitHub target; left on disk') unless target

    copy, note = shrink(mp4, runner: runner || method(:docker_run), max_bytes: max_bytes)
    return Outcome.new(path: mp4, target: target, message: note) unless copy

    result = (uploader || ChangeScreenshotUpload.new).upload(copy)
    return Outcome.new(path: mp4, target: target, message: "upload skipped: #{result.error}") unless result.uploaded?

    error = attach(target, result.url, gh: gh)
    Outcome.new(path: mp4, url: result.url, target: target, message: error || note)
  rescue StandardError => e
    Outcome.new(path: mp4, message: "publish failed: #{e.class}: #{e.message}")
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
  out = WalkthroughPublish.publish(File.expand_path(mp4), argv: ARGV.drop(1))
  puts "mp4 #{out.path}"
  puts "url #{out.url}" if out.url
  puts "target #{out.target.kind} ##{out.target.number}" if out.target && out.url
  puts out.message if out.message
end
