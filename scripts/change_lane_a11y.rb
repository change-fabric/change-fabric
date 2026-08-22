#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'change_lane'
require_relative 'change_findings'

# The accessibility lane. Drives axe-core against each configured route inside
# the shared browserless Chromium container (no host browser, no second image),
# reusing the exact approach of a prior client's apps/e2e/src/a11y.ts it subsumes: load
# the page over the browser, inject axe-core, run it against the rendered DOM,
# and grade each violation against an impact threshold. A violation at or above
# the threshold (default "serious") is a fail; below it is a warn.
#
# The scan runs as a single browserless /function module with the routes, base
# url, threshold, and the axe-core source itself baked in as literals, so one
# HTTP round trip returns every route's violations.
#
# axe-core is vendored, not fetched. It used to be pulled from a CDN at scan
# time, which meant the scanner could change underneath the gate without a
# single line of this repo changing: a new axe release adds rules, and a commit
# that passed on Monday fails on Tuesday for reasons no diff explains. The
# pinned bundle under scripts/vendor/axe-core is the exact file the CDN served
# for that version, injected into each page as source text. A missing bundle is
# a loud failing finding, never a quiet fall back to the network: an
# unreproducible scan is worth less than no scan.
class ChangeLaneA11y < ChangeLane
  IMPACT_ORDER = %w[minor moderate serious critical].freeze
  DEFAULT_THRESHOLD = 'serious'

  # The vendored scanner. The version is in the constant and in the filename,
  # and it is what the run manifest records, so a report names the exact
  # scanner that produced it. Upgrading axe means dropping in the new file,
  # bumping this, and reading the findings diff on purpose.
  AXE_VERSION = '4.10.2'
  AXE_BUNDLE = File.join(__dir__, 'vendor', 'axe-core', "axe-#{AXE_VERSION}.min.js")

  class MissingAxeBundle < StandardError; end

  def self.axe_version = AXE_VERSION

  def run
    session = @context.browserless
    return [ unavailable ] unless session

    result = session.run_function(scan_module)
    Array(result).flat_map { |route| route_findings(route) }
  rescue MissingAxeBundle => e
    [ Finding.new(lane: 'a11y', check: 'axe-core bundle', status: 'fail', severity: 'high',
                  detail: e.message) ]
  rescue StandardError => e
    [ Finding.new(lane: 'a11y', check: 'a11y scan', status: 'fail', severity: 'high',
                  detail: "scan error: #{e.message}") ]
  end

  private

  def axe_source
    unless File.exist?(AXE_BUNDLE)
      raise MissingAxeBundle,
            "the vendored axe-core #{AXE_VERSION} bundle is missing at #{AXE_BUNDLE}; " \
            'the a11y lane will not fall back to fetching axe from the network, because a scanner ' \
            'resolved at scan time cannot be pinned to this report. Reinstall the toolkit (install.rb).'
    end

    @axe_source ||= File.read(AXE_BUNDLE)
  end

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
    # A route whose navigation threw (the scan module's own catch pushes
    # `{ route, error, violations: [] }`) used to fall through every branch
    # below and land on "no violations", which graded a page that never
    # loaded as a pass. That is the worst possible failure mode for a gate:
    # a whole lane reported clean against an unreachable target.
    if route['error']
      return [ Finding.new(lane: 'a11y', check: 'navigation error', status: 'fail', severity: 'high',
                           target: base_url, location: route['route'].to_s,
                           detail: "could not load the route: #{route['error']}") ]
    end

    if route['nonOkStatus']
      return [ Finding.new(lane: 'a11y', check: 'non-2xx response', status: 'fail', severity: 'high',
                           target: base_url, location: route['route'].to_s,
                           detail: "scanned a non-2xx response (#{route['httpStatus'].inspect}); " \
                                   'a11y results for this route are not meaningful') ]
    end

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

  # Each route's readiness contract. The a11y lane's routes are plain strings,
  # so the contract is stated once for the lane (`lanes.a11y.wait_for`) and
  # applies to every route; the per-route form arrives with the route-entry
  # shape the browserless lane already has.
  def route_wait_for = routes.to_h { |route| [ route, lane_wait_for ] }

  # The ES module POSTed to browserless /function. Values are interpolated as
  # JSON literals; the module loops routes, injects axe, and returns one entry
  # per route with its violations flattened to the fields the finding needs.
  def scan_module
    <<~JS
      export default async function ({ page }) {
        const baseUrl = #{JSON.generate(base_url)};
        const routes = #{JSON.generate(routes)};
        const waitForByRoute = #{JSON.generate(route_wait_for)};
        const axeSource = #{JSON.generate(axe_source)};
        const basicAuth = #{JSON.generate(basic_auth)};

        #{ChangeLane.wait_for_js}
        if (basicAuth) {
          // page.authenticate() only fires on a WWW-Authenticate challenge,
          // which some gates never send (an ALB fixed-response 401 has no
          // mechanism to set arbitrary response headers - confirmed against
          // terraform/cms_signoz_basic_auth.tf's own "KNOWN GAP" comment).
          // Sending the header unconditionally works regardless of whether
          // the target's 401 carries a real challenge.
          // btoa, not Buffer: this module runs inside browserless's function
          // sandbox, a browser-like context with no Node globals.
          const encoded = btoa(`${basicAuth.username}:${basicAuth.password}`);
          await page.setExtraHTTPHeaders({ Authorization: `Basic ${encoded}` });
        }
        const out = [];
        for (const route of routes) {
          const waitFor = waitForByRoute[route];
          try {
            const resp = await page.goto(baseUrl + route, { waitUntil: waitFor.loadState, timeout: waitFor.timeoutMs });
            const httpStatus = resp ? resp.status() : null;
            if (!httpStatus || httpStatus < 200 || httpStatus >= 300) {
              out.push({ route, finalUrl: page.url(), httpStatus, nonOkStatus: true, violations: [] });
              continue;
            }
            await awaitReadiness(page, waitFor);
            // The vendored bundle as source text, not a url: nothing about
            // this scan reaches the network for its own scanner.
            await page.addScriptTag({ content: axeSource });
            const result = await page.evaluate(async () => await window.axe.run());
            out.push({
              route,
              finalUrl: page.url(),
              httpStatus,
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
