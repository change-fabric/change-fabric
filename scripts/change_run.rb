#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'optparse'
require_relative 'change_apps'
require_relative 'change_artifact'
require_relative 'change_boot'
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
require_relative 'change_lane_testcases'

# The change-fabric orchestrator: the one command the cf:change / cf:k6 /
# cf:a11y / cf:zap / cf:testcases skills invoke. It reads a project's config, boots the target
# app and waits for its health signal, stands up the ephemeral runners (a shared
# browserless container only when a browser lane runs), executes the requested
# lanes, writes a CSV+Markdown report pair to the Desktop, and records the
# outcome under the git head SHA so the merge gate can consult it later.
#
# Usage: change_run.rb <all|k6|a11y|zap|browserless|testcases> [--config PATH] [--profile NAME]
#        [--app NAME]... [--target-url URL] [--health-url URL] [--suite NAME]...
#        [--no-publish] [--for-tag TAGNAME]
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
# `--suite <suite-or-tag>` narrows the testcases lane to the named suite or tag.
# It is the deterministic regression entry point `cf:qa --suite` drives: no
# scoping model, no generated script, just the committed cases that selection
# names.
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
  # The app lifecycle (boot_up / boot_down / wait_healthy / healthy?) lives in
  # ChangeBoot so cf:screenshot, which boots the same app at two git refs,
  # shares it instead of growing a second health poller.
  include ChangeBoot

  BROWSER_LANES = %w[a11y browserless testcases].freeze
  LANE_CLASSES = {
    'k6' => ChangeLaneK6, 'a11y' => ChangeLaneA11y,
    'zap' => ChangeLaneZap, 'browserless' => ChangeLaneBrowserless,
    'testcases' => ChangeLaneTestcases
  }.freeze

  # Per-lane run context. Lanes talk only to this, never to the run internals:
  # the network to join, the default target url, the browser session (nil unless
  # a browser lane asked for one), and a logger.
  # `media` (0.32.0) is the run's artifact media sink, or nil. It is nil unless
  # the repo carries a `contributors_team.platform:` block, and a lane holding
  # a nil sink captures nothing, which is what keeps the artifact pipeline
  # entirely opt-in.
  # `suite_select` (the `--suite` flag) is the testcases lane's invocation-time
  # narrowing: a suite id or a tag, naming which committed cases this run is
  # about. It rides the context rather than the config because it is a property
  # of this invocation and not of the repo; `cf:qa --suite <name>` is exactly
  # this flag, and asking for one suite must never require editing CHANGE.md.
  # Spelled with the prefix because a Struct is Enumerable: a member named
  # `select` would be shadowed by Enumerable#select, and a lane probing for it
  # would get a filtered member list rather than the flag.
  Context = Struct.new(:network, :target_url, :health_url, :browserless, :media, :suite_select, :logger,
                       keyword_init: true) do
    def log(message) = logger.call(message)
  end

  Args = Struct.new(:scope, :config_path, :profile, :apps, :target_url, :health_url, :publish, :suites,
                    :for_tag, :ref, keyword_init: true)

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
    suites = []
    for_tag = nil
    ref = nil
    OptionParser.new do |o|
      o.on('--config PATH') { |value| path = value }
      o.on('--profile NAME') { |value| profile = value }
      o.on('--app NAME') { |value| apps << value }
      o.on('--target-url URL') { |value| target_url = value }
      o.on('--health-url URL') { |value| health_url = value }
      o.on('--suite NAME') { |value| suites << value }
      o.on('--no-publish') { publish = false }
      o.on('--for-tag NAME') { |value| for_tag = value }
      o.on('--ref REF') { |value| ref = value }
    end.parse(argv.drop(1))
    valid = %w[all sweep gate-status] + ChangeConfig::LANES
    abort_and_exit("scope must be one of: #{valid.join(', ')}") unless valid.include?(scope)
    # `--suite` narrows the testcases lane and nothing else reads it. Refusing
    # it outside a run that includes that lane keeps a mistyped invocation from
    # looking like it filtered something: a flag that is silently ignored is
    # indistinguishable, from the outside, from a filter that matched.
    abort_and_exit('--suite narrows the testcases lane; run scope testcases or all') if
      !suites.empty? && !%w[testcases all].include?(scope)
    Args.new(scope: scope, config_path: path, profile: profile, apps: apps, target_url: target_url,
             health_url: health_url, publish: publish, suites: suites, for_tag: for_tag, ref: ref)
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
    manifest = run_manifest(config, lanes)
    report = write_report(config, findings, lanes, instances, app: label, manifest: manifest)
    record_gate(config, findings, report, app: label, manifest: manifest)
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
      health_url: config.boot.health_url, media: artifact&.media, suite_select: @args.suites,
      logger: method(:log)
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
      lane_findings, instances[name] = run_lane(name, config.lane(name), ctx)
      lane_findings.each { |finding| findings.add(finding) }
    end
    [ findings, instances ]
  end

  # Runs one lane, retrying it while it fails and its own budget allows. The
  # budget is 0 by default, so nothing retries unless a lane's config asks for
  # it: a gate that quietly re-runs until green is not a gate. When a retry
  # does clear the failure, the surviving findings are recorded with the
  # attempt count and `flaky: true`, so the pass is visibly a pass that took
  # more than one try rather than one that looks identical to a clean first
  # run. The status itself is never rewritten; {pass, warn, fail} stays the
  # sole gate signal.
  def run_lane(name, lane_config, ctx)
    budget = retry_budget(lane_config)
    attempts = 0
    lane = nil
    results = []
    loop do
      attempts += 1
      lane = LANE_CLASSES.fetch(name).new(lane_config, ctx)
      results = Array(lane.run)
      break if attempts > budget || results.none?(&:fail?)

      log("[change] #{name} lane failed on attempt #{attempts}; retrying (#{budget - attempts + 1} left)")
    end
    [ results.map { |finding| finding.with_attempt(attempts: attempts, flaky: attempts > 1 && !finding.fail?) }, lane ]
  end

  # A lane's `retries:` count, floored at 0. Opt-in per lane; absent means the
  # lane runs exactly once, which is what every existing config gets.
  def retry_budget(lane_config)
    [ lane_config.fetch('retries', 0).to_i, 0 ].max
  end

  def write_report(config, findings, lanes, instances, app:, manifest: {})
    ChangeReport.new(
      project: config.project, scope: @args.scope, findings: findings, app: app,
      meta: report_meta(config, findings),
      manifest: manifest,
      sections: report_sections(config, lanes, instances)
    ).write
  end

  # The inputs this run was produced from, recorded in the report and in the
  # gate record. A verdict without them is not reproducible in any useful
  # sense: two runs of "the same" audit could differ because a runner image
  # moved, the accessibility scanner was a different version, or the config
  # resolved differently under a profile, and nothing written down could tell
  # you which. Only the images a lane in this run actually used are listed, so
  # the manifest describes this run and not the platform in general.
  def run_manifest(config, lanes)
    manifest = {}
    manifest['k6 image'] = ChangeDocker::K6_IMAGE if lanes.include?('k6')
    manifest['zap image'] = ChangeDocker::ZAP_IMAGE if lanes.include?('zap')
    manifest['browserless image'] = ChangeDocker::BROWSERLESS_IMAGE unless (lanes & BROWSER_LANES).empty?
    manifest['axe-core'] = ChangeLaneA11y.axe_version if lanes.include?('a11y')
    manifest['config digest'] = "sha256:#{config.digest}"
    manifest['toolkit version'] = toolkit_version
    manifest
  end

  # The toolkit has no version file: a release is a `skills/vX.Y.Z` tag, picked
  # when it is cut. So the honest answer is whatever git says about the tree
  # these scripts were loaded from, and `(unknown)` when they were installed
  # somewhere with no git history at all rather than a number nothing backs.
  def toolkit_version
    out, status = Open3.capture2e(
      'git', '-C', __dir__, 'describe', '--tags', '--always', '--dirty', '--match', 'skills/v*'
    )
    status.success? && !out.strip.empty? ? out.strip : '(unknown)'
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
  # lane's scenario narrative, (F6 step 1) browserless's own per-cell timing
  # table read off the instance that already ran it, and the testcases lane's
  # acceptance criteria beside each case's verdict.
  def report_sections(config, lanes, instances)
    sections = []
    sections << ChangeK6Narrative.section(config.lane('k6')['scenario']) if lanes.include?('k6')
    sections << instances['browserless']&.timing_section if lanes.include?('browserless')
    sections << instances['testcases']&.acceptance_section if lanes.include?('testcases')
    sections.compact
  end

  # Records the outcome under the head SHA. Only a comprehensive `all` run that
  # passed satisfies the release merge gate; a single-lane run records its own
  # scope and never unlocks a protected-branch merge. `app` (0.4.0) merges this
  # entry into the (sha, profile) record's per-app map instead of overwriting
  # it, so a monorepo swept one `--app` at a time still ends up with one
  # complete record.
  def record_gate(config, findings, report, app:, manifest: nil)
    ChangeGateStore.new(head_sha, profile: config.profile).record(
      scope: @args.scope, status: findings.passed? ? 'pass' : 'fail',
      project: config.project, lanes: findings.lane_status,
      report: File.basename(report[:markdown]), app: app,
      profile: config.profile, target: config.boot.target_url, manifest: manifest
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
    flaky = findings.flaky
    log("[change] #{prefix}#{flaky.size} finding(s) only stopped failing on a retry") unless flaky.empty?
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

  # ChangeBoot's methods arrive public through the include; they were private
  # here before the extraction and stay that way, so this class's public API is
  # still just `run`.
  private :boot_up, :boot_env, :parse_env_file, :boot_down, :wait_healthy, :healthy?, :tail

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
