#!/usr/bin/env ruby
# frozen_string_literal: true

require 'erb'
require 'fileutils'
require 'json'
require_relative 'change_artifact_templates'
require_relative 'change_coverage_brand'
require_relative 'change_coverage_schema'
require_relative 'change_schema'

# Renders the QA coverage page (`index.html`) that sits beside a coverage
# store's `report-data.js`.
#
# The page is a function of the resolved brand and the template constants
# below, nothing else: no run data, no clock, no path. Run data reaches it at
# view time through `<script src="report-data.js">`, so the same bytes serve
# every history and a rebuild that changes nothing writes nothing.
module ChangeCoveragePage
  TEMPLATE_VERSION = 1
  RUN_SCHEMA_MAX = ChangeCoverageSchema::RUN_SCHEMA
  FILE = 'index.html'

  # The fixed, neutral chart panel inside the brand chrome, and the dataviz
  # categorical slots in fixed order (route coverage, case pass rate, line,
  # branch). Brand colors are never a chart palette; slots never follow rank.
  CHART = {
    'light' => { 'chart-surface' => '#fcfcfb', 'chart-ink' => '#0b0b0b', 'chart-muted' => '#52514e',
                 'chart-grid' => '#e4e3df', 's1' => '#2a78d6', 's2' => '#eb6834', 's3' => '#1baf7a', 's4' => '#eda100' },
    'dark' => { 'chart-surface' => '#1a1a19', 'chart-ink' => '#f0efec', 'chart-muted' => '#c3c2b7',
                'chart-grid' => '#33332f', 's1' => '#3987e5', 's2' => '#d95926', 's3' => '#199e70', 's4' => '#c98500' }
  }.freeze

  module_function

  def render(resolved, template: ChangeArtifactTemplates.coverage)
    View.new(resolved).render(template)
  end

  # Writes DIR/index.html only when its bytes would change, through a temp
  # file and a rename. Returns :written or :unchanged.
  def write(dir, resolved, template: ChangeArtifactTemplates.coverage)
    html = render(resolved, template: template).b
    path = File.join(dir, FILE)
    return :unchanged if File.file?(path) && File.binread(path) == html

    FileUtils.mkdir_p(dir)
    tmp = "#{path}.tmp-#{Process.pid}"
    File.binwrite(tmp, html)
    File.rename(tmp, path)
    :written
  ensure
    FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
  end

  # The template's whole world: the resolved brand, the constants above and
  # an HTML escaper.
  class View
    def initialize(resolved) = @brand = resolved

    def render(template_path) = ERB.new(File.read(template_path), trim_mode: '-').result(binding)

    def name = @brand.name
    def title = @brand.title
    def logo_uri = @brand.logo_uri
    def logo_dark_uri = @brand.logo_dark_uri
    def template_version = TEMPLATE_VERSION
    def run_schema_max = RUN_SCHEMA_MAX
    def lanes_json = JSON.generate(ChangeSchema::LANES)

    # Validated by ChangeCoverageBrand to [A-Za-z0-9 ,'"-] plus the fixed
    # system stack, so it is safe as raw CSS (HTML escaping would break the
    # quotes inside <style>).
    def font_stack = @brand.font_stack

    # Every color custom property for one theme: brand tokens, the fixed
    # status colors, the fixed chart panel.
    def tokens(theme)
      brand = theme == 'light' ? @brand.light : @brand.dark
      ChangeCoverageBrand::TOKENS.to_h { |key| [ key, brand.fetch(key) ] }
                                 .merge(ChangeCoverageBrand::STATUS.fetch(theme))
                                 .merge(CHART.fetch(theme))
    end

    def css_tokens(theme, indent)
      tokens(theme).map { |key, hex| "#{indent}--#{key}: #{hex};" }.join("\n")
    end

    def h(text) = ERB::Util.html_escape(text.to_s)
  end
end
