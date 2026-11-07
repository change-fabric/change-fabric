# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../scripts/host_capabilities"

class HostCapabilitiesTest < Minitest::Test
  def test_unknown_versions_never_claim_tested_support
    report = HostCapabilities.new.resolve(host: "codex", surface: "cli", version: "codex-cli 999.0.0")
    assert_equal "unverified", report["version_status"]
    assert_equal "instructions-only", report["effective_support"]
    assert_equal "adapter-tested", report.dig("capabilities", "tool_guard")
    assert_equal "not-run", report["live_verification"]
  end

  def test_live_evidence_is_scoped_to_the_exact_verified_version
    report = HostCapabilities.new.resolve(host: "codex", surface: "cli", version: "0.166.0")
    assert_equal "passed", report["live_verification"]
    future = HostCapabilities.new.resolve(host: "codex", surface: "cli", version: "999.0.0")
    assert_nil future["live_scope"]
    assert_equal [ "0.166.0" ], future.dig("reference_live_evidence", "versions")
  end

  def test_reference_version_is_not_a_live_or_adapter_test
    report = HostCapabilities.new.resolve(host: "claude", surface: "cli", version: "2.1.318")
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

  def test_extra_version_components_do_not_match_a_registered_prefix
    %w[0.166.0.1 0.166.0+custom].each do |version|
      report = HostCapabilities.new.resolve(host: "codex", surface: "cli", version: "codex-cli #{version}")
      refute_equal "reference-only", report["version_status"], version
    end
  end
end
