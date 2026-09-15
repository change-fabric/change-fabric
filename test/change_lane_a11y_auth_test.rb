# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_config"
require_relative "../scripts/change_lane_a11y"

# Covers change_config.lanes.a11y.auth (0.11.0): the a11y lane taking the same
# form-login block the browserless lane has always taken.
#
# The bug it closes: a config declaring seven routes behind a form login got no
# config error for the absent auth support, every route redirected to the login
# page, and the lane injected axe into that one page seven times and reported
# the result under seven route names. The sweep read green while covering a
# single route.
#
# The generated /function module only runs against a live browserless container,
# so what is exercised here is the Ruby: which findings a blocked or failed
# login produces, and that the module string carries the compiled login, or none.
class ChangeLaneA11yAuthTest < Minitest::Test
  FakeSession = Struct.new(:result, :module_source) do
    def run_function(code)
      self.module_source = code
      result
    end
  end

  Ctx = Struct.new(:network, :target_url, :browserless) do
    def log(_message) = nil
  end

  def lane(raw = {}, session: FakeSession.new([]))
    config = ChangeConfig::LaneConfig.new("a11y", raw, "/repo")
    ChangeLaneA11y.new(config, Ctx.new("net", "https://portal.example.com", session))
  end

  def with_env(vars)
    previous = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| ENV[k] = v }
  end

  def shorthand_auth
    { "login_url" => "/login", "email_env" => "CF_A11Y_EMAIL", "password_env" => "CF_A11Y_PASSWORD" }
  end

  def routes = [ "/home", "/dashboard" ]

  # --- the compiled login reaching the module -----------------------------------

  def test_no_auth_block_emits_no_login
    session = FakeSession.new([])
    lane({ "routes" => routes }, session: session).run
    assert_includes session.module_source, "const auth = null;"
  end

  def test_shorthand_auth_compiles_into_the_module
    with_env("CF_A11Y_EMAIL" => "qa@example.com", "CF_A11Y_PASSWORD" => "pw") do
      session = FakeSession.new([])
      lane({ "routes" => routes, "auth" => shorthand_auth }, session: session).run

      assert_includes session.module_source, "https://portal.example.com/login"
      assert_includes session.module_source, "qa@example.com"
      assert_includes session.module_source, "runAuthStep(session, step)"
    end
  end

  # The a11y lane is handed a bare page; the shared login runtime takes the
  # browserless lane's session shape. The bridge is one wrapper in the module.
  def test_the_module_wraps_the_page_in_a_session_for_the_shared_runtime
    with_env("CF_A11Y_EMAIL" => "qa@example.com", "CF_A11Y_PASSWORD" => "pw") do
      session = FakeSession.new([])
      lane({ "routes" => routes, "auth" => shorthand_auth }, session: session).run
      assert_includes session.module_source, "{ page: page, lastAuthResponse: null }"
    end
  end

  # --- a login that cannot even be attempted -------------------------------------

  def test_unset_credential_env_var_fails_the_lane_and_scans_nothing
    with_env("CF_A11Y_EMAIL" => "qa@example.com", "CF_A11Y_PASSWORD" => "") do
      session = FakeSession.new([])
      findings = lane({ "routes" => routes, "auth" => shorthand_auth }, session: session).run

      assert_nil session.module_source, "the scan must not run at all when the login cannot"
      assert_equal "auth login", findings.first.check
      assert_equal "fail", findings.first.status
      assert_includes findings.first.detail, "CF_A11Y_PASSWORD"
      assert_equal routes, findings.drop(1).map(&:location)
      assert(findings.all? { |f| f.status == "fail" })
    end
  end

  def test_missing_login_url_fails_the_lane
    with_env("CF_A11Y_EMAIL" => "qa@example.com", "CF_A11Y_PASSWORD" => "pw") do
      findings = lane({ "routes" => routes, "auth" => shorthand_auth.merge("login_url" => "") }).run
      assert_equal "auth login", findings.first.check
      assert_includes findings.first.detail, "auth.login_url is not set"
    end
  end

  # --- a login that ran and failed in the container --------------------------------

  def test_a_failed_login_reports_every_route_unscanned_rather_than_scanning_it
    with_env("CF_A11Y_EMAIL" => "qa@example.com", "CF_A11Y_PASSWORD" => "pw") do
      session = FakeSession.new({ "authError" => "TimeoutError: waiting for selector failed" })
      findings = lane({ "routes" => routes, "auth" => shorthand_auth }, session: session).run

      assert_equal "auth login", findings.first.check
      assert_includes findings.first.detail, "TimeoutError"
      assert_equal [ "route not scanned" ] * routes.size, findings.drop(1).map(&:check)
      assert_equal routes, findings.drop(1).map(&:location)
    end
  end

  # A successful login leaves the route grading exactly as it was.
  def test_a_successful_login_grades_routes_normally
    with_env("CF_A11Y_EMAIL" => "qa@example.com", "CF_A11Y_PASSWORD" => "pw") do
      scanned = [ { "route" => "/dashboard", "finalUrl" => "https://portal.example.com/dashboard",
                    "httpStatus" => 200, "violations" => [] } ]
      findings = lane({ "routes" => [ "/dashboard" ], "auth" => shorthand_auth },
                      session: FakeSession.new(scanned)).run

      assert_equal "no violations", findings.first.check
      assert_equal "pass", findings.first.status
    end
  end

  # The explicit multi-step form, for a login needing more than one page.
  def test_steps_form_compiles_every_step
    with_env("CF_A11Y_EMAIL" => "qa@example.com", "OTP" => "123456") do
      auth = { "steps" => [
        { "url" => "/login", "fields" => [ { "selector" => "#email", "env" => "CF_A11Y_EMAIL" } ] },
        { "url" => "/login/code", "fields" => [ { "selector" => "#code", "env" => "OTP" } ] }
      ] }
      session = FakeSession.new([])
      lane({ "routes" => routes, "auth" => auth }, session: session).run

      assert_includes session.module_source, "https://portal.example.com/login/code"
      assert_includes session.module_source, "123456"
    end
  end
end
