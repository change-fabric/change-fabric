# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_config"
require_relative "../scripts/change_lane_a11y"

# Covers two a11y-lane fixes:
#
# - Basic auth: page.authenticate() only fires on a real WWW-Authenticate
#   challenge header. An AWS ALB fixed-response 401 (used to gate e.g.
#   cms.staging.amfm.org/admin/login) never sends that header, so
#   page.authenticate() silently never engages and axe scans the raw 401
#   challenge body instead of the real page. The fix sends the
#   Authorization header unconditionally via page.setExtraHTTPHeaders(),
#   mirroring change_lane_browserless.rb's identical fix.
# - Non-2xx status guard: a route whose navigation lands on a non-2xx
#   response (an error page, an unhandled 401/403/500) must not be graded
#   by axe at all; the challenge/error body has no <title> or lang
#   attribute and produces real-looking, false violations.
class ChangeLaneA11yStatusGuardTest < Minitest::Test
  Ctx = Struct.new(:network, :target_url) do
    def browserless = nil
    def log(_message) = nil
  end

  def a11y_lane(raw = {})
    config = ChangeConfig::LaneConfig.new("a11y", raw, "/repo")
    ChangeLaneA11y.new(config, Ctx.new("net", "https://app.example.org"))
  end

  def with_env(vars)
    previous = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| ENV[k] = v }
  end

  # --- basic auth: header-based, not page.authenticate() alone -----------------

  def test_module_sends_authorization_header_unconditionally
    with_env("BA_USER" => "svc", "BA_PASS" => "s3cr3t") do
      js = a11y_lane("basic_auth" => { "username_env" => "BA_USER", "password_env" => "BA_PASS" }).send(:scan_module)
      assert_includes js, "setExtraHTTPHeaders"
      assert_includes js, "Authorization"
      # still calls page.authenticate() too, belt-and-suspenders for a target
      # that *does* send a real challenge.
      assert_includes js, "page.authenticate"
    end
  end

  # The header-setting code is always emitted (guarded at runtime by `if
  # (basicAuth)`, exactly like browserless), so an unconfigured basic_auth
  # module still carries the literal but never executes it.
  def test_module_skips_header_when_unconfigured
    js = a11y_lane.send(:scan_module)
    assert_includes js, "const basicAuth = null;"
    assert_includes js, "if (basicAuth) {"
  end

  # --- non-2xx status guard -----------------------------------------------------

  def test_non_ok_status_is_a_single_fail_finding
    route = { "route" => "/admin/login", "finalUrl" => "https://app.example.org/admin/login",
              "httpStatus" => 401, "nonOkStatus" => true, "violations" => [] }
    findings = a11y_lane.send(:route_findings, route)
    assert_equal 1, findings.size
    finding = findings.first
    assert_equal "fail", finding.status
    assert_equal "non-2xx response", finding.check
    assert_includes finding.detail, "401"
    assert_includes finding.detail, "not meaningful"
  end

  def test_ok_status_still_grades_normally
    route = { "route" => "/", "finalUrl" => "https://app.example.org/", "httpStatus" => 200, "violations" => [] }
    findings = a11y_lane.send(:route_findings, route)
    assert_equal 1, findings.size
    assert_equal "pass", findings.first.status
  end

  def test_module_carries_a_non_ok_status_branch
    js = a11y_lane.send(:scan_module)
    assert_includes js, "nonOkStatus"
  end
end
