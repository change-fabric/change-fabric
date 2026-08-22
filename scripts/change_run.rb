#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'optparse'
require_relative 'change_apps'
require_relative 'change_artifact'
require_relative 'change_config'
require_relative 'change_docker'
require_relative 'change_findings'
require_relative 'change_gate_check'
require_relative 'change_policy'
require_relative 'change_report'
require_relative 'change_k6_narrative'
require_relative 'change_gate_store'
require_relative 'change_lane_k6'
require_relative 'change_lane_a11y'
require_relative 'change_lane_zap'
require_relative 'change_lane_browserless'

# The change-fabric orchestrator: the one command the cf:change / cf:k6 /
# cf:a11y / cf:zap skills invoke. It reads a project's config, boots the target
# app and waits for its health signal, stands up the ephemeral runners (a shared
# browserless container only when a browser lane runs), executes the requested
# lanes, writes a CSV+Markdown report pair to the Desktop, and records the
# outcome under the git head SHA so the merge gate can consult it later.
#
# Usage: change_run.rb <all|k6|a11y|zap|browserless> [--config PATH] [--profile NAME]
#        [--app NAME]... [--target-url URL] [--health-url URL] [--no-publish]
#        [--for-tag TAGNAME]
#        change_run.rb gate-status [--ref REF] [--config PATH]
#
# --for-tag TAGNAME (0.9.0, trunk + tag releases): resolves the tag against
# change_policy.promotion's tag: rules, runs `all` once per distinct profile
# those rules name (recording each), and refuses to run when the tag already
# exists locally and does not point at HEAD -- the two ways a tag-topology
# sweep could otherwise silently record the wrong thing (right commit, wrong
# profile, or right profile, wrong commit).
#
# gate-status [--ref REF] is read-only: no docker, no boot, no lanes. It
# resolves REF (a tag name, a branch, a SHA; default HEAD), prints every
# promotion rule that matches, and whether the recorded gate already
# satisfies each one, exiting 0 only when every matching rule is satisfied.
# It is what makes change_tag_guard.rb's deny decision reproducible outside
# the hook.
#
# A repo whose CHANGE.md carries a `contributors_team.platform:` block also
# gets a findings artifact (an HTML page with the run's screenshots, per
# viewport recordings, and per viewport PDFs) built and published to the team's
# S3 + CloudFront area after the gate is recorded; `--no-publish` builds the
# bundle locally without uploading it. A repo without that block is untouched
# by all of it.
#
# In a monorepo (change_config.apps, 0.4.0) a bare `all` sweeps every
# registered, enabled app, in registry order, each with its own boot/teardown
# lifecycle, and exits 0 only if every app passed; --app narrows the sweep.
# Single-app mode (no change_config.apps) is unaffected: the registry is
# exactly one synthetic entry pointing at the root CHANGE.md itself.
#
# Everything that stands up gets torn down: the app via the config's `down`
# command, the browser container and any ephemeral network via their block
# helpers. Exit status is 0 when every app's every lane passed, 1 when any
# lane in any app failed, 2 on a setup failure (no docker, bad config, app
# never ready) -- which, for a boot failure inside one app's lifecycle, hard
# -exits the whole sweep rather than continuing to the next app, the correct
# fail-closed behavior for a release gate.
class ChangeRun
  BROWSER_LANES = %w[a11y browserless].freeze
  OUTPUT_TAIL_LINES = 40
  LANE_CLASSES = {
    'k6' => ChangeLaneK6, 'a11y' => ChangeLaneA11y,
    'zap' => ChangeLaneZap, 'browserless' => ChangeLaneBrowserless
  }.freeze

  # Per-lane run context. Lanes talk only to this, never to the run internals:
  # the network to join, the default target url, the browser session (nil unless
  # a browser lane asked for one), and a logger.
  # `media` (0.32.0) is the run's artifact media sink, or nil. It is nil unless
  # the repo carries a `contributors_team.platform:` block, and a lane holding
  # a nil sink captures nothing, which is what keeps the artifact pipeline
  # entirely opt-in.
  Context = Struct.new(:network, :target_url, :health_url, :browserless, :media, :logger, keyword_init: true) do
    def log(message) = logger.call(message)
  end

  Args = Struct.new(:scope, :config_path, :profile, :apps, :target_url, :health_url, :publish, :for_tag, :ref,
                     keyword_init: true)

  def self.main(argv)
    new(argv).run
  end

  def initialize(argv)
    @args = parse_args(argv)
  end

  def run
    return gate_status if @args.scope == 'gate-status'
    return abort_setup('docker is not available') unless ChangeDocker.available?
    return sweep_stale_resources if @args.scope == 'sweep'
    return run_for_tag if @args.for_tag

    run_sweep
  rescue ChangeConfig::ConfigError => e
    abort_setup(e.message)
  end

  private

  def run_sweep
    registry = ChangeAppRegistry.load(@args.config_path)
    entries = @args.apps.empty? ? registry.enabled_entries : registry.fetch(@args.apps)
    results = entries.map { |entry| run_entry(entry, multi: registry.multi_app?) }
    write_rollup(registry, results) if registry.multi_app?
    results.all? { |result| result[:passed] } ? 0 : 1
  end

  # --for-tag TAGNAME: runs the same `run_sweep` once per distinct profile the
  # tag's matching change_policy.promotion tag: rules name, so the recorded
  # gate lands under the right profile for a tag-topology release. Exits 2
  # (via resolve_for_tag_profiles / the HEAD check below) rather than running
  # against a config mistake or the wrong commit.
  def run_for_tag
    profiles = resolve_for_tag_profiles(@args.for_tag)
    original = @args
    codes = profiles.map do |profile|
      @args = original.dup
      @args.profile = profile
      run_sweep
    end
    codes.all?(&:zero?) ? 0 : 1
  ensure
    @args = original if original
  end

  # The distinct `profile` values the tag's matching tag: rules name, after
  # validating the tag against three of the ways a tag-topology sweep could
  # otherwise silently record the wrong thing: no rule governs the tag at
  # all, an explicit --profile conflicts with what the rule(s) name, or the
  # tag already exists locally and points somewhere other than HEAD.
  def resolve_for_tag_profiles(tag)
    policy = ChangePolicy.for_repo(repo_root)
    abort_and_exit("--for-tag #{tag}: no CHANGE.md found; a tag sweep needs a governed repo") unless policy

    rules = policy.tag_rules_for(tag)
    if rules.empty?
      abort_and_exit("--for-tag #{tag}: no change_policy.promotion tag: rule matches this tag; " \
                      'a tag sweep for an ungoverned tag is a config mistake, not a run to make')
    end

    check_tag_head_match(tag)
    profiles = rules.filter_map { |_pattern, rule| policy.profile_for_rule(rule) }.uniq
    check_for_tag_profile_conflict(tag, profiles)
    profiles.empty? ? [ @args.profile ] : profiles
  end

  def check_for_tag_profile_conflict(tag, profiles)
    return if @args.profile.nil? || profiles.empty? || profiles.include?(@args.profile)

    abort_and_exit("--for-tag #{tag}: --profile #{@args.profile} conflicts with the profile(s) " \
                    "its matching rule(s) name (#{profiles.join(', ')})")
  end

  # Refuses to run when the tag already exists locally and points somewhere
  # other than HEAD: right commit under the wrong profile and right profile
  # against the wrong commit are exactly the two silent-wrong-record failure
  # modes --for-tag exists to close. A tag that does not exist locally yet
  # (the normal pre-push case) is not checked; there is nothing to compare
  # against.
  def check_tag_head_match(tag)
    tag_sha = resolve_ref_sha("#{tag}^{commit}")
    return unless tag_sha
    return if tag_sha == head_sha

    abort_and_exit("--for-tag #{tag}: tag points at #{tag_sha[0, 12]} but HEAD is #{head_sha[0, 12]}; " \
                    'check out the commit the tag points at before running --for-tag')
  end

  # Read-only: resolves REF (default HEAD) to a commit, prints every
  # promotion rule that matches it (a branch rule by exact key, tag rules by
  # fnmatch), and whether ChangeGateCheck already considers the recorded gate
  # satisfied for each. No docker, no boot, no lanes -- this is what makes
  # change_tag_guard.rb's and change_merge_guard.rb's own deny decision
  # reproducible outside the hook. Exits 0 only when every matching rule is
  # satisfied, 1 when any is not, 2 when the ref or the policy cannot be
  # resolved at all.
  def gate_status
    ref = @args.ref || 'HEAD'
    root = repo_root
    policy = ChangePolicy.for_repo(root)
    unless policy
      log("[change] gate-status: no CHANGE.md at #{root}; nothing is governed")
      return 0
    end

    sha = resolve_ref_sha("#{ref}^{commit}")
    return abort_setup("gate-status: could not resolve ref '#{ref}' to a commit") unless sha

    rules = matching_rules(policy, ref)
    if rules.empty?
      log("[change] gate-status: no promotion rule matches ref '#{ref}' (#{sha[0, 12]})")
      return 0
    end

    rules.map { |kind, pattern, rule| report_rule_status(policy, root, sha, kind, pattern, rule) }.all? ? 0 : 1
  end

  # The `[kind, pattern-or-branch-name, rule]` triples matching this ref: a
  # branch rule when `ref` is exactly one of `branch_promotion`'s keys, plus
  # every tag rule whose pattern fnmatches `ref`. A bare SHA matches neither,
  # which is the correct "nothing governs this ref by name" answer.
  def matching_rules(policy, ref)
    rules = []
    branch_rule = policy.branch_promotion[ref]
    rules << [ 'branch', ref, branch_rule ] if branch_rule
    policy.tag_rules_for(ref).each { |pattern, rule| rules << [ 'tag', pattern, rule ] }
    rules
  end

  def report_rule_status(policy, root, sha, kind, pattern, rule)
    profile = policy.profile_for_rule(rule)
    apps = ChangeGateCheck.required_apps(root, policy.apps_for_rule(rule))
    check = ChangeGateCheck.new(sha: sha, profile: profile, apps: apps)
    satisfied = check.satisfied?
    status = satisfied ? 'SATISFIED' : 'NOT SATISFIED'
    log("[change] gate-status: #{kind} rule '#{pattern}' (profile=#{profile || '(none)'}): " \
        "#{status}#{check.missing_apps_clause}")
    satisfied
  end

  def resolve_ref_sha(ref)
    out, status = Open3.capture2e('git', '-C', repo_root, 'rev-parse', '--verify', '--quiet', ref)
    status.success? ? out.strip : nil
  end

  def parse_args(argv)
    scope = argv.first
    path = ChangeConfig::DEFAULT_PATH
    profile = nil
    apps = []
    target_url = nil
    health_url = nil
    publish = true
    for_tag = nil
    ref = nil
    OptionParser.new do |o|
      o.on('--config PATH') { |value| path = value }
      o.on('--profile NAME') { |value| profile = value }
      o.on('--app NAME') { |value| apps << value }
      o.on('--target-url URL') { |value| target_url = value }
      o.on('--health-url URL') { |value| health_url = value }
      o.on('--no-publish') { publish = false }
      o.on('--for-tag NAME') { |value| for_tag = value }
      o.on('--ref REF') { |value| ref = value }
    end.parse(argv.drop(1))
    valid = %w[all sweep gate-status] + ChangeConfig::LANES
    abort_and_exit("scope must be one of: #{valid.join(', ')}") unless valid.include?(scope)
    Args.new(scope: scope, config_path: path, profile: profile, apps: apps, target_url: target_url,
             health_url: health_url, publish: publish, for_tag: for_tag, ref: ref)
  end

  def overrides
    { target_url: @args.target_url, health_url: @args.health_url }.compact
  end

  # Force-removes any `cf-change-*` container or network left behind by a run
  # that crashed before its own teardown ran. Takes no CHANGE.md, since it is
  # meant to run standalone between runs, not as part of one.
  #
  # Per-app runs are sequential today (never concurrent), so a global reap of
  # every cf-change-* resource is safe. If per-app runs ever become
  # concurrent, this would reap a sibling app's still-live containers; revisit
  # this method before adding any concurrency.
  def sweep_stale_resources
    removed = ChangeDocker.sweep
    removed[:containers].each { |name| log("[change] removed stale container: #{name}") }
    removed[:networks].each { |name| log("[change] removed stale network: #{name}") }
    log("[change] sweep: #{removed[:containers].size} container(s), #{removed[:networks].size} network(s) removed")
    0
  end

  # One app's full boot -> lanes -> report -> gate-record cycle. `multi` names
  # the run in every log line and report filename only when this sweep covers
  # more than one app, so a single-app repo's output is unchanged.
  def run_entry(entry, multi:)
    config = entry.load(profile: @args.profile, overrides: overrides)
    log("[change] warning: #{config.spec_version_mismatch}") if config.spec_version_mismatch
    label = multi ? entry.name : nil
    log("[change] app: #{entry.name}") if multi
    lanes = resolve_lanes(config)
    artifact = ChangeArtifactStep.for(repo_root: repo_root, publish: @args.publish, label: label)
    findings, instances = with_app(config, artifact) { |ctx| execute(config, lanes, ctx) }
    report = write_report(config, findings, lanes, instances, app: label)
    record_gate(config, findings, report, app: label)
    summarize(findings, report, app: label)
    publish_artifact(artifact, config, findings, report, app: label)
    { app: entry.name, passed: findings.passed?, failing: findings.failures.size, report: File.basename(report[:markdown]) }
  end

  def write_rollup(registry, results)
    rollup = ChangeReport.rollup(project: registry.project, scope: @args.scope, rows: results)
    log("[change] sweep report: #{rollup[:markdown]}")
  end

  def resolve_lanes(config)
    return config.enabled_lanes if @args.scope == 'all'

    [ @args.scope ]
  end

  # Boots the app, waits for health, then yields a context to run lanes in,
  # tearing the app down afterward. Network and browser lifecycle nest inside so
  # they too are always cleaned up.
  def with_app(config, artifact = nil)
    boot = config.boot
    boot_up(boot)
    wait_healthy(boot)
    ChangeDocker.with_network(boot.network) do |network|
      with_context(config, network, artifact) { |ctx| yield ctx }
    end
  ensure
    boot_down(boot)
  end

  def with_context(config, network, artifact = nil)
    ctx_args = {
      network: network.name, target_url: config.boot.target_url,
      health_url: config.boot.health_url, media: artifact&.media, logger: method(:log)
    }
    if browser_needed?(config)
      ChangeDocker.with_browserless(network: network.name) do |session|
        yield Context.new(browserless: session, **ctx_args)
      end
    else
      yield Context.new(browserless: nil, **ctx_args)
    end
  end

  def browser_needed?(config) = !(resolve_lanes(config) & BROWSER_LANES).empty?

  # Returns the lane instances alongside their findings so report_sections
  # can read a lane's own post-run state (today, browserless's per-cell
  # timing) without changing what #run itself returns.
  def execute(config, lanes, ctx)
    findings = Findings.new
    instances = {}
    lanes.each do |name|
      log("[change] running #{name} lane")
      lane = LANE_CLASSES.fetch(name).new(config.lane(name), ctx)
      Array(lane.run).each { |finding| findings.add(finding) }
      instances[name] = lane
    end
    [ findings, instances ]
  end

  def boot_up(boot)
    return unless boot.up?

    log("[change] booting: #{boot.up}")
    out, status = Open3.capture2e(boot_env(boot), boot.up, chdir: repo_root)
    return if status.success?

    abort_and_exit("boot command failed: #{boot.up}\n--- boot output (last #{OUTPUT_TAIL_LINES} lines) ---\n#{tail(out)}")
  end

  # Parses each configured boot.env_file (simple KEY=VALUE lines, no shell
  # `source`, so no secret is ever echoed) and merges them into the inherited
  # process environment, later files winning over earlier ones. This is the
  # shell-level equivalent of `set -a; source .env.local; set +a`: it makes a
  # compose `build.args:` entry's `${VAR}` interpolation resolve without the
  # author having to pre-export anything. Fails fast, by name, when a declared
  # file is missing.
  def boot_env(boot)
    files = boot.env_files
    return {} if files.empty?

    files.each_with_object({}) do |path, merged|
      abort_and_exit("boot.env_file not found: #{path}") unless File.exist?(path)

      merged.merge!(parse_env_file(path))
    end
  end

  def parse_env_file(path)
    File.readlines(path).each_with_object({}) do |line, env|
      stripped = line.strip
      next if stripped.empty? || stripped.start_with?('#')

      key, value = stripped.delete_prefix('export ').split('=', 2)
      next unless key && value

      env[key.strip] = value.strip.gsub(/\A['"]|['"]\z/, '')
    end
  end

  def boot_down(boot)
    return if boot.down.empty?

    log("[change] tearing down: #{boot.down}")
    out, status = Open3.capture2e(boot.down, chdir: repo_root)
    log("[change] teardown command failed: #{boot.down}\n--- teardown output (last #{OUTPUT_TAIL_LINES} lines) ---\n#{tail(out)}") unless status.success?
  end

  # Polls the health url from the host until it returns the expected status or
  # the timeout elapses. A run with no health url skips straight through, trusting
  # the boot command to have blocked until ready. Carries the last poll's own
  # curl output into the timeout message, so "never became healthy" names the
  # actual response (a connection refused, a wrong status, a TLS failure)
  # instead of leaving the cause to be re-discovered by hand.
  def wait_healthy(boot)
    return if boot.health_url.empty?

    deadline = Time.now + boot.health_timeout
    last_out = nil
    loop do
      ok, last_out = healthy?(boot)
      return if ok

      if Time.now > deadline
        abort_and_exit("app never became healthy at #{boot.health_url}\n--- last health check output ---\n#{tail(last_out)}")
      end
      sleep 2
    end
  end

  # The health poll goes through curl, not Net::HTTP, on purpose. Local dev
  # stacks are commonly fronted by a local CA (a Caddy dev cert), which the OS
  # keychain trusts but Ruby's OpenSSL does not by default, so Net::HTTP raises
  # "certificate verify failed" against a URL a browser and curl both accept.
  # curl trusts the system trust store (and honors SSL_CERT_FILE/SSL_CERT_DIR
  # when set), so the check works against a local-CA https health url with no
  # extra configuration. A short per-attempt timeout keeps the outer deadline
  # loop responsive.
  # Returns [ok?, output] so a caller giving up on the timeout can carry the
  # last attempt's own diagnostic into its own message.
  def healthy?(boot)
    out, status = Open3.capture2e(
      'curl', '-sS', '-o', '/dev/null', '-w', '%{http_code}', '--max-time', '5', boot.health_url
    )
    [ status.success? && out.strip.to_i == boot.health_status, out ]
  rescue StandardError => e
    [ false, e.message ]
  end

  # A bounded tail of captured subprocess output, so a noisy build log stays
  # readable while the line that actually explains the failure is still there.
  def tail(out)
    out.to_s.lines.last(OUTPUT_TAIL_LINES).join
  end

  def write_report(config, findings, lanes, instances, app:)
    ChangeReport.new(
      project: config.project, scope: @args.scope, findings: findings, app: app,
      meta: report_meta(config, findings),
      sections: report_sections(config, lanes, instances)
    ).write
  end

  # `profile`/`target`/`lane targets` (0.4.0) state which deployment this
  # report actually audited, not just which profile was requested, so the
  # exact silent-mismatch a profile-unaware lane could otherwise cause (one
  # lane auditing a different host than the rest) is visible in the artifact
  # itself rather than depending on a careful read of the CSV's target column.
  def report_meta(config, findings)
    {
      'head' => head_sha, 'lanes' => findings.lanes.join(', '),
      'profile' => config.profile || '(none)', 'target' => config.boot.target_url,
      'lane targets' => config.lane_targets.map { |lane, targets| "#{lane}=#{targets.join(',')}" }.join(', ')
    }
  end

  # Narrative sections that belong in the Markdown but not the CSV: the k6
  # lane's scenario narrative, and (F6 step 1) browserless's own per-cell
  # timing table read off the instance that already ran it.
  def report_sections(config, lanes, instances)
    sections = []
    sections << ChangeK6Narrative.section(config.lane('k6')['scenario']) if lanes.include?('k6')
    sections << instances['browserless']&.timing_section if lanes.include?('browserless')
    sections.compact
  end

  # Records the outcome under the head SHA. Only a comprehensive `all` run that
  # passed satisfies the release merge gate; a single-lane run records its own
  # scope and never unlocks a protected-branch merge. `app` (0.4.0) merges this
  # entry into the (sha, profile) record's per-app map instead of overwriting
  # it, so a monorepo swept one `--app` at a time still ends up with one
  # complete record.
  def record_gate(config, findings, report, app:)
    ChangeGateStore.new(head_sha, profile: config.profile).record(
      scope: @args.scope, status: findings.passed? ? 'pass' : 'fail',
      project: config.project, lanes: findings.lane_status,
      report: File.basename(report[:markdown]), app: app,
      profile: config.profile, target: config.boot.target_url
    )
  end

  # The optional final step: build the findings artifact and publish it to the
  # team's S3 + CloudFront area. Deliberately after `record_gate` and
  # `summarize`, and deliberately unable to change either: the lanes' pass/fail
  # is the release gate, and a bucket that is not provisioned yet, an expired
  # AWS session, or a failed upload is reported as its own line rather than
  # turning a passing audit into a failing run.
  def publish_artifact(artifact, config, findings, report, app:)
    return unless artifact

    run = {
      project: config.project, app: app, scope: @args.scope,
      profile: config.profile || '(none)', target: config.boot.target_url
    }
    artifact.finish(findings: findings, report: report, run: run)
            .each { |line| log("[change] #{app ? "[#{app}] " : ''}#{line}") }
  end

  def summarize(findings, report, app:)
    log('')
    prefix = app ? "[#{app}] " : ''
    findings.lane_status.each { |lane, status| log("[change] #{prefix}#{lane}: #{status.upcase}") }
    log("[change] #{prefix}#{findings.failures.size} failing finding(s)")
    log("[change] #{prefix}report: #{report[:markdown]}")
    log("[change] #{prefix}data:   #{report[:csv]}")
    log("[change] #{prefix}#{findings.passed? ? 'PASS' : 'FAIL'} (scope: #{@args.scope}#{@args.profile ? ", profile: #{@args.profile}" : ''})")
  end

  def repo_root
    @repo_root ||= begin
      out, status = Open3.capture2e('git', 'rev-parse', '--show-toplevel')
      status.success? ? out.strip : Dir.pwd
    end
  end

  def head_sha
    @head_sha ||= begin
      out, status = Open3.capture2e('git', '-C', repo_root, 'rev-parse', 'HEAD')
      status.success? ? out.strip : ''
    end
  end

  def log(message) = warn(message)

  def abort_setup(message)
    warn("[change] setup error: #{message}")
    2
  end

  def abort_and_exit(message)
    warn("[change] #{message}")
    exit 2
  end
end

exit(ChangeRun.main(ARGV)) if __FILE__ == $PROGRAM_NAME
