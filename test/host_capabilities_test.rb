# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../scripts/host_capabilities"

class HostCapabilitiesTest < Minitest::Test
  def test_unknown_versions_never_claim_tested_support
    report = HostCapabilities.new.resolve(host: "codex", surface: "cli", version: "codex-cli 999.0.0")
    assert_equal "unverified", report["version_status"]
    assert_equal "instructions-only", report["effective_support"]
    assert_equal "documented", report.dig("capabilities", "tool_guard")
    assert_equal "not-run", report["live_verification"]
  end

  def test_reference_version_is_not_a_live_or_adapter_test
    report = HostCapabilities.new.resolve(host: "codex", surface: "cli", version: "0.166.0")
    assert_equal "reference-only", report["version_status"]
    assert_equal "instructions-only", report["effective_support"]
  end

  def test_cloud_and_editor_do_not_inherit_cli_capabilities
    registry = HostCapabilities.new
    %w[cloud editor].each do |surface|
      report = registry.resolve(host: "copilot", surface: surface, version: "1.0.0")
      assert_equal "instructions-only", report.dig("capabilities", "tool_guard")
    end
    assert_equal "unknown-surface", registry.resolve(host: "codex", surface: "future")["version_status"]
  end

  def test_invalid_registry_fails_visibly
    Tempfile.create("capabilities") do |file|
      file.write('{"schema_version":99,"profiles":[]}')
      file.flush
      assert_raises(ArgumentError) { HostCapabilities.new(path: file.path) }
    end
  end
end
