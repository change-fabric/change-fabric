#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'
require_relative 'change_frontmatter'
require_relative 'change_schema'

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
  PROFILE_LANE_KEYS = %w[enabled base_url basic_auth].freeze
  PROFILE_TOP_KEYS = %w[project boot lanes].freeze

  # basic_auth (0.3.0) is answered via page.authenticate() in a browser page, so
  # it only means anything on a lane that actually drives one.
  BROWSER_LANES = %w[a11y browserless].freeze

  def self.load(path, profile: nil)
    raise ConfigError, "CHANGE.md not found: #{path}. #{REFERENCE_HINT}" unless File.exist?(path)

    front = ChangeFrontmatter.parse_file(path)
    config = front['change_config']
    raise ConfigError, missing_config_message(path) unless config.is_a?(Hash)

    new(config, File.dirname(path), profile: profile, spec_version: front['spec_version'])
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

  # Loads and reports on a CHANGE.md without running any lane: a fast
  # well-formed check an author runs while iterating, before a full sweep.
  def self.doctor(path, profile: nil)
    config = load(path, profile: profile)
    boot = config.boot
    lines = [ "CHANGE.md OK: #{path}" ]
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
    lines.join("\n")
  end

  # `dir` is the CHANGE.md directory, i.e. the repo root, used to resolve
  # repo-relative paths (a k6 script) the lanes reference. `profile` selects
  # a named change_config.profiles entry (v0.2.0); nil is the ordinary,
  # pre-0.2.0 single-target shape.
  def initialize(raw, dir, profile: nil, spec_version: nil)
    @dir = dir
    @declared_spec_version = spec_version.to_s
    @profile = resolve_profile_name(raw, profile)
    @raw = @profile ? merge_profile(raw, @profile) : raw
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

  # The enabled lanes, in the fixed LANES order so a report's lane sequence is
  # stable across runs regardless of the file's key order.
  def enabled_lanes
    LANES.select { |name| lane_enabled?(name) }
  end

  def lane(name) = LaneConfig.new(name.to_s, @raw.dig('lanes', name.to_s) || {}, @dir)

  private

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
    deep_merge(base, profile)
  end

  def validate_profile_keys(name, profile)
    unknown_top = profile.keys - PROFILE_TOP_KEYS
    raise ConfigError, "profile '#{name}' sets unknown key(s): #{unknown_top.join(', ')}. Profiles may only set #{PROFILE_TOP_KEYS.join(', ')}." unless unknown_top.empty?

    lanes = profile['lanes']
    raise ConfigError, "profile '#{name}' lanes must be a mapping" unless lanes.nil? || lanes.is_a?(Hash)

    (lanes || {}).each do |lane, section|
      raise ConfigError, "profile '#{name}' lane '#{lane}' override must be a mapping" unless section.is_a?(Hash)

      unknown_lane = section.keys - PROFILE_LANE_KEYS
      unless unknown_lane.empty?
        raise ConfigError,
              "profile '#{name}' lane '#{lane}' sets unknown key(s): #{unknown_lane.join(', ')}. " \
              "A profile's lane override may only set #{PROFILE_LANE_KEYS.join(', ')}; other lane behavior is shared across profiles."
      end

      reject_basic_auth_outside_browser_lanes(lane, section, subject: "profile '#{name}' lane '#{lane}'")
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
    def [](key) = @raw[key.to_s]
    def fetch(key, default) = @raw.fetch(key.to_s, default)
    def env = (@raw['env'] || {}).transform_keys(&:to_s).transform_values(&:to_s)

    # Resolves a repo-relative path (e.g. a k6 script) against the config dir, or
    # nil when the key is absent so the lane can fall back to a built-in default.
    def path(key)
      value = @raw[key.to_s]
      value && File.expand_path(value.to_s, @dir)
    end

    def base_url(fallback) = (@raw['base_url'] || fallback).to_s
  end
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.first == 'doctor'
    config_flag = ARGV.index('--config')
    path = config_flag ? ARGV[config_flag + 1] : ChangeConfig::DEFAULT_PATH
    profile_flag = ARGV.index('--profile')
    profile = profile_flag ? ARGV[profile_flag + 1] : nil
    begin
      puts ChangeConfig.doctor(path, profile: profile)
    rescue ChangeConfig::ConfigError => e
      warn "[change] setup error: #{e.message}"
      exit 2
    end
  else
    warn 'usage: change_config.rb doctor [--config PATH] [--profile NAME]'
    exit 1
  end
end
