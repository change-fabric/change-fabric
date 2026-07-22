# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_config"
require_relative "../scripts/change_lane_a11y"
require_relative "../scripts/change_lane_browserless"

# Covers change_config.lanes.<lane>.basic_auth (0.3.0): a browser lane hitting a
# target gated by HTTP Basic Auth answers it via Puppeteer's page.authenticate(),
# never by embedding credentials in the url (the Fetch spec forbids constructing
# a Request from a url with credentials, so any same-origin fetch() the loaded
# page's own JS makes throws and crashes the page). Config carries
# username_env/password_env, the same env-var-name indirection
# browserless.auth.email_env/password_env already uses, never a real value. The
# generated /function module itself only runs against a live browserless
# container (see change_lane_redirect_test.rb's own note on this), so this
# exercises the pure Ruby: the shared reader, and that the generated module
# string carries the right page.authenticate() call, or none, without
# executing it.
class ChangeLaneBasicAuthTest < Minitest::Test
  Ctx = Struct.new(:network, :target_url) do
    def browserless = nil
    def log(_message) = nil
  end

  def a11y_lane(raw = {})
    config = ChangeConfig::LaneConfig.new("a11y", raw, "/repo")
    ChangeLaneA11y.new(config, Ctx.new("net", "https://app.example.org"))
  end

  def browserless_lane(raw = {})
    config = ChangeConfig::LaneConfig.new("browserless", raw, "/repo")
    ChangeLaneBrowserless.new(config, Ctx.new("net", "https://app.example.org"))
  end

  def with_env(vars)
    previous = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| ENV[k] = v }
  end

  # --- shared reader (ChangeLane#basic_auth) -----------------------------------

  def test_basic_auth_reads_username_and_password_from_the_named_env_vars
    with_env("BA_USER" => "svc", "BA_PASS" => "s3cr3t") do
      creds = a11y_lane("basic_auth" => { "username_env" => "BA_USER", "password_env" => "BA_PASS" }).send(:basic_auth)
      assert_equal({ "username" => "svc", "password" => "s3cr3t" }, creds)
    end
  end

  def test_basic_auth_absent_is_nil
    assert_nil a11y_lane.send(:basic_auth)
  end

  def test_basic_auth_non_hash_is_nil
    assert_nil a11y_lane("basic_auth" => "svc:s3cr3t").send(:basic_auth)
  end

  def test_basic_auth_unset_env_vars_is_nil
    assert_nil a11y_lane("basic_auth" => { "username_env" => "NO_SUCH_BA_USER", "password_env" => "NO_SUCH_BA_PASS" }).send(:basic_auth)
  end

  # A half-set credential (a typo'd or unset env var name on one side only) must
  # not silently send a blank username or password to page.authenticate().
  def test_basic_auth_with_only_username_set_is_nil
    with_env("BA_USER" => "svc") do
      assert_nil a11y_lane("basic_auth" => { "username_env" => "BA_USER", "password_env" => "NO_SUCH_BA_PASS" }).send(:basic_auth)
    end
  end

  def test_basic_auth_with_only_password_set_is_nil
    with_env("BA_PASS" => "s3cr3t") do
      assert_nil a11y_lane("basic_auth" => { "username_env" => "NO_SUCH_BA_USER", "password_env" => "BA_PASS" }).send(:basic_auth)
    end
  end

  # --- a11y module wiring -------------------------------------------------------

  def test_a11y_module_authenticates_when_configured
    with_env("BA_USER" => "svc", "BA_PASS" => "s3cr3t") do
      js = a11y_lane("basic_auth" => { "username_env" => "BA_USER", "password_env" => "BA_PASS" }).send(:scan_module)
      assert_includes js, "page.authenticate"
      assert_includes js, "svc"
      assert_includes js, "s3cr3t"
    end
  end

  def test_a11y_module_skips_authenticate_when_unconfigured
    js = a11y_lane.send(:scan_module)
    assert_includes js, "const basicAuth = null;"
  end

  # --- browserless module wiring -------------------------------------------------

  def test_browserless_module_authenticates_when_configured
    with_env("BA_USER" => "svc", "BA_PASS" => "s3cr3t") do
      js = browserless_lane("basic_auth" => { "username_env" => "BA_USER", "password_env" => "BA_PASS" })
        .send(:scan_module, [], nil, {})
      assert_includes js, "page.authenticate"
      assert_includes js, "svc"
      assert_includes js, "s3cr3t"
    end
  end

  def test_browserless_module_skips_authenticate_when_unconfigured
    js = browserless_lane.send(:scan_module, [], nil, {})
    assert_includes js, "const basicAuth = null;"
  end
end
