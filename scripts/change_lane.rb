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

  def initialize(config, context)
    @config = config
    @context = context
  end

  private

  def base_url = @config.base_url(@context.target_url)

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
