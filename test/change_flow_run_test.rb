# frozen_string_literal: true

require "minitest/autorun"
require "uri"
require "json"
require "tmpdir"
require_relative "../scripts/change_flow_run"

class ChangeFlowRunTest < Minitest::Test
  def test_parse_collects_repeated_add_hosts_and_the_https_flag
    options = ChangeFlowRun.parse(%w[flow.yml --add-host a.local.example.test:host-gateway
                                     --add-host b.test:10.0.0.5 --ignore-https-errors])
    assert_equal %w[a.local.example.test:host-gateway b.test:10.0.0.5], options[:add_hosts]
    assert options[:ignore_https_errors]
  end

  def test_parse_rejects_an_add_host_without_a_target
    assert_raises(ArgumentError) { ChangeFlowRun.parse(%w[flow.yml --add-host app.test]) }
  end

  def test_local_hosts_are_recognised
    %w[https://localhost:3000 https://app.localhost https://app.local.example.test https://box.local
       https://app.test https://svc.internal https://127.0.0.1 https://10.1.2.3 https://192.168.1.4
       https://172.16.0.9 https://[::1]].each do |url|
      assert ChangeFlowRun.local_host?(url), "#{url} should be local"
    end
  end

  def test_public_hosts_are_not_local
    %w[https://example.com https://localexample.com https://app.example.com https://8.8.8.8
       https://test.example.com not-a-url].each do |url|
      refute ChangeFlowRun.local_host?(url), "#{url} should not be local"
    end
  end

  def test_ignore_https_errors_is_refused_for_a_public_base_url
    Dir.mktmpdir do |dir|
      flow = File.join(dir, "flow.yml")
      File.write(flow, "steps:\n  - goto: /\n")
      _out, err = capture_io do
        assert_equal 1, ChangeFlowRun.main([ flow, "--base-url", "https://example.com", "--ignore-https-errors", "--dump" ])
      end
      assert_match(/needs a local base URL/, err)
    end
  end

  def test_launch_args_reach_the_function_url_as_an_encoded_query
    session = ChangeDocker::Browserless.new(port: 4321, token: "tok")
    plain = session.function_url
    refute_includes plain, "launch="
    with_flag = URI(session.function_url([ "--ignore-certificate-errors" ]))
    launch = URI.decode_www_form(with_flag.query).to_h.fetch("launch")
    assert_equal({ "args" => [ "--ignore-certificate-errors" ] }, JSON.parse(launch))
  end
end
