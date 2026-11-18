# frozen_string_literal: true

require "minitest/autorun"
require "uri"
require "json"
require "tmpdir"
require "yaml"
require_relative "../scripts/change_flow_run"

class ChangeFlowRunTest < Minitest::Test
  def test_parse_collects_repeated_add_hosts_and_the_https_flag
    options = ChangeFlowRun.parse(%w[flow.yml --add-host a.local.example.test:host-gateway
                                     --add-host b.test:10.0.0.5 --ignore-https-errors --profile local])
    assert_equal %w[a.local.example.test:host-gateway b.test:10.0.0.5], options[:add_hosts]
    assert options[:ignore_https_errors]
    assert_equal "local", options[:profile]
  end

  def test_parse_rejects_an_add_host_without_a_target
    assert_raises(ArgumentError) { ChangeFlowRun.parse(%w[flow.yml --add-host app.test]) }
  end

  def test_ignore_https_errors_is_refused_for_a_public_base_url
    Dir.mktmpdir do |dir|
      flow = File.join(dir, "flow.yml")
      File.write(flow, "steps:\n  - goto: /\n")
      _out, err = capture_io do
        assert_equal 1, ChangeFlowRun.main([ flow, "--base-url", "https://example.com", "--ignore-https-errors", "--dump" ])
      end
      assert_match(/needs a local target/, err)
    end
  end

  def test_a_profile_supplies_hosts_the_https_flag_and_the_base_url
    Dir.mktmpdir do |dir|
      change_md = File.join(dir, "CHANGE.md")
      File.write(change_md, <<~MD)
        ---
        change_config:
          boot:
            target_url: http://web:3000
          lanes:
            a11y: { routes: ["/"] }
          profiles:
            local:
              boot:
                target_url: https://app.local.example.com
                add_hosts: ["app.local.example.com:host-gateway"]
                ignore_https_errors: true
        ---
      MD
      options = ChangeFlowRun.parse([ "flow.yml", "--change-md", change_md, "--profile", "local", "--add-host", "x.test:10.0.0.1" ])
      ChangeFlowRun.apply_change_md(options)
      assert_equal %w[app.local.example.com:host-gateway x.test:10.0.0.1], options[:add_hosts]
      assert options[:ignore_https_errors]
      assert_equal "https://app.local.example.com", options[:config_base_url]
      ChangeFlowRun.check_ignore_https(options, options[:config_base_url])
      assert_equal %w[app.local.example.com x.test], options[:allowed_hosts]
    end
  end

  def test_launch_args_reach_the_function_url_as_an_encoded_query
    session = ChangeDocker::Browserless.new(port: 4321, token: "tok")
    refute_includes session.function_url, "launch="
    with_flag = URI(session.function_url([ "--ignore-certificate-errors" ]))
    launch = URI.decode_www_form(with_flag.query).to_h.fetch("launch")
    assert_equal({ "args" => [ "--ignore-certificate-errors" ] }, JSON.parse(launch))
  end

  def test_parse_collects_launch_args_and_rejects_a_non_flag
    options = ChangeFlowRun.parse(%w[flow.yml --launch-arg --disable-features=LocalNetworkAccessChecks])
    assert_equal %w[--disable-features=LocalNetworkAccessChecks], options[:launch_args]
    assert_raises(ArgumentError) { ChangeFlowRun.parse(%w[flow.yml --launch-arg nope]) }
  end

  def test_a_profile_supplies_the_testcases_launch_args
    Dir.mktmpdir do |dir|
      change_md = File.join(dir, "CHANGE.md")
      File.write(change_md, <<~MD)
        ---
        change_config:
          boot:
            target_url: http://web:3000
          lanes:
            testcases:
              suites: ["*.yml"]
              launch_args: ["--disable-features=LocalNetworkAccessChecks"]
        ---
      MD
      options = ChangeFlowRun.parse([ "flow.yml", "--change-md", change_md, "--launch-arg", "--x" ])
      ChangeFlowRun.apply_change_md(options)
      assert_equal %w[--disable-features=LocalNetworkAccessChecks --x], options[:launch_args]
    end
  end

  # --- promote: default suite and persona ref (0.22.0) -------------------------------

  PERSONA_MD = <<~MD
    ---
    change_config:
      boot:
        target_url: http://web:3000
      lanes:
        testcases:
          suites: ["*.yml"]
          personas:
            admin:
              login_url: /admin/login
              email_env: ADMIN_EMAIL
              password_env: ADMIN_PASSWORD
              email_selector: "#email"
              password_selector: "#password"
              submit_selector: "#sign-in"
    ---
  MD

  LOGIN_FLOW = <<~YAML
    steps:
      - goto: http://localhost:3000/admin/login
      - fill: { selector: "#email", env: ADMIN_EMAIL }
      - fill: { selector: "#password", env: ADMIN_PASSWORD }
      - click: "#sign-in"
      - goto: /admin/users
      - expect_visible: ".users"
  YAML

  def promote_in(flow_body, *extra)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "CHANGE.md"), PERSONA_MD)
      flow = File.join(dir, "admin-users.flow.yml")
      File.write(flow, flow_body)
      out, err = capture_io do
        assert_equal 0, ChangeFlowRun.main([ flow, "--promote", "--change-md", File.join(dir, "CHANGE.md"),
                                             "--case-id", "list", "--acceptance", "An admin sees the users.", *extra ])
      end
      return [ YAML.safe_load(out), err ]
    end
  end

  def test_promote_defaults_the_suite_to_the_flow_file_name
    doc, = promote_in("steps:\n  - goto: /\n  - expect_visible: main\n")
    assert_equal "admin-users", doc["suite"]
  end

  def test_promote_replaces_a_persona_login_with_a_persona_ref
    doc, err = promote_in(LOGIN_FLOW)
    item = doc["cases"].first
    assert_equal "admin", item["persona"]
    assert_equal 3, doc["suite_version"]
    assert_equal [ { "goto" => "/admin/users" }, { "expect_visible" => ".users" } ], item["steps"]
    assert_includes err, "persona: admin"
  end

  def test_promote_persona_flag_forces_the_ref
    doc, = promote_in("steps:\n  - goto: /admin/users\n", "--persona", "admin")
    assert_equal "admin", doc["cases"].first["persona"]
    assert_equal [ { "goto" => "/admin/users" } ], doc["cases"].first["steps"]
  end

  def test_promote_keeps_a_flow_that_does_not_start_with_a_login
    flow = LOGIN_FLOW.sub('"#sign-in"', '"#other"')
    doc, = promote_in(flow)
    refute doc["cases"].first.key?("persona")
    assert_equal 6, doc["cases"].first["steps"].size
  end

  # The navigation wait after the submit belongs to the login: left behind, it
  # would wait for a navigation the seeded case never makes.
  def test_promote_drops_the_navigation_wait_after_the_login_submit
    flow = LOGIN_FLOW.sub("  - click: \"#sign-in\"\n", "  - click: \"#sign-in\"\n  - wait_for: { state: domcontentloaded }\n")
    doc, = promote_in(flow)
    item = doc["cases"].first
    assert_equal "admin", item["persona"]
    assert_equal [ { "goto" => "/admin/users" }, { "expect_visible" => ".users" } ], item["steps"]
  end

  # A hash route is the page in a client-routed app, so two logins on one
  # path are told apart by their route.
  def test_login_path_matching_keeps_hash_routes
    assert ChangeFlowLogin.same_path?("http://localhost:3000/#/admin-login", "/#/admin-login")
    refute ChangeFlowLogin.same_path?("http://localhost:3000/#/admin-login", "/#/member-login")
    refute ChangeFlowLogin.same_path?("http://localhost:3000/#/admin-login", "/")
    assert ChangeFlowLogin.same_path?("http://localhost:3000/admin/login/", "/admin/login")
  end

  # A query the config names (a tenant, an auth mode) picks the login, so the
  # flow has to carry it. An extra flow param such as next= can change where
  # the login lands, so it is not the configured login and its steps stay.
  def test_login_path_matching_keeps_the_configured_query
    assert ChangeFlowLogin.same_path?("http://localhost:3000/login?tenant=admin", "/login?tenant=admin")
    refute ChangeFlowLogin.same_path?("http://localhost:3000/login?tenant=admin&next=/x", "/login?tenant=admin")
    refute ChangeFlowLogin.same_path?("http://localhost:3000/login?next=/settings", "/login")
    refute ChangeFlowLogin.same_path?("http://localhost:3000/login?tenant=admin", "/login?tenant=member")
    refute ChangeFlowLogin.same_path?("http://localhost:3000/login", "/login?tenant=member")
  end

  # Two personas on one login form differ only in their credentials, so the
  # env vars the flow typed decide which one it was.
  def test_promote_tells_personas_on_one_form_apart_by_their_env
    md = PERSONA_MD.sub("          personas:\n", <<~YAML.gsub(/^/, "          ").sub(/\A {10}/, "")
      auth:
        login_url: /admin/login
        email_env: USER_EMAIL
        password_env: USER_PASSWORD
        email_selector: "#email"
        password_selector: "#password"
        submit_selector: "#sign-in"
      personas:
    YAML
    )
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "CHANGE.md"), md)
      flow = File.join(dir, "admin-users.flow.yml")
      File.write(flow, LOGIN_FLOW)
      out, = capture_io do
        ChangeFlowRun.main([ flow, "--promote", "--change-md", File.join(dir, "CHANGE.md"),
                             "--case-id", "list", "--acceptance", "An admin sees the users." ])
      end
      assert_equal "admin", YAML.safe_load(out)["cases"].first["persona"]
    end
  end
end
