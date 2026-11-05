# frozen_string_literal: true

require 'json'
require 'rubygems/version'

# Evidence is distinct from availability. Unknown versions never inherit a
# tested claim, and unknown surfaces never inherit another surface's hooks.
class HostCapabilities
  FEATURES = %w[skill_discovery startup_context prompt_context tool_guard mode_persistence child_inheritance completion_gate].freeze
  LEVELS = %w[documented adapter-tested instructions-only unavailable].freeze

  def initialize(path: File.expand_path('../config/host_capabilities.json', __dir__))
    data = JSON.parse(File.read(path))
    raise ArgumentError, 'unknown capability schema' unless data['schema_version'] == 1

    @profiles = data.fetch('profiles')
    keys = @profiles.map { |row| [ row.fetch('host'), row.fetch('surface') ] }
    raise ArgumentError, 'duplicate host surface' unless keys.uniq == keys

    @profiles.each { |row| validate(row) }
  end

  def resolve(host:, surface:, version: nil)
    profile = @profiles.find { |row| row['host'] == host && row['surface'] == surface }
    return fallback(host, surface, version) unless profile

    version = normalize_version(version)
    tested = version && profile.fetch('tested_versions').include?(version)
    reference = version && profile.fetch('reference_versions').include?(version)
    profile.merge('detected_version' => version,
      'version_status' => tested ? 'tested' : reference ? 'reference-only' : 'unverified',
      'effective_support' => tested ? 'adapter-tested' : 'instructions-only')
  end

  def profiles = @profiles.map { |row| row.slice('host', 'surface', 'capabilities', 'live_verification') }

  private

  def validate(row)
    raise ArgumentError, 'invalid capability contract' unless row['contract_version'] == 1
    raise ArgumentError, 'missing capabilities' unless row.fetch('capabilities').keys.sort == FEATURES.sort
    raise ArgumentError, 'unknown evidence level' unless row['capabilities'].values.all? { |value| LEVELS.include?(value) }

    %w[reference_versions tested_versions].each do |key|
      raise ArgumentError, "invalid #{key}" unless row.fetch(key).all? { |version| normalize_version(version) == version }
    end
    raise ArgumentError, 'live evidence must be explicit' unless %w[not-run passed failed].include?(row['live_verification'])
  end

  def normalize_version(raw)
    # Take the whole token so 0.166.0.1 or 0.166.0+build never matches a registered 0.166.0.
    version = raw.to_s[/\d+(?:\.\d+)+(?:[-+][\w.+-]+)?/]
    version if version && Gem::Version.correct?(version)
  end

  def fallback(host, surface, version)
    { 'host' => host, 'surface' => surface, 'detected_version' => normalize_version(version),
      'version_status' => 'unknown-surface', 'effective_support' => 'instructions-only',
      'capabilities' => FEATURES.to_h { |feature| [ feature, 'unavailable' ] }, 'live_verification' => 'not-run' }
  end
end
