#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'erb'
require 'fileutils'
require 'json'
require_relative 'change_artifact_templates'
require_relative 'change_artifact_view'
require_relative 'change_docker'

# Assembles one run's findings artifact: a self-contained static site directory
# holding `index.html`, the run's `manifest.json`, the screenshots and
# recordings the browserless lane captured, one annotated PDF per viewport, and
# a copy of the Desktop report pair. It is a plain directory of plain files, so
# the same bytes that open from disk in a browser also serve unchanged from S3
# behind CloudFront; nothing here needs a server, a build step, or a network
# fetch at view time.
#
# Best-effort by construction. Every step is individually rescued and recorded
# in `warnings`, because the audit lanes are the gate and this is the evidence
# attached to it: a PDF that failed to render must never turn a passing run red,
# and must never hide the fact that it failed either.
class ChangeArtifactBundle
  Result = Struct.new(:dir, :index, :manifest_path, :pdfs, :warnings, keyword_init: true)

  # `dir` is the bundle root, which is also the media sink's root: the lane has
  # already written screenshots and recordings into it by the time this runs.
  def initialize(dir:, manifest:, media:, report:, artifacts:)
    @dir = dir
    @manifest = manifest
    @media = media
    @report = report
    @artifacts = artifacts
    @warnings = []
  end

  def build
    FileUtils.mkdir_p(@dir)
    copy_reports
    pdfs = render_pdfs
    write_manifest
    index = render_index
    Result.new(dir: @dir, index: index, manifest_path: manifest_path, pdfs: pdfs, warnings: @warnings)
  end

  private

  def manifest_path = File.join(@dir, 'manifest.json')

  def write_manifest = File.write(manifest_path, "#{JSON.pretty_generate(@manifest)}\n")

  # The Markdown and CSV the run already wrote to the Desktop ride along in the
  # bundle, so the published artifact is the whole record rather than a prettier
  # view of a record that stayed on one laptop.
  def copy_reports
    return unless @report

    { markdown: 'report.md', csv: 'report.csv' }.each do |key, name|
      source = @report[key]
      FileUtils.cp(source, File.join(@dir, name)) if source && File.exist?(source)
    end
  rescue StandardError => e
    @warnings << "could not copy the report pair into the bundle: #{e.message}"
  end

  def render_index
    path = File.join(@dir, 'index.html')
    File.write(path, ChangeArtifactView.new(@manifest, artifacts: @artifacts).render(ChangeArtifactTemplates.page))
    path
  rescue StandardError => e
    @warnings << "could not render the artifact page: #{e.message}"
    nil
  end

  # --- per-viewport PDFs --------------------------------------------------------

  # One PDF per viewport, each a cover page plus one page per route: the route's
  # full-page screenshot with that route's own findings printed underneath it.
  #
  # Interleaved annotation text, not boxes drawn on the screenshot, is a
  # deliberate choice. A box has to be positioned, and the only positions
  # available are the ones the lanes actually produce: axe reports a CSS
  # selector, not a rectangle, and the responsive and Figma checks are
  # whole-page measurements with no element to point at. Drawing a box would
  # mean inventing coordinates, which is worse than useless on an evidence
  # artifact. The caption under each screenshot says exactly what was found on
  # that route at that viewport, and says nothing it cannot source.
  #
  # Rendering follows cf:pdf-rendering: a compiled template with escaped data,
  # local assets only (screenshots are inlined as data URIs, since the
  # rendering browser is inside a container that cannot read host files),
  # explicit `page.pdf` options, and the page closed on every path. The
  # template engine is ERB rather than Handlebars because the renderer is Ruby
  # and this repo ships no Node runtime; `ERB::Util.html_escape` is doing the
  # job Handlebars' `{{ }}` escaping does there.
  def render_pdfs
    sections = Array(@manifest['viewports'])
    return [] if sections.empty?

    ChangeDocker.with_browserless(network: nil) do |session|
      sections.filter_map { |section| render_pdf(session, section) }
    end
  rescue StandardError => e
    @warnings << "could not render per-viewport PDFs: #{e.message}"
    []
  end

  def render_pdf(session, section)
    html = ChangeArtifactView.new(@manifest, artifacts: @artifacts, section: section, inline: method(:data_uri))
                             .render(ChangeArtifactTemplates.pdf)
    base64 = session.run_function(pdf_module(html))
    return nil if base64.to_s.empty?

    path = File.join(@dir, 'pdf', "#{ChangeArtifactTemplates.slug(section['name'])}.pdf")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, Base64.decode64(base64))
    path
  rescue StandardError => e
    @warnings << "could not render the #{section['name']} PDF: #{e.message}"
    nil
  end

  # A bundle-relative image as a data URI, so the PDF renderer needs no access
  # to the host filesystem and no network at all.
  def data_uri(relative)
    path = File.join(@dir, relative.to_s)
    return nil unless File.exist?(path)

    "data:image/jpeg;base64,#{Base64.strict_encode64(File.binread(path))}"
  end

  # The chunk the returned bytes are walked in when they are turned into base64.
  # `String.fromCharCode` is variadic, and applying it to a whole multi-megabyte
  # PDF at once overflows the argument stack, so the bytes are folded in slices
  # small enough to stay well inside it.
  PDF_BASE64_CHUNK = 0x8000

  # The page itself is not closed here on purpose: browserless owns the page
  # and the browser for the lifetime of one /function call and disposes both
  # when it returns, including when it throws. Closing it from inside the
  # module would race that teardown against the response browserless is still
  # assembling. The cf:pdf-rendering rule that no browser resource outlives an
  # error path is satisfied one layer up, by `with_browserless`, which force
  # -removes the container in its own `ensure`.
  #
  # `page.pdf` hands back a Uint8Array, and the browserless /function sandbox is
  # NOT a full Node context: it has no `Buffer` and no `process`, only the web
  # globals (`btoa`, `TextDecoder`, the typed arrays). `Buffer.from(pdf)` was
  # therefore a ReferenceError on every call, and because the whole artifact step
  # is best-effort it surfaced as one warning line on an otherwise green run
  # rather than as a failure, which is how every published bundle came to be
  # missing every one of its per-viewport PDFs without anybody noticing.
  # Encoding through `btoa` keeps this to the globals the sandbox actually has.
  def pdf_module(html)
    <<~JS
      export default async function ({ page }) {
        const html = #{JSON.generate(html)};
        await page.setContent(html, { waitUntil: "load", timeout: 60000 });
        await page.evaluate(() => document.fonts.ready);
        const pdf = await page.pdf({
          format: "A4",
          printBackground: true,
          margin: { top: "14mm", right: "12mm", bottom: "14mm", left: "12mm" },
        });
        const bytes = new Uint8Array(pdf);
        let binary = "";
        for (let offset = 0; offset < bytes.length; offset += #{PDF_BASE64_CHUNK}) {
          binary += String.fromCharCode.apply(
            null,
            bytes.subarray(offset, offset + #{PDF_BASE64_CHUNK}),
          );
        }
        return { data: btoa(binary), type: "application/json" };
      }
    JS
  end
end
