#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "preview_host"
require_relative "../change_config"
require_relative "../change_lane_a11y"

module ApprovalConsole
  # Runs the cf:a11y lane (axe-core, vendored) over every approval console
  # preview route, in light and in dark, inside browserless-cf, then stops the
  # preview. A serious or critical violation, or a route that did not load, is
  # a failure.
  #
  #   ruby scripts/approval_console/preview_a11y.rb
  #
  # Exits 1 on any failing finding, 2 when Docker is unavailable.
  module PreviewA11y
    SCHEMES = %w[light dark].freeze
    THRESHOLD = "serious"

    Context = Struct.new(:network, :target_url, :browserless) do
      def log(_message) = nil
    end

    module_function

    # The lane config for one color scheme. The page's strict CSP blocks the
    # inline axe source, so the lane is told to bypass it for this scan only.
    def lane_config(scheme, routes)
      raw = { "routes" => routes, "threshold" => THRESHOLD, "bypass_csp" => true, "color_scheme" => scheme }
      ChangeConfig::LaneConfig.new("a11y", raw, Dir.pwd)
    end

    # Findings per scheme: { "light" => [Finding], "dark" => [Finding] }.
    def scan(session, url, routes: PreviewHost.routes)
      SCHEMES.to_h do |scheme|
        [ scheme, ChangeLaneA11y.new(lane_config(scheme, routes), Context.new(nil, url, session)).run ]
      end
    end

    def failures(results)
      results.flat_map { |scheme, findings| findings.select(&:fail?).map { |finding| [ scheme, finding ] } }
    end

    def report(results)
      total = results.values.sum(&:size)
      lines = failures(results).map do |scheme, finding|
        "FAIL #{scheme} #{finding.check} #{finding.location} (#{finding.severity}): #{finding.detail}"
      end
      lines << "#{results.size} schemes, #{total} findings, #{lines.size} failing"
      lines
    end

    def main
      results = PreviewHost.with_session { |session, url| scan(session, url) }
      puts report(results)
      exit(failures(results).empty? ? 0 : 1)
    rescue PreviewHost::Unavailable => e
      warn "preview_a11y: #{e.message}"
      exit 2
    end
  end
end

ApprovalConsole::PreviewA11y.main if $PROGRAM_NAME == __FILE__
