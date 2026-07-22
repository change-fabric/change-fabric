#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'change_lane'
require_relative 'change_findings'

# The accessibility lane. Drives axe-core against each configured route inside
# the shared browserless Chromium container (no host browser, no second image),
# reusing the exact approach of the REDACTED apps/e2e/src/a11y.ts it subsumes: load
# the page over the browser, inject axe-core, run it against the rendered DOM,
# and grade each violation against an impact threshold. A violation at or above
# the threshold (default "serious") is a fail; below it is a warn.
#
# The scan runs as a single browserless /function module with the routes, base
# url, and threshold baked in as literals, so one HTTP round trip returns every
# route's violations. axe-core is loaded into each page from a CDN; the
# browserless container has outbound network, and this keeps the platform from
# shipping a bundled copy of the library.
class ChangeLaneA11y < ChangeLane
  IMPACT_ORDER = %w[minor moderate serious critical].freeze
  DEFAULT_THRESHOLD = 'serious'
  AXE_CDN = 'https://cdnjs.cloudflare.com/ajax/libs/axe-core/4.10.2/axe.min.js'

  def run
    session = @context.browserless
    return [ unavailable ] unless session

    result = session.run_function(scan_module)
    Array(result).flat_map { |route| route_findings(route) }
  rescue StandardError => e
    [ Finding.new(lane: 'a11y', check: 'a11y scan', status: 'fail', severity: 'high',
                  detail: "scan error: #{e.message}") ]
  end

  private

  def threshold
    value = @config.fetch('threshold', DEFAULT_THRESHOLD).to_s
    IMPACT_ORDER.include?(value) ? value : DEFAULT_THRESHOLD
  end

  def meets_threshold?(impact)
    return false unless impact

    idx = IMPACT_ORDER.index(impact.to_s)
    idx && idx >= IMPACT_ORDER.index(threshold)
  end

  def route_findings(route)
    served = redirected_path(route['route'], route['finalUrl'])
    if served
      return [ Finding.new(lane: 'a11y', check: 'redirected', status: 'warn', severity: 'moderate',
                           target: base_url, location: route['route'].to_s,
                           detail: "requested #{route['route']}, redirected to #{served}; " \
                                   'axe ran against that page, not the requested route') ]
    end

    violations = Array(route['violations'])
    if violations.empty?
      return [ Finding.new(lane: 'a11y', check: 'no violations', status: 'pass', severity: 'info',
                           target: base_url, location: route['route'].to_s) ]
    end
    violations.map { |violation| violation_finding(route, violation) }
  end

  def violation_finding(route, violation)
    impact = violation['impact']
    failing = meets_threshold?(impact)
    selectors = Array(violation['nodes']).join(', ')
    Finding.new(lane: 'a11y', check: violation['id'].to_s, target: base_url,
                status: failing ? 'fail' : 'warn', severity: impact.to_s,
                location: [ route['route'], selectors ].reject { |x| x.to_s.empty? }.join(' '),
                detail: violation['help'].to_s, help: violation['helpUrl'].to_s)
  end

  def unavailable
    Finding.new(lane: 'a11y', check: 'browserless', status: 'fail', severity: 'high',
                detail: 'browserless session unavailable; cannot run axe-core')
  end

  # The ES module POSTed to browserless /function. Values are interpolated as
  # JSON literals; the module loops routes, injects axe, and returns one entry
  # per route with its violations flattened to the fields the finding needs.
  def scan_module
    <<~JS
      export default async function ({ page }) {
        const baseUrl = #{JSON.generate(base_url)};
        const routes = #{JSON.generate(routes)};
        const axeUrl = #{JSON.generate(AXE_CDN)};
        const basicAuth = #{JSON.generate(basic_auth)};
        if (basicAuth) await page.authenticate({ username: basicAuth.username, password: basicAuth.password });
        const out = [];
        for (const route of routes) {
          try {
            await page.goto(baseUrl + route, { waitUntil: "networkidle2", timeout: 30000 });
            await page.addScriptTag({ url: axeUrl });
            const result = await page.evaluate(async () => await window.axe.run());
            out.push({
              route,
              finalUrl: page.url(),
              violations: result.violations.map((v) => ({
                id: v.id,
                impact: v.impact,
                help: v.help,
                helpUrl: v.helpUrl,
                nodes: v.nodes.map((n) => n.target.join(" ")),
              })),
            });
          } catch (err) {
            out.push({ route, error: String(err), violations: [] });
          }
        }
        return { data: out, type: "application/json" };
      }
    JS
  end
end
