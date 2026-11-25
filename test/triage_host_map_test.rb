# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/triage/host_map"

class TriageHostMapTest < Minitest::Test
  def with_map(text)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "hosts.yml")
      File.write(path, text) if text
      yield Triage::HostMap.load(path)
    end
  end

  def test_a_missing_file_is_an_empty_valid_map
    with_map(nil) do |map|
      assert map.valid?
      assert_empty map.repos
      assert_nil map.host_for("acme/api")
    end
  end

  def test_a_valid_map_keeps_file_order_and_versions
    with_map("repos:\n  acme/web: {host: vm, assignment_version: 3}\n  acme/api: {host: mini, assignment_version: 1}\n") do |map|
      assert map.valid?
      assert_equal %w[acme/web acme/api], map.repos
      assert_equal "vm", map.host_for("acme/web")
      assert_equal 3, map.version_for("acme/web")
      assert_equal 0, map.rank("acme/web")
      assert_equal 2, map.rank("acme/unmapped"), "an unmapped repo sorts after every mapped one"
      assert_equal %w[vm mini], map.hosts
    end
  end

  def test_an_unknown_host_is_invalid
    with_map("repos:\n  acme/api: {host: laptop, assignment_version: 1}\n") do |map|
      refute map.valid?
      assert_includes map.error, "host must be one of mini, vm"
      assert_empty map.repos, "an invalid map is report-only everywhere"
    end
  end

  def test_a_missing_or_non_integer_assignment_version_is_invalid
    with_map("repos:\n  acme/api: {host: mini}\n") { |map| refute map.valid? }
    with_map("repos:\n  acme/api: {host: mini, assignment_version: '1'}\n") { |map| refute map.valid? }
    with_map("repos:\n  acme/api: {host: mini, assignment_version: 0}\n") { |map| refute map.valid? }
  end

  def test_corrupt_yaml_is_invalid_rather_than_raising
    with_map("repos: [unclosed\n  : :\n") do |map|
      refute map.valid?
      refute_nil map.error
    end
  end

  def test_a_non_mapping_document_is_invalid
    with_map("- just\n- a list\n") { |map| refute map.valid? }
  end

  def test_ssh_aliases_default_to_the_host_name
    with_map("repos:\n  acme/api: {host: mini, assignment_version: 1}\nhosts:\n  vm: {ssh: exe-vm}\n") do |map|
      assert_equal "exe-vm", map.ssh_target("vm")
      assert_equal "mini", map.ssh_target("mini")
    end
  end

  def test_the_acting_host_comes_only_from_the_environment
    previous = ENV["CF_TRIAGE_HOST"]
    ENV["CF_TRIAGE_HOST"] = "mini"
    assert_equal "mini", Triage::Paths.host
    ENV["CF_TRIAGE_HOST"] = "somebox.local"
    assert_nil Triage::Paths.host
    ENV.delete("CF_TRIAGE_HOST")
    assert_nil Triage::Paths.host
  ensure
    previous ? ENV["CF_TRIAGE_HOST"] = previous : ENV.delete("CF_TRIAGE_HOST")
  end
end
