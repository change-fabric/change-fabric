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

  # The server-side limiter is set explicitly, and its default job timeout is
  # never below the per-call timeout the client sends.
  def test_browserless_command_sets_the_limiter_explicitly
    argv = ChangeDocker.browserless_command("cf-change-bl-x", nil, 1234, "tok")
    envs = argv.each_cons(2).select { |flag, _| flag == "-e" }.map(&:last)
    assert_includes envs, "CONCURRENT=10"
    assert_includes envs, "QUEUED=10"
    assert_includes envs, "TIMEOUT=#{ChangeDocker::Browserless::FUNCTION_TIMEOUT_MS}"
    assert_equal ChangeDocker::BROWSERLESS_IMAGE, argv.last
  end

  # Env values ride in the docker client's environment; only names reach
  # argv, so `ps` never shows a key or the browserless token.
  def test_run_keeps_env_values_off_argv
    seen = nil
    original = Open3.method(:capture2e)
    Open3.define_singleton_method(:capture2e) { |*call| seen = call and [ "", nil ] }
    begin
      ChangeDocker.run(network: nil, image: "img", args: %w[cmd], env: { "API_KEY" => "sk-never-on-argv" })
    ensure
      Open3.define_singleton_method(:capture2e, original)
    end
    env, *argv = seen
    assert_equal({ "API_KEY" => "sk-never-on-argv" }, env)
    assert_equal [ "-e", "API_KEY" ], argv.each_cons(2).find { |flag, _| flag == "-e" }
    refute(argv.any? { |arg| arg.include?("sk-never-on-argv") })
  end

  def test_browserless_command_names_the_token_without_its_value
    argv = ChangeDocker.browserless_command("cf-change-bl-x", nil, 1234, "tok-secret")
    assert_includes argv.each_cons(2).to_a, [ "-e", "TOKEN" ]
    refute(argv.any? { |arg| arg.include?("tok-secret") })
  end

  # A session whose post returns the scripted responses in order.
  def scripted_session(*responses)
    session = browserless
    calls = []
    session.define_singleton_method(:post) do |_uri, _body, _type|
      calls << 1
      responses.shift
    end
    [ session, calls ]
  end

  def http_response(klass, code, body)
    response = klass.new("1.1", code, "")
    response.instance_variable_set(:@body, body)
    response.instance_variable_set(:@read, true)
    response
  end

  def ok_response = http_response(Net::HTTPOK, "200", '{"data":["frame"],"type":"application/json"}')
  def timed_out = http_response(Net::HTTPRequestTimeout, "408", "Request has timed out")

  # run_function itself never re-runs: a module that clicked or submitted may
  # have acted before the timeout. A 408 gets its own class for replay-safe
  # callers; anything else stays a plain failure.
  def test_run_function_raises_timed_out_on_a_408_without_rerunning
    session, calls = scripted_session(timed_out, ok_response)
    error = assert_raises(ChangeDocker::Browserless::TimedOut) { session.run_function("code") }
    assert_match(/408 Request has timed out/, error.message)
    assert_equal 1, calls.size
  end

  def test_run_function_raises_a_plain_error_on_another_failure
    session, calls = scripted_session(http_response(Net::HTTPBadRequest, "400", "boom"), ok_response)
    error = assert_raises(RuntimeError) { session.run_function("code") }
    refute_kind_of ChangeDocker::Browserless::TimedOut, error
    assert_equal 1, calls.size
  end

  def test_run_function_unwraps_a_success
    session, = scripted_session(ok_response)
    assert_equal [ "frame" ], session.run_function("code")
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

  # The host alias. The spec tells authors to reach a host-booted app via
  # host.docker.internal when no boot.network is configured, but only Docker
  # Desktop defines that name for free; on Docker Engine every lane failed
  # against a target the host-side health check had just called healthy.
  # Asserted on the argv so the flag is covered without a docker daemon.
  def test_run_command_maps_the_host_alias_to_the_host_gateway
    argv = ChangeDocker.run_command(network: nil, image: "img", args: [ "cmd" ])
    assert_includes argv.each_cons(2).to_a, [ "--add-host", "host.docker.internal:host-gateway" ]
  end

  def test_run_command_labels_every_container_with_the_owner_pid
    argv = ChangeDocker.run_command(network: nil, image: "img", args: [], name: "cf-change-k6-x")
    assert_includes argv.each_cons(2).to_a, [ "--label", "#{ChangeDocker::OWNER_LABEL}=#{Process.pid}" ]
  end

  def test_run_command_keeps_the_image_and_its_command_last
    argv = ChangeDocker.run_command(network: "net", image: "img", args: %w[a b], name: "cf-change-x")
    assert_equal %w[img a b], argv.last(3)
    assert_includes argv.each_cons(2).to_a, [ "--network", "net" ]
  end

  # A host path holding ":" or "," splits the old `-v host:container` form;
  # the CSV-quoted --mount source keeps it whole.
  def test_run_command_quotes_a_mount_source_with_a_colon_and_a_comma
    argv = ChangeDocker.run_command(network: nil, image: "img", args: [],
                                    mounts: { "/a:b,c" => { target: "/repo", readonly: true } })
    assert_includes argv.each_cons(2).to_a, [ "--mount", 'type=bind,"source=/a:b,c",target=/repo,readonly' ]
    refute_includes argv, "-v"
  end

  def test_run_command_string_mount_target_is_writable
    argv = ChangeDocker.run_command(network: nil, image: "img", args: [], mounts: { "/work" => "/out" })
    assert_includes argv.each_cons(2).to_a, [ "--mount", 'type=bind,"source=/work",target=/out' ]
  end

  def test_run_command_emits_an_entrypoint_override_before_the_image
    argv = ChangeDocker.run_command(network: nil, image: "img", args: %w[cmd], entrypoint: "ffprobe")
    at = argv.index("--entrypoint")
    assert_equal "ffprobe", argv[at + 1]
    assert_operator at, :<, argv.index("img")
    refute_includes ChangeDocker.run_command(network: nil, image: "img", args: %w[cmd]), "--entrypoint"
  end

  def test_run_command_emits_user_and_workdir_before_the_image
    argv = ChangeDocker.run_command(network: nil, image: "img", args: %w[cmd], user: "1:2", workdir: "/w")
    image_at = argv.index("img")
    user_at = argv.index("--user")
    workdir_at = argv.index("-w")
    assert_equal "1:2", argv[user_at + 1]
    assert_equal "/w", argv[workdir_at + 1]
    assert_operator user_at, :<, image_at
    assert_operator workdir_at, :<, image_at
    assert_equal %w[img cmd], argv.last(2)
  end

  def test_browserless_command_maps_the_host_alias_to_the_host_gateway
    argv = ChangeDocker.browserless_command("cf-change-bl-x", "net", 1234, "tok")
    assert_includes argv.each_cons(2).to_a, [ "--add-host", "host.docker.internal:host-gateway" ]
    assert_equal ChangeDocker::BROWSERLESS_IMAGE, argv.last
    assert_includes argv, "127.0.0.1:1234:3000"
  end

  # The ephemeral-network branch really creates and removes a docker network.
  def test_with_network_creates_and_removes_an_ephemeral_network
    skip "docker not available" unless ChangeDocker.available?

    captured = nil
    ChangeDocker.with_network(nil) do |net|
      captured = net
      assert net.owned
      assert net.name.start_with?("cf-change-")
      _out, status = Open3.capture2e("docker", "network", "inspect", net.name)
      assert status.success?, "ephemeral network should exist during the block"
    end
    _out, status = Open3.capture2e("docker", "network", "inspect", captured.name)
    refute status.success?, "ephemeral network should be removed after the block"
  end

  # start_browserless used to discard docker's own stderr on failure, so a
  # missing/renamed network (the boot.network inheritance footgun: a non-local
  # profile inheriting a local-only network name) surfaced as a bare "failed to
  # start browserless container" with nothing to act on.
  def test_with_browserless_surfaces_dockers_own_error_on_a_bad_network
    skip "docker not available" unless ChangeDocker.available?

    error = assert_raises(RuntimeError) do
      ChangeDocker.with_browserless(network: "cf-change-no-such-network-#{SecureRandom.hex(4)}") { |_s| }
    end
    assert_match(/network/i, error.message)
  end

  # docker network create used to run unchecked: a failure (a name collision, a
  # daemon hiccup) was silently ignored and the run proceeded as if a real
  # network existed, only to fail confusingly at the first container that tried
  # to join it.
  def test_with_network_raises_with_dockers_output_when_create_fails
    skip "docker not available" unless ChangeDocker.available?

    existing = "cf-change-#{SecureRandom.hex(4)}"
    Open3.capture2e("docker", "network", "create", existing)
    begin
      error = assert_raises(RuntimeError) do
        ChangeDocker.send(:create_ephemeral_network, existing) { |_n| }
      end
      assert_match(/#{Regexp.escape(existing)}/, error.message)
    ensure
      Open3.capture2e("docker", "network", "rm", existing)
    end
  end

  # The dogfooding fix: a run that crashes before its own teardown leaves a
  # prefixed container or network behind, with no way to reclaim it. Tests sweep
  # only their own per-test prefix, never the global `cf-change-`, so a test run
  # cannot remove a live render's browserless container.
  def test_sweep_removes_an_orphaned_container_and_network
    skip "docker not available" unless ChangeDocker.available?

    prefix = test_prefix
    network = "#{prefix}net"
    Open3.capture2e("docker", "network", "create", network)
    container = "#{prefix}zap"
    Open3.capture2e("docker", "run", "-d", "--name", container, "alpine", "sleep", "60")

    removed = ChangeDocker.sweep(prefix: prefix)

    assert_equal [ container ], removed[:containers]
    assert_includes removed[:networks], network
    _out, status = Open3.capture2e("docker", "inspect", container)
    refute status.success?, "swept container should be gone"
  end

  def test_sweep_keeps_a_container_whose_owner_pid_is_alive
    skip "docker not available" unless ChangeDocker.available?

    prefix = test_prefix
    live = "#{prefix}live"
    dead = "#{prefix}dead"
    Open3.capture2e("docker", "run", "-d", "--name", live, "--label", "cf.owner_pid=#{Process.pid}", "alpine", "sleep", "60")
    Open3.capture2e("docker", "run", "-d", "--name", dead, "--label", "cf.owner_pid=2147483646", "alpine", "sleep", "60")
    begin
      removed = ChangeDocker.sweep(prefix: prefix)

      assert_equal [ dead ], removed[:containers]
      _out, status = Open3.capture2e("docker", "inspect", live)
      assert status.success?, "a container owned by a live pid must survive the sweep"
    ensure
      Open3.capture2e("docker", "rm", "-f", live)
      Open3.capture2e("docker", "rm", "-f", dead)
    end
  end

  def test_browserless_command_labels_the_owner_pid
    cmd = ChangeDocker.browserless_command("cf-change-bl-x", nil, 1234, "tok")

    assert_includes cmd.each_cons(2).to_a, [ "--label", "cf.owner_pid=#{Process.pid}" ]
  end

  def test_sweep_default_prefix_is_the_resource_prefix
    # Stubbed (no minitest/mock in this bundle) so no real sweep touches docker.
    seen = []
    original = ChangeDocker.method(:matching_names)
    ChangeDocker.define_singleton_method(:matching_names) { |*cmd| seen << cmd; [] }
    begin
      ChangeDocker.sweep
    ensure
      ChangeDocker.define_singleton_method(:matching_names, original)
    end

    refute_empty seen
    assert seen.all? { |cmd| cmd.include?("name=#{ChangeDocker::RESOURCE_PREFIX}") }
  end

  private

  def test_prefix = "cf-change-test-#{SecureRandom.hex(4)}-"
end
