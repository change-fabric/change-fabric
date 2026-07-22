#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'tmpdir'
require 'uri'
require_relative 'change_lane'
require_relative 'change_docker'
require_relative 'change_findings'

# The k6 load/burst lane. Runs the digest-pinned grafana/k6 image as a one-shot
# container against the target on the run network, exporting the end-of-test
# summary so each k6 threshold becomes a finding. The lane passes when every
# threshold passes (k6's own exit code, which is non-zero on any threshold
# breach).
#
# A project supplies its own script via `lanes.k6.script`; a project with none
# gets the built-in light-load script below (a small GET against a health route),
# so a repo can adopt the lane with zero k6 assets of its own, exactly the "zero
# tools installed, just the CHANGE.md config" case the platform exists to serve.
class ChangeLaneK6 < ChangeLane
  # The default script when a project ships none: a modest constant-VU load
  # against BASE_URL. VUS/DURATION/BASE_URL come from the lane env, so the same
  # script serves as a real light-load default without the project authoring k6.
  DEFAULT_SCRIPT = <<~JS
    import http from "k6/http";
    import { check, sleep } from "k6";

    const BASE_URL = __ENV.BASE_URL;
    const PATH = __ENV.HEALTH_PATH || "/health";
    if (!BASE_URL) { throw new Error("BASE_URL is required for the default k6 script"); }

    export const options = {
      vus: Number(__ENV.VUS || 5),
      duration: __ENV.DURATION || "30s",
      thresholds: {
        http_req_failed: [__ENV.THRESHOLD_REQ_FAILED || "rate<0.01"],
        http_req_duration: [__ENV.THRESHOLD_REQ_DURATION || "p(95)<500"],
      },
    };

    export default function () {
      const res = http.get(`${BASE_URL}${PATH}`);
      check(res, { "status is 200": (r) => r.status === 200 });
      sleep(1);
    }
  JS

  def run
    Dir.mktmpdir('cf-change-k6') do |dir|
      script = resolve_script(dir)
      summary = File.join(dir, 'summary.json')
      out, status = execute(script, summary, dir)
      @context.log("[k6] #{status.success? ? 'thresholds passed' : 'thresholds failed'}")
      findings(summary, out, status)
    end
  end

  private

  # The project's script when configured, else the built-in default written into
  # the mount dir. Returned as the container-side path under /work.
  def resolve_script(dir)
    configured = @config.path('script')
    if configured && File.exist?(configured)
      target = File.join(dir, File.basename(configured))
      File.write(target, File.read(configured))
      File.basename(configured)
    else
      File.write(File.join(dir, 'default.js'), DEFAULT_SCRIPT)
      'default.js'
    end
  end

  def execute(script, summary, dir)
    ChangeDocker.run(
      network: @context.network,
      image: ChangeDocker::K6_IMAGE,
      args: [ 'run', '--summary-export', "/work/#{File.basename(summary)}", "/work/#{script}" ],
      env: env,
      mounts: { dir => '/work' },
      name: "#{ChangeDocker::RESOURCE_PREFIX}k6-#{SecureRandom.hex(4)}"
    )
  end

  # Lane env, defaulting BASE_URL to the run's target so the default script has a
  # host even when the project omits it, mapping any configured thresholds to
  # the env knobs the default script reads, and defaulting HEALTH_PATH to
  # boot.health.url's own path so the default script load-tests the same route
  # the health check already proved reachable, instead of a second,
  # independently-guessed "/health" that silently 404s on a repo whose route is
  # named differently (e.g. "/api/health").
  def env
    base = { 'BASE_URL' => base_url }
    thresholds = @config['thresholds'] || {}
    base['THRESHOLD_REQ_FAILED'] = thresholds['http_req_failed'] if thresholds['http_req_failed']
    base['THRESHOLD_REQ_DURATION'] = thresholds['http_req_duration'] if thresholds['http_req_duration']
    configured = @config.env
    base['HEALTH_PATH'] = default_health_path if default_health_path && !configured.key?('HEALTH_PATH')
    base.merge(configured)
  end

  def default_health_path
    url = @context.health_url.to_s
    return nil if url.empty?

    path = URI(url).path
    path.empty? ? nil : path
  rescue URI::InvalidURIError
    nil
  end

  def findings(summary, out, status)
    rows = threshold_findings(summary)
    return rows unless rows.empty?

    # No parseable thresholds: fall back to the process outcome so the lane still
    # reports a pass/fail rather than nothing.
    tail = out.to_s.lines.last(3).join.strip
    [ Finding.new(lane: 'k6', check: 'k6 run', target: base_url,
                  status: status.success? ? 'pass' : 'fail', severity: status.success? ? 'info' : 'high',
                  detail: tail) ]
  end

  def threshold_findings(summary)
    data = read_summary(summary) or return []
    metrics = data['metrics']
    return [] unless metrics.is_a?(Hash)

    metrics.flat_map do |metric, body|
      thresholds = body.is_a?(Hash) ? body['thresholds'] : nil
      next [] unless thresholds.is_a?(Hash)

      thresholds.map { |expr, result| threshold_finding(metric, expr, result) }
    end
  end

  def threshold_finding(metric, expr, result)
    ok = threshold_passed?(result)
    Finding.new(lane: 'k6', check: "#{metric} #{expr}", target: base_url,
                status: ok ? 'pass' : 'fail', severity: ok ? 'info' : 'high',
                detail: ok ? 'threshold met' : 'threshold breached')
  end

  # k6's --summary-export writes each threshold as a bare boolean that is TRUE
  # when the threshold was crossed (failed) and FALSE when it held (passed), so a
  # passing threshold reads as `false`. An earlier revision treated any non-false
  # value as passing, which inverted the verdict: every held threshold reported
  # as breached even though k6 itself exited 0. Some k6 output modes instead
  # write `{ "ok": bool }` where ok means passed, so both shapes are handled.
  def threshold_passed?(result)
    return result['ok'] == true if result.is_a?(Hash)

    result == false
  end

  def read_summary(summary)
    return nil unless File.exist?(summary)

    JSON.parse(File.read(summary))
  rescue JSON::ParserError
    nil
  end
end
