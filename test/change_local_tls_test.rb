# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_local_tls"
require_relative "../scripts/change_flow_compiler"

class ChangeLocalTlsTest < Minitest::Test
  def test_local_hosts_are_recognised
    %w[https://localhost:3000 https://app.localhost https://app.local.example.test https://box.local
       https://app.test https://svc.internal https://127.0.0.1 https://10.1.2.3 https://192.168.1.4
       https://172.16.0.9 https://[::1]].each do |url|
      assert ChangeLocalTls.local_host?(url), "#{url} should be local"
    end
  end

  def test_public_hosts_are_not_local
    %w[https://example.com https://localexample.com https://app.example.com https://8.8.8.8
       https://test.example.com https://app.local.example.com not-a-url].each do |url|
      refute ChangeLocalTls.local_host?(url), "#{url} should not be local"
    end
  end

  # A name under a public domain is local only when this run pins it to the
  # host or a private address.
  def test_an_add_host_mapping_to_the_host_or_a_private_ip_makes_a_name_local
    url = "https://app.local.example.com"
    assert ChangeLocalTls.local_host?(url, [ "app.local.example.com:host-gateway" ])
    assert ChangeLocalTls.local_host?(url, [ "app.local.example.com:192.168.1.20" ])
    refute ChangeLocalTls.local_host?(url, [ "app.local.example.com:8.8.8.8" ])
    refute ChangeLocalTls.local_host?(url, [ "other.example.com:host-gateway" ])
  end

  def test_allowed_hosts_are_the_local_target_and_local_mappings_only
    hosts = ChangeLocalTls.allowed_hosts("https://app.local.example.com",
                                         %w[app.local.example.com:host-gateway cdn.example.com:8.8.8.8])
    assert_equal %w[app.local.example.com], hosts
    assert_raises(ArgumentError) { ChangeLocalTls.allowed_hosts("https://example.com", []) }
  end

  def test_wrap_guards_every_page_before_the_module_body
    code = ChangeLocalTls.wrap(ChangeFlowCompiler.new([ { "goto" => "/" } ], base_url: "https://app.test").function_module, %w[app.test])
    assert_includes code, 'const cfLocalHosts = ["app.test"];'
    assert_includes code, 'const host = url.hostname.replace(/^\\[|\\]$/g, "");'
    assert_match(/protocol === "https:" && !cfLocalHosts\.includes\(host\)\) return request\.abort/, code)
    assert_includes code, "target.__cfLocalTls ||= (async () => {"
    assert_includes code, "await target.__cfLocalTls;"
    assert_includes code, "cfPatchNewPage(cfBrowser);"
    assert_includes code, 'cfBrowser.on("targetcreated"'
    assert_operator code.index("await cfGuard(page);"), :<, code.index("const results = await cfRunFlow(page")
  end

  def test_wrap_accepts_the_lane_function_entry_shape
    code = ChangeLocalTls.wrap("export default async function ({ page }) {\n  return 1;\n}\n", %w[app.test])
    assert_operator code.index("await cfGuard(page);"), :<, code.index("return 1;")
  end

  def test_wrap_refuses_an_unrecognised_module
    assert_raises(ArgumentError) { ChangeLocalTls.wrap("export default () => 1", %w[app.test]) }
  end
end
