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
       https://test.example.com https://app.local.example.com not-a-url].each do |url|
      refute ChangeFlowRun.local_host?(url), "#{url} should not be local"
    end
  end

  # A name under a public domain is local only when this run pins it to the
  # host or a private address.
  def test_an_add_host_mapping_to_the_host_or_a_private_ip_makes_a_name_local
    url = "https://app.local.example.com"
    assert ChangeFlowRun.local_host?(url, [ "app.local.example.com:host-gateway" ])
    assert ChangeFlowRun.local_host?(url, [ "app.local.example.com:192.168.1.20" ])
    refute ChangeFlowRun.local_host?(url, [ "app.local.example.com:8.8.8.8" ])
    refute ChangeFlowRun.local_host?(url, [ "other.example.com:host-gateway" ])
  end

  def test_https_requests_to_non_local_hosts_are_aborted_when_errors_are_ignored
    compiler = ChangeFlowCompiler.new([ { "goto" => "/" } ], base_url: "https://app.test")
    code = ChangeFlowRun.local_https_only(compiler.function_module, %w[app.test])
    assert_includes code, 'const cfLocalHosts = ["app.test"];'
    assert_includes code, "await page.setRequestInterception(true);"
    assert_includes code, 'const host = url.hostname.replace(/^\\[|\\]$/g, "");'
    assert_match(/protocol === "https:" && !cfLocalHosts\.includes\(host\)\) return request\.abort/, code)
    assert_operator code.index("setRequestInterception"), :<, code.index("const results = await cfRunFlow(page")
  end

  def test_allowed_hosts_are_the_local_base_and_local_mappings_only
    options = ChangeFlowRun.parse(%w[f.yml --ignore-https-errors --add-host app.local.example.com:host-gateway
                                     --add-host cdn.example.com:8.8.8.8])
    ChangeFlowRun.check_ignore_https(options, "https://app.local.example.com")
    assert_equal %w[app.local.example.com], options[:allowed_hosts]
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
