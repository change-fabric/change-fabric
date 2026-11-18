#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'json'
require_relative 'change_docker'

# Prints a report directory's HTML page to PDF in the pinned browserless image.
#
# The directory is mounted at MOUNT and the page is opened as a file:// url, so
# every relative path in it (evidence screenshots under cases/...) resolves the
# same way it does when a person opens the page from disk. That needs
# browserless's file protocol, which is off by default, so the PDF runs in its
# own container with nothing but that directory mounted.
#
# The page sets `data-cf-ready` on <body> once it has rendered; the print waits
# for that marker and for every <img> to finish loading, so a PDF never catches
# the page half drawn.
module BrowserlessPdf
  MOUNT = '/cf-run'
  READY_TIMEOUT_MS = 30_000
  BASE64_CHUNK = 8192

  Error = Class.new(StandardError)

  module_function

  # Writes `dir/out_name` from `dir/html_name` and returns its path. `session`
  # is a seam for tests; a real call starts its own container.
  def render(dir, html_name: 'report.html', out_name: 'report.pdf', session: nil)
    code = module_js("file://#{MOUNT}/#{html_name}")
    result = if session
      session.run_function(code)
    else
      ChangeDocker.with_browserless(network: nil, mounts: { dir => MOUNT }, allow_file_protocol: true) do |live|
        live.run_function(code)
      end
    end
    raise Error, "pdf render failed: #{result.inspect[0, 300]}" unless result.is_a?(Hash) && result['pdf']
    broken = result.dig('images', 'broken').to_i
    raise Error, "#{broken} image(s) in #{html_name} did not load from the run dir" if broken.positive?

    path = File.join(dir, out_name)
    File.binwrite(path, Base64.decode64(result['pdf']))
    path
  end

  # The function's own page runs this module, so the report opens in a second
  # page: navigating the function's page away would end the call.
  def module_js(url)
    <<~JS
      export default async function ({ page }) {
        const report = await page.browser().newPage();
        try {
          await report.goto(#{JSON.generate(url)}, { waitUntil: "load", timeout: #{READY_TIMEOUT_MS} });
          await report.waitForFunction(
            () => document.body && document.body.hasAttribute("data-cf-ready") &&
              Array.from(document.images).every((img) => img.complete),
            { timeout: #{READY_TIMEOUT_MS} }
          );
          const images = await report.evaluate(() => ({
            total: document.images.length,
            broken: Array.from(document.images).filter((img) => img.naturalWidth === 0).length,
          }));
          const pdf = await report.pdf({
            format: "A4", landscape: true, printBackground: true,
            margin: { top: "12mm", right: "10mm", bottom: "12mm", left: "10mm" },
          });
          const bytes = new Uint8Array(pdf);
          let binary = "";
          for (let offset = 0; offset < bytes.length; offset += #{BASE64_CHUNK}) {
            binary += String.fromCharCode.apply(null, bytes.subarray(offset, offset + #{BASE64_CHUNK}));
          }
          return { data: { pdf: btoa(binary), images: images }, type: "application/json" };
        } finally {
          await report.close();
        }
      }
    JS
  end
end
