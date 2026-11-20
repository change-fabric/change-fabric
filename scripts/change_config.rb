#!/usr/bin/env ruby
# frozen_string_literal: true

require 'uri'
require 'yaml'
require 'json'
require 'digest'
require 'date'
require_relative 'change_frontmatter'
require_relative 'change_schema'
require_relative 'change_suite'
require_relative 'change_local_tls'
require_relative 'change_command_config'
require_relative 'emit_digest'
require_relative 'execution_config_schema'
require_relative 'change_schedule_config'

# Parses and validates a project's change-fabric config. There is one
# change-fabric file per repo, `CHANGE.md` at the repo root: its YAML
# frontmatter carries a `change_config:` block (the mechanical target-app
# details this class reads) alongside a `change_policy:` block (read by the merge
# gate), and its prose body is the human governance FAQ. Keeping everything in
# one file was a deliberate call: a repo declares how it is audited and how it is
# governed in a single place a person already opens.
#
# YAML frontmatter over a separate JSON file is deliberate: a human edits this by
# hand and wants comments, and the same block already holds the policy the gate
# reads. Validation fails loud with a ConfigError naming the offending key. A
# lane the project does not want is omitted or `enabled: false`; only lanes
# present and enabled run, so a repo can adopt one lane at a time.
class ChangeConfig
  class ConfigError < StandardError; end

  DEFAULT_PATH = 'CHANGE.md'
  # The accepted lanes come from the schema registry, so the validator and the
  # documented schema can never name a different set.
  LANES = ChangeSchema::LANES

  TEMPLATE_DOC = 'skills/change/reference/CHANGE.template.md'
  SPEC_DOC = 'skills/change/reference/CHANGE-frontmatter-spec.md'
  REFERENCE_HINT = "See the template at #{TEMPLATE_DOC} and the field spec at #{SPEC_DOC}. " \
                   "Everything (change_config: and change_policy:) belongs in this file's YAML " \
                   'frontmatter; there is no separate config file.'
  PLACEHOLDER_HINT = 'This looks like a pre-1.0 placeholder layout: config used to live in a ' \
                     'separate .cf file, but the shipped platform inlines it into CHANGE.md ' \
                     'frontmatter. Migrate the config into the frontmatter block here.'

  # A profile (v0.2.0) may only override these change_config keys: enough to
  # point the same lanes at a different deployed target (a different project
  # label, boot command, or lane base_url/enabled), never a different audit
  # surface (routes, thresholds, viewports) per environment. That keeps the
  # documented field set small and every profile field's meaning identical to
  # its base-config counterpart, rather than a second, parallel schema.
  # `targets` (0.4.0) is the one exception: a target list is a *where*, the
  # same reason `base_url` is already overridable, not a *what*. `auth` is a
  # second exception for the same reason: a login url and its credential env
  # vars are how a profile's environment is reached, not what gets audited
  # once the login succeeds - the same distinction that already lets `targets`
  # and `base_url` vary per profile while routes, thresholds, and viewports
  # stay shared.
  PROFILE_LANE_KEYS = %w[enabled base_url basic_auth targets auth].freeze
  # `allow_active_scan` (0.20.0) is accepted on a profile but is
  # never merged into the resolved config: it is the profile's opt-in to being
  # an active-scan target, read only by ChangeScheduleConfig.
  PROFILE_TOP_KEYS = %w[project boot lanes allow_active_scan].freeze
  PROFILE_ONLY_KEYS = %w[allow_active_scan].freeze

  # basic_auth (0.3.0) is answered via page.authenticate() in a browser page, so
  # it only means anything on a lane that actually drives one.
  BROWSER_LANES = %w[a11y browserless testcases].freeze

  # Lanes that read a `targets` list at all (0.4.0). Only zap has a notion of
  # more than one in-scope url; every other lane has exactly one base_url.
  # `testcases` (0.10.0) is deliberately not here: a case says where it goes
  # step by step, from one base url, so a `targets` list on it would be a scope
  # the lane never reads.
  TARGET_LANES = %w[zap].freeze

  # Lanes that read an `auth` login-flow block. Every browser-driving lane is
  # here as of 0.11.0. a11y was excluded until then on the reasoning that it
  # only ever read basic_auth, but that reasoning had the failure backwards: a
  # config declaring seven routes behind a form login got no error for the
  # absent `auth`, every route redirected to the login page, and the lane
  # graded the login page seven times under seven route names. `testcases`
  # (0.10.0) reads the same block, in the same shape, since a case behind a
  # login has to get through it first.
  AUTH_LANES = %w[a11y browserless testcases].freeze

  # Host-run steps (boot.up, boot.down, command lane entries, 0.17.0) declare
  # the variables they need by name; these are the shapes and the names a step
  # may not declare because the runner always provides them.
  ENV_NAME = ChangeCommandConfig::ENV_NAME
  RESERVED_ENV_NAMES = ChangeCommandConfig::RESERVED_ENV_NAMES
  MAX_TIMEOUT_SECONDS = ChangeCommandConfig::MAX_TIMEOUT_SECONDS

  def self.timeout?(value) = value.is_a?(Integer) && value.between?(1, MAX_TIMEOUT_SECONDS)

  # The cf:docker doctrine at config load: a host-run step that would start a
  # project service as a host daemon is refused with the same pattern list the
  # PreToolUse guard uses, and the same CF_ALLOW_HOSTDAEMON=1 escape hatch.
  def self.doctrine_error(field, cmd) = ChangeCommandConfig.doctrine_error(field, cmd)

  def self.load(path, profile: nil, root: nil, overrides: {})
    raise ConfigError, "CHANGE.md not found: #{path}. #{REFERENCE_HINT}" unless File.exist?(path)

    front = ChangeFrontmatter.parse_file(path)
    config = front['change_config']
    raise ConfigError, missing_config_message(path) unless config.is_a?(Hash)

    new(config, root || File.dirname(path), profile: profile, spec_version: front['spec_version'], overrides: overrides)
  end

  # Loads one app's change_config from a standalone config file (conventionally
  # `<app-dir>/CHANGE.app.yml`, registered under a monorepo root CHANGE.md's
  # `change_config.apps`). `root` is always the repo root (the directory
  # holding the root CHANGE.md), never this file's own directory: every
  # repo-relative path and boot command an app config carries resolves the
  # same way a single-app CHANGE.md's would, regardless of where the app file
  # itself lives.
  def self.load_app(path, root:, profile: nil, overrides: {})
    raise ConfigError, "app config not found: #{path}. #{REFERENCE_HINT}" unless File.exist?(path)

    raw = YAML.safe_load(File.read(path), aliases: true)
    raise ConfigError, "app config is not a mapping: #{path}" unless raw.is_a?(Hash)

    unknown_top = raw.keys - ChangeSchema::APP_FILE_TOP_KEYS
    raise ConfigError, app_top_key_message(path, unknown_top) unless unknown_top.empty?

    config = raw['change_config']
    raise ConfigError, "app config has no change_config: block (or it is not a mapping): #{path}" unless config.is_a?(Hash)
    if config.key?('apps')
      raise ConfigError, "app config '#{path}' may not itself declare change_config.apps; the registry is flat, one level"
    end

    new(config, root, profile: profile, overrides: overrides)
  end

  def self.app_top_key_message(path, unknown_top)
    message = "app config '#{path}' sets unknown top-level key(s): #{unknown_top.join(', ')}. " \
              "An app file's only accepted top-level key is change_config:."
    message += ' Governance is repo-wide and lives only in the root CHANGE.md.' if unknown_top.include?('change_policy')
    message
  end

  def self.missing_config_message(path)
    message = "CHANGE.md has no change_config: frontmatter block (or it is not a mapping): #{path}. #{REFERENCE_HINT}"
    message += " #{PLACEHOLDER_HINT}" if placeholder_era_layout?(path)
    message
  end

  # Narrow, string-based detection so it only fires on the specific pre-1.0
  # shape (a sibling .cf config file, or CHANGE.md prose still pointing at
  # one) and never misfires on a valid file that simply lacks change_config:.
  def self.placeholder_era_layout?(path)
    dir = File.dirname(path)
    return true if File.exist?(File.join(dir, '.cf', 'change-fabric.yml'))
    return true if File.exist?(File.join(dir, '.cf', 'change.yml'))

    body = File.read(path)
    body.include?('placeholder: true') || body.include?('.cf/change-fabric.yml') || body.include?('.cf/change.yml')
  rescue StandardError
    false
  end

  # Loads and reports on a CHANGE.md (or, given an already-loaded config, just
  # that config) without running any lane: a fast well-formed check an author
  # runs while iterating, before a full sweep.
  def self.doctor(path, profile: nil, overrides: {})
    doctor_lines(path, load(path, profile: profile, overrides: overrides)).join("\n")
  end

  # The single-config doctor report body. Shared by the plain single-app
  # `doctor` above and by ChangeAppRegistry, which calls this once per
  # registered app so a monorepo doctor walk and a single-app one read
  # identically.
  def self.doctor_lines(label, config)
    boot = config.boot
    lines = [ "CHANGE.md OK: #{label}" ]
    lines << "warning: #{config.spec_version_mismatch}" if config.spec_version_mismatch
    lines << "profile: #{config.profile}" if config.profile
    lines += [
      "project: #{config.project}",
      "enabled lanes: #{config.enabled_lanes.join(', ')}",
      "boot.up: #{boot.up? ? boot.up : '(none, assumes the app is already running)'}",
      "boot.down: #{boot.down.empty? ? '(none)' : boot.down}"
    ]
    if boot.health_url.empty?
      lines << 'warning: no boot.health.url set; the run trusts boot.up to block until the app is ready'
    else
      lines << "boot.health.url: #{boot.health_url}"
    end
    lines << 'lane targets:'
    config.lane_targets.each { |lane, targets| lines << "  #{lane}: #{targets.join(', ')}" }
    lines.concat(target_mismatch_warnings(config))
    lines.concat(testcase_suite_lines(config))
    lines.concat(schedule_lines(config))
    lines
  end

  # change_config.schedules (0.20.0): one line per schedule, then
  # every url a declared active scan would hit, so a human sees each active
  # target before it is ever scanned. Silent when no schedules block exists,
  # so a file without one reports exactly what it always did.
  def self.schedule_lines(config)
    return [] unless config.schedule_config.declared?

    lines = [ 'schedules:' ]
    config.schedule_config.schedules.each do |s|
      lines << "  #{s.name}: runner=#{s.runner} cron=\"#{s.cron}\" profile=#{s.profile} lanes=#{s.lanes.join(', ')}"
    end
    targets = config.active_scan_targets
    return lines << 'active-scan targets: none' if targets.empty?

    lines + targets.map { |url, profile, name| "active-scan targets: #{url} (profile #{profile}, schedule #{name})" }
  end

  # The testcases lane's suite files, checked here rather than only at run
  # time. Every problem is reported at once, and each is an `error:` line
  # because each one means the lane checks less than its author believes: a
  # glob matching nothing, a suite with no cases, a duplicate case id, an
  # unknown step verb, a case with no acceptance criterion, a quarantine missing
  # its reason or its date, or a `gate_tags` entry no case carries. Silent on a
  # repo that does not run the lane.
  def self.testcase_suite_lines(config)
    return [] unless config.enabled_lanes.include?('testcases')

    lane = config.lane('testcases')
    set = ChangeSuiteSet.load(lane['suites'], lane.dir)
    lines = set.errors.map { |message| "error: #{message}" }
    lines.concat(set.unmatched_gate_tags(Array(lane['gate_tags'])).map do |tag|
      "error: lanes.testcases.gate_tags names '#{tag}', which no loaded case carries"
    end)
    lines.concat(quarantine_lines(set))
    lines.concat(measure_lines(set))
    lines.concat(persona_lines(set, lane))
    lines << "testcases: this install reads suite_version up to #{ChangeSuiteSchema::SUITE_VERSION}"
    return lines unless set.errors.empty?

    lines << "testcases: #{set.cases.size} case(s) in #{set.suites.size} suite(s)"
  end

  # Two cases that look verified and measure nothing, raised as warnings: a
  # figure captured and then never compared (a `capture` or `expect_stable`
  # var that no `expect_equal` reads), and a case whose every expectation is a
  # literal text match with no captured figure. Both pass on a page that shows
  # the right words and the wrong numbers.
  ASSERTION_VERBS = ChangeFlowCompiler::RUNTIME_VERBS.values_at(*ChangeFlowCompiler::ASSERTIONS).freeze

  def self.measure_lines(set)
    set.cases.flat_map do |item|
      steps = compile_quietly(item)
      next [] unless steps

      unread_capture_lines(item, steps) + static_text_lines(item, steps)
    end
  end

  def self.compile_quietly(item)
    ChangeFlowCompiler.new(item.steps, base_url: 'http://doctor.invalid', env: {}).compile
  rescue ChangeFlowCompiler::Error
    nil
  end

  def self.unread_capture_lines(item, steps)
    read = steps.flat_map { |step| [ step[:var], step[:equalsVar] ] if step[:verb] == 'expectEqual' }.compact
    steps.filter_map { |step| step[:as] if step[:verb] == 'capture' }.uniq.reject { |name| read.include?(name) }.map do |name|
      "warning: testcases captured figure #{name} in #{item.qualified_id} is never compared " \
        '(no expect_equal reads it)'
    end
  end

  def self.static_text_lines(item, steps)
    expectations = steps.select { |step| ASSERTION_VERBS.include?(step[:verb]) }
    return [] if expectations.empty? || steps.any? { |step| %w[capture expectStable].include?(step[:verb]) }
    return [] unless expectations.all? { |step| step[:verb] == 'expectText' }

    [ "warning: testcases case '#{item.qualified_id}' asserts only static text (every expectation is a literal " \
      'text match, nothing is measured)' ]
  end

  # A case naming a persona the lane does not define runs as nobody, so it is
  # an error here as well as a failing case at run time.
  def self.persona_lines(set, lane)
    defined = (lane['personas'].is_a?(Hash) ? lane['personas'].keys.map(&:to_s) : [])
    (set.named_personas - defined).map do |name|
      "error: a testcases case names persona '#{name}', which lanes.testcases.personas does not define"
    end
  end

  # The quarantine debt, raised here rather than only at gate time. An expiry
  # that has passed is an `error:` because the file now says something untrue,
  # and one coming due is a `warning:` because the author still has time to
  # either fix the case or make a deliberate decision to re-quarantine it.
  # Neither line changes what runs: a quarantine lapses on its own date.
  def self.quarantine_lines(set)
    today = Date.today
    set.expired_quarantines(today).map do |item|
      "error: testcases case '#{item.qualified_id}' has an expired quarantine " \
        "(#{item.quarantine.until_on.iso8601}); it gates again, so either fix it or re-quarantine it"
    end + set.expiring_quarantines(today).map do |item|
      "warning: testcases case '#{item.qualified_id}' quarantine expires in " \
        "#{item.quarantine.days_left(today)} day(s) (#{item.quarantine.until_on.iso8601}): #{item.quarantine.reason}"
    end
  end

  # Warns when a lane's own absolute url literal (an absolute zap target, an
  # explicit lane base_url, a k6 env BASE_URL) points somewhere other than the
  # resolved profile's own boot.target_url host. Only meaningful once a config
  # actually has a resolved profile: an unprofiled config has exactly one
  # target by construction, so there is nothing for a literal to disagree
  # with. A warning, not an error: a deliberately cross-origin scope is
  # legitimate, just rarely what the author meant when profiles exist.
  def self.target_mismatch_warnings(config)
    return [] unless config.profile

    profile_host = uri_host(config.boot.target_url)
    return [] unless profile_host

    config.enabled_lanes.each_with_object([]) do |lane_name, warnings|
      config.lane(lane_name).absolute_literals.each do |literal|
        host = uri_host(literal)
        next if host.nil? || host == profile_host

        warnings << "warning: lane '#{lane_name}' target '#{literal}' does not match profile " \
                    "'#{config.profile}' target '#{config.boot.target_url}'; an absolute lane target " \
                    'is not profile-scoped.'
      end
    end
  end

  def self.uri_host(url)
    URI.parse(url.to_s).host
  rescue URI::InvalidURIError
    nil
  end

  # `dir` is the CHANGE.md directory, i.e. the repo root, used to resolve
  # repo-relative paths (a k6 script) the lanes reference. `profile` selects
  # a named change_config.profiles entry (v0.2.0); nil is the ordinary,
  # pre-0.2.0 single-target shape. `overrides` (0.4.0) carries an optional
  # `:target_url` and/or `:health_url`, deep-merged into `boot` after the
  # profile merge so a CLI flag always wins over whatever the resolved
  # profile set, letting an ephemeral preview deployment's url be passed at
  # invocation time instead of committed and hand-edited.
  def initialize(raw, dir, profile: nil, spec_version: nil, overrides: {})
    @dir = dir
    @source = raw
    @schedule_config = ChangeScheduleConfig.new(raw)
    @declared_spec_version = spec_version.to_s
    @profile_names = raw['profiles'].is_a?(Hash) ? raw['profiles'].keys.map(&:to_s) : []
    @profile = resolve_profile_name(raw, profile)
    merged = @profile ? merge_profile(raw, @profile) : raw
    @raw = apply_overrides(merged, overrides)
    validate
  end

  def project = @raw.fetch('project', 'project').to_s
  def boot = Boot.new(@raw['boot'] || {}, @dir)

  # The resolved profile name, or nil when this config has no profiles block
  # (or none was requested and none is configured as the default).
  def profile = @profile

  # nil when CHANGE.md's frontmatter spec_version is absent or matches this
  # toolkit's ChangeSchema::VERSION; otherwise a named, actionable message.
  # spec_version is optional and unenforced (a mismatch never raises): a repo
  # pinned to an older schema still loads and runs, since every field this
  # toolkit added since is simply additive. The point is visibility, not a
  # gate, catching the class of bug where a config was authored against a
  # newer schema than the toolkit installed reading it actually understands
  # (a field silently ignored) before that surfaces as a confusing runtime gap.
  def spec_version_mismatch
    return nil if @declared_spec_version.empty? || @declared_spec_version == ChangeSchema::VERSION

    message = "CHANGE.md declares spec_version #{@declared_spec_version} but the installed change-fabric is " \
      "#{ChangeSchema::VERSION}. If #{@declared_spec_version} is older, fields added since are silently " \
      "ignored; if newer, this toolkit may not understand fields it relies on yet. Update the toolkit or " \
      'CHANGE.md\'s spec_version.'
    message += ' Note: one of these is a pre-release schema, whose field set may still be changing; ' \
               'pin to a stable version for anything you depend on.' if prerelease?

    message
  end

  # The repo root: the directory holding CHANGE.md.
  def repo_root = @dir

  # change_config.schedules (0.20.0), parsed from the file as
  # authored, before any profile merge. Empty when the block is absent.
  def schedule_config = @schedule_config

  # Every url a declared active scan (a schedule with zap.mode: full) would
  # hit, as [url, profile, schedule] triples. Resolved through the schedule's
  # own profile, so it names exactly what that scan targets.
  def active_scan_targets
    @schedule_config.schedules.select(&:active_scan?).flat_map do |schedule|
      resolved = ChangeConfig.new(@source, @dir, profile: schedule.profile)
      lane = resolved.lane('zap').merge(schedule.override('zap'))
      lane.targets(resolved.boot.target_url).map { |url| [ url, schedule.profile, schedule.name ] }
    end
  end

  # A stable digest of the config this run actually resolved, after the profile
  # merge and any CLI overrides. Recorded in the run manifest so two reports
  # that disagree can be checked against what each was run with, instead of the
  # question stopping at "it passed for me". Keys are sorted before hashing, so
  # re-ordering CHANGE.md without changing a value leaves the digest alone; the
  # values are env var names and urls, never secrets, so the hashed input is
  # safe to derive from the config as-is.
  def digest = EmitDigest.of(@raw)

  # The enabled lanes, in the fixed LANES order so a report's lane sequence is
  # stable across runs regardless of the file's key order.
  def enabled_lanes
    LANES.select { |name| lane_enabled?(name) }
  end

  def lane(name) = LaneConfig.new(name.to_s, @raw.dig('lanes', name.to_s) || {}, @dir)

  # The resolved target(s) each enabled lane will actually hit, keyed by lane
  # name: `zap` may carry more than one, every other lane exactly one. Used by
  # `doctor` so an author sees at a glance what a selected `--profile` sends
  # each lane at, and to catch a lane target that silently did not follow a
  # profile switch.
  def lane_targets
    enabled_lanes.to_h { |name| [ name, resolved_targets(name) ] }
  end

  private

  # Key-sorted, symbol-free rendering of a config tree, so #digest depends on
  # the values a run resolved and not on the order they were written in.
  def resolved_targets(name)
    lane_config = lane(name)
    return lane_config.targets(boot.target_url) if name == 'zap'

    if name == 'k6'
      env_url = lane_config.env['BASE_URL'].to_s
      return [ env_url ] unless env_url.empty?
    end

    [ lane_config.base_url(boot.target_url) ]
  end

  def apply_overrides(raw, overrides)
    boot_overrides = {}
    boot_overrides['target_url'] = overrides[:target_url].to_s if overrides[:target_url]
    boot_overrides['health'] = { 'url' => overrides[:health_url].to_s } if overrides[:health_url]
    return raw if boot_overrides.empty?

    deep_merge(raw, { 'boot' => boot_overrides })
  end

  # This toolkit does no ordering or comparison on SemVer prerelease
  # identifiers (0.4.0-alpha.1); a bare hyphen check is enough to flag that
  # one side of a spec_version mismatch is still moving, which is all
  # spec_version_mismatch needs, not real precedence.
  def prerelease?
    @declared_spec_version.include?('-') || ChangeSchema::VERSION.include?('-')
  end

  # nil when `raw` has no profiles block at all (a request is simply ignored,
  # so an unprofiled CHANGE.md never has to know profiles exist). Otherwise
  # the requested name, or `default_profile`, or a loud error: a profiles
  # block with no way to pick one is treated as author error, not a silent
  # "run something anyway".
  def resolve_profile_name(raw, requested)
    profiles = raw['profiles']
    return nil unless profiles.is_a?(Hash) && !profiles.empty?

    name = requested.to_s.empty? ? raw['default_profile'].to_s : requested.to_s
    if name.empty?
      raise ConfigError,
            "change_config.profiles is set but no profile was selected: pass --profile NAME or set default_profile. " \
            "Defined profiles: #{profiles.keys.join(', ')}"
    end
    raise ConfigError, "unknown profile '#{name}'; defined profiles: #{profiles.keys.join(', ')}" unless profiles[name].is_a?(Hash)

    name
  end

  # The base config with the named profile's overrides deep-merged over it.
  # `profiles`/`default_profile` themselves are dropped from the result so a
  # merged config is indistinguishable in shape from an ordinary unprofiled
  # one, which is what every downstream reader (Boot, LaneConfig, validate)
  # already expects.
  def merge_profile(raw, name)
    profile = raw.dig('profiles', name)
    validate_profile_keys(name, profile)
    base = raw.reject { |key, _| %w[profiles default_profile].include?(key) }
    deep_merge(base, profile.except(*PROFILE_ONLY_KEYS))
  end

  def validate_profile_keys(name, profile)
    unknown_top = profile.keys - PROFILE_TOP_KEYS
    raise ConfigError, "profile '#{name}' sets unknown key(s): #{unknown_top.join(', ')}. Profiles may only set #{PROFILE_TOP_KEYS.join(', ')}." unless unknown_top.empty?

    lanes = profile['lanes']
    raise ConfigError, "profile '#{name}' lanes must be a mapping" unless lanes.nil? || lanes.is_a?(Hash)

    (lanes || {}).each do |lane, section|
      raise ConfigError, "profile '#{name}' lane '#{lane}' override must be a mapping" unless section.is_a?(Hash)

      command_error = lane == 'command' && ChangeCommandConfig.profile_override_error(name, section)
      raise ConfigError, command_error if command_error

      unknown_lane = section.keys - PROFILE_LANE_KEYS
      unless unknown_lane.empty?
        raise ConfigError,
              "profile '#{name}' lane '#{lane}' sets unknown key(s): #{unknown_lane.join(', ')}. " \
              "A profile's lane override may only set #{PROFILE_LANE_KEYS.join(', ')}; other lane behavior is shared across profiles."
      end

      reject_basic_auth_outside_browser_lanes(lane, section, subject: "profile '#{name}' lane '#{lane}'")
      reject_targets_outside_target_lanes(lane, section, subject: "profile '#{name}' lane '#{lane}'")
      reject_auth_outside_auth_lanes(lane, section, subject: "profile '#{name}' lane '#{lane}'")
    end
  end

  def deep_merge(base, override)
    base.merge(override) do |_key, base_val, override_val|
      base_val.is_a?(Hash) && override_val.is_a?(Hash) ? deep_merge(base_val, override_val) : override_val
    end
  end

  def lane_enabled?(name)
    section = @raw.dig('lanes', name)
    section.is_a?(Hash) && section.fetch('enabled', true) != false
  end

  def validate
    lanes = @raw['lanes']
    raise ConfigError, "'lanes' must be a mapping" unless lanes.nil? || lanes.is_a?(Hash)

    unknown = (lanes || {}).keys - LANES
    raise ConfigError, "unknown lane(s): #{unknown.join(', ')}" unless unknown.empty?
    raise ConfigError, 'no lanes enabled' if enabled_lanes.empty?

    validate_basic_auth_lanes(lanes || {})
    validate_launch_args(lanes || {})
    validate_testcases_parallel(lanes || {})
    validate_testcases_personas(lanes || {})
    validate_testcases_auth_expiry(lanes || {})
    validate_command_lane(lanes || {})
    validate_zap_mode(lanes || {})
    schedule_errors = @schedule_config.errors
    raise ConfigError, schedule_errors.join('; ') unless schedule_errors.empty?
    boot_errors = boot.errors
    raise ConfigError, boot_errors.join('; ') unless boot_errors.empty?
    design_errors = ChangeSchema.design_errors(@raw['design'], apps: @raw['apps'].is_a?(Hash) ? @raw['apps'].keys : [])
    raise ConfigError, design_errors.join('; ') unless design_errors.empty?

    # execution / outbound / trackers (0.19.0).
    execution_errors = ExecutionConfigSchema.errors(@raw)
    raise ConfigError, execution_errors.join('; ') unless execution_errors.empty?
  end

  # lanes.zap.mode (0.20.0): baseline is the only mode a per-PR
  # lane may run. full is an active scan and is accepted only inside a
  # schedule override whose profile has opted in (ChangeScheduleConfig).
  def validate_zap_mode(lanes)
    section = lanes['zap']
    return unless section.is_a?(Hash) && section.key?('mode')

    mode = section['mode']
    return if mode == ChangeScheduleConfig::ZAP_DEFAULT_MODE

    if mode == 'full'
      raise ConfigError, 'lanes.zap.mode: full is an active scan and is accepted only inside a schedule ' \
                         'override (change_config.schedules.<name>.zap.mode) whose profile sets allow_active_scan: true'
    end
    raise ConfigError, "lanes.zap.mode must be one of #{ChangeScheduleConfig::ZAP_MODES.join(', ')}; got #{mode.inspect}"
  end

  # lanes.command (0.17.0): see ChangeCommandConfig for the entry rules.
  def validate_command_lane(lanes)
    return unless lanes.key?('command')

    errors = ChangeCommandConfig.errors(lanes['command'], profiles: @profile_names)
    raise ConfigError, errors.join('; ') unless errors.empty?
  end

  # lanes.testcases.launch_args (0.16.0): Chromium flags for the lane's browser.
  # Only the shape is checked: a list of strings that each look like a flag.
  def validate_launch_args(lanes)
    section = lanes['testcases']
    return unless section.is_a?(Hash) && section.key?('launch_args')

    args = section['launch_args']
    return if args.is_a?(Array) && args.all? { |arg| arg.is_a?(String) && arg.match?(/\A--\S/) }

    raise ConfigError, "lanes.testcases.launch_args must be a list of Chromium flags, each starting with '--'; got #{args.inspect}"
  end

  # lanes.testcases.parallel (0.21.0): how many cases run at once, each in its
  # own browserless call. 1 (serial) by default; 10 at most, the container's
  # CONCURRENT, so the pool can never queue behind itself.
  TESTCASES_PARALLEL_RANGE = (1..10)

  def validate_testcases_parallel(lanes)
    section = lanes['testcases']
    return unless section.is_a?(Hash) && section.key?('parallel')

    value = section['parallel']
    return if value.is_a?(Integer) && TESTCASES_PARALLEL_RANGE.cover?(value)

    raise ConfigError, "lanes.testcases.parallel must be an integer from #{TESTCASES_PARALLEL_RANGE.min} to " \
                       "#{TESTCASES_PARALLEL_RANGE.max}; got #{value.inspect}"
  end

  # lanes.testcases.personas (0.22.0): named logins, each the same shape as
  # the lane's `auth:` block. `default` is that block and `anonymous` is no
  # login, so neither may be redefined here.
  def validate_testcases_personas(lanes)
    section = lanes['testcases']
    return unless section.is_a?(Hash) && section.key?('personas')

    personas = section['personas']
    raise ConfigError, "lanes.testcases.personas must be a mapping of persona name to an auth block; got #{personas.inspect}" unless personas.is_a?(Hash)

    personas.each do |name, block|
      validate_persona(name.to_s, block)
      validate_expired_when(block['expired_when'], "lanes.testcases.personas.#{name}") if block.key?('expired_when')
    end
  end

  def validate_testcases_auth_expiry(lanes)
    auth = lanes['testcases'].is_a?(Hash) ? lanes['testcases']['auth'] : nil
    validate_expired_when(auth['expired_when'], 'lanes.testcases.auth') if auth.is_a?(Hash) && auth.key?('expired_when')
  end

  # expired_when (0.22.0): exactly one probe, a selector shown only when
  # logged out, or a probe_url whose GET answers expect_status once the
  # session is gone.
  def validate_expired_when(rule, where)
    field = "#{where}.expired_when"
    raise ConfigError, "#{field} must be a mapping with selector: or probe_url:; got #{rule.inspect}" unless rule.is_a?(Hash)

    kinds = %w[selector probe_url].select { |key| rule.key?(key) }
    raise ConfigError, "#{field} must set exactly one of selector or probe_url" unless kinds.size == 1
    return validate_expired_selector(rule, field) if kinds == [ 'selector' ]

    validate_expired_probe(rule, field)
  end

  def validate_expired_selector(rule, field)
    raise ConfigError, "#{field}.selector must be a non-empty string" unless rule['selector'].is_a?(String) && !rule['selector'].strip.empty?
    raise ConfigError, "#{field}.expect_status only goes with probe_url" if rule.key?('expect_status')
  end

  def validate_expired_probe(rule, field)
    raise ConfigError, "#{field}.probe_url must be a path such as /api/me" unless rule['probe_url'].is_a?(String) && rule['probe_url'].start_with?('/')

    statuses = Array(rule['expect_status'])
    return if !statuses.empty? && statuses.all? { |code| code.is_a?(Integer) && code.between?(100, 599) }

    raise ConfigError, "#{field}.expect_status must be an HTTP status or a list of them; got #{rule['expect_status'].inspect}"
  end

  def validate_persona(name, block)
    if ChangeSuite::BUILTIN_PERSONAS.include?(name)
      raise ConfigError, "lanes.testcases.personas.#{name} is reserved: `default` is the lane's auth: block and " \
                         '`anonymous` is no login'
    end
    raise ConfigError, "lanes.testcases.personas has a name that is not letters, digits, - and _: #{name.inspect}" unless name.match?(/\A[A-Za-z0-9_-]+\z/)
    return if block.is_a?(Hash) && !block.empty?

    raise ConfigError, "lanes.testcases.personas.#{name} must be an auth block (login_url plus email_env and " \
                       "password_env, or steps:); got #{block.inspect}"
  end

  # basic_auth only means anything on a lane that drives a real browser page
  # (a11y, browserless); k6 and zap never read it, so setting it there is
  # silently a no-op rather than the credential gate an author would expect.
  # Shared by the base-config validator and the per-profile lane validator so
  # the rule and its message stay in exactly one place.
  def validate_basic_auth_lanes(lanes)
    lanes.each { |name, section| reject_basic_auth_outside_browser_lanes(name, section, subject: "lane '#{name}'") }
  end

  def reject_basic_auth_outside_browser_lanes(lane, section, subject:)
    return unless section.is_a?(Hash) && section.key?('basic_auth')
    return if BROWSER_LANES.include?(lane)

    raise ConfigError,
          "#{subject} sets basic_auth, but basic_auth only applies to a browser lane " \
          "(#{BROWSER_LANES.join(', ')}); #{lane} never reads it."
  end

  # targets (0.4.0) only means anything on zap; every other lane has exactly
  # one base_url, so accepting targets there would be a scope list an author
  # believes is doing something that no lane script ever reads.
  def reject_targets_outside_target_lanes(lane, section, subject:)
    return unless section.is_a?(Hash) && section.key?('targets')
    return if TARGET_LANES.include?(lane)

    raise ConfigError,
          "#{subject} sets targets, but targets only applies to the zap lane; #{lane} never reads it."
  end

  # auth (the multi-step login-flow block) only means anything on a lane that
  # drives a login: browserless and testcases. a11y drives a real browser page
  # too but only ever reads basic_auth, so accepting auth there would be the
  # same silent no-op basic_auth's own guard exists to prevent.
  def reject_auth_outside_auth_lanes(lane, section, subject:)
    return unless section.is_a?(Hash) && section.key?('auth')
    return if AUTH_LANES.include?(lane)

    raise ConfigError,
          "#{subject} sets auth, but auth only applies to a login-driving lane " \
          "(#{AUTH_LANES.join(', ')}); #{lane} never reads it."
  end

  # How to bring the target app up and confirm it is ready before any lane runs.
  # `network` is an existing docker network the runners join (the app's own
  # compose network); when absent the runner creates an ephemeral one. `health`
  # is polled from the host, so its url must be host-reachable even though the
  # lane `base_url`s address services by their in-network name.
  class Boot
    def initialize(raw, dir)
      @raw = raw
      @dir = dir
    end

    def up = @raw['up'].to_s
    def down = @raw['down'].to_s
    def network = @raw['network']&.to_s
    def target_url = @raw['target_url'].to_s
    def health_url = @raw.dig('health', 'url').to_s
    def health_status = Integer(@raw.dig('health', 'expect_status') || 200)
    def health_timeout = Integer(@raw.dig('health', 'timeout_seconds') || 120)
    def up? = !up.empty?

    # Repo-relative path(s) of env file(s) to parse and pass into the boot
    # subprocess environment, letting a project's own ${VAR} build-arg
    # interpolation (a compose `build.args:` entry, which never reads a
    # service's `env_file:`) resolve without pre-exporting anything. Accepts
    # a single path or a list; later files win over earlier ones. Resolved
    # against the CHANGE.md directory, same as a lane's repo-relative paths.
    def env_files = Array(@raw['env_file']).map { |path| File.expand_path(path.to_s, @dir) }

    # boot.env_file as authored (repo-relative), for the trust digest: the
    # digest describes the definition, not where this checkout happens to be.
    def env_file_entries = Array(@raw['env_file']).map(&:to_s)

    # boot.env (0.17.0): the names boot.up and boot.down may see beyond the
    # minimal base environment. Values come from ENV, then boot.env_file.
    def env_names = Array(@raw['env']).map(&:to_s)

    # boot.timeout_seconds (0.17.0): applies to boot.up and boot.down alike.
    # nil means no limit, so a long first build is never cut short by default.
    def timeout_seconds = @raw['timeout_seconds']

    # 0.15.0: reaching a local HTTPS dev app from the browser container.
    # `add_hosts` are "HOST:TARGET" docker --add-host mappings (the container
    # cannot read the host's /etc/hosts); `ignore_https_errors` skips the local
    # dev CA's certificate check, refused unless target_url is local.
    def add_hosts = Array(@raw['add_hosts']).map(&:to_s)
    def ignore_https_errors = @raw['ignore_https_errors'] == true

    # The ChangeLocalTls allowlist when the bypass is on, else nil.
    def local_tls_hosts = ignore_https_errors ? ChangeLocalTls.allowed_hosts(target_url, add_hosts) : nil

    def errors
      errors = []
      hosts = @raw['add_hosts']
      unless hosts.nil? || (hosts.is_a?(Array) && hosts.all? { |entry| entry.is_a?(String) && entry.match?(/\A[^:\s]+:\S+\z/) })
        errors << 'boot.add_hosts must be a list of "HOST:TARGET" strings'
      end
      if @raw.key?('ignore_https_errors') && ![ true, false ].include?(@raw['ignore_https_errors'])
        errors << 'boot.ignore_https_errors must be true or false'
      elsif ignore_https_errors && !ChangeLocalTls.local_host?(target_url, add_hosts)
        errors << "boot.ignore_https_errors needs a local boot.target_url or an add_hosts mapping for its host; got #{target_url.inspect}"
      end
      errors.concat(env_errors, timeout_errors, doctrine_errors)
    end

    private

    def env_errors
      return [] unless @raw.key?('env')

      names = @raw['env']
      unless names.is_a?(Array) && names.all? { |name| name.is_a?(String) && name.match?(ChangeConfig::ENV_NAME) }
        return [ "boot.env must be a list of variable names (A-Z, 0-9, _); got #{names.inspect}" ]
      end

      reserved = names & ChangeConfig::RESERVED_ENV_NAMES
      return [] if reserved.empty?

      [ "boot.env may not declare #{reserved.join(', ')}; the base environment and CF_CHANGE_* values are always provided" ]
    end

    def timeout_errors
      return [] unless @raw.key?('timeout_seconds')
      return [] if ChangeConfig.timeout?(@raw['timeout_seconds'])

      [ "boot.timeout_seconds must be an integer from 1 to #{ChangeConfig::MAX_TIMEOUT_SECONDS}; got #{@raw['timeout_seconds'].inspect}" ]
    end

    def doctrine_errors
      { 'boot.up' => up, 'boot.down' => down }.filter_map { |field, cmd| ChangeConfig.doctrine_error(field, cmd) }
    end
  end

  # One lane's settings, read through named accessors so a lane script never digs
  # into the raw hash. Absent keys fall back to per-lane defaults the lane script
  # supplies, keeping this a thin typed view rather than a place for policy.
  class LaneConfig
    def initialize(name, raw, dir)
      @name = name
      @raw = raw
      @dir = dir
    end

    def name = @name

    # The config directory (the repo root), for a lane that resolves
    # repo-relative paths itself rather than one key at a time: the testcases
    # lane expands a list of suite-file globs against it.
    def dir = @dir

    def [](key) = @raw[key.to_s]

    # A copy with some keys replaced, for an invocation-time override (a
    # cf:screenshot --route) that must not touch the loaded config itself.
    def merge(overrides) = LaneConfig.new(@name, @raw.merge(overrides.transform_keys(&:to_s)), @dir)
    def fetch(key, default) = @raw.fetch(key.to_s, default)
    def env = (@raw['env'] || {}).transform_keys(&:to_s).transform_values(&:to_s)

    # Resolves a repo-relative path (e.g. a k6 script) against the config dir, or
    # nil when the key is absent so the lane can fall back to a built-in default.
    def path(key)
      value = @raw[key.to_s]
      value && File.expand_path(value.to_s, @dir)
    end

    def base_url(fallback) = (@raw['base_url'] || fallback).to_s

    # The zap lane's scanned urls (0.4.0). Absent, the lane base url alone.
    # An entry may be absolute (used as-is) or relative (resolved against the
    # lane base url exactly as change_lane.rb#redirected_path already resolves
    # a11y/browserless routes), so a multi-path scope stays profile-portable
    # instead of pinning every profile at one committed host.
    def targets(fallback)
      list = Array(@raw['targets']).map(&:to_s).reject(&:empty?)
      base = base_url(fallback)
      return [ base ] if list.empty?

      list.map { |entry| absolute?(entry) ? entry : URI.join("#{base}/", entry).to_s }
    end

    # The absolute url literals this lane was authored with: an absolute
    # `targets` entry, an explicit `base_url`, or (on k6) `env['BASE_URL']`.
    # Each is a fixed value no profile switch changes, which is exactly what
    # `doctor`'s profile-mismatch lint checks against the resolved profile's
    # own target.
    def absolute_literals
      literals = Array(@raw['targets']).map(&:to_s).select { |entry| absolute?(entry) }
      literals << @raw['base_url'].to_s if @raw['base_url']
      literals << env['BASE_URL'].to_s if @name == 'k6' && env['BASE_URL']
      literals.reject(&:empty?).uniq
    end

    private

    def absolute?(value) = value.to_s.match?(%r{\A[a-z][a-z0-9+.\-]*://}i)
  end
end

if __FILE__ == $PROGRAM_NAME
  # Run directly (not required), this file's own path was never added to
  # $LOADED_FEATURES, so change_apps.rb's own require_relative of this same
  # file would otherwise reload and redefine every constant above. Registering
  # it first makes that require_relative the no-op it should be.
  $LOADED_FEATURES << File.expand_path(__FILE__) unless $LOADED_FEATURES.include?(File.expand_path(__FILE__))
  require_relative 'change_apps'

  if ARGV.first == 'doctor'
    config_flag = ARGV.index('--config')
    path = config_flag ? ARGV[config_flag + 1] : ChangeConfig::DEFAULT_PATH
    profile_flag = ARGV.index('--profile')
    profile = profile_flag ? ARGV[profile_flag + 1] : nil
    apps = ARGV.each_index.select { |i| ARGV[i] == '--app' }.map { |i| ARGV[i + 1] }
    target_url_flag = ARGV.index('--target-url')
    health_url_flag = ARGV.index('--health-url')
    overrides = {}
    overrides[:target_url] = ARGV[target_url_flag + 1] if target_url_flag
    overrides[:health_url] = ARGV[health_url_flag + 1] if health_url_flag
    begin
      puts ChangeAppRegistry.doctor(path, profile: profile, apps: apps, overrides: overrides)
    rescue ChangeConfig::ConfigError => e
      warn "[change] setup error: #{e.message}"
      exit 2
    end
  else
    warn 'usage: change_config.rb doctor [--config PATH] [--profile NAME] [--app NAME]... [--target-url URL] [--health-url URL]'
    exit 1
  end
end
