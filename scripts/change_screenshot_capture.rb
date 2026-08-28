#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'json'
require_relative 'change_lane_browserless'

# The before/after capture half of cf:screenshot: one full route x viewport
# matrix photographed at one git ref, and the pixel diff of two such matrices.
#
# It subclasses the browserless lane rather than reimplementing it so the route
# list, the mapping-shaped route normalization, the viewport list, the readiness
# contract, and the pinned rendering inputs are the ones the audit lane already
# uses. What it deliberately does not inherit is the lane's grading: nothing
# here produces a Finding. A route that overflows horizontally is not this
# tool's business; whether it looks different than it did at the base ref is.
#
# Two differences from the lane's own capture are deliberate:
#
# - PNG, not the lane's quality-72 JPEG. The lane's screenshots are evidence
#   attached to a report; these are the deliverable a human reads inline in a
#   pull request, and they are also the diff's own input, where a lossy
#   encoder's ringing around text is indistinguishable from a real change.
# - The stability CSS is injected on every shot, not only before a Figma
#   comparison. Every shot here is one half of a comparison.
class ChangeScreenshotCapture < ChangeLaneBrowserless
  # FIGMA_DIFF_THRESHOLD is the per-pixel RGB distance cutoff, reused verbatim:
  # what counts as two pixels being different does not depend on why they are
  # being compared. This is the separate question of how much of a page must
  # differ before the pair is worth a human's attention in a pull request.
  # Below it a pair is noise (a re-rendered timestamp, one antialiased glyph)
  # and is dropped, so the Demo section stays signal-only.
  #
  # 0.1% is a first cut, deliberately a named constant in one file so tuning it
  # after the first few real runs is a one-line change.
  CHANGED_MIN_DIFF_PERCENT = 0.1

  # How long a full-page capture waits for the document to stop growing, and
  # how often it asks. The lane's readiness contract answers "has a document
  # been parsed", which a client-rendered app satisfies before it has rendered
  # anything, so a full-page shot taken on that signal alone catches some cells
  # mid-render and others complete. The diff then reports that race rather than
  # the branch, which is the one thing this tool must never do. Bounded, so a
  # page that genuinely never settles (a ticking clock, an infinite scroll) is
  # photographed rather than hung on.
  SETTLE_TIMEOUT_MS = 5_000
  SETTLE_INTERVAL_MS = 150

  # One captured cell: which route at which viewport, its base64 PNG, where it
  # landed on disk, and the navigation error if it never rendered.
  Cell = Struct.new(:viewport, :route, :path, :base64, :http_status, :error, keyword_init: true) do
    def key = [ viewport, route ]
    def ok? = error.nil? && !base64.to_s.empty?
  end

  # One route/viewport pair across both refs. `changed` is the whole point:
  # only a changed pair is uploaded or offered to a pull request body.
  Pair = Struct.new(:viewport, :route, :before_path, :after_path, :diff_percent,
                    :changed, :reason, :missing_side, keyword_init: true)

  # The full cross product, in viewport-major order so a reader scanning the
  # manifest sees one viewport's whole story before the next one starts.
  def matrix
    viewports.flat_map do |viewport|
      route_entries.map { |entry| [ viewport, entry ] }
    end
  end

  # Photographs every cell of the matrix at whatever ref is currently serving
  # `base_url`, writes each PNG under `<out_dir>/<side>/`, and returns the
  # cells. `side` is "before" or "after"; it names the subdirectory and nothing
  # else, so the two sides' filenames line up by construction.
  def capture(session:, side:, out_dir:, base_url: nil)
    result = session.run_function(capture_module(base_url || lane_base_url))
    cells(result).map { |raw| write_cell(raw, side: side, out_dir: out_dir) }
  end

  # The diff of two captured sides, one browserless call per pair. Per pair
  # rather than one call for the whole matrix: a full-page PNG of a real page
  # is routinely hundreds of kilobytes, and base64ing an entire matrix of them
  # into a single /function module body is a request large enough to be
  # rejected for reasons that have nothing to do with the images.
  def diff_pairs(before:, after:, session:)
    b_index = index(before)
    a_index = index(after)
    diffs = (b_index.keys & a_index.keys).each_with_object({}) do |key, acc|
      b = b_index[key]
      a = a_index[key]
      next unless b.ok? && a.ok?

      acc[key] = session.run_function(diff_module(shot: a.base64, reference: b.base64))
    end
    pair_rows(before: before, after: after, diffs: diffs)
  end

  # Pairs the two sides by (viewport, route) and decides which pairs are worth
  # keeping. Split out from diff_pairs with no browser in it, because this is
  # the judgment the whole tool rests on and it should be readable and testable
  # without a container.
  #
  # Three ways a pair counts as changed:
  #
  # - It is present on only one side. A new page or a deleted page is the most
  #   visible change there is; dropping it because there is nothing to diff
  #   against would hide exactly the change most worth showing.
  # - The two captures have different dimensions. diffAgainstReference only
  #   compares the overlapping region, so a full-page capture that got taller
  #   is a real layout change the overlap's percentage would understate.
  # - Its diff percentage clears CHANGED_MIN_DIFF_PERCENT.
  def pair_rows(before:, after:, diffs: {})
    b_index = index(before)
    a_index = index(after)
    ordered_keys(b_index, a_index).map do |key|
      row(key, b_index[key], a_index[key], diffs[key])
    end
  end

  # The browserless module that walks the matrix. Each cell gets its own page,
  # so one route's cookies or scroll position never decide what the next one
  # looks like; the lane isolates cells for the same reason.
  def capture_module(url)
    <<~JS
      export default async function ({ page }) {
        const baseUrl = #{JSON.generate(url)};
        const routeEntries = #{JSON.generate(js_capture_entries)};
        const viewports = #{JSON.generate(viewports)};
        const deviceScaleFactor = #{JSON.generate(ChangeLaneBrowserless::DEVICE_SCALE_FACTOR)};
        const diffStabilityCss = #{JSON.generate(ChangeLaneBrowserless::DIFF_STABILITY_CSS)};
        const locale = #{JSON.generate(locale)};
        const basicAuth = #{JSON.generate(basic_auth)};
        const settleTimeoutMs = #{JSON.generate(SETTLE_TIMEOUT_MS)};
        const settleIntervalMs = #{JSON.generate(SETTLE_INTERVAL_MS)};

        #{ChangeLane.wait_for_js}

        // A full-page capture is only meaningful once the document has stopped
        // growing, so this waits on the one quantity the capture actually
        // depends on rather than on a fixed sleep: three consecutive equal
        // readings of scrollHeight, or the bound, whichever comes first.
        // Web fonts are waited on for the same reason: a page rasterized in a
        // fallback face differs from the same page rasterized in its real one,
        // and which of the two a cell caught would otherwise be a race.
        async function settle(cellPage) {
          try { await cellPage.evaluate(() => (document.fonts ? document.fonts.ready : null)); } catch (err) { void err; }
          const deadline = Date.now() + settleTimeoutMs;
          let last = -1;
          let stable = 0;
          while (Date.now() < deadline) {
            const height = await cellPage.evaluate(() => document.documentElement.scrollHeight);
            stable = height === last ? stable + 1 : 0;
            last = height;
            if (stable >= 2) return height;
            await new Promise((resolve) => setTimeout(resolve, settleIntervalMs));
          }
          return last;
        }

        const out = [];
        for (const vp of viewports) {
          for (const entry of routeEntries) {
            const cell = { viewport: vp.name, route: entry.path };
            let cellPage = null;
            try {
              cellPage = await page.browser().newPage();
              const headers = { "Accept-Language": locale };
              if (basicAuth) {
                await cellPage.authenticate({ username: basicAuth.username, password: basicAuth.password });
                headers.Authorization = "Basic " + btoa(`${basicAuth.username}:${basicAuth.password}`);
              }
              await cellPage.setExtraHTTPHeaders(headers);
              await cellPage.setViewport({ width: vp.width, height: vp.height, deviceScaleFactor: deviceScaleFactor });
              const resp = await cellPage.goto(baseUrl + entry.path, { waitUntil: entry.waitFor.loadState, timeout: entry.waitFor.timeoutMs });
              cell.httpStatus = resp ? resp.status() : null;
              await awaitReadiness(cellPage, entry.waitFor);
              // Injected before every shot, not only before a comparison
              // against a fixed reference: every shot here is one half of a
              // comparison, so an animation mid-flight or a blinking caret
              // would read as a change the branch did not make.
              await cellPage.addStyleTag({ content: diffStabilityCss });
              cell.pageHeight = await settle(cellPage);
              cell.shot = await cellPage.screenshot({ encoding: "base64", type: "png", fullPage: true });
            } catch (err) {
              cell.error = String(err);
            } finally {
              if (cellPage) { try { await cellPage.close(); } catch (err) { void err; } }
            }
            out.push(cell);
          }
        }
        return { data: { cells: out }, type: "application/json" };
      }
    JS
  end

  # One pair's comparison, run in a blank page. The reference is the base ref's
  # capture and the shot is HEAD's, so a positive dimension delta reads as the
  # page having grown, in the direction a reader expects.
  def diff_module(shot:, reference:)
    <<~JS
      export default async function ({ page }) {
        #{ChangeLaneBrowserless.diff_against_reference_js}
        const shot = #{JSON.generate(shot)};
        const reference = #{JSON.generate(reference)};
        const threshold = #{JSON.generate(ChangeLaneBrowserless::FIGMA_DIFF_THRESHOLD)};
        const result = await diffAgainstReference(page, shot, reference, threshold, "image/png");
        return { data: result, type: "application/json" };
      }
    JS
  end

  private

  # ChangeLane#base_url is private and the capture keyword shares its name;
  # this is the unambiguous way to reach the inherited one.
  def lane_base_url = base_url

  def js_capture_entries
    route_entries.map { |entry| { path: entry[:path], waitFor: entry[:wait_for] } }
  end

  def index(cells) = cells.to_h { |cell| [ cell.key, cell ] }

  # Every key from the base ref in capture order, then the keys only HEAD has.
  # A route added on the branch belongs at the end, after the ones a reader can
  # compare against something.
  def ordered_keys(b_index, a_index)
    b_index.keys + (a_index.keys - b_index.keys)
  end

  def row(key, before_cell, after_cell, diff)
    viewport, route = key
    changed, reason, missing = verdict(before_cell, after_cell, diff)
    Pair.new(viewport: viewport, route: route,
             before_path: before_cell&.path, after_path: after_cell&.path,
             diff_percent: diff && diff['diffPercent'],
             changed: changed, reason: reason, missing_side: missing)
  end

  def verdict(before_cell, after_cell, diff)
    return [ true, 'route exists only at the head ref', 'before' ] if before_cell.nil?
    return [ true, 'route exists only at the base ref', 'after' ] if after_cell.nil?
    return [ true, capture_failure_reason(before_cell, after_cell), nil ] unless before_cell.ok? && after_cell.ok?
    return [ true, 'the two captures were never compared', nil ] if diff.nil?
    return [ true, dimension_reason(diff), nil ] if dimensions_differ?(diff)

    percent = diff['diffPercent'].to_f
    [ percent > CHANGED_MIN_DIFF_PERCENT, format('%.3f%% of compared pixels differ', percent), nil ]
  end

  # A cell that failed to render at one ref and rendered at the other is kept:
  # a page that stopped loading is a change, and one that is broken at both
  # refs still needs saying out loud rather than being filtered into silence.
  def capture_failure_reason(before_cell, after_cell)
    failed = [ before_cell.ok? ? nil : 'base', after_cell.ok? ? nil : 'head' ].compact
    "capture failed at the #{failed.join(' and ')} ref: #{(before_cell.error || after_cell.error)}"
  end

  def dimensions_differ?(diff)
    diff['shotWidth'] != diff['refWidth'] || diff['shotHeight'] != diff['refHeight']
  end

  def dimension_reason(diff)
    format('page size changed: %dx%d at the base ref, %dx%d at the head ref',
           diff['refWidth'].to_i, diff['refHeight'].to_i, diff['shotWidth'].to_i, diff['shotHeight'].to_i)
  end

  def write_cell(raw, side:, out_dir:)
    cell = Cell.new(viewport: raw['viewport'], route: raw['route'], base64: raw['shot'],
                    http_status: raw['httpStatus'], error: raw['error'])
    return cell if cell.base64.to_s.empty?

    path = File.join(out_dir, side, "#{slug(cell.viewport)}--#{slug(cell.route)}.png")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, Base64.decode64(cell.base64))
    cell.path = path
    cell
  end

  # ChangeMedia's own convention, repeated rather than reached for: this class
  # writes into its own output directory, not into a run's artifact bundle, and
  # borrowing a sink only to use its private filename rule would couple the two
  # for no shared behavior. The site root becomes `root`, not an empty segment.
  def slug(text)
    cleaned = text.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/-+/, '-').gsub(/\A-|-\z/, '')
    cleaned.empty? ? 'root' : cleaned
  end
end
