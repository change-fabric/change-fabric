#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'tmpdir'
require 'uri'
require_relative 'change_boot'
require_relative 'change_config'
require_relative 'change_docker'
require_relative 'change_screenshot_capture'
require_relative 'change_screenshot_upload'

# The cf:screenshot entry point: what visibly changed on screen between two git
# refs.
#
# It boots the app at a base ref inside an ephemeral git worktree, photographs
# every configured route at every configured viewport, tears that down, boots
# HEAD in the main working tree, photographs the same matrix again, pixel-diffs
# each pair, and keeps only the pairs that actually differ. Unchanged pairs are
# discarded and never uploaded, so what reaches a pull request is signal only.
#
# Usage: change_screenshot.rb [--base REF] [--base-url URL] [--config PATH]
#        [--profile NAME] [--out DIR] [--pr NUMBER] [--no-upload]
#
# Three decisions in here are load-bearing and worth reading before changing
# anything:
#
# - The base ref is a merge-base, not a branch tip. Merge-base is the only
#   choice that guarantees the diff is caused by this branch alone rather than
#   by trunk drift that landed after the branch forked.
# - The base side boots with `chdir` set to the worktree, not the repo root.
#   Booting it from the main working tree would boot HEAD's code and produce a
#   same-ref-twice diff, presented as a real one.
# - Between the two sides the old server is verified gone, not assumed gone.
#   The single worst failure mode for a before/after tool is photographing the
#   same ref twice, so a stuck port fails loudly and the second capture never
#   runs.
class ChangeScreenshot
  include ChangeBoot

  # How long the old server gets to stop answering after `boot.down` exits, and
  # how often it is asked. The same order of magnitude as wait_healthy's own
  # polling, without making a stuck-port failure slow to surface.
  VERIFY_GONE_TIMEOUT = 30
  VERIFY_GONE_INTERVAL = 1

  DEFAULT_OUT_DIR = 'cf-screenshots'

  Args = Struct.new(:base, :base_url, :config_path, :profile, :out_dir, :pr, :upload, keyword_init: true)

  # How the base ref is reached. Exactly one of the two is set: an
  # already-running url given with --base-url, or a commit to check out into an
  # ephemeral worktree and boot.
  BaseSide = Struct.new(:url, :commit, keyword_init: true) do
    def external? = !url.to_s.empty?
  end

  def self.main(argv) = new(argv).run

  def initialize(argv)
    @args = parse_args(argv)
  end

  def run
    return abort_setup('docker is not available') unless ChangeDocker.available?

    config = load_config
    base_side = plan_base_side(config)
    preflight(config.boot, base_side)
    report(config, capture_both(config, base_side))
  rescue ChangeConfig::ConfigError => e
    abort_setup(e.message)
  end

  # --- ref resolution ---------------------------------------------------------

  # Resolution order, in full:
  #
  #   1. --base <ref>: used literally, no merge-base computation. The escape
  #      hatch for a branching model this tool guesses wrong.
  #   2. A resolvable pull request: merge-base of HEAD and origin/<its base>.
  #   3. Otherwise: merge-base of HEAD and the repo's default branch, read from
  #      origin/HEAD and falling back to `gh repo view`.
  #
  # No step guesses a branch name. A repo with no resolvable default branch
  # aborts saying so, because guessing "main" against a repo that uses
  # something else produces a diff that is wrong without looking wrong.
  def resolve_base_ref
    return @args.base if @args.base

    pr_base = pr_base_ref
    return merge_base!("origin/#{pr_base}") if pr_base

    default = default_branch_ref
    unless default
      abort_and_exit('cannot resolve a base ref: no --base was given, no pull request base branch could be read, ' \
                     'and the default branch is unknown (origin/HEAD is not set and `gh repo view --json ' \
                     'defaultBranchRef` did not answer). Pass --base <ref> explicitly.')
    end
    merge_base!(default)
  end

  def pr_base_ref
    args = [ 'gh', 'pr', 'view' ]
    args << @args.pr.to_s if @args.pr
    out, ok = capture(*args, '--json', 'baseRefName', '--jq', '.baseRefName')
    ok && !out.empty? ? out : nil
  end

  def default_branch_ref
    out, ok = git('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD')
    return out if ok && !out.empty?

    out, ok = capture('gh', 'repo', 'view', '--json', 'defaultBranchRef', '--jq', '.defaultBranchRef.name')
    ok && !out.empty? ? "origin/#{out}" : nil
  end

  def merge_base!(ref)
    out, ok = git('merge-base', 'HEAD', ref)
    return out if ok && !out.empty?

    abort_and_exit("git merge-base HEAD #{ref} failed; #{ref} is not a ref this repo can resolve. " \
                   'Fetch it, or pass --base <ref> explicitly.')
  end

  # --- the two sides ----------------------------------------------------------

  # `--base-url` skips the worktree and the boot for the base side entirely and
  # points capture at something already running (a preview deployment, a server
  # started by hand). It exists because not every `boot.up` command is
  # relocatable to an arbitrary worktree path: absolute paths, a shared pidfile,
  # a fixed port claimed elsewhere.
  def plan_base_side(config)
    return BaseSide.new(url: @args.base_url) if @args.base_url

    unless config.boot.up?
      abort_and_exit('the base ref cannot be booted: this CHANGE.md sets no boot.up, which means "assume the app ' \
                     'is already running", and only one app can be already running. Point --base-url at a second ' \
                     'running instance of the base ref, or configure boot.up.')
    end
    BaseSide.new(commit: resolve_base_ref)
  end

  # A health url already answering before anything has been booted means a
  # stale server is holding the port, and every capture from here would be of
  # whatever that server is serving.
  def preflight(boot, base_side)
    return if base_side.external? || !boot.up? || boot.health_url.empty?

    ok, = healthy?(boot)
    return unless ok

    abort_and_exit("#{boot.health_url} is already answering before anything was booted, so a stale server is " \
                   "holding the port and every capture would be of that server.#{listener_clause(boot)}")
  end

  def capture_both(config, base_side)
    boot = config.boot
    out_dir = File.expand_path(@args.out_dir)
    ChangeDocker.with_network(boot.network) do |network|
      ChangeDocker.with_browserless(network: network.name) do |session|
        capturer = ChangeScreenshotCapture.new(config.lane('browserless'), lane_context(config, network, session))
        before, after = run_sides(
          boot: boot,
          base_capture: -> { capture_base(config, base_side, capturer, session, out_dir) },
          head_capture: -> { capture_head(config, capturer, session, out_dir) },
          verify: !base_side.external?
        )
        { pairs: capturer.diff_pairs(before: before, after: after, session: session),
          before: before, after: after, out_dir: out_dir, base_side: base_side }
      end
    end
  end

  # The order the whole tool rests on: base side, then a positive confirmation
  # that its server is gone, then the head side. Split out with both captures as
  # blocks so the sequencing (and its refusal to continue) is readable and
  # testable on its own.
  def run_sides(boot:, base_capture:, head_capture:, verify: true)
    before = base_capture.call
    require_server_gone(boot) if verify
    [ before, head_capture.call ]
  end

  def capture_base(config, base_side, capturer, session, out_dir)
    if base_side.external?
      return capturer.capture(session: session, side: 'before', out_dir: out_dir, base_url: base_side.url)
    end

    boot = config.boot
    in_worktree(base_side.commit) do |dir|
      # chdir is the worktree, never repo_root: booting from the main working
      # tree here would photograph HEAD twice.
      boot_up(boot, chdir: dir)
      wait_healthy(boot)
      capturer.capture(session: session, side: 'before', out_dir: out_dir)
    ensure
      boot_down(boot, chdir: dir)
    end
  end

  def capture_head(config, capturer, session, out_dir)
    boot = config.boot
    boot_up(boot, chdir: repo_root)
    wait_healthy(boot)
    capturer.capture(session: session, side: 'after', out_dir: out_dir)
  ensure
    boot_down(boot, chdir: repo_root)
  end

  # `git worktree add --detach` matters: a merge-base is a commit, not a
  # branch, and a non-detached add of a bare commit fails.
  def in_worktree(commit)
    dir = Dir.mktmpdir('cf-screenshot-base-')
    _out, ok = git('worktree', 'add', '--detach', dir, commit)
    abort_and_exit("git worktree add --detach #{dir} #{commit} failed; cannot capture the base ref") unless ok

    begin
      yield dir
    ensure
      git('worktree', 'remove', '--force', dir)
      # `worktree remove` already deletes the directory; this only catches the
      # case where it did not, so a run never leaves a checkout of the base ref
      # sitting in the temp directory.
      FileUtils.rm_rf(dir)
    end
  end

  # --- the verify-gone check --------------------------------------------------

  # True once the health url has stopped answering with `expect_status`. A
  # connection refused, a non-2xx, and a curl failure all count as gone: the
  # question is whether the old server is still serving, not why it is not.
  def verify_gone(boot, deadline_seconds: VERIFY_GONE_TIMEOUT)
    return true if boot.health_url.empty?

    deadline = Time.now + deadline_seconds
    loop do
      ok, = healthy?(boot)
      return true unless ok
      return false if Time.now >= deadline

      sleep VERIFY_GONE_INTERVAL
    end
  end

  # `boot.down` exiting is not evidence. A pidfile can hold a wrapper process
  # while the real server keeps the port, and the next boot then fails into
  # "address already in use" whose health check passes against the server it
  # did not start.
  def require_server_gone(boot)
    return if verify_gone(boot)

    abort_and_exit("the base ref's server is still answering #{boot.health_url} with " \
                   "#{boot.health_status} #{VERIFY_GONE_TIMEOUT}s after teardown.#{listener_clause(boot)} " \
                   'Refusing to capture the head ref: the result would be the same ref photographed twice ' \
                   'and presented as a real diff. Stop that process and re-run.')
  end

  # Best effort, and explicitly so: lsof may be absent, or may not see a
  # process owned by another user. A missing listener line must not turn the
  # real message into an error of its own.
  def listener_clause(boot)
    port = port_of(boot.health_url)
    return '' unless port

    out, ok = capture('lsof', '-nP', "-iTCP:#{port}", '-sTCP:LISTEN')
    return " Port #{port}; no listener reported by lsof." unless ok && !out.empty?

    " Port #{port}, listening process:\n#{out}"
  end

  def port_of(url)
    uri = URI.parse(url.to_s)
    uri.port
  rescue StandardError
    nil
  end

  # --- output -----------------------------------------------------------------

  def report(config, result)
    pairs = result[:pairs]
    kept = pairs.select(&:changed)
    manifest_path = write_manifest(config, result, kept)
    uploads = upload(kept)
    summarize(result, pairs, kept, manifest_path, uploads)
    0
  end

  def write_manifest(config, result, kept)
    path = File.join(result[:out_dir], 'manifest.json')
    FileUtils.mkdir_p(result[:out_dir])
    File.write(path, "#{JSON.pretty_generate(manifest(config, result, kept))}\n")
    path
  end

  # The manifest is the run's own record, and the upload step and the Demo
  # composer both read it: a run can be re-uploaded without being re-captured.
  def manifest(config, result, kept)
    {
      'project' => config.project,
      'baseCommit' => result[:base_side].commit,
      'baseUrl' => result[:base_side].url,
      'headCommit' => head_sha,
      'outDir' => result[:out_dir],
      'capturedPairs' => result[:pairs].size,
      'keptPairs' => kept.size,
      'pairs' => result[:pairs].map { |pair| manifest_pair(pair) }
    }
  end

  def manifest_pair(pair)
    {
      'route' => pair.route, 'viewport' => pair.viewport,
      'before' => pair.before_path, 'after' => pair.after_path,
      'diffPercent' => pair.diff_percent, 'changed' => pair.changed,
      'reason' => pair.reason, 'missingSide' => pair.missing_side
    }
  end

  # Zero kept pairs is a valid, successful outcome, so there is nothing to
  # upload and nothing to offer a pull request. Reporting "no visible change"
  # is the answer, not a failure.
  def upload(kept)
    return [] if !@args.upload || kept.empty?

    uploader = ChangeScreenshotUpload.new
    kept.flat_map { |pair| [ pair.before_path, pair.after_path ].compact }
        .map { |path| uploader.upload(path) }
  end

  def summarize(result, pairs, kept, manifest_path, uploads)
    log("[screenshot] captured #{pairs.size} route/viewport pair(s); #{kept.size} differ")
    kept.each { |pair| log("[screenshot]   #{pair.viewport} #{pair.route}: #{pair.reason}") }
    log('[screenshot] no visible change; nothing to upload and nothing to offer a pull request') if kept.empty?
    summarize_uploads(uploads)
    log("[screenshot] manifest: #{manifest_path}")
    log("[screenshot] images:   #{result[:out_dir]}")
  end

  def summarize_uploads(uploads)
    return if uploads.empty?

    failed = uploads.reject(&:uploaded?)
    uploads.select(&:uploaded?).each { |item| log("[screenshot] uploaded #{File.basename(item.path)}: #{item.url}") }
    return if failed.empty?

    log("[screenshot] upload degraded (#{failed.first.error}); these stayed local:")
    failed.each { |item| log("[screenshot]   #{item.path}") }
  end

  # --- plumbing ---------------------------------------------------------------

  private

  def parse_args(argv)
    args = Args.new(config_path: ChangeConfig::DEFAULT_PATH, out_dir: DEFAULT_OUT_DIR, upload: true)
    OptionParser.new do |o|
      o.on('--base REF') { |value| args.base = value }
      o.on('--base-url URL') { |value| args.base_url = value }
      o.on('--config PATH') { |value| args.config_path = value }
      o.on('--profile NAME') { |value| args.profile = value }
      o.on('--out DIR') { |value| args.out_dir = value }
      o.on('--pr NUMBER') { |value| args.pr = value }
      o.on('--no-upload') { args.upload = false }
    end.parse(argv)
    args
  end

  def load_config = ChangeConfig.load(@args.config_path, profile: @args.profile)

  # The lane context ChangeScreenshotCapture inherits its base_url and its
  # browserless session from. It is deliberately the run context shape the
  # audit lanes already take, so the capture class stays a lane subclass rather
  # than a lane-shaped thing with its own private plumbing.
  def lane_context(config, network, session)
    LaneContext.new(network: network.name, target_url: config.boot.target_url,
                    browserless: session, logger: method(:log))
  end

  LaneContext = Struct.new(:network, :target_url, :browserless, :logger, keyword_init: true) do
    def log(message) = logger.call(message)
  end

  def git(*args) = capture('git', '-C', repo_root, *args)

  # Every shell-out goes through here, so a test can watch what this class
  # actually asks git and gh for without a fixture repo.
  def capture(*argv)
    out, status = Open3.capture2e(*argv)
    [ out.to_s.strip, status.success? ]
  rescue StandardError => e
    [ e.message, false ]
  end

  def repo_root
    @repo_root ||= begin
      out, ok = capture('git', 'rev-parse', '--show-toplevel')
      ok ? out : Dir.pwd
    end
  end

  def head_sha
    @head_sha ||= begin
      out, ok = git('rev-parse', 'HEAD')
      ok ? out : ''
    end
  end

  def log(message) = warn(message)

  def abort_setup(message)
    warn("[screenshot] setup error: #{message}")
    2
  end

  def abort_and_exit(message)
    warn("[screenshot] #{message}")
    exit 2
  end
end

exit(ChangeScreenshot.main(ARGV)) if __FILE__ == $PROGRAM_NAME
