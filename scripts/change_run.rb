#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'optparse'
require_relative 'change_config'
require_relative 'change_docker'
require_relative 'change_findings'
require_relative 'change_report'
require_relative 'change_k6_narrative'
require_relative 'change_gate_store'
require_relative 'change_lane_k6'
require_relative 'change_lane_a11y'
require_relative 'change_lane_zap'
require_relative 'change_lane_browserless'

# The change-fabric orchestrator: the one command the pst:change / pst:k6 /
# pst:a11y / pst:zap skills invoke. It reads a project's config, boots the target
# app and waits for its health signal, stands up the ephemeral runners (a shared
# browserless container only when a browser lane runs), executes the requested
# lanes, writes a CSV+Markdown report pair to the Desktop, and records the
# outcome under the git head SHA so the merge gate can consult it later.
#
# Usage: change_run.rb <all|k6|a11y|zap|browserless> [--config PATH] [--profile NAME]
#
# Everything that stands up gets torn down: the app via the config's `down`
# command, the browser container and any ephemeral network via their block
# helpers. Exit status is 0 when every run lane passed, 1 when any lane failed,
# 2 on a setup failure (no docker, bad config, app never ready).
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
  Context = Struct.new(:network, :target_url, :health_url, :browserless, :logger, keyword_init: true) do
    def log(message) = logger.call(message)
  end

  def self.main(argv)
    new(argv).run
  end

  def initialize(argv)
    @scope, @config_path, @profile = parse_args(argv)
  end

  def run
    return abort_setup('docker is not available') unless ChangeDocker.available?
    return sweep_stale_resources if @scope == 'sweep'

    config = ChangeConfig.load(@config_path, profile: @profile)
    lanes = resolve_lanes(config)
    findings = with_app(config) { |ctx| execute(config, lanes, ctx) }
    report = write_report(config, findings, lanes)
    record_gate(config, lanes, findings, report)
    summarize(findings, report)
    findings.passed? ? 0 : 1
  rescue ChangeConfig::ConfigError => e
    abort_setup(e.message)
  end

  private

  def parse_args(argv)
    scope = argv.first
    path = ChangeConfig::DEFAULT_PATH
    profile = nil
    OptionParser.new do |o|
      o.on('--config PATH') { |value| path = value }
      o.on('--profile NAME') { |value| profile = value }
    end.parse(argv.drop(1))
    valid = %w[all sweep] + ChangeConfig::LANES
    abort_and_exit("scope must be one of: #{valid.join(', ')}") unless valid.include?(scope)
    [ scope, path, profile ]
  end

  # Force-removes any `pst-change-*` container or network left behind by a run
  # that crashed before its own teardown ran. Takes no CHANGE.md, since it is
  # meant to run standalone between runs, not as part of one.
  def sweep_stale_resources
    removed = ChangeDocker.sweep
    removed[:containers].each { |name| log("[change] removed stale container: #{name}") }
    removed[:networks].each { |name| log("[change] removed stale network: #{name}") }
    log("[change] sweep: #{removed[:containers].size} container(s), #{removed[:networks].size} network(s) removed")
    0
  end

  def resolve_lanes(config)
    return config.enabled_lanes if @scope == 'all'

    [ @scope ]
  end

  # Boots the app, waits for health, then yields a context to run lanes in,
  # tearing the app down afterward. Network and browser lifecycle nest inside so
  # they too are always cleaned up.
  def with_app(config)
    boot = config.boot
    boot_up(boot)
    wait_healthy(boot)
    ChangeDocker.with_network(boot.network) do |network|
      with_context(config, network) { |ctx| yield ctx }
    end
  ensure
    boot_down(boot)
  end

  def with_context(config, network)
    ctx_args = {
      network: network.name, target_url: config.boot.target_url,
      health_url: config.boot.health_url, logger: method(:log)
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

  def execute(config, lanes, ctx)
    findings = Findings.new
    lanes.each do |name|
      log("[change] running #{name} lane")
      lane = LANE_CLASSES.fetch(name).new(config.lane(name), ctx)
      Array(lane.run).each { |finding| findings.add(finding) }
    end
    findings
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

  def write_report(config, findings, lanes)
    ChangeReport.new(
      project: config.project, scope: @scope, findings: findings,
      meta: { 'head' => head_sha, 'lanes' => findings.lanes.join(', ') },
      sections: report_sections(config, lanes)
    ).write
  end

  # Narrative sections that belong in the Markdown but not the CSV. Today only
  # the k6 lane contributes one, built from its config scenario block.
  def report_sections(config, lanes)
    return [] unless lanes.include?('k6')

    [ ChangeK6Narrative.section(config.lane('k6')['scenario']) ].compact
  end

  # Records the outcome under the head SHA. Only a comprehensive `all` run that
  # passed satisfies the release merge gate; a single-lane run records its own
  # scope and never unlocks a protected-branch merge.
  def record_gate(config, _lanes, findings, report)
    ChangeGateStore.new(head_sha, profile: config.profile).record(
      scope: @scope, status: findings.passed? ? 'pass' : 'fail',
      project: config.project, lanes: findings.lane_status,
      report: File.basename(report[:markdown])
    )
  end

  def summarize(findings, report)
    log('')
    findings.lane_status.each { |lane, status| log("[change] #{lane}: #{status.upcase}") }
    log("[change] #{findings.failures.size} failing finding(s)")
    log("[change] report: #{report[:markdown]}")
    log("[change] data:   #{report[:csv]}")
    log("[change] #{findings.passed? ? 'PASS' : 'FAIL'} (scope: #{@scope}#{@profile ? ", profile: #{@profile}" : ''})")
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
