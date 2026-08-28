# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/change_config"
require_relative "../scripts/change_screenshot_capture"

# The capture half of cf:screenshot: what gets photographed, and which of the
# resulting pairs is worth a human's attention.
#
# The browserless /function JS is exercised for real only by a live docker run.
# What is covered here is the Ruby that decides what that JS is handed, and the
# pair-selection rule, which is the judgment the whole tool rests on: a wrong
# answer here either buries a real change or fills a pull request with noise.
class ChangeScreenshotCaptureTest < Minitest::Test
  Ctx = Struct.new(:network, :target_url) do
    def browserless = nil
    def log(_message) = nil
  end

  def capturer(raw = {})
    ChangeScreenshotCapture.new(ChangeConfig::LaneConfig.new("browserless", raw, "/repo"),
                                Ctx.new("net", "https://app.example.org"))
  end

  def cell(viewport, route, base64: "AAAA", path: nil, error: nil)
    ChangeScreenshotCapture::Cell.new(viewport: viewport, route: route, base64: base64,
                                      path: path || "/out/#{viewport}--#{route.delete('/')}.png", error: error)
  end

  def diff(percent, shot: [ 800, 600 ], ref: [ 800, 600 ])
    { "diffPercent" => percent, "shotWidth" => shot[0], "shotHeight" => shot[1],
      "refWidth" => ref[0], "refHeight" => ref[1] }
  end

  # --- the matrix ---------------------------------------------------------------

  def test_the_capture_matrix_is_the_full_cross_product_of_routes_and_viewports
    subject = capturer("routes" => [ "/", "/spec", "/changelog" ],
                       "viewports" => [ { "name" => "mobile", "width" => 390, "height" => 844 },
                                        { "name" => "desktop", "width" => 1440, "height" => 900 } ])
    pairs = subject.matrix.map { |viewport, entry| [ viewport["name"], entry[:path] ] }
    assert_equal 6, pairs.size
    assert_equal [ [ "mobile", "/" ], [ "mobile", "/spec" ], [ "mobile", "/changelog" ],
                   [ "desktop", "/" ], [ "desktop", "/spec" ], [ "desktop", "/changelog" ] ], pairs
  end

  # The route list is the audit lane's own, read through the inherited
  # normalize_route, so a mapping-shaped entry (the shape that carries auth: and
  # wait_for:) is not silently dropped or stringified into "{path=>...}".
  def test_a_mapping_shaped_route_normalizes_through_the_inherited_normalizer
    subject = capturer("routes" => [ "/", { "path" => "/dashboard", "wait_for" => "[data-test=ready]" } ],
                       "viewports" => [ { "name" => "desktop", "width" => 1440, "height" => 900 } ])
    entries = subject.matrix.map { |_viewport, entry| entry }
    assert_equal [ "/", "/dashboard" ], entries.map { |entry| entry[:path] }
    assert_equal "[data-test=ready]", entries[1][:wait_for]["selector"]
  end

  def test_the_default_viewports_are_the_lanes_own
    assert_equal ChangeLaneBrowserless::DEFAULT_VIEWPORTS.map { |v| v["name"] },
                 capturer("routes" => [ "/" ]).matrix.map { |viewport, _| viewport["name"] }
  end

  # --- the emitted capture module -----------------------------------------------

  def test_the_capture_module_pins_the_rendering_inputs_every_comparison_depends_on
    js = capturer("routes" => [ "/" ]).capture_module("https://app.example.org")
    assert_includes js, "const deviceScaleFactor = 1;"
    assert_includes js, "deviceScaleFactor: deviceScaleFactor"
    assert_includes js, "addStyleTag({ content: diffStabilityCss })"
    assert_includes js, "animation-duration: 1ms !important;"
    assert_includes js, "-webkit-font-smoothing: antialiased !important;"
  end

  # PNG, not the audit lane's quality-72 JPEG: these images are both the
  # deliverable a human reads and the diff's own input.
  def test_the_capture_module_shoots_full_page_png
    js = capturer("routes" => [ "/" ]).capture_module("https://app.example.org")
    assert_includes js, 'type: "png"'
    assert_includes js, "fullPage: true"
    refute_includes js, "quality: 72"
  end

  # The inherited readiness contract answers "a document was parsed", which a
  # client-rendered app satisfies before it has rendered anything. A full-page
  # shot taken on that alone catches some cells mid-render, and the diff then
  # reports the race rather than the branch.
  def test_the_capture_module_waits_for_the_page_to_stop_growing_before_shooting
    js = capturer("routes" => [ "/" ]).capture_module("https://app.example.org")
    settle = js.index("cell.pageHeight = await settle(cellPage);")
    shot = js.index("cell.shot = await cellPage.screenshot(")

    assert_includes js, "document.documentElement.scrollHeight"
    assert_includes js, "document.fonts.ready"
    assert_includes js, "const settleTimeoutMs = #{ChangeScreenshotCapture::SETTLE_TIMEOUT_MS};"
    assert settle < shot, "the page must be settled before it is photographed, not after"
    refute_includes js, "await new Promise((resolve) => setTimeout(resolve, 2000))"
  end

  def test_the_capture_module_waits_on_the_inherited_readiness_contract
    js = capturer("routes" => [ "/" ]).capture_module("https://app.example.org")
    assert_includes js, "waitUntil: entry.waitFor.loadState"
    assert_includes js, "awaitReadiness(cellPage, entry.waitFor)"
  end

  def test_the_diff_module_uses_the_shared_diff_function_at_the_shared_threshold
    js = capturer.diff_module(shot: "AAA", reference: "BBB")
    assert_includes js, "async function diffAgainstReference(cellPage, shotBase64, refBase64, threshold, mime)"
    assert_includes js, "const threshold = #{ChangeLaneBrowserless::FIGMA_DIFF_THRESHOLD};"
    assert_includes js, '"image/png"'
  end

  # --- pair selection -------------------------------------------------------------

  def test_a_pair_over_the_minimum_is_kept_and_one_under_it_is_dropped
    subject = capturer
    before = [ cell("desktop", "/loud"), cell("desktop", "/quiet") ]
    after = [ cell("desktop", "/loud"), cell("desktop", "/quiet") ]
    diffs = { [ "desktop", "/loud" ] => diff(4.2), [ "desktop", "/quiet" ] => diff(0.01) }
    rows = subject.pair_rows(before: before, after: after, diffs: diffs).to_h { |r| [ r.route, r ] }

    assert rows["/loud"].changed, "4.2% is well over the minimum and must be kept"
    refute rows["/quiet"].changed, "0.01% is rendering noise, not a change worth a pull request"
    assert_in_delta 4.2, rows["/loud"].diff_percent, 0.0001
  end

  def test_the_minimum_is_a_named_constant_and_the_boundary_is_exclusive
    assert_in_delta 0.1, ChangeScreenshotCapture::CHANGED_MIN_DIFF_PERCENT, 0.0001
    subject = capturer
    exactly = subject.pair_rows(before: [ cell("desktop", "/") ], after: [ cell("desktop", "/") ],
                                diffs: { [ "desktop", "/" ] => diff(ChangeScreenshotCapture::CHANGED_MIN_DIFF_PERCENT) })
    refute exactly.first.changed, "a pair exactly at the minimum is not over it"
  end

  # diffAgainstReference only compares the overlapping region, so a full-page
  # capture that got taller is a real layout change the overlap's percentage
  # would understate into silence.
  def test_a_dimension_mismatch_is_kept_regardless_of_the_diff_percentage
    row = capturer.pair_rows(
      before: [ cell("desktop", "/") ], after: [ cell("desktop", "/") ],
      diffs: { [ "desktop", "/" ] => diff(0.0, shot: [ 800, 2400 ], ref: [ 800, 600 ]) }
    ).first
    assert row.changed, "a page that got 1800px taller changed, whatever the overlap says"
    assert_includes row.reason, "page size changed"
    assert_includes row.reason, "800x600"
    assert_includes row.reason, "800x2400"
  end

  def test_a_route_present_only_at_the_head_ref_is_kept_and_marked
    row = capturer.pair_rows(before: [], after: [ cell("desktop", "/new") ]).first
    assert row.changed
    assert_equal "before", row.missing_side
    assert_nil row.before_path
    refute_nil row.after_path
    assert_includes row.reason, "only at the head ref"
  end

  def test_a_route_present_only_at_the_base_ref_is_kept_and_marked
    row = capturer.pair_rows(before: [ cell("desktop", "/gone") ], after: []).first
    assert row.changed
    assert_equal "after", row.missing_side
    assert_includes row.reason, "only at the base ref"
  end

  # A pair whose capture failed at one ref is kept rather than filtered into
  # silence: a page that stopped loading is a change.
  def test_a_cell_that_failed_to_render_is_kept_with_the_failure_named
    row = capturer.pair_rows(
      before: [ cell("desktop", "/") ],
      after: [ cell("desktop", "/", base64: "", error: "TimeoutError: navigation timed out") ]
    ).first
    assert row.changed
    assert_includes row.reason, "capture failed at the head ref"
    assert_includes row.reason, "TimeoutError"
  end

  def test_pairs_are_ordered_base_side_first_then_the_routes_only_head_has
    rows = capturer.pair_rows(before: [ cell("desktop", "/a"), cell("desktop", "/b") ],
                              after: [ cell("desktop", "/b"), cell("desktop", "/a"), cell("desktop", "/c") ])
    assert_equal [ "/a", "/b", "/c" ], rows.map(&:route)
  end

  # --- writing the captures to disk -------------------------------------------------

  def test_capture_writes_one_png_per_cell_under_the_sides_own_directory
    session = Object.new
    def session.run_function(_code)
      { "cells" => [ { "viewport" => "desktop", "route" => "/", "shot" => ["fake png".b].pack("m0") },
                     { "viewport" => "desktop", "route" => "/spec", "shot" => ["fake png".b].pack("m0") } ] }
    end

    Dir.mktmpdir do |dir|
      cells = capturer("routes" => %w[/ /spec]).capture(session: session, side: "before", out_dir: dir)
      assert_equal [ "desktop--root.png", "desktop--spec.png" ], cells.map { |c| File.basename(c.path) }
      cells.each { |c| assert_equal "fake png", File.binread(c.path) }
      assert_equal [ dir ], cells.map { |c| File.dirname(File.dirname(c.path)) }.uniq
      assert_equal [ "before" ], cells.map { |c| File.basename(File.dirname(c.path)) }.uniq
    end
  end

  def test_a_cell_that_captured_nothing_is_kept_without_a_path
    session = Object.new
    def session.run_function(_code)
      { "cells" => [ { "viewport" => "desktop", "route" => "/", "error" => "boom" } ] }
    end

    Dir.mktmpdir do |dir|
      cell = capturer("routes" => [ "/" ]).capture(session: session, side: "after", out_dir: dir).first
      assert_nil cell.path
      refute cell.ok?
      assert_equal "boom", cell.error
    end
  end
end
