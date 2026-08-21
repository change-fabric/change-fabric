# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_config"
require_relative "../scripts/change_lane_browserless"

# Covers two browserless-lane auth-failure fixes:
#
# - F2 (structured diagnostics): an auth failure used to store only
#   `authError = String(err)`, a bare Puppeteer timeout message. The finding
#   now also carries what the login flow actually landed on - the url, the
#   last main-frame response status, the page title, and a body-text
#   snippet - so a failure reads as a real diagnosis. (The screenshot half of
#   this capture is media evidence, not text - see capture_media; not
#   exercised here since it needs a real media sink.)
# - F3 (grade the real page): previously every auth-required route
#   short-circuited to an identical generic "auth failed" finding without
#   ever navigating. The scan module still navigates each one and grades its
#   real response (reusing the same bad_status? threshold an ungated route
#   uses), while every branch still names the login failure so the reader
#   knows the checks reflect an unauthenticated/error page, not the real
#   gated route.
class ChangeLaneBrowserlessAuthDiagnosticsTest < Minitest::Test
  Ctx = Struct.new(:network, :target_url) do
    def browserless = nil
    def log(_message) = nil
  end

  def lane(raw = {})
    config = ChangeConfig::LaneConfig.new("browserless", raw, "/repo")
    ChangeLaneBrowserless.new(config, Ctx.new("net", "https://app.example.org"))
  end

  # --- F2: diagnostics rendered into the finding's detail -----------------------

  def test_auth_blocked_with_no_diagnostics_keeps_the_bare_message
    finding = lane.send(:check_finding,
                        { "viewport" => "desktop", "width" => 1440, "height" => 900, "route" => "/dashboard",
                          "authBlocked" => true, "authError" => "TimeoutError: waiting for selector failed" })
    assert_equal "fail", finding.status
    assert_includes finding.detail, "TimeoutError"
  end

  def test_auth_blocked_with_diagnostics_names_the_landed_page
    finding = lane.send(:check_finding,
                        { "viewport" => "desktop", "width" => 1440, "height" => 900, "route" => "/dashboard",
                          "authBlocked" => true, "authError" => "invalid credentials",
                          "authDiagnostics" => { "url" => "https://app.example.org/login?error=1",
                                                 "status" => 401, "title" => "Sign in failed",
                                                 "bodyText" => "Your email or password is incorrect." } })
    assert_equal "fail", finding.status
    assert_includes finding.detail, "https://app.example.org/login?error=1"
    assert_includes finding.detail, "http 401"
    assert_includes finding.detail, "Sign in failed"
    assert_includes finding.detail, "incorrect"
  end

  def test_diagnostics_with_blank_fields_are_omitted
    finding = lane.send(:check_finding,
                        { "viewport" => "desktop", "width" => 1440, "height" => 900, "route" => "/dashboard",
                          "authBlocked" => true, "authError" => "boom",
                          "authDiagnostics" => { "url" => "", "status" => nil, "title" => "", "bodyText" => "" } })
    refute_includes finding.detail, "landed on"
    refute_includes finding.detail, "http "
  end

  # --- F3: the real response is graded, not a generic short-circuit -------------

  def test_auth_blocked_route_with_no_status_is_a_bare_fail
    finding = lane.send(:check_finding,
                        { "viewport" => "desktop", "width" => 1440, "height" => 900, "route" => "/dashboard",
                          "authBlocked" => true, "authError" => "boom" })
    assert_equal "fail", finding.status
    assert_equal "high", finding.severity
  end

  def test_auth_blocked_route_with_a_bad_status_still_fails_on_that_status
    finding = lane.send(:check_finding,
                        { "viewport" => "desktop", "width" => 1440, "height" => 900, "route" => "/dashboard",
                          "authBlocked" => true, "authError" => "boom", "httpStatus" => 500 })
    assert_equal "fail", finding.status
    assert_includes finding.detail, "http 500"
    assert_includes finding.detail, "boom"
  end

  # The route was actually reached (unauthenticated) and served 200 - this
  # is real, useful information, but it is a warn (not a silent pass) with
  # the login failure still named, since the page served is not the
  # requested gated route.
  def test_auth_blocked_route_with_an_ok_status_is_a_warn_not_a_pass
    finding = lane.send(:check_finding,
                        { "viewport" => "desktop", "width" => 1440, "height" => 900, "route" => "/dashboard",
                          "authBlocked" => true, "authError" => "boom", "httpStatus" => 200 })
    assert_equal "warn", finding.status
    assert_includes finding.detail, "http 200"
    assert_includes finding.detail, "not the requested gated route"
    assert_includes finding.detail, "boom"
  end

  # --- figma diff suppression: purely a JS-module concern, asserted on the
  # generated source since it needs a live Chromium page to execute -------------

  def test_module_suppresses_figma_diff_for_an_auth_blocked_cell
    js = lane.send(:scan_module, [], nil, {})
    assert_includes js, "!cell.authBlocked && entry.figmaViewport"
  end

  def test_module_no_longer_short_circuits_the_route_loop_on_auth_failure
    js = lane.send(:scan_module, [], nil, {})
    refute_includes js, "out.push(cell);\n                continue;"
  end

  def test_module_captures_auth_diagnostics_on_failure
    js = lane.send(:scan_module, [], nil, {})
    assert_includes js, "captureAuthDiagnostics"
    assert_includes js, "diag.screenshot"
  end
end
