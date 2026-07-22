# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_config"
require_relative "../scripts/change_lane_browserless"
require_relative "../scripts/change_lane_a11y"

# Focuses on the redirect-blindness bug the staging dogfood run surfaced: a route
# behind an auth wall (portal /dashboard 307 -> /login) was navigated by the
# browser, which followed the redirect, and both browser lanes graded the served
# page as the requested route. The browserless lane reported PASS "no responsive
# break" for /dashboard, and the a11y lane reported its /login violations under
# /dashboard, a false all-clear for a page that never rendered. The fix surfaces
# any path-changing redirect as a warn naming the served path.
class ChangeLaneRedirectTest < Minitest::Test
  Ctx = Struct.new(:network, :target_url) do
    def browserless = nil
    def log(_message) = nil
  end

  def browserless_lane
    config = ChangeConfig::LaneConfig.new("browserless", { "base_url" => "https://portal.REDACTEDstaging.org" }, "/repo")
    ChangeLaneBrowserless.new(config, Ctx.new("net", "https://portal.REDACTEDstaging.org"))
  end

  def a11y_lane
    config = ChangeConfig::LaneConfig.new("a11y", { "base_url" => "https://portal.REDACTEDstaging.org" }, "/repo")
    ChangeLaneA11y.new(config, Ctx.new("net", "https://portal.REDACTEDstaging.org"))
  end

  # A clean cell (requested page actually served) still passes.
  def test_browserless_same_path_is_pass
    check = {
      "viewport" => "desktop", "width" => 1440, "height" => 900, "route" => "/login",
      "httpStatus" => 200, "finalUrl" => "https://portal.REDACTEDstaging.org/login",
      "scrollWidth" => 1440, "overflow" => false, "consoleErrors" => 0
    }
    finding = browserless_lane.send(:check_finding, check)
    assert_equal "pass", finding.status
  end

  # The bug: /dashboard redirected to /login is no longer a silent PASS.
  def test_browserless_auth_redirect_is_warn_not_pass
    check = {
      "viewport" => "desktop", "width" => 1440, "height" => 900, "route" => "/dashboard",
      "httpStatus" => 200, "finalUrl" => "https://portal.REDACTEDstaging.org/login",
      "scrollWidth" => 1440, "overflow" => false, "consoleErrors" => 0
    }
    finding = browserless_lane.send(:check_finding, check)
    assert_equal "warn", finding.status
    assert_includes finding.detail, "/dashboard"
    assert_includes finding.detail, "/login"
  end

  # A trailing-slash-only difference is the same page, not a redirect.
  def test_browserless_trailing_slash_is_not_a_redirect
    check = {
      "viewport" => "mobile", "width" => 390, "height" => 844, "route" => "/resources",
      "httpStatus" => 200, "finalUrl" => "https://portal.REDACTEDstaging.org/resources/",
      "scrollWidth" => 390, "overflow" => false, "consoleErrors" => 0
    }
    finding = browserless_lane.send(:check_finding, check)
    assert_equal "pass", finding.status
  end

  # The a11y lane reports the redirect instead of attributing the served page's
  # violations to the requested route.
  def test_a11y_auth_redirect_is_reported_as_redirect
    route = {
      "route" => "/dashboard", "finalUrl" => "https://portal.REDACTEDstaging.org/login",
      "violations" => [ { "id" => "color-contrast", "impact" => "serious",
                          "help" => "contrast", "helpUrl" => "x", "nodes" => [ "button" ] } ]
    }
    findings = a11y_lane.send(:route_findings, route)
    assert_equal 1, findings.size
    assert_equal "redirected", findings.first.check
    assert_equal "warn", findings.first.status
    assert_includes findings.first.detail, "/login"
  end

  # A route that served itself still reports its real violations.
  def test_a11y_same_path_reports_violations
    route = {
      "route" => "/login", "finalUrl" => "https://portal.REDACTEDstaging.org/login",
      "violations" => [ { "id" => "color-contrast", "impact" => "serious",
                          "help" => "contrast", "helpUrl" => "x", "nodes" => [ "button" ] } ]
    }
    findings = a11y_lane.send(:route_findings, route)
    assert_equal "color-contrast", findings.first.check
  end
end
