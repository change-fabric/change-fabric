# frozen_string_literal: true

require "minitest/autorun"
require "uri"
require "json"
require "tmpdir"
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
end
