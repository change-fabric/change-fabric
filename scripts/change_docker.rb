#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'securerandom'
require 'net/http'
require 'json'
require 'uri'

# Ephemeral-container plumbing shared by every lane, holding the pst:docker
# doctrine in one place: every runner image is digest-pinned, every container is
# `--rm`, and nothing here stands up a host or long-lived daemon. A lane asks for
# a one-shot run or a scoped browser; this module owns the run, the network, and
# the teardown so a lane script never writes a raw `docker run`.
module ChangeDocker
  # Images reused verbatim from the REDACTED ad hoc runners this platform subsumes, so
  # a project migrating off those files gets byte-identical tooling. Bump these in
  # one place when a runner is upgraded.
  K6_IMAGE = 'grafana/k6:1.4.0@sha256:6a3ee54ac0e9ff5527923f6295257453dd88012f32f40dadf0eb1b638cbb21c7'
  ZAP_IMAGE = 'ghcr.io/zaproxy/zaproxy:stable@sha256:8d387b1a63e3425beef4846e39719f5af2a787753af2d8b6558c6257d7a577a2'
  BROWSERLESS_IMAGE = 'ghcr.io/browserless/chromium:v2.38.1@sha256:78afaada9f7b049783bfed624e6b5e9a2d3438fc04bb46801ed777e82ae1501f'

  module_function

  def available?
    _out, status = Open3.capture2e('docker', 'info')
    status.success?
  rescue StandardError
    false
  end

  # Runs a one-shot container to completion and returns [stdout+stderr, ok?].
  # `--rm` and the digest pin are enforced here so no lane can opt out. `name`
  # gets the `pst-change-` prefix every resource this platform creates carries,
  # so a container orphaned by a crashed run (`--rm` never ran) is identifiable
  # and reachable by `sweep`. Extra args are the image plus its command.
  def run(network:, image:, args:, env: {}, mounts: {}, name: nil)
    cmd = [ 'docker', 'run', '--rm' ]
    cmd += [ '--name', name ] if name
    cmd += [ '--network', network ] if network
    env.each { |key, value| cmd += [ '-e', "#{key}=#{value}" ] }
    mounts.each { |host, container| cmd += [ '-v', "#{host}:#{container}" ] }
    cmd << image
    cmd += Array(args)
    Open3.capture2e(*cmd)
  end

  # Yields a Network the caller uses for the whole run: the app's own network
  # when the config names one (the runners reach services by name on it), or a
  # throwaway network created here and removed on exit.
  def with_network(configured)
    if configured && !configured.empty?
      yield Network.new(name: configured, owned: false)
    else
      name = "pst-change-#{SecureRandom.hex(4)}"
      Open3.capture2e('docker', 'network', 'create', name)
      begin
        yield Network.new(name: name, owned: true)
      ensure
        Open3.capture2e('docker', 'network', 'rm', name)
      end
    end
  end

  # Starts one browserless Chromium container for the browser lanes (a11y and
  # viewport), scoped to the block. It joins the run network so it can reach the
  # target app by service name, and publishes 3000 on a loopback host port so the
  # host-side lane can POST scan scripts to its /function endpoint. Torn down on
  # exit whether the block succeeds or raises.
  def with_browserless(network:)
    token = SecureRandom.hex(8)
    name = "pst-change-bl-#{SecureRandom.hex(4)}"
    port = free_port
    start_browserless(name, network, port, token)
    begin
      session = Browserless.new(port: port, token: token)
      session.wait_ready or raise 'browserless did not become ready'
      yield session
    ensure
      Open3.capture2e('docker', 'rm', '-f', name)
    end
  end

  def start_browserless(name, network, port, token)
    cmd = [ 'docker', 'run', '-d', '--rm', '--name', name ]
    cmd += [ '--network', network ] if network
    cmd += [ '-p', "127.0.0.1:#{port}:3000", '-e', "TOKEN=#{token}", BROWSERLESS_IMAGE ]
    _out, status = Open3.capture2e(*cmd)
    raise 'failed to start browserless container' unless status.success?
  end

  # Prefix every ephemeral resource this platform creates carries, so a
  # container or network orphaned by a run that crashed before its own
  # teardown (a kill, an interrupted host) is identifiable and reclaimable.
  RESOURCE_PREFIX = 'pst-change-'

  # Force-removes any running container or existing network carrying the
  # `pst-change-` prefix. Meant to run standalone, between runs, so every match
  # is by definition not part of a run in progress. Returns the names removed.
  def sweep
    containers = matching_names('docker', 'ps', '-a', '--filter', "name=#{RESOURCE_PREFIX}", '--format', '{{.Names}}')
    containers.each { |name| Open3.capture2e('docker', 'rm', '-f', name) }
    networks = matching_names('docker', 'network', 'ls', '--filter', "name=#{RESOURCE_PREFIX}", '--format', '{{.Name}}')
    networks.each { |name| Open3.capture2e('docker', 'network', 'rm', name) }
    { containers: containers, networks: networks }
  end

  def matching_names(*cmd)
    out, status = Open3.capture2e(*cmd)
    return [] unless status.success?

    out.split("\n").map(&:strip).reject(&:empty?)
  end

  # An OS-assigned free loopback port. Bind to 0 to let the kernel pick, read it
  # back, and close before docker publishes it. A benign race, acceptable for a
  # local audit tool.
  def free_port
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    port
  end

  # A live network handle; `owned` tells the caller whether teardown already
  # happened in with_network (it did for an owned one).
  Network = Struct.new(:name, :owned, keyword_init: true)

  # A running browserless container reachable on the host loopback. It exposes
  # just enough to run a scan script in a fresh page: the /function endpoint takes
  # a JS module whose default export receives the puppeteer page, so a lane ships
  # its scan logic as a string and gets structured JSON back. This keeps the
  # browser automation in the browserless container, no host browser, no second
  # runner image to build.
  class Browserless
    require 'socket'

    READY_TRIES = 30
    READY_SLEEP = 1

    def initialize(port:, token:)
      @port = port
      @token = token
    end

    def wait_ready
      READY_TRIES.times do
        return true if version_ok?

        sleep READY_SLEEP
      end
      false
    end

    # Runs `code` (an ES module exporting `default async ({ page }) => {...}`)
    # against a fresh page and returns the payload the module resolves with.
    # Raises on a transport or browserless-side error so a lane surfaces it as a
    # failing finding rather than a silent empty result.
    #
    # A browserless /function module returns `{ data, type }`, and browserless
    # echoes that whole envelope back as the JSON body rather than unwrapping it,
    # so the module's real result is under "data". Unwrap it here so a lane
    # receives the value it returned (its array of route results), not the
    # envelope. Treating the envelope as the result was what made the a11y and
    # browserless lanes crash with "no implicit conversion of String into
    # Integer": Array({data,type}) yields [key, value] pairs, and indexing a pair
    # by a string key raised.
    def run_function(code)
      uri = URI("http://127.0.0.1:#{@port}/function?token=#{@token}")
      response = post(uri, code, 'application/javascript')
      raise "browserless /function failed: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

      unwrap(JSON.parse(response.body))
    end

    # browserless echoes the module's `{ data, type }` return value back as the
    # JSON body rather than unwrapping it, so the real result is under "data".
    def unwrap(parsed)
      parsed.is_a?(Hash) && parsed.key?('data') ? parsed['data'] : parsed
    end

    private

    def version_ok?
      uri = URI("http://127.0.0.1:#{@port}/json/version?token=#{@token}")
      Net::HTTP.get_response(uri).is_a?(Net::HTTPSuccess)
    rescue StandardError
      false
    end

    def post(uri, body, content_type)
      http = Net::HTTP.new(uri.host, uri.port)
      http.read_timeout = 120
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = content_type
      request.body = body
      http.request(request)
    end
  end
end
