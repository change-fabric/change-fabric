#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "json"
require "optparse"
require_relative "change_docker"

# Renders a cf:diagram SVG to PNG in the pinned browserless container, once
# per color scheme, so cf:roast can judge the light and dark themes from
# real pixels. The SVG picks its own palette from prefers-color-scheme, so
# each shot only emulates the scheme. Exit 0 ok, 2 usage or read problem,
# 3 Docker or browserless unavailable.
#
#   ruby diagram_render.rb [--scale N] [--out-prefix PREFIX] FILE.svg
#
# Writes PREFIX-light.png and PREFIX-dark.png (PREFIX defaults to the SVG
# path without its extension) and prints each path.
class DiagramRender
  PAGE_BG = { "light" => "#FFFFFF", "dark" => "#0D1117" }.freeze
  SCHEMES = PAGE_BG.keys.freeze
  DEFAULT_SCALE = 2
  USAGE = "usage: diagram_render.rb [--scale N] [--out-prefix PREFIX] FILE.svg"

  class UsageError < StandardError; end
  class Unavailable < StandardError; end

  def initialize(browser: nil, available: -> { ChangeDocker.available? })
    @browser = browser || ->(&blk) { ChangeDocker.with_browserless(network: nil, &blk) }
    @available = available
  end

  # Returns { "light" => png_bytes, "dark" => png_bytes }.
  def render(svg, scale: DEFAULT_SCALE)
    raise Unavailable, "Docker is not available" unless @available.call

    shots = nil
    @browser.call { |session| shots = session.run_function(js_module(svg, scale)) }
    SCHEMES.to_h do |s|
      data = shots.is_a?(Hash) ? shots[s] : nil
      raise Unavailable, "browserless returned no #{s} shot" unless data.is_a?(String) && !data.empty?

      [ s, Base64.decode64(data) ]
    end
  rescue Unavailable
    raise
  rescue StandardError => e
    raise Unavailable, "browserless failed: #{e.message}"
  end

  private

  def js_module(svg, scale)
    <<~JS
      export default async function ({ page }) {
        const svg = #{JSON.generate(svg)};
        const bg = #{JSON.generate(PAGE_BG)};
        const out = {};
        for (const scheme of #{JSON.generate(SCHEMES)}) {
          await page.setViewport({ width: 1600, height: 1200, deviceScaleFactor: #{Integer(scale)} });
          await page.emulateMediaFeatures([{ name: "prefers-color-scheme", value: scheme }]);
          await page.setContent(`<html><body style="margin:0;background:${bg[scheme]}">${svg}</body></html>`);
          const el = await page.$("svg");
          out[scheme] = await el.screenshot({ encoding: "base64" });
        }
        return { data: out, type: "application/json" };
      }
    JS
  end

  def self.parse_args(argv)
    opts = { scale: DEFAULT_SCALE }
    rest = OptionParser.new do |o|
      o.on("--scale N", Integer) { |n| opts[:scale] = n }
      o.on("--out-prefix PREFIX") { |p| opts[:prefix] = p }
    end.parse(argv)
    raise UsageError, USAGE unless rest.size == 1
    raise UsageError, "scale must be 1 to 4" unless (1..4).cover?(opts[:scale])

    path = rest.first
    raise UsageError, "cannot read #{path}" unless File.file?(path) && File.readable?(path)

    opts.merge(path: path, prefix: opts[:prefix] || path.sub(/\.svg\z/i, ""))
  rescue OptionParser::ParseError => e
    raise UsageError, e.message
  end

  def self.main(argv, out: $stdout, err: $stderr, renderer: nil)
    opts = parse_args(argv)
    shots = (renderer || new).render(File.read(opts[:path]), scale: opts[:scale])
    shots.each do |scheme, bytes|
      file = "#{opts[:prefix]}-#{scheme}.png"
      File.binwrite(file, bytes)
      out.puts(file)
    end
    0
  rescue Unavailable => e
    err.puts("diagram_render: #{e.message}")
    3
  rescue UsageError, SystemCallError => e
    err.puts("diagram_render: #{e.message}")
    2
  end
end

exit(DiagramRender.main(ARGV)) if $PROGRAM_NAME == __FILE__
