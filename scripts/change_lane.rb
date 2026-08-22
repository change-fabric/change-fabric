#!/usr/bin/env ruby
# frozen_string_literal: true

require 'uri'

# Shared base for the four change-fabric lanes. It owns the two things every lane
# resolves the same way: the base url a lane addresses the target by (a per-lane
# override falling back to the run's target), and the route list (falling back to
# the site root). A lane subclass supplies its own DEFAULT_ROUTES only when the
# root is not a sensible default; otherwise it inherits this one. Keeping these
# here means a change to how a lane picks its target propagates to all of them
# instead of drifting between copies.
class ChangeLane
  DEFAULT_ROUTES = %w[/].freeze

  # The readiness contract a browser lane waits on before it grades a page.
  # `networkidle2` used to stand in for this: a page was called ready when it
  # had gone quiet for half a second, which is a timing heuristic wearing a
  # contract's clothes. It passes early on a page still hydrating and hangs on
  # a page holding an open socket, and neither outcome is reproducible.
  #
  # What replaces it is stated per route: a Puppeteer load state, a selector
  # that must exist, and optionally a url the browser must have reached. The
  # wait condition is the contract; the timeout is only the failure mode, the
  # bound past which the contract is declared unmet.
  LOAD_STATES = %w[load domcontentloaded networkidle0 networkidle2].freeze
  DEFAULT_LOAD_STATE = 'domcontentloaded'
  # The weakest honest selector: `body` exists on every rendered document, so
  # it asserts "a document was parsed" and nothing more. A route that means
  # something more specific by "ready" should name its own selector.
  DEFAULT_READY_SELECTOR = 'body'
  DEFAULT_READY_TIMEOUT_MS = 30_000

  def initialize(config, context)
    @config = config
    @context = context
  end

  # The JS every browser lane's module uses to honor one normalized contract.
  # Emitted once per module and called per navigation, so the two lanes cannot
  # drift on what "ready" means.
  def self.wait_for_js
    <<~JS
      // Applies one readiness contract after a navigation: the load state was
      // already passed to page.goto, so what is left is the selector and the
      // optional url predicate. A miss throws, and the caller grades it as the
      // navigation failure it is.
      async function awaitReadiness(page, waitFor) {
        if (waitFor.selector) {
          await page.waitForSelector(waitFor.selector, { timeout: waitFor.timeoutMs });
        }
        if (waitFor.urlContains) {
          await page.waitForFunction(
            (needle) => window.location.href.indexOf(needle) !== -1,
            { timeout: waitFor.timeoutMs },
            waitFor.urlContains
          );
        }
        if (waitFor.urlMatches) {
          await page.waitForFunction(
            (pattern) => new RegExp(pattern).test(window.location.href),
            { timeout: waitFor.timeoutMs },
            waitFor.urlMatches
          );
        }
      }
    JS
  end

  private

  # The lane-wide readiness contract, the fallback for a route that states none
  # of its own.
  def lane_wait_for = wait_for(@config['wait_for'])

  # Normalizes a `wait_for` block into the flat mapping the lanes hand to their
  # browserless module as a JSON literal. Accepts a bare string (read as a
  # selector, the common case), or a mapping carrying any of `load_state`,
  # `selector`, `url_contains`, `url_matches`, and `timeout_ms`. Anything
  # unstated falls back to the lane contract, then to the platform default.
  def wait_for(raw, fallback = nil)
    base = fallback || default_wait_for
    return base if raw.nil?
    return base.merge('selector' => raw.to_s) unless raw.is_a?(Hash)

    {
      'loadState' => load_state(raw['load_state'], base['loadState']),
      'selector' => raw.key?('selector') ? raw['selector'].to_s : base['selector'],
      'urlContains' => raw.key?('url_contains') ? raw['url_contains'].to_s : base['urlContains'],
      'urlMatches' => raw.key?('url_matches') ? raw['url_matches'].to_s : base['urlMatches'],
      'timeoutMs' => Integer(raw['timeout_ms'] || base['timeoutMs'])
    }
  end

  def default_wait_for
    {
      'loadState' => DEFAULT_LOAD_STATE, 'selector' => DEFAULT_READY_SELECTOR,
      'urlContains' => nil, 'urlMatches' => nil,
      'timeoutMs' => Integer(@config.fetch('timeout_ms', DEFAULT_READY_TIMEOUT_MS))
    }
  end

  # An unknown load state is a config typo, not a new Puppeteer feature: fall
  # back to the default rather than handing Puppeteer a value it will reject
  # mid-scan, which would read as a navigation error on every route.
  def load_state(value, fallback)
    return fallback if value.nil?

    LOAD_STATES.include?(value.to_s) ? value.to_s : fallback
  end

  def base_url = @config.base_url(@context.target_url)

  # HTTP Basic Auth credentials for a browser lane hitting a target gated by it
  # (0.3.0), or nil when unconfigured. Answered via Puppeteer's
  # page.authenticate() in the lane's own /function module, never by embedding
  # credentials in a url: a https://user:pass@host url loads fine, but the Fetch
  # spec forbids constructing a Request from a url carrying credentials, so any
  # same-origin fetch() the loaded page's own JS makes (a framework's Server
  # Action, an RSC navigation, exactly what a real login-gated page triggers)
  # throws and crashes the page.
  #
  # Config carries username_env/password_env (env var NAMES), never the real
  # values, the same indirection browserless.auth.email_env/password_env
  # already uses for form-based logins: a real credential is never written
  # into CHANGE.md.
  def basic_auth
    raw = @config['basic_auth']
    return nil unless raw.is_a?(Hash)

    username = ENV[raw['username_env'].to_s].to_s
    password = ENV[raw['password_env'].to_s].to_s
    return nil if username.empty? || password.empty?

    { 'username' => username, 'password' => password }
  end

  def routes
    list = Array(@config['routes']).map(&:to_s).reject(&:empty?)
    list.empty? ? self.class::DEFAULT_ROUTES : list
  end

  # Compares the route a browser lane asked for against the final url the browser
  # actually landed on, returning the served path when the two paths differ (an
  # auth wall, a moved route, a marketing redirect) and nil when the browser
  # stayed on the requested path. A browser lane consults this so a route that
  # silently redirected is never graded as the page that was requested: without
  # it, /dashboard redirecting to /login is scored "no responsive break" and
  # reported PASS, a false all-clear for a page that never rendered. A redirect
  # that only adds or drops a trailing slash, or only changes scheme or host, is
  # treated as no redirect since the same page was served.
  def redirected_path(route, final_url)
    final = final_url.to_s
    return nil if final.empty?

    requested = normalize_path(uri_path(URI.join("#{base_url}/", route.to_s)))
    actual = normalize_path(uri_path(URI.parse(final)))
    return nil if requested.nil? || actual.nil? || requested == actual

    actual
  end

  def uri_path(uri)
    uri.path
  rescue StandardError
    nil
  end

  def normalize_path(path)
    return nil if path.nil?

    stripped = path.sub(%r{/+\z}, '')
    stripped.empty? ? '/' : stripped
  end
end
