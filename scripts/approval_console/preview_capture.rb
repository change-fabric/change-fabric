#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require_relative "preview_host"

module ApprovalConsole
  # Stills of every approval console preview route for the PR body: 390x844 and
  # 1280x800, light and dark, taken in browserless-cf against the preview
  # renderer, then the preview is stopped. It also runs the first-load check
  # from the approval-console-design plan: at 390x844 the what-changes line and
  # the fixed action bar are both inside the first viewport, on the carve-out
  # fixture that carries 12 files. No pixel baselines; the PNGs are for people.
  #
  #   ruby scripts/approval_console/preview_capture.rb [--out DIR]
  #
  # Exits 1 when the first-load check fails or any still could not be taken.
  class PreviewCapture
    VIEWPORTS = { "390x844" => [ 390, 844 ], "1280x800" => [ 1280, 800 ] }.freeze
    SCHEMES = %w[light dark].freeze
    # Client states the page script reaches from the preview's #state= fragment
    # (stills only): [route, state].
    CLIENT_STILLS = [
      [ "/type/carve-out/state/pending", "success" ], [ "/type/prod-op/state/pending", "locked" ],
      [ "/type/step/state/pending", "code-refused" ], [ "/type/carve-out/state/pending", "in-app" ]
    ].freeze
    DEFAULT_OUT = File.join(Dir.home, "Desktop", "approval-console-preview")
    # What the page must show once a client state has settled: the result
    # block's kind, a prefix of the status line, or the in-app hint.
    EXPECTED = {
      "success" => { "result_kind" => "ok" }, "locked" => { "msg" => "Too many failed tries" },
      "code-refused" => { "msg" => "That code did not match" }, "in-app" => { "hint_hidden" => false }
    }.freeze
    FIRST_LOAD_ROUTE = "/type/carve-out/state/pending"

    Still = Struct.new(:route, :state, :viewport, :scheme, :base64, :error, keyword_init: true) do
      def ok? = error.nil? && !base64.to_s.empty?

      def filename
        slug = route.sub(%r{\A/}, "").gsub(%r{/state/}, "-").tr("/", "-")
        "#{[ slug, state, viewport, scheme ].compact.join('-')}.png"
      end
    end

    def self.targets
      PreviewHost.routes.map { |route| [ route, nil ] } + CLIENT_STILLS
    end

    def self.capture_module(url, targets, viewport, scheme)
      width, height = VIEWPORTS.fetch(viewport)
      <<~JS
        export default async function ({ page }) {
          const base = #{JSON.generate(url)};
          const targets = #{JSON.generate(targets)};
          await page.setViewport({ width: #{width}, height: #{height}, deviceScaleFactor: 2 });
          await page.emulateMediaFeatures([{ name: "prefers-color-scheme", value: #{JSON.generate(scheme)} }]);
          const out = [];
          for (const [route, state] of targets) {
            const entry = { route, state };
            try {
              await page.goto(base + route + (state ? "#state=" + state : ""), { waitUntil: "load" });
              if (state) {
                await page.reload({ waitUntil: "load" });
                await new Promise((resolve) => setTimeout(resolve, 600));
              }
              if (route === #{JSON.generate(FIRST_LOAD_ROUTE)} && !state) {
                entry.first_load = await page.evaluate(() => {
                  const changes = document.querySelector(".changes");
                  const bar = document.getElementById("approve");
                  const box = (el) => (el ? el.getBoundingClientRect() : null);
                  return { changes: box(changes) && { top: box(changes).top, bottom: box(changes).bottom },
                           bar: box(bar) && { top: box(bar).top, bottom: box(bar).bottom },
                           inner_height: window.innerHeight, scroll_y: window.scrollY };
                });
              }
              if (state) {
                entry.observed = await page.evaluate(() => {
                  const $ = (id) => document.getElementById(id);
                  return { result_hidden: $("result").hidden, result_kind: $("result").dataset.kind,
                           msg: $("msg") ? $("msg").textContent : "", hint_hidden: $("inapp") ? $("inapp").hidden : null };
                });
              }
              entry.shot = await page.screenshot({ encoding: "base64", type: "png", fullPage: true });
            } catch (err) {
              entry.error = String(err && err.message ? err.message : err);
            }
            out.push(entry);
          }
          return { data: out, type: "application/json" };
        }
      JS
    end

    # The first-load verdict for one narrow-viewport result, or nil when the
    # entry carries no measurement. The what-changes line must end inside the
    # first viewport with the page at the top, and the bar must sit inside it.
    def self.first_load_problem(entry, viewport)
      return nil unless viewport == "390x844" && entry["first_load"]

      m = entry["first_load"]
      height = m["inner_height"]
      return "the page did not open at the top (scrollY #{m['scroll_y']})" unless m["scroll_y"].to_f.zero?
      return "the what-changes line is missing" unless m["changes"]
      return "the what-changes line ends at #{m['changes']['bottom'].round}px, below the first viewport (#{height}px)" if m["changes"]["bottom"] > height
      return "the action bar is missing" unless m["bar"]
      return "the action bar is outside the first viewport" if m["bar"]["top"] >= height || m["bar"]["bottom"] > height + 1

      nil
    end

    # Why a client-state still did not reach its state, or nil. A screenshot
    # of a form stuck in "cannot use passkeys" would otherwise pass as evidence.
    def self.state_problem(entry)
      expected = EXPECTED[entry["state"]]
      return nil unless expected

      seen = entry["observed"] || {}
      expected.each do |key, want|
        got = seen[key]
        ok = key == "msg" ? got.to_s.start_with?(want) : got == want
        return "#{entry['route']} #{entry['state']}: expected #{key} #{want.inspect}, saw #{got.inspect}" unless ok
      end
      nil
    end

    def initialize(out_dir:, session:, url:)
      @out_dir = out_dir
      @session = session
      @url = url
    end

    # Returns { stills:, problems: } and writes every PNG under the out dir.
    def run
      FileUtils.mkdir_p(@out_dir)
      stills = []
      problems = []
      VIEWPORTS.each_key do |viewport|
        SCHEMES.each do |scheme|
          results = Array(@session.run_function(self.class.capture_module(@url, self.class.targets, viewport, scheme),
                                                    launch_args: PreviewHost.launch_args(@url), timeout_ms: 240_000))
          results.each do |entry|
            still = Still.new(route: entry["route"], state: entry["state"], viewport: viewport, scheme: scheme, base64: entry["shot"], error: entry["error"])
            write(still)
            stills << still
            problem = self.class.first_load_problem(entry, viewport)
            problems << "#{viewport} #{scheme}: #{problem}" if problem
            state_problem = self.class.state_problem(entry)
            problems << "#{viewport} #{scheme}: #{state_problem}" if state_problem
          end
        end
      end
      stills.reject(&:ok?).each { |still| problems << "#{still.filename}: #{still.error || 'no image'}" }
      { stills: stills, problems: problems.uniq }
    end

    def write(still)
      return unless still.ok?

      File.binwrite(File.join(@out_dir, still.filename), Base64.decode64(still.base64))
    end

    def self.main(argv)
      out = DEFAULT_OUT
      args = argv.dup
      until args.empty?
        case args.shift
        when "--out" then out = File.expand_path(args.shift.to_s)
        else abort "usage: preview_capture.rb [--out DIR]"
        end
      end
      result = PreviewHost.with_session { |session, url| new(out_dir: out, session: session, url: url).run }
      ok = result[:stills].count(&:ok?)
      puts "#{ok} of #{result[:stills].size} stills written to #{out}"
      result[:problems].each { |problem| puts "PROBLEM #{problem}" }
      exit(result[:problems].empty? ? 0 : 1)
    rescue PreviewHost::Unavailable => e
      warn "preview_capture: #{e.message}"
      exit 2
    end
  end
end

ApprovalConsole::PreviewCapture.main(ARGV) if $PROGRAM_NAME == __FILE__
