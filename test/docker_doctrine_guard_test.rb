# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"

require_relative "../scripts/docker_doctrine_guard"

class DockerDoctrineGuardTest < Minitest::Test
  def setup
    @prev = ENV.delete("PST_ALLOW_HOSTDAEMON")
  end

  def teardown
    ENV["PST_ALLOW_HOSTDAEMON"] = @prev if @prev
  end

  def guard(tool_name, tool_input)
    io = StringIO.new
    DockerDoctrineGuard.new("tool_name" => tool_name, "tool_input" => tool_input).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string)["hookSpecificOutput"]
  end

  def decision(command)
    guard("Bash", "command" => command)&.dig("permissionDecision")
  end

  def test_denies_brew_services_for_a_proxy
    assert_equal "deny", decision("brew services start caddy")
  end

  def test_denies_brew_install_for_a_datastore
    assert_equal "deny", decision("brew install postgresql@16")
  end

  def test_denies_a_bare_daemon_binary
    assert_equal "deny", decision("redis-server --port 6380 &")
  end

  def test_denies_caddy_run
    assert_equal "deny", decision("caddy run --config /opt/homebrew/etc/Caddyfile")
  end

  def test_allows_unrelated_brew_install
    assert_nil decision("brew install jq")
  end

  def test_allows_brew_services_list
    assert_nil decision("brew services list")
  end

  def test_allows_listing_a_service_in_a_downstream_pipe
    # The service name sits past a pipe, in a command that does not start a daemon.
    assert_nil decision("brew services list | grep caddy")
  end

  def test_allows_a_dockerized_service
    assert_nil decision("docker run -d --name caddy caddy:2")
  end

  def test_allows_a_commit_message_that_mentions_the_daemons
    # A service name inside an argument or quoted prose is a mention, not a run.
    assert_nil decision(%q(git commit -m "guard denies brew install caddy and redis-server"))
  end

  def test_allows_grep_for_a_daemon_binary
    assert_nil decision("grep -rn redis-server scripts/")
  end

  def test_denies_after_a_shell_separator
    assert_equal "deny", decision("cd /tmp && brew services start nginx")
  end

  def test_denies_behind_sudo
    assert_equal "deny", decision("sudo redis-server /etc/redis.conf")
  end

  def test_ignores_non_bash_tools
    assert_nil guard("Write", "content" => "brew services start caddy")
  end

  def test_escape_hatch_bypasses
    ENV["PST_ALLOW_HOSTDAEMON"] = "1"
    assert_nil decision("brew services start caddy")
  end

  def test_deny_reason_names_the_offender_and_the_fix
    reason = guard("Bash", "command" => "brew install redis")&.dig("permissionDecisionReason")
    assert_includes reason, "brew install redis"
    assert_includes reason, "Docker container"
    assert_includes reason, "PST_ALLOW_HOSTDAEMON=1"
  end
end
