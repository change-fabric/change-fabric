#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'json'
require 'open3'
require 'optparse'
require 'securerandom'
require 'time'
require 'tmpdir'
require_relative 'change_apps'
require_relative 'change_artifact'
require_relative 'change_boot'
require_relative 'change_case_selection'
require_relative 'change_config'
require_relative 'change_docker'
require_relative 'change_findings'
require_relative 'change_frontmatter'
require_relative 'change_gate_check'
require_relative 'change_policy'
require_relative 'change_report'
require_relative 'change_schedule_store'
require_relative 'change_k6_narrative'
require_relative 'change_gate_store'
require_relative 'change_lane_k6'
require_relative 'change_lane_a11y'
require_relative 'change_lane_zap'
require_relative 'change_lane_browserless'
require_relative 'change_lane_testcases'
require_relative 'change_testcases_evidence'
require_relative 'change_testcases_report'
require_relative 'browserless_pdf'
require_relative 'change_lane_command'
require_relative 'change_trust'

# The change-fabric orchestrator: the one command the cf:change / cf:k6 /
# cf:a11y / cf:zap / cf:testcases skills invoke. It reads a project's config, boots the target
# app and waits for its health signal, stands up the ephemeral runners (a shared
# browserless container only when a browser lane runs), executes the requested
# lanes, writes a CSV+Markdown report pair to the Desktop, and records the
# outcome under the git head SHA so the merge gate can consult it later.
#
# Usage: change_run.rb <all|k6|a11y|zap|browserless|testcases> [--config PATH] [--profile NAME]
#        [--app NAME]... [--target-url URL] [--health-url URL] [--suite NAME]... [--case ID]... [--changed [REF]] [--strict]
#        [--no-publish] [--for-tag TAGNAME]
#        change_run.rb gate-status [--ref REF] [--config PATH]
#        change_run.rb schedule <name> [--repo PATH] [--dry-run]
#        change_run.rb zap --mode full [--profile NAME]
#
# schedule <name> (0.20.0) runs one change_config.schedules entry:
# its lanes, against its profile, with its per-lane overrides. CHANGE.md is
# read from the default branch (origin/<default> after a fetch), never the
# working tree, so boot steps are base-trusted and a branch cannot redefine
# what a schedule runs. The outcome goes to the time-keyed schedule store
# (change_schedule_store.rb), never a per-sha gate record, so a scheduled run
# can never satisfy the per-PR gate. --dry-run prints what would run and runs
# nothing. An active zap scan (zap.mode: full) is refused before any docker
# call unless the profile sets allow_active_scan: true; `zap --mode full` is
# the standalone form of the same opt-in.
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
# `--case <id>` (repeatable) narrows the testcases lane further to the named
# cases, by `suite/id` or a bare id; an unknown id exits 2 listing the known
# ids. It intersects with --suite and the lane's tags, never widens them, and
# is refused outside scope testcases so a filtered run cannot record the
# comprehensive pass the merge gate reads.
#
# `--changed [<base-ref>]` (default origin/main) runs only the cases the diff
# `<base>...HEAD` can affect (see change_case_selection.rb): cases whose
# `covers` globs match a changed path, every case of an edited suite file, and
# every case with no `covers`. `--strict` runs all cases when any lacks
# `covers`. No match exits 0 with "no cases affected". Like --case it intersects
# with the other filters and is refused outside scope testcases.
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
    'testcases' => ChangeLaneTestcases, 'command' => ChangeLaneCommand
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
  # `signoff` rides the context the same way `suite_select` does: a property of
  # this invocation, not of the repo. It softens the testcases lane's grader
  # gate (row 39, Decision 8: missing grader or an `unclear` verdict fails
  # under full auto, warns under `--signoff`) without changing anything a lane
  # grades deterministically.
  # The command lane (0.17.0) also reads `run_id` (CF_CHANGE_RUN_ID and its
  # Desktop directory), `profile` (its per-entry filter), `trust` (the run's
  # ChangeTrust verdict), `step_prefix` (the app in a monorepo) and
  # `env_file_values` (parsed boot.env_file, a source for declared names).
  Context = Struct.new(:network, :target_url, :health_url, :browserless, :media, :suite_select, :signoff,
                       :logger, :run_id, :profile, :trust, :step_prefix, :env_file_values,
                       :active_scan_allowed, :out_dir, :evidence_dir, :commit, :exports, :video_budget_mb,
                       :case_select, keyword_init: true) do
    def log(message) = logger.call(message)
    def signoff? = signoff == true
  end

  Args = Struct.new(:scope, :config_path, :profile, :apps, :target_url, :health_url, :publish, :suites,
                    :for_tag, :ref, :signoff, :schedule, :repo, :dry_run, :zap_mode, :out, :exports,
                    :video_budget_mb, :cases, :changed, :strict, keyword_init: true)

  def self.main(argv)
    new(argv).run
  end

  def initialize(argv)
    @args = parse_args(argv)
  end

  def run
    return gate_status if @args.scope == 'gate-status'
    return run_schedule if @args.scope == 'schedule'
    return abort_setup('docker is not available') unless ChangeDocker.available?
    return sweep_stale_resources if @args.scope == 'sweep'
    return run_for_tag if @args.for_tag

    run_sweep
  rescue ChangeConfig::ConfigError => e
    abort_setup(e.message)
  end

  private

  # schedule <name>: resolves the schedule from the default branch's
  # CHANGE.md, refuses an un-opted-in active scan or a k6 script that differs
  # from the base before any docker call, then runs the schedule's lanes
  # through the same boot and lane machinery a sweep uses and writes a
  # schedule-store record.
  def run_schedule
    base_ref, base_sha, raw = base_change_config
    schedule = resolve_schedule(raw)
    Dir.mktmpdir('cf-schedule') do |dir|
      config = load_base_config(dir, base_ref, schedule)
      check_schedule_safety(config, schedule, base_ref, base_sha)
      return print_schedule_plan(config, schedule, base_ref, base_sha) if @args.dry_run
      return abort_setup('docker is not available') unless ChangeDocker.available?

      @head_sha = base_sha
      execute_schedule(config, schedule, ChangeTrust::Base.new(ref: base_ref, sha: base_sha))
    end
  end

  # [ref, sha, change_config] from origin/<default branch>, after a fetch. A
  # failed fetch is logged and the last fetched ref is used, as the trust
  # check does.
  def base_change_config
    default = ChangeTrust.default_branch(repo_root)
    note = ChangeTrust.fetch_note(repo_root, default)
    log("[change] schedule: #{note}") if note
    ref = "origin/#{default}"
    sha = resolve_ref_sha("#{ref}^{commit}")
    abort_and_exit("schedule: #{ref} does not resolve; a schedule runs the default branch's CHANGE.md") unless sha
    # Read at the resolved sha, not the moving ref, so a fetch mid-run cannot
    # swap the definitions the record attributes to this sha.
    @base_change_md = git_show(sha, 'CHANGE.md')
    abort_and_exit("schedule: #{ref} has no CHANGE.md") unless @base_change_md
    raw = ChangeFrontmatter.parse(@base_change_md)['change_config']
    abort_and_exit("schedule: #{ref}:CHANGE.md has no change_config block") unless raw.is_a?(Hash)
    [ ref, sha, raw ]
  end

  def resolve_schedule(raw)
    if raw.key?('apps')
      abort_and_exit('schedule: a monorepo (change_config.apps) cannot run schedules yet; ' \
                     'declare them in a single-app CHANGE.md')
    end
    schedules = ChangeScheduleConfig.new(raw)
    schedule = schedules.fetch(@args.schedule)
    return schedule if schedule

    declared = schedules.names.empty? ? 'none' : schedules.names.join(', ')
    abort_and_exit("schedule: no schedule named '#{@args.schedule}' on the default branch; declared: #{declared}")
  end

  # The base CHANGE.md written to a temp file and loaded under the schedule's
  # profile, rooted at the repo so boot steps and repo paths resolve as usual.
  def load_base_config(dir, base_ref, schedule)
    path = File.join(dir, 'CHANGE.md')
    File.write(path, @base_change_md)
    ChangeConfig.load(path, profile: schedule.profile, root: repo_root)
  rescue ChangeConfig::ConfigError => e
    abort_and_exit("schedule: #{base_ref}:CHANGE.md does not load: #{e.message}")
  end

  # Both refusals happen before docker is touched. Validation already rejects
  # an un-opted-in full scan; the re-check here is the runner's own guard.
  def check_schedule_safety(config, schedule, base_ref, base_sha)
    @schedule = schedule
    @base_sha = base_sha
    @lane_overrides = schedule.overrides
    if schedule.active_scan?
      unless config.schedule_config.allow_active_scan?(schedule.profile)
        abort_and_exit("schedule #{schedule.name}: refusing an active zap scan (mode: full): profile " \
                       "'#{schedule.profile}' does not set allow_active_scan: true")
      end
      @active_scan_allowed = true
    end
    check_k6_script_matches_base(scheduled_lane(config, 'k6'), base_ref) if schedule.lanes.include?('k6')
    check_suites_match_base(scheduled_lane(config, 'testcases'), base_ref) if schedule.lanes.include?('testcases')
  end

  # The testcases lane loads suites from the working tree by glob, so the
  # matched file set and every file's bytes must equal the base branch's, or
  # a branch-local case could change a verdict recorded against the base sha.
  def check_suites_match_base(lane, base_ref)
    base_files = git_ls(@base_sha)
    Array(lane['suites']).map(&:to_s).reject(&:empty?).each do |glob|
      working = Dir.glob(File.expand_path(glob, lane.dir.to_s)).select { |f| File.file?(f) }
                   .map { |f| f.delete_prefix("#{repo_root}/") }.sort
      base = base_files.select { |f| File.fnmatch?(glob.delete_prefix('./'), f, File::FNM_PATHNAME | File::FNM_EXTGLOB) }.sort
      same = working == base && working.all? { |f| git_show(@base_sha, f)&.b == File.binread(File.join(repo_root, f)) }
      next if same

      abort_and_exit("schedule #{@schedule.name}: testcase suites '#{glob}' differ from #{base_ref}; " \
                     "a scheduled run executes only the default branch's definitions")
    end
    nil
  end

  def git_ls(ref)
    out, status = Open3.capture2e('git', '-C', repo_root, 'ls-tree', '-r', '--name-only', ref)
    status.success? ? out.split("\n") : []
  end

  # The k6 lane reads its script from the working tree. A scheduled run is
  # base-trusted, so that file must be byte-identical to the base branch's.
  def check_k6_script_matches_base(lane, base_ref)
    rel = lane['script']
    return if rel.nil?

    working = lane.path('script')
    base = git_show(@base_sha, rel.to_s.delete_prefix('./'))
    return if base && File.exist?(working) && File.binread(working) == base.b

    abort_and_exit("schedule #{@schedule.name}: k6 script '#{rel}' differs from #{base_ref} (or is missing " \
                   "there); a scheduled run executes only the default branch's definitions")
  end

  def print_schedule_plan(config, schedule, base_ref, base_sha)
    log("[change] schedule #{schedule.name} (dry run; nothing runs)")
    log("[change]   base: #{base_ref} #{base_sha[0, 12]}")
    log("[change]   runner: #{schedule.runner}, cron: #{schedule.cron} (UTC)")
    log("[change]   profile: #{schedule.profile}, target: #{config.boot.target_url}")
    schedule.lanes.each do |name|
      lane = scheduled_lane(config, name)
      mode = name == 'zap' ? " mode=#{lane.fetch('mode', ChangeScheduleConfig::ZAP_DEFAULT_MODE)}" : ''
      log("[change]   lane #{name}#{mode} -> #{scheduled_targets(config, name, lane).join(', ')}")
    end
    run_manifest(config, schedule.lanes).each { |key, value| log("[change]   #{key}: #{value}") }
    0
  end

  def scheduled_targets(config, name, lane)
    return lane.targets(config.boot.target_url) if name == 'zap'

    [ lane.base_url(config.boot.target_url) ]
  end

  def execute_schedule(config, schedule, base)
    base_ref = base.ref
    trust = trust_verdict(config, base: base)
    untrusted = trust.head_digests.keys.reject { |step| trust.trusted?(step) }
    abort_and_exit(trust.refusal(untrusted.first)) unless untrusted.empty?

    started_at = Time.now.utc.iso8601
    findings, instances = with_app(config, trust: trust) { |ctx| execute(config, schedule.lanes, ctx) }
    manifest = run_manifest(config, schedule.lanes)
               .merge('schedule' => schedule.name, 'base' => "#{base_ref} #{head_sha[0, 12]}")
    report = write_report(config, findings, schedule.lanes, instances, app: nil, manifest: manifest,
                                                                       scope: schedule_report_scope(schedule))
    write_testcases_report(config)
    path = ChangeScheduleStore.new(schedule.name, schedule.profile, repo: ChangeScheduleStore.repo_key(repo_root))
                              .write(schedule_record(schedule, findings, report, started_at))
    summarize(findings, report, app: nil)
    log("[change] schedule record: #{path}")
    findings.passed? ? 0 : 1
  end

  # Two schedules (or two overlapping runs of one) finishing in the same second
  # must not overwrite each other's report, so the name carries the schedule,
  # its profile, and a short random run id.
  def schedule_report_scope(schedule)
    "schedule-#{schedule.name}-#{schedule.profile}-#{SecureRandom.hex(3)}"
  end

  def schedule_record(schedule, findings, report, started_at)
    {
      'schedule' => schedule.name, 'profile' => schedule.profile, 'runner' => schedule.runner,
      'sha' => head_sha, 'started_at' => started_at, 'finished_at' => Time.now.utc.iso8601,
      'result' => findings.passed? ? 'pass' : 'fail', 'lanes' => findings.lane_status,
      'report_path' => report[:markdown]
    }
  end

  # A lane's config with this run's invocation overrides (a schedule's
  # per-lane block, or `zap --mode full`) applied.
  def scheduled_lane(config, name) = config.lane(name).merge(lane_overrides.fetch(name, {}))

  def lane_overrides = @lane_overrides || {}

  def git_show(ref, rel)
    out, status = Open3.capture2e('git', '-C', repo_root, 'show', "#{ref}:#{rel}")
    status.success? ? out : nil
  end

  # `zap --mode full`: the standalone active scan. Re-checks the resolved
  # profile's opt-in before anything runs.
  def prepare_zap_mode(config)
    return unless @args.zap_mode

    if @args.zap_mode == 'full' && !config.schedule_config.allow_active_scan?(config.profile)
      abort_and_exit("zap --mode full: refusing an active scan: profile '#{config.profile || '(none)'}' " \
                     'does not set allow_active_scan: true')
    end
    @lane_overrides = { 'zap' => { 'mode' => @args.zap_mode } }
    @active_scan_allowed = @args.zap_mode == 'full'
  end

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
    check = ChangeGateCheck.new(sha: sha, profile: profile, apps: apps, root: root)
    satisfied = check.satisfied?
    status = satisfied ? 'SATISFIED' : 'NOT SATISFIED'
    log("[change] gate-status: #{kind} rule '#{pattern}' (profile=#{profile || '(none)'}): " \
        "#{status}#{check.missing_apps_clause}#{check.trust_clause}")
    satisfied
  end

  def resolve_ref_sha(ref)
    out, status = Open3.capture2e('git', '-C', repo_root, 'rev-parse', '--verify', '--quiet', ref)
    status.success? ? out.strip : nil
  end

  def parse_args(argv)
    scope = argv.first&.start_with?('-') ? nil : argv.first
    lane = nil
    path = ChangeConfig::DEFAULT_PATH
    profile = nil
    apps = []
    target_url = nil
    health_url = nil
    publish = true
    suites = []
    cases = []
    changed = nil
    strict = false
    for_tag = nil
    ref = nil
    signoff = false
    repo = nil
    dry_run = false
    zap_mode = nil
    out = nil
    exports = []
    video_budget_mb = nil
    rest = scope ? argv.drop(1) : argv
    schedule = scope == 'schedule' && rest.first && !rest.first.start_with?('-') ? rest.shift : nil
    OptionParser.new do |o|
      o.on('--config PATH') { |value| path = value }
      o.on('--profile NAME') { |value| profile = value }
      o.on('--app NAME') { |value| apps << value }
      o.on('--target-url URL') { |value| target_url = value }
      o.on('--health-url URL') { |value| health_url = value }
      o.on('--suite NAME') { |value| suites << value }
      o.on('--case ID') { |value| cases << value }
      o.on('--changed [REF]') { |value| changed = value || 'origin/main' }
      o.on('--strict') { strict = true }
      o.on('--no-publish') { publish = false }
      o.on('--for-tag NAME') { |value| for_tag = value }
      o.on('--ref REF') { |value| ref = value }
      o.on('--signoff') { signoff = true }
      o.on('--repo PATH') { |value| repo = value }
      o.on('--dry-run') { dry_run = true }
      o.on('--mode MODE') { |value| zap_mode = value }
      o.on('--out DIR') { |value| out = File.expand_path(value) }
      o.on('--export LIST') { |value| exports.concat(value.split(',').map(&:strip).reject(&:empty?)) }
      o.on('--video-budget-mb N', Integer) { |value| video_budget_mb = value }
      o.on('--lane NAME') { |value| lane = value }
    end.parse(rest)
    scope = lane_scope(scope, lane) if lane
    valid = %w[all sweep gate-status schedule] + ChangeConfig::LANES
    abort_and_exit("scope must be one of: #{valid.join(', ')}") unless valid.include?(scope)
    # `--suite` narrows the testcases lane and nothing else reads it. Refusing
    # it outside a run that includes that lane keeps a mistyped invocation from
    # looking like it filtered something: a flag that is silently ignored is
    # indistinguishable, from the outside, from a filter that matched.
    abort_and_exit('--suite narrows the testcases lane; run scope testcases or all') if
      !suites.empty? && !%w[testcases all].include?(scope)
    # Only a testcases-scope run: a filtered `all` run would still record a
    # comprehensive pass for the gate while skipping the excluded cases.
    abort_and_exit('--case narrows the testcases lane; run scope testcases (not all)') if
      !cases.empty? && scope != 'testcases'
    # The same refusal as --case, for the same reason: a diff-narrowed run must
    # never record the comprehensive pass.
    abort_and_exit('--changed narrows the testcases lane; run scope testcases (not all)') if
      changed && scope != 'testcases'
    abort_and_exit('--strict applies only with --changed') if strict && !changed
    abort_and_exit('schedule needs a schedule name: change_run.rb schedule <name>') if scope == 'schedule' && schedule.nil?
    abort_and_exit('--dry-run applies only to schedule <name>') if dry_run && scope != 'schedule'
    abort_and_exit('--mode applies only to the zap scope') if zap_mode && scope != 'zap'
    unknown_exports = exports - EXPORTS
    abort_and_exit("--export takes #{EXPORTS.join(', ')}; got #{unknown_exports.join(', ')}") if unknown_exports.any?
    abort_and_exit('--export applies to the testcases lane; run scope testcases or all') if
      !exports.empty? && !%w[testcases all].include?(scope)
    abort_and_exit('--video-budget-mb must be positive') if video_budget_mb && !video_budget_mb.positive?
    if zap_mode && !ChangeScheduleConfig::ZAP_MODES.include?(zap_mode)
      abort_and_exit("--mode must be one of #{ChangeScheduleConfig::ZAP_MODES.join(', ')}")
    end
    Args.new(scope: scope, config_path: path, profile: profile, apps: apps, target_url: target_url,
             health_url: health_url, publish: publish, suites: suites, cases: cases.uniq, changed: changed, strict: strict, for_tag: for_tag, ref: ref,
             signoff: signoff, schedule: schedule, repo: repo, dry_run: dry_run, zap_mode: zap_mode, out: out,
             exports: exports.uniq, video_budget_mb: video_budget_mb)
  end

  # What --export may name: the testcases report as a PDF, and one MP4 per
  # case. Neither makes a paid call.
  EXPORTS = %w[pdf video].freeze

  # `--lane NAME` is an alias for the lane scope: it narrows `all` (or no
  # scope) to that one lane, and refuses a different scope rather than guess.
  def lane_scope(scope, lane)
    abort_and_exit("--lane must be one of: #{ChangeConfig::LANES.join(', ')}") unless ChangeConfig::LANES.include?(lane)
    return lane if [ nil, 'all', lane ].include?(scope)

    abort_and_exit("--lane #{lane} conflicts with scope #{scope}; run change_run.rb #{lane} [options]")
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
    qa = ChangeDocker.sweep(prefix: ChangeDocker::QA_PREFIX)
    removed = { containers: removed[:containers] + qa[:containers], networks: removed[:networks] + qa[:networks] }
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
    prepare_zap_mode(config)
    label = multi ? entry.name : nil
    @evidence_app = label
    log("[change] app: #{entry.name}") if multi
    lanes = resolve_lanes(config)
    check_case_ids(config, lanes)
    return no_cases_affected(entry) if resolve_changed(config, lanes) == :none

    prefix = multi ? "#{entry.name}/" : ''
    trust = trust_verdict(config, prefix: prefix, apps: multi ? [ entry.name ] : nil)
    refuse_untrusted_boot(config, trust, app: label)
    artifact = ChangeArtifactStep.for(repo_root: repo_root, publish: @args.publish, label: label)
    findings, instances = with_app(config, artifact, trust: trust, prefix: prefix) do |ctx|
      execute(config, lanes, ctx)
    end
    manifest = run_manifest(config, lanes)
    report = write_report(config, findings, lanes, instances, app: label, manifest: manifest.merge(trust_rows(trust)))
    write_testcases_report(config)
    gate_manifest = manifest.merge('trust' => trust.manifest(trust.head_digests.keys))
    record_gate(config, findings, report, app: label, manifest: gate_manifest)
    summarize(findings, report, app: label)
    publish_artifact(artifact, config, findings, report, app: label)
    { app: entry.name, passed: findings.passed?, failing: findings.failures.size, report: File.basename(report[:markdown]) }
  end

  # An unknown `--case` id is a setup error (exit 2) before anything boots, and
  # the message lists the known ids so the typo is fixable from the output.
  def check_case_ids(config, lanes)
    return if @args.cases.to_a.empty? || !lanes.include?('testcases')

    lane = config.lane('testcases')
    set = ChangeSuiteSet.load(lane['suites'], lane.dir)
    unknown = set.unknown_case_ids(@args.cases)
    return if unknown.empty?

    known = set.cases.map(&:qualified_id)
    raise ChangeConfig::ConfigError,
          "--case names #{unknown.map { |id| id[0, 80].inspect }.join(', ')}, which matches no case; " \
          "known ids: #{known.first(50).join(', ')}#{known.size > 50 ? ', ...' : ''}"
  end

  # `--changed`: turns the diff into the qualified ids of the cases it selects
  # (intersected with any `--case`), kept in @case_select for the lane. Returns
  # :none when nothing is affected, before anything boots, and nil (no narrowing)
  # whenever the lane should own the outcome, such as an empty or broken suite set.
  def resolve_changed(config, lanes)
    @case_select = nil
    return unless @args.changed && lanes.include?('testcases')

    lane = config.lane('testcases')
    set = ChangeSuiteSet.load(lane['suites'], lane.dir)
    # A broken suite, a mistyped --suite or an unmatched gate tag must reach the lane, which reports it
    # as a failure, and a lane with no cases at all fails in the lane itself; a successful
    # "no cases affected" would hide either.
    return if set.cases.empty?
    return unless set.errors.empty? && set.unmatched_selectors(@args.suites).empty? &&
                  set.unmatched_gate_tags(Array(lane['gate_tags']).map(&:to_s)).empty?

    paths = ChangeCaseSelection.changed_paths(@args.changed, repo_root)
    result = ChangeCaseSelection.select(set, paths, repo: repo_root, strict: @args.strict)
    ChangeCaseSelection.summary(result, set.cases.size, @args.changed).each { |line| log(line) }
    # Only cases the lane would run under --suite, its tags and --case.
    eligible = set.selected(Array(lane['tags']).map(&:to_s), selectors: @args.suites, case_ids: @args.cases)
    # Nothing eligible before the diff (a renamed tag, say) is the lane's failure to report, not a no-op.
    return if eligible.empty?

    picked = result.cases & eligible
    return :none if picked.empty?

    @case_select = picked.map(&:qualified_id)
    nil
  rescue ChangeCaseSelection::Error => e
    raise ChangeConfig::ConfigError, e.message
  end

  def no_cases_affected(entry)
    log('[change] no cases affected')
    { app: entry.name, passed: true, failing: 0, report: 'none (no cases affected)' }
  end

  # The testcases lane's own report.html and junit.xml in its run dir, and its
  # run appended to the project's history ledger. Best effort: a report that
  # could not be written is logged, never a changed verdict.
  def write_testcases_report(config)
    dir = evidence_dir(config)
    return unless dir && File.exist?(File.join(dir, ChangeTestcasesEvidence::RESULTS_FILE))

    report = ChangeTestcasesReport.new(run_dir: dir, ledger: ChangeTestcasesReport.ledger_path(config.project, repo: repo_root,
                                                                                               app: @evidence_app))
    paths = report.write
    log("[change] testcases report: #{paths[:html]} (junit: #{paths[:junit]})")
    return unless Array(@args.exports).include?('pdf')

    export_testcases_pdf(dir)
    report.write_html
  rescue StandardError => e
    log("[change] testcases report failed: #{e.message}")
  end

  # report.pdf beside report.html. A failure is logged and recorded in
  # exports.json; it changes no case's result.
  def export_testcases_pdf(dir)
    entry = begin
      { 'status' => 'ok', 'path' => BrowserlessPdf.render(dir) }
    rescue StandardError => e
      { 'status' => 'failed', 'reason' => e.message }
    end
    ChangeTestcasesEvidence.new(dir).write_exports('pdf' => { 'report' => entry })
    log("[change] testcases pdf: #{entry['path'] || "failed, #{entry['reason']}"}")
  end

  def write_rollup(registry, results)
    rollup = ChangeReport.rollup(project: registry.project, scope: @args.scope, rows: results, out_dir: out_dir)
    log("[change] sweep report: #{rollup[:markdown]}")
  end

  def resolve_lanes(config)
    return @schedule.lanes if @schedule
    return config.enabled_lanes if @args.scope == 'all'

    [ @args.scope ]
  end

  # Boots the app, waits for health, then yields a context to run lanes in,
  # tearing the app down afterward. Network and browser lifecycle nest inside so
  # they too are always cleaned up.
  def with_app(config, artifact = nil, trust:, prefix: '')
    boot = config.boot
    boot_up(boot, trust: trust, prefix: prefix)
    wait_healthy(boot)
    ChangeDocker.with_network(boot.network) do |network|
      with_context(config, network, artifact, trust: trust, prefix: prefix) { |ctx| yield ctx }
    end
  ensure
    boot_down(boot, trust: trust, prefix: prefix)
  end

  # HEAD's host-run step definitions (as loaded from the working tree)
  # compared against the base branch's and this sha's approvals. Logged when
  # the base could not be fetched, so a stale comparison is never silent.
  def trust_verdict(config, prefix: '', apps: nil, base: nil)
    verdict = ChangeTrust.evaluate(root: repo_root, head_sha: head_sha, profile: config.profile, apps: apps, base: base,
                                   head_definitions: ChangeTrust.step_definitions(config, prefix: prefix))
    log("[change] trust: #{verdict.note}") if verdict.note
    log("[change] trust: approval policy #{verdict.policy_sha}") if verdict.policy_sha
    verdict
  end

  # An untrusted boot.up stops the run before anything executes, and records
  # a failing gate for this sha so an earlier pass can never stand in for it.
  def refuse_untrusted_boot(config, trust, app:)
    step = trust.head_digests.keys.find { |name| name.end_with?('boot.up') }
    return if step.nil? || trust.trusted?(step)

    ChangeGateStore.new(head_sha, profile: config.profile).record(
      scope: @args.scope, status: 'fail', project: config.project, lanes: {}, report: '', app: app,
      profile: config.profile, target: config.boot.target_url
    )
    abort_and_exit(trust.refusal(step))
  end

  # The trust block flattened into report manifest rows, one per step.
  def trust_rows(trust)
    rows = trust.head_digests.to_h do |step, digest|
      [ "trust #{step}", "#{digest} (#{trust.sources[step] || 'untrusted'})" ]
    end
    rows['trust base'] = "#{trust.base_ref} #{trust.base_sha.to_s[0, 12]}" unless rows.empty?
    rows
  end

  # boot.env_file values the command lane may resolve declared names from;
  # parsed only when that lane runs, and a missing file stops the run by name
  # exactly as it does for boot.
  def command_env_file_values(config)
    return {} unless resolve_lanes(config).include?('command')

    boot_env(config.boot) { |message| abort_and_exit(message) }
  end

  def boot_run_id = @boot_run_id ||= "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(3)}"

  def with_context(config, network, artifact = nil, trust: nil, prefix: '')
    ctx_args = {
      network: network.name, target_url: config.boot.target_url,
      health_url: config.boot.health_url, media: artifact&.media, suite_select: @args.suites, case_select: @case_select || @args.cases,
      signoff: @args.signoff, logger: method(:log), run_id: boot_run_id, profile: config.profile,
      trust: trust, step_prefix: prefix, env_file_values: command_env_file_values(config),
      active_scan_allowed: @active_scan_allowed == true, out_dir: out_dir,
      evidence_dir: evidence_dir(config), commit: head_sha, exports: @args.exports,
      video_budget_mb: @args.video_budget_mb
    }
    if browser_needed?(config)
      boot = config.boot
      mounts = ctx_args[:evidence_dir] ? { ctx_args[:evidence_dir] => ChangeTestcasesEvidence::MOUNT } : {}
      ChangeDocker.with_browserless(network: network.name, add_hosts: boot.add_hosts,
                                    local_tls_hosts: boot.local_tls_hosts, mounts: mounts,
                                    run_id: boot_run_id) do |session|
        yield Context.new(browserless: session, **ctx_args)
      end
    else
      yield Context.new(browserless: nil, **ctx_args)
    end
  end

  def browser_needed?(config) = !(resolve_lanes(config) & BROWSER_LANES).empty?

  # Where reports land: `--out DIR`, else the Desktop.
  def out_dir = @args.out || ChangeReport::DESKTOP

  # The testcases lane's run-scoped evidence root, `<out>/testcases-<run-id>`,
  # created only when that lane runs. It is mounted into the browser
  # container, so a case's checkpoints survive the call being killed.
  def evidence_dir(config)
    return nil unless resolve_lanes(config).include?('testcases')

    @evidence_dirs ||= {}
    @evidence_dirs[config.object_id] ||= ChangeTestcasesEvidence.prepare(out_dir, evidence_run(config))
  end

  # One dir per profile and app in a sweep, or two apps' cases would overwrite
  # each other's records and attempt files. The slugs keep the name readable;
  # a digest of the exact (profile, app) pair keeps it unique when names slug
  # or join alike.
  def evidence_run(config)
    scope = [ config.profile, @evidence_app ].map(&:to_s)
    return boot_run_id if scope.all?(&:empty?)

    readable = scope.reject(&:empty?).map { |part| ChangeReport.slug_for(part) }
    [ boot_run_id, *readable, Digest::SHA256.hexdigest(JSON.generate(scope))[0, 8] ].join('-')
  end

  # Returns the lane instances alongside their findings so report_sections
  # can read a lane's own post-run state (today, browserless's per-cell
  # timing) without changing what #run itself returns.
  def execute(config, lanes, ctx)
    findings = Findings.new
    instances = {}
    lanes.each do |name|
      log("[change] running #{name} lane")
      lane_findings, instances[name] = run_lane(name, scheduled_lane(config, name), ctx)
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
  # A self-retrying lane (the command lane) runs exactly once here and keeps
  # the per-entry attempt counts its own findings already carry.
  def run_lane(name, lane_config, ctx)
    budget = retry_budget(lane_config)
    attempts = 0
    lane = nil
    results = []
    loop do
      attempts += 1
      lane = LANE_CLASSES.fetch(name).new(lane_config, ctx)
      results = Array(lane.run)
      return [ results, lane ] if lane.self_retrying?
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

  def write_report(config, findings, lanes, instances, app:, manifest: {}, scope: @args.scope)
    ChangeReport.new(
      project: config.project, scope: scope, findings: findings, app: app, out_dir: out_dir,
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
      'lane targets' => effective_lane_targets(config).map { |lane, targets| "#{lane}=#{targets.join(',')}" }.join(', ')
    }
  end

  # Lane targets with this run's overrides applied, as execution resolves them.
  def effective_lane_targets(config)
    config.lane_targets.to_h do |lane, targets|
      next [ lane, targets ] unless lane_overrides.key?(lane)

      [ lane, scheduled_targets(config, lane, scheduled_lane(config, lane)) ]
    end
  end

  # Narrative sections that belong in the Markdown but not the CSV: the k6
  # lane's scenario narrative, (F6 step 1) browserless's own per-cell timing
  # table read off the instance that already ran it, and the testcases lane's
  # acceptance criteria beside each case's verdict.
  def report_sections(config, lanes, instances)
    sections = []
    sections << ChangeK6Narrative.section(scheduled_lane(config, 'k6')['scenario']) if lanes.include?('k6')
    sections << instances['browserless']&.timing_section if lanes.include?('browserless')
    sections << instances['testcases']&.acceptance_section if lanes.include?('testcases')
    sections << instances['command']&.report_section if lanes.include?('command')
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
    artifact.finish(findings: findings, report: report, run: run, evidence_dir: evidence_dir(config))
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
    return @repo_root ||= File.expand_path(@args.repo) if @args&.repo

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
  private :boot_up, :boot_env, :parse_env_file, :boot_down, :wait_healthy, :healthy?, :tail, :boot_step_env,
          :boot_extra_env, :failure_reason, :boot_runner

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
