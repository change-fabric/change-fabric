# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require_relative "../scripts/change_docker"

class ChangeDockerTest < Minitest::Test
  # The browserless /function envelope unwrap, the fix for the a11y and
  # browserless lane crashes: browserless returns { data, type } and the lane
  # needs the value under "data".
  def browserless = ChangeDocker::Browserless.new(port: 1, token: "x")

  def test_unwrap_returns_the_data_payload
    payload = [ { "route" => "/", "violations" => [] } ]
    assert_equal payload, browserless.unwrap("data" => payload, "type" => "application/json")
  end

  def test_unwrap_passes_through_a_bare_array
    payload = [ { "route" => "/" } ]
    assert_equal payload, browserless.unwrap(payload)
  end

  def test_unwrap_passes_through_a_hash_without_data
    hash = { "route" => "/", "violations" => [] }
    assert_equal hash, browserless.unwrap(hash)
  end

  # The configured-network branch must not touch docker: it just wraps the name.
  # This exercises the keyword-arg Struct construction that a runtime bug once
  # broke (a mixed positional/keyword call raised ArgumentError).
  def test_with_network_uses_a_configured_network_without_creating_one
    seen = nil
    ChangeDocker.with_network("my-existing-net") { |net| seen = net }
    assert_equal "my-existing-net", seen.name
    refute seen.owned
  end

  # The ephemeral-network branch really creates and removes a docker network.
  def test_with_network_creates_and_removes_an_ephemeral_network
    skip "docker not available" unless ChangeDocker.available?

    captured = nil
    ChangeDocker.with_network(nil) do |net|
      captured = net
      assert net.owned
      assert net.name.start_with?("pst-change-")
      _out, status = Open3.capture2e("docker", "network", "inspect", net.name)
      assert status.success?, "ephemeral network should exist during the block"
    end
    _out, status = Open3.capture2e("docker", "network", "inspect", captured.name)
    refute status.success?, "ephemeral network should be removed after the block"
  end

  # The dogfooding fix: a run that crashes before its own teardown leaves a
  # `pst-change-*` container or network behind, with no way to reclaim it.
  def test_sweep_removes_an_orphaned_container_and_network
    skip "docker not available" unless ChangeDocker.available?

    network = "pst-change-#{SecureRandom.hex(4)}"
    Open3.capture2e("docker", "network", "create", network)
    container = "pst-change-zap-#{SecureRandom.hex(4)}"
    Open3.capture2e("docker", "run", "-d", "--name", container, "alpine", "sleep", "60")

    removed = ChangeDocker.sweep

    assert_includes removed[:containers], container
    assert_includes removed[:networks], network
    _out, status = Open3.capture2e("docker", "inspect", container)
    refute status.success?, "swept container should be gone"
  end
end
