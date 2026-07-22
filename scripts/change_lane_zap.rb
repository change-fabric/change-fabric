#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'tmpdir'
require_relative 'change_lane'
require_relative 'change_docker'
require_relative 'change_findings'

# The OWASP ZAP penetration-test lane. Runs the digest-pinned ZAP image's
# baseline automation (a passive spider plus passive checks: security headers,
# cookie flags, information leakage, known-vulnerable libraries) against each
# in-scope target on the run network, then parses ZAP's JSON report so every
# alert becomes a finding. The baseline sends no attack traffic, so it is safe
# against a local stack.
#
# Gate policy is this lane's own, stated here because it is a release gate rather
# than a mirror of ZAP's WARN/FAIL exit convention: a high-risk alert fails the
# lane; with `strict: true` any low-risk-or-above alert fails. Everything below
# the fail bar is a warn and still appears in the report. This is the net-new
# lane: no ZAP automation existed in the platform's source repos, so this defines
# the contract rather than porting one.
class ChangeLaneZap < ChangeLane
  # ZAP riskcode: 0 informational, 1 low, 2 medium, 3 high.
  RISK = { '0' => 'informational', '1' => 'low', '2' => 'medium', '3' => 'high' }.freeze

  def run
    targets.flat_map { |target| scan(target) }
  end

  private

  def targets
    list = Array(@config['targets']).map(&:to_s).reject(&:empty?)
    list.empty? ? [ base_url ] : list
  end

  def strict? = @config.fetch('strict', false)

  def scan(target)
    Dir.mktmpdir('pst-change-zap') do |dir|
      report = 'report.json'
      out, status = execute(target, dir, report)
      @context.log("[zap] #{target} exit #{exit_code(status)}")
      alerts_findings(target, File.join(dir, report), status, out)
    end
  end

  def execute(target, dir, report)
    ChangeDocker.run(
      network: @context.network,
      image: ChangeDocker::ZAP_IMAGE,
      args: [ 'zap-baseline.py', '-t', target, '-J', report, '-r', 'report.html' ],
      mounts: { dir => '/zap/wrk' },
      name: "#{ChangeDocker::RESOURCE_PREFIX}zap-#{SecureRandom.hex(4)}"
    )
  end

  def alerts_findings(target, report, status, out)
    alerts = parse_alerts(report)
    return [ no_alert_finding(target, status, out) ] if alerts.empty?

    alerts.map { |alert| alert_finding(target, alert) }
  end

  # An alert-free scan still reports pass, unless ZAP itself errored (exit 3),
  # so a broken run never silently reads as clean. On an error, surface the tail
  # of ZAP's own output rather than a generic string, since the cause is usually
  # actionable (the target is unreachable from inside the runner: a hostname the
  # ZAP container cannot resolve, or a TLS endpoint served by a proxy that is not
  # on this run's docker network). Configure boot.network so the runner shares
  # the network that can reach the target, or point the target at a
  # network-internal service url.
  def no_alert_finding(target, status, out)
    errored = exit_code(status) == 3
    Finding.new(lane: 'zap', check: 'baseline scan', target: target,
                status: errored ? 'fail' : 'pass', severity: errored ? 'high' : 'info',
                detail: errored ? "ZAP could not scan the target: #{output_tail(out)}" : 'no alerts')
  end

  # The last few non-empty lines of ZAP's combined output, which name the real
  # failure (a resolution error, a connection refused, a TLS handshake failure).
  def output_tail(out)
    lines = out.to_s.lines.map(&:strip).reject(&:empty?)
    tail = lines.last(4).join(' | ')
    tail.empty? ? 'no output captured' : tail
  end

  def alert_finding(target, alert)
    risk = RISK.fetch(alert['riskcode'].to_s, 'unknown')
    Finding.new(lane: 'zap', check: alert['alert'].to_s, target: target,
                status: alert_status(alert['riskcode'].to_s), severity: risk,
                location: instance_url(alert), detail: alert['name'].to_s,
                help: alert['reference'].to_s.split.first.to_s)
  end

  # High risk always fails; low-and-above fails only under strict. Below the bar
  # is a warn.
  def alert_status(riskcode)
    return 'fail' if riskcode == '3'
    return 'fail' if strict? && riskcode.to_i >= 1

    'warn'
  end

  def instance_url(alert)
    alert['instances']&.first&.fetch('uri', '').to_s
  end

  # ZAP writes site[].alerts[] in the JSON report.
  def parse_alerts(report)
    return [] unless File.exist?(report)

    data = JSON.parse(File.read(report))
    Array(data['site']).flat_map { |site| Array(site['alerts']) }
  rescue JSON::ParserError
    []
  end

  def exit_code(status) = status.respond_to?(:exitstatus) ? status.exitstatus : nil
end
