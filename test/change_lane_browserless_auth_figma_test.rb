# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_config"
require_relative "../scripts/change_lane_browserless"
require_relative "../scripts/change_figma"

# Covers the two capabilities layered onto the browserless lane: authenticated
# routes (a route marked auth: true is only ever checked for real, after a real
# login, or skipped with a named finding) and Figma visual alignment (a route's
# figma: block is diffed, graded against the configured threshold, and a fetch
# blocker is surfaced rather than silently skipped). Exercises the pure Ruby
# logic (route normalization, auth readiness, diff grading, the real Figma REST
# client's error paths); the browserless /function JS itself is exercised by a
# real docker+browserless smoke run, not unit tests, since it needs a live
# Chromium page.
class ChangeLaneBrowserlessAuthFigmaTest < Minitest::Test
  Ctx = Struct.new(:network, :target_url) do
    def browserless = nil
    def log(_message) = nil
  end

  def lane(raw = {})
    config = ChangeConfig::LaneConfig.new("browserless", raw, "/repo")
    ChangeLaneBrowserless.new(config, Ctx.new("net", "https://app.example.org"))
  end

  # --- route normalization ----------------------------------------------------

  def test_plain_string_route_has_no_auth_or_figma
    entries = lane("routes" => [ "/login" ]).send(:route_entries)
    assert_equal [ { path: "/login", auth: false, figma: nil } ], entries
  end

  def test_mapping_route_carries_auth_and_figma
    entries = lane("routes" => [
      { "path" => "/dashboard", "auth" => true,
        "figma" => { "file_key" => "FK", "node_id" => "1:2", "viewport" => "desktop" } }
    ]).send(:route_entries)
    assert_equal true, entries.first[:auth]
    assert_equal({ file_key: "FK", node_id: "1:2", viewport: "desktop" }, entries.first[:figma])
  end

  def test_figma_block_missing_file_key_is_dropped
    entries = lane("routes" => [ { "path" => "/x", "figma" => { "node_id" => "1:2" } } ]).send(:route_entries)
    assert_nil entries.first[:figma]
  end

  # --- auth readiness ----------------------------------------------------------

  def with_env(vars)
    previous = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| ENV[k] = v }
  end

  def test_no_auth_required_routes_need_no_auth_config
    l = lane("routes" => [ "/login" ])
    ready, finding = l.send(:resolve_auth, l.send(:route_entries), l.send(:auth_config))
    assert ready
    assert_nil finding
  end

  def test_auth_required_route_without_auth_block_is_blocked
    l = lane("routes" => [ { "path" => "/dashboard", "auth" => true } ])
    ready, finding = l.send(:resolve_auth, l.send(:route_entries), l.send(:auth_config))
    refute ready
    assert_equal "fail", finding.status
    assert_includes finding.detail, "not configured"
  end

  def test_auth_required_route_with_missing_credentials_is_blocked
    with_env("CF_TEST_EMAIL" => nil, "CF_TEST_PASSWORD" => nil) do
      raw = { "routes" => [ { "path" => "/dashboard", "auth" => true } ],
              "auth" => { "login_url" => "/login", "email_env" => "CF_TEST_EMAIL",
                          "password_env" => "CF_TEST_PASSWORD" } }
      l = lane(raw)
      ready, finding = l.send(:resolve_auth, l.send(:route_entries), l.send(:auth_config))
      refute ready
      assert_includes finding.detail, "CF_TEST_EMAIL"
    end
  end

  def test_auth_required_route_with_real_credentials_is_ready
    with_env("CF_TEST_EMAIL" => "user@example.org", "CF_TEST_PASSWORD" => "hunter2") do
      raw = { "routes" => [ { "path" => "/dashboard", "auth" => true } ],
              "auth" => { "login_url" => "/login", "email_env" => "CF_TEST_EMAIL",
                          "password_env" => "CF_TEST_PASSWORD" } }
      l = lane(raw)
      ready, finding = l.send(:resolve_auth, l.send(:route_entries), l.send(:auth_config))
      assert ready
      assert_nil finding
    end
  end

  # --- auth.steps (multi-step / OTP login) -------------------------------------

  def test_legacy_shorthand_normalizes_into_a_single_step
    with_env("CF_TEST_EMAIL" => "user@example.org", "CF_TEST_PASSWORD" => "hunter2") do
      auth = lane("auth" => { "login_url" => "/login", "email_env" => "CF_TEST_EMAIL",
                               "password_env" => "CF_TEST_PASSWORD" }).send(:auth_config)
      steps = auth.steps
      assert_equal 1, steps.size
      assert_equal "/login", steps.first[:url]
      assert_equal [ "user@example.org", "hunter2" ], steps.first[:fields].map { |f| f[:value] }
    end
  end

  def test_multi_step_auth_is_ready_when_every_field_resolves
    with_env("PORTAL_TEST_EMAIL" => "user@example.org") do
      raw = {
        "routes" => [ { "path" => "/dashboard", "auth" => true } ],
        "auth" => { "steps" => [
          { "url" => "/login", "fields" => [ { "selector" => "input[name=email]", "env" => "PORTAL_TEST_EMAIL" } ],
            "wait_for_selector" => "input[name=otp]" },
          { "fields" => [ { "selector" => "input[name=otp]",
                            "code_source" => { "url" => "http://mailpit:8025/api/v1/messages/latest" } } ] }
        ] }
      }
      l = lane(raw)
      ready, finding = l.send(:resolve_auth, l.send(:route_entries), l.send(:auth_config))
      assert ready
      assert_nil finding
    end
  end

  def test_multi_step_auth_missing_env_value_is_blocked
    with_env("PORTAL_TEST_EMAIL" => nil) do
      raw = {
        "routes" => [ { "path" => "/dashboard", "auth" => true } ],
        "auth" => { "steps" => [
          { "url" => "/login", "fields" => [ { "selector" => "input[name=email]", "env" => "PORTAL_TEST_EMAIL" } ] }
        ] }
      }
      l = lane(raw)
      ready, finding = l.send(:resolve_auth, l.send(:route_entries), l.send(:auth_config))
      refute ready
      assert_includes finding.detail, "PORTAL_TEST_EMAIL"
    end
  end

  def test_multi_step_auth_missing_code_source_url_is_blocked
    raw = {
      "routes" => [ { "path" => "/dashboard", "auth" => true } ],
      "auth" => { "steps" => [
        { "url" => "/login", "fields" => [ { "selector" => "input[name=otp]", "code_source" => {} } ] }
      ] }
    }
    l = lane(raw)
    ready, finding = l.send(:resolve_auth, l.send(:route_entries), l.send(:auth_config))
    refute ready
    assert_includes finding.detail, "code_source.url"
  end

  def test_multi_step_auth_missing_first_step_url_is_blocked
    raw = {
      "routes" => [ { "path" => "/dashboard", "auth" => true } ],
      "auth" => { "steps" => [ { "fields" => [] } ] }
    }
    l = lane(raw)
    ready, finding = l.send(:resolve_auth, l.send(:route_entries), l.send(:auth_config))
    refute ready
    assert_includes finding.detail, "login_url"
  end

  def test_js_auth_carries_code_source_through_without_resolving_it_on_the_host
    raw = { "auth" => { "steps" => [
      { "url" => "/login", "fields" => [ { "selector" => "input[name=otp]",
                                           "code_source" => { "url" => "http://mailpit:8025/latest", "pattern" => '(\d{6})' } } ] }
    ] } }
    l = lane(raw)
    js = l.send(:js_auth, l.send(:auth_config))
    field = js[:steps].first[:fields].first
    assert_equal "http://mailpit:8025/latest", field[:codeSource][:url]
    assert_equal '(\d{6})', field[:codeSource][:pattern]
    refute field.key?(:value)
  end

  def test_auth_skip_finding_names_the_route
    finding = lane.send(:auth_skip_finding, { path: "/dashboard", auth: true, figma: nil })
    assert_equal "fail", finding.status
    assert_equal "/dashboard", finding.location
  end

  # --- authBlocked cell grading -------------------------------------------------

  def test_auth_blocked_cell_fails_with_reason
    finding = lane.send(:check_finding,
                        { "viewport" => "desktop", "width" => 1440, "height" => 900, "route" => "/dashboard",
                          "authBlocked" => true, "authError" => "TimeoutError: waiting for selector failed" })
    assert_equal "fail", finding.status
    assert_includes finding.detail, "TimeoutError"
  end

  # --- figma diff grading -------------------------------------------------------

  def figma_check(percent)
    { "viewport" => "desktop", "route" => "/dashboard",
      "figmaDiff" => { "diffPercent" => percent, "comparedWidth" => 1440, "comparedHeight" => 900,
                       "shotWidth" => 1440, "shotHeight" => 900, "refWidth" => 1440, "refHeight" => 900 } }
  end

  def test_zero_diff_is_pass
    finding = lane.send(:figma_diff_finding, figma_check(0))
    assert_equal "pass", finding.status
  end

  def test_small_nonzero_diff_is_warn_not_pass
    finding = lane.send(:figma_diff_finding, figma_check(2.5))
    assert_equal "warn", finding.status
    assert_includes finding.detail, "2.50%"
  end

  def test_diff_over_threshold_fails
    finding = lane.send(:figma_diff_finding, figma_check(15))
    assert_equal "fail", finding.status
  end

  def test_custom_threshold_is_honored
    l = lane("figma" => { "max_diff_percent" => 20 })
    finding = l.send(:figma_diff_finding, figma_check(15))
    assert_equal "warn", finding.status
  end

  # --- figma reference fetch blockers (no network needed) ------------------------

  def test_missing_token_env_blocks_with_named_env_var
    l = lane("figma" => { "token_env" => "NO_SUCH_FIGMA_TOKEN_VAR" })
    entries = [ { path: "/dashboard", auth: false, figma: { file_key: "FK", node_id: "1:2", viewport: nil } } ]
    refs, findings = l.send(:resolve_figma_refs, entries)
    assert_empty refs
    assert_equal 1, findings.size
    assert_includes findings.first.detail, "NO_SUCH_FIGMA_TOKEN_VAR"
  end

  def test_figma_error_no_token_configured
    error = assert_raises(ChangeFigma::FigmaError) do
      ChangeFigma.fetch_reference_png_base64(file_key: "FK", node_id: "1:2", token: "")
    end
    assert_match(/token/, error.message)
  end

  def test_figma_error_missing_file_key
    error = assert_raises(ChangeFigma::FigmaError) do
      ChangeFigma.fetch_reference_png_base64(file_key: "", node_id: "1:2", token: "tok")
    end
    assert_match(/file_key/, error.message)
  end
end
