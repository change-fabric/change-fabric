# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_config"
require_relative "../scripts/change_lane_a11y"
require_relative "../scripts/change_lane_browserless"

# Phase 0 determinism hardening. Everything here is about a run giving the same
# answer twice: a scanner that cannot change underneath the gate, a readiness
# contract stated rather than timed, a cell that cannot inherit its neighbour's
# state, and the rendering inputs a pixel diff is only meaningful against.
#
# The browserless /function JS is exercised for real by a live docker run, not
# here; what these cover is the Ruby that decides what that JS is handed, which
# is where the determinism decisions actually live.
class ChangeLaneDeterminismTest < Minitest::Test
  Ctx = Struct.new(:network, :target_url) do
    def browserless = nil
    def log(_message) = nil
  end

  def browserless(raw = {})
    ChangeLaneBrowserless.new(ChangeConfig::LaneConfig.new("browserless", raw, "/repo"),
                              Ctx.new("net", "https://app.example.org"))
  end

  def a11y(raw = {})
    ChangeLaneA11y.new(ChangeConfig::LaneConfig.new("a11y", raw, "/repo"),
                       Ctx.new("net", "https://app.example.org"))
  end

  # --- vendored axe-core --------------------------------------------------------

  def test_the_pinned_axe_bundle_ships_with_the_toolkit
    assert File.exist?(ChangeLaneA11y::AXE_BUNDLE),
           "the vendored axe-core bundle must be present at #{ChangeLaneA11y::AXE_BUNDLE}"
  end

  def test_the_vendored_bundle_is_the_version_the_manifest_claims
    source = File.read(ChangeLaneA11y::AXE_BUNDLE)
    assert_includes source, "axe.version=\"#{ChangeLaneA11y::AXE_VERSION}\""
    assert_equal ChangeLaneA11y::AXE_VERSION, ChangeLaneA11y.axe_version
  end

  def test_the_scan_module_inlines_the_bundle_and_names_no_remote_scanner
    js = a11y.send(:scan_module)
    assert_includes js, "page.addScriptTag({ content: axeSource })"
    refute_match(%r{addScriptTag\(\{ url:}, js)
    refute_match(/cdnjs|unpkg|jsdelivr/, js)
  end

  # A missing bundle is a named failing finding. Falling back to the network
  # would make the scan run, and make its result untraceable to any version.
  def test_a_missing_bundle_fails_loudly_instead_of_reaching_for_the_network
    lane = a11y
    original = ChangeLaneA11y::AXE_BUNDLE
    ChangeLaneA11y.send(:remove_const, :AXE_BUNDLE)
    ChangeLaneA11y.const_set(:AXE_BUNDLE, "/no/such/axe.min.js")
    error = assert_raises(ChangeLaneA11y::MissingAxeBundle) { lane.send(:axe_source) }
    assert_match(/will not fall back to fetching axe from the network/, error.message)
  ensure
    ChangeLaneA11y.send(:remove_const, :AXE_BUNDLE)
    ChangeLaneA11y.const_set(:AXE_BUNDLE, original)
  end

  # --- the readiness contract ---------------------------------------------------

  def test_the_default_contract_is_domcontentloaded_plus_an_explicit_selector
    contract = browserless.send(:lane_wait_for)
    assert_equal "domcontentloaded", contract["loadState"]
    assert_equal "body", contract["selector"]
    assert_equal 30_000, contract["timeoutMs"]
    assert_nil contract["urlContains"]
  end

  def test_a_bare_string_wait_for_reads_as_a_selector
    contract = browserless("wait_for" => "[data-test=ready]").send(:lane_wait_for)
    assert_equal "[data-test=ready]", contract["selector"]
    assert_equal "domcontentloaded", contract["loadState"]
  end

  def test_a_contract_can_state_a_load_state_a_selector_and_a_url_predicate
    contract = browserless(
      "wait_for" => { "load_state" => "networkidle0", "selector" => "main", "url_contains" => "/dashboard",
                      "timeout_ms" => 5_000 }
    ).send(:lane_wait_for)
    assert_equal "networkidle0", contract["loadState"]
    assert_equal "main", contract["selector"]
    assert_equal "/dashboard", contract["urlContains"]
    assert_equal 5_000, contract["timeoutMs"]
  end

  # A typo must not be handed to Puppeteer, which would reject it on every
  # navigation and report a scan-wide failure that reads as a broken app.
  def test_an_unknown_load_state_falls_back_rather_than_reaching_puppeteer
    contract = browserless("wait_for" => { "load_state" => "whenever" }).send(:lane_wait_for)
    assert_equal "domcontentloaded", contract["loadState"]
  end

  def test_a_route_states_its_own_contract_and_inherits_the_rest_from_the_lane
    lane = browserless(
      "wait_for" => { "selector" => "#app", "timeout_ms" => 9_000 },
      "routes" => [ "/", { "path" => "/slow", "wait_for" => { "load_state" => "networkidle2" } } ]
    )
    entries = lane.send(:route_entries)
    assert_equal "domcontentloaded", entries[0][:wait_for]["loadState"]
    assert_equal "networkidle2", entries[1][:wait_for]["loadState"]
    # Unstated keys keep the lane contract rather than resetting to the default.
    assert_equal "#app", entries[1][:wait_for]["selector"]
    assert_equal 9_000, entries[1][:wait_for]["timeoutMs"]
  end

  def test_neither_browser_lane_still_hardcodes_networkidle2
    refute_match(/waitUntil: "networkidle2"/, a11y.send(:scan_module))
    refute_match(/waitUntil: "networkidle2"/, browserless.send(:scan_module, [], nil, {}))
  end

  def test_the_module_waits_on_the_contract_after_navigating
    lane = browserless("routes" => [ "/" ])
    js = lane.send(:scan_module, lane.send(:route_entries), nil, {})
    assert_includes js, "waitUntil: waitFor.loadState"
    assert_includes js, "awaitReadiness(session.page, waitFor)"
  end

  # --- per-cell isolation --------------------------------------------------------

  def test_cells_are_isolated_by_default
    assert browserless.send(:cell_isolation?)
    assert_includes browserless.send(:scan_module, [], nil, {}), "const isolateCells = true;"
  end

  def test_continuity_is_opt_in
    lane = browserless("cell_isolation" => false)
    refute lane.send(:cell_isolation?)
    assert_includes lane.send(:scan_module, [], nil, {}), "const isolateCells = false;"
  end

  def test_an_isolated_cell_opens_and_closes_its_own_context
    js = browserless.send(:scan_module, [], nil, {})
    assert_includes js, "createBrowserContext"
    assert_includes js, "if (isolateCells) await closeSession(session);"
  end

  # The listener used to live on the shared page around a window that had
  # already navigated, and its count was read before the cell's remaining
  # awaits had run. It now brackets exactly the route being graded: after any
  # login, before this cell's navigation, off again in the cell's own finally.
  def test_the_console_listener_brackets_exactly_the_route_being_graded
    js = browserless.send(:scan_module, [], nil, {})
    login = js.index("await ensureAuth(session);")
    listener = js.index('session.page.on("console", onError);')
    navigation = js.index("session.page.goto(baseUrl + entry.path")
    read = js.index("cell.consoleErrors = consoleErrors;")
    assert login < listener, "a login's own console errors are not the route's"
    assert listener < navigation, "the listener must be registered before the cell navigates"
    assert navigation < read, "the count must be read after the cell's work, not during it"
    assert_includes js, 'session.page.off("console", onError);'
  end

  # --- pinned rendering inputs ---------------------------------------------------

  def test_the_pixel_distance_threshold_is_named_rather_than_buried_in_the_loop
    assert_equal 32, ChangeLaneBrowserless::FIGMA_DIFF_THRESHOLD
    js = browserless.send(:scan_module, [], nil, {})
    assert_includes js, "const diffThreshold = 32;"
    refute_includes js, "const threshold = 32;"
  end

  def test_locale_and_device_scale_factor_are_pinned_and_overridable
    js = browserless.send(:scan_module, [], nil, {})
    assert_includes js, 'const locale = "en-US";'
    assert_includes js, "const deviceScaleFactor = 1;"
    assert_includes js, "deviceScaleFactor: deviceScaleFactor"
    assert_includes js, '"Accept-Language": locale'
    assert_includes browserless("locale" => "de-DE").send(:scan_module, [], nil, {}), 'const locale = "de-DE";'
  end

  def test_the_diff_screenshot_freezes_animation_and_pins_antialiasing
    js = browserless.send(:scan_module, [], nil, {})
    assert_includes js, "addStyleTag({ content: diffStabilityCss })"
    assert_includes ChangeLaneBrowserless::DIFF_STABILITY_CSS, "-webkit-font-smoothing: antialiased"
    assert_includes ChangeLaneBrowserless::DIFF_STABILITY_CSS, "animation-duration: 1ms"
    assert_includes js, "ctx.imageSmoothingEnabled = false;"
  end
end
