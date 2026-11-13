# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require "base64"
require "json"
require_relative "../scripts/prototype_reference"

class PrototypeReferenceTest < Minitest::Test
  LANE_AUTH = { "login_url" => "/login", "email_env" => "REF_EMAIL", "password_env" => "REF_PASSWORD" }.freeze
  PNG = Base64.strict_encode64("png-bytes")

  # A fake browserless session: records the module, answers with `reply`.
  class Session
    attr_reader :modules

    def initialize(reply)
      @reply = reply
      @modules = []
    end

    def run_function(code)
      @modules << code
      @reply
    end
  end

  # The linked app's config, as ChangeConfig would expose it.
  FakeLane = Struct.new(:raw, :url) do
    def [](key) = raw[key]
    def base_url(fallback) = url || fallback
  end
  FakeApp = Struct.new(:lanes, :target_url) do
    def lane(name) = FakeLane.new(lanes.fetch(name, {}), nil)
    def boot = Struct.new(:target_url).new(target_url)
  end

  def app_loader(lanes = { "browserless" => { "auth" => LANE_AUTH } })
    ->(_root, _name) { FakeApp.new(lanes, "https://staging.example.org") }
  end

  def with_repo(reference, app: "portal")
    Dir.mktmpdir do |root|
      target = { "source" => "tailwind", "theme" => "apps/portal/src/app/globals.css", "kit" => "packages/design-kit",
                 "reference" => reference }
      target["app"] = app if app
      config = { "design" => { "targets" => { "portal" => target } } }
      config["apps"] = { "portal" => { "config" => "apps/portal/CHANGE.app.yml" } } if app
      File.write(File.join(root, "CHANGE.md"), "#{YAML.dump('change_config' => config)}---\n")
      yield root
    end
  end

  ROUTES = [ { "path" => "/admin/analytics", "mask" => [ "[data-live-value]" ] } ].freeze
  ENV_OK = { "REF_EMAIL" => "ref@example.org", "REF_PASSWORD" => "correct-horse" }.freeze

  def test_string_auth_resolves_to_the_linked_apps_lane_auth_and_base_url
    with_repo({ "routes" => ROUTES, "auth" => "browserless" }) do |root|
      plan = PrototypeReference.plan(root, "portal", app_loader: app_loader)
      assert_equal LANE_AUTH, plan.auth
      assert_equal "https://staging.example.org", plan.base_url
    end
  end

  def test_hash_auth_is_used_as_given
    with_repo({ "base_url" => "https://ref.example.org/", "routes" => ROUTES, "auth" => LANE_AUTH }, app: nil) do |root|
      plan = PrototypeReference.plan(root, "portal", app_loader: ->(*) { flunk "no app is loaded" })
      assert_equal LANE_AUTH, plan.auth
      assert_equal "https://ref.example.org", plan.base_url
    end
  end

  def test_lane_name_with_no_auth_block_is_a_named_error
    with_repo({ "routes" => ROUTES, "auth" => "a11y" }) do |root|
      error = assert_raises(PrototypeReference::Error) { PrototypeReference.plan(root, "portal", app_loader: app_loader) }
      assert_match(/lanes\.a11y has no auth block/, error.message)
    end
  end

  def test_literal_secret_in_auth_is_rejected_at_load
    with_repo({ "routes" => ROUTES, "auth" => LANE_AUTH.merge("password" => "hunter2") }, app: nil) do |root|
      assert_raises(DesignConfig::Error) { PrototypeReference.plan(root, "portal") }
    end
  end

  def test_missing_env_is_named_and_nothing_is_captured
    with_repo({ "routes" => ROUTES, "auth" => "browserless" }) do |root|
      session = Session.new([])
      error = assert_raises(PrototypeReference::Error) do
        PrototypeReference.capture(root, "portal", session: session, source: { "REF_EMAIL" => "ref@example.org" }, app_loader: app_loader)
      end
      assert_match(/REF_PASSWORD/, error.message)
      assert_match(/no unauthenticated capture/, error.message)
      assert_empty session.modules
    end
  end

  def test_capture_writes_stills_to_the_ignored_cache_with_masks_applied
    with_repo({ "routes" => ROUTES, "auth" => "browserless" }) do |root|
      session = Session.new([ { "path" => "/admin/analytics", "status" => 200, "png" => PNG } ])
      paths = PrototypeReference.capture(root, "portal", session: session, source: ENV_OK, app_loader: app_loader)
      assert_equal [ File.join(root, ".cache/reference/portal/admin-analytics.png") ], paths
      assert_equal "png-bytes", File.binread(paths.first)
      assert_equal "*\n", File.read(File.join(root, ".cache/reference/.gitignore"))
      code = session.modules.first
      assert_includes code, "[data-live-value]"
      assert_includes code, "runAuthStep"
      assert_includes code, "https://staging.example.org/login"
    end
  end

  def test_a_failed_login_is_reported_with_secrets_masked
    with_repo({ "routes" => ROUTES, "auth" => "browserless" }) do |root|
      session = Session.new({ "authError" => "typed correct-horse into #password, still on /login" })
      error = assert_raises(PrototypeReference::Error) do
        PrototypeReference.capture(root, "portal", session: session, source: ENV_OK, app_loader: app_loader)
      end
      refute_includes error.message, "correct-horse"
      assert_includes error.message, "***REF_PASSWORD***"
    end
  end

  def test_a_non_ok_route_fails_by_name
    with_repo({ "routes" => ROUTES, "auth" => "browserless" }) do |root|
      session = Session.new([ { "path" => "/admin/analytics", "status" => 403, "png" => PNG } ])
      error = assert_raises(PrototypeReference::Error) do
        PrototypeReference.capture(root, "portal", session: session, source: ENV_OK, app_loader: app_loader)
      end
      assert_match(%r{/admin/analytics answered HTTP 403}, error.message)
    end
  end

  def test_a_target_without_a_reference_is_a_named_error
    Dir.mktmpdir do |root|
      error = assert_raises(PrototypeReference::Error) { PrototypeReference.plan(root, nil) }
      assert_match(/names no reference/, error.message)
    end
  end
end
