#!/usr/bin/env ruby
# frozen_string_literal: true

require 'ipaddr'
require 'json'
require 'net/http'
require 'openssl'
require 'resolv'
require 'securerandom'
require 'socket'
require 'time'
require 'timeout'
require 'uri'

# Host-side reference reads for `reference_get` (suite_version 6): one figure
# fetched from an allowlisted JSON API, to be compared with the same figure on a
# page. It runs here, in Ruby, and not in the browser, because the checks that
# make it safe (an allowlist the suite cannot widen, the address a name
# resolves to, a response size cap) are the host's to enforce.
#
# Policy, all of it enforced before or while the bytes arrive:
#
# - The host must be on the allowlist the invocation gave (`--reference-host`).
#   A suite cannot allowlist itself.
# - GET only, `https` unless the host is listed as `http`, no redirect followed
#   (a 3xx is an error), 5 s to connect and to read, 1 MiB of body at most, and
#   the body must be JSON.
# - The name is resolved here and every address checked. A private, loopback or
#   link-local address (and its IPv6 forms) is refused unless the host is listed
#   `private`. The connection goes to the address that was checked, so a name
#   that resolves differently a moment later (DNS rebinding) is never trusted.
#
# Timing is "within N ms of the page read", not the same moment: both read times
# are kept, and a reference outside the skew is read once more before the case
# is declared blocked.
class ChangeReferenceRead
  Error = Class.new(StandardError)
  # A policy refusal: the read was never made.
  Refused = Class.new(Error)
  # The reference could not be paired with its page read in time.
  Skew = Class.new(Error)

  TIMEOUT_S = 5
  MAX_BYTES = 1_048_576
  DEFAULT_MAX_SKEW_MS = 2_000
  MAX_VALUE_CHARS = 500

  # One allowlisted host. `private` admits private and loopback addresses;
  # `http` admits plain http.
  Host = Struct.new(:name, :allow_private, :allow_http, keyword_init: true)

  # The fetched value, the time it was read (ms since the epoch and ISO-8601).
  Reading = Struct.new(:value, :read_at, :read_at_ms, keyword_init: true)

  PRIVATE_RANGES = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.168.0.0/16
    198.18.0.0/15 224.0.0.0/4 240.0.0.0/4 ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8
  ].map { |range| IPAddr.new(range) }.freeze

  # `--reference-host api.example.org` or `--reference-host api.example.org=private,http`.
  def self.parse_host(text)
    name, flags = text.to_s.split('=', 2)
    name = name.to_s.strip.downcase
    raise Error, "--reference-host needs a host name, got #{text.inspect}" if name.empty? || name.include?('/')

    given = flags.to_s.split(',').map(&:strip).reject(&:empty?)
    unknown = given - %w[private http]
    raise Error, "--reference-host #{name} has unknown flag(s): #{unknown.join(', ')} (known: private, http)" if unknown.any?

    Host.new(name: name, allow_private: given.include?('private'), allow_http: given.include?('http'))
  end

  def self.private_address?(address)
    ip = address.is_a?(IPAddr) ? address : IPAddr.new(address.to_s)
    ip = ip.native if ip.ipv6? && ip.ipv4_mapped?
    PRIVATE_RANGES.any? { |range| range.family == ip.family && range.include?(ip) }
  end

  # The value a JSONPath-style expression picks from a parsed body: `$`, `.key`,
  # `['key']` and `[index]`, nothing else. A path that picks nothing is an error.
  def self.pick(data, path)
    tokens = path.to_s.sub(/\A\$/, '').scan(/\.([A-Za-z0-9_-]+)|\['([^']*)'\]|\["([^"]*)"\]|\[(-?\d+)\]|(.)/m)
    tokens.reduce(data) do |node, (dotted, single, double, index, stray)|
      raise Error, "json_path #{path.inspect} has an unsupported segment #{stray.inspect}" if stray

      step = dotted || single || double
      if step
        raise Error, "json_path #{path.inspect} found no #{step}" unless node.is_a?(Hash) && node.key?(step)

        node[step]
      else
        raise Error, "json_path #{path.inspect} found no [#{index}]" unless node.is_a?(Array) && node[index.to_i]

        node[index.to_i]
      end
    end
  end

  # A scalar or a list of scalars, which is all a relation can compare.
  def self.shape(value, path)
    case value
    when Numeric then value
    when String then value.strip[0, MAX_VALUE_CHARS]
    when Array
      raise Error, "json_path #{path.inspect} picked a list of non-scalars" unless value.all? { |item| item.is_a?(String) || item.is_a?(Numeric) }

      value.map { |item| item.is_a?(String) ? item.strip[0, MAX_VALUE_CHARS] : item }
    else
      raise Error, "json_path #{path.inspect} picked #{value.class}, not a number, string or list"
    end
  end

  # `fetch` is the seam a test drives: it receives the URI, the checked address,
  # the timeout and the size cap and returns [status, content_type, body].
  # `resolver` returns the addresses a name resolves to.
  def initialize(hosts:, resolver: nil, fetch: nil, clock: nil, timeout_s: TIMEOUT_S, max_bytes: MAX_BYTES)
    @timeout_s = timeout_s
    @max_bytes = max_bytes
    @hosts = Array(hosts).to_h { |host| [ host.name, host ] }
    @resolver = resolver || ->(name) { Resolv.getaddresses(name) }
    @fetch = fetch || method(:http_get)
    @clock = clock || -> { (Time.now.to_f * 1000).round }
  end

  def allowed? = !@hosts.empty?

  # One checked GET and the figure it yields.
  def read(url:, json_path:)
    uri = parse(url)
    address = checked_address(uri, host_for(uri))
    status, type, body = @fetch.call(uri, address, @timeout_s, @max_bytes)
    reading(uri, status, type, body, json_path)
  end

  # A read paired with a page read made at `page_read_at_ms`. Outside the skew it
  # is read once more; still outside, the pairing is refused as Skew.
  def read_paired(url:, json_path:, page_read_at_ms:, max_skew_ms: DEFAULT_MAX_SKEW_MS)
    reading = read(url: url, json_path: json_path)
    return reading if (reading.read_at_ms - page_read_at_ms).abs <= max_skew_ms

    reading = read(url: url, json_path: json_path)
    return reading if (reading.read_at_ms - page_read_at_ms).abs <= max_skew_ms

    raise Skew, "reference skew: read at #{reading.read_at} is #{(reading.read_at_ms - page_read_at_ms).abs} ms from its page read, " \
                "over the #{max_skew_ms} ms allowed"
  end

  private

  def parse(url)
    uri = URI.parse(url.to_s)
    raise Refused, "reference url #{url.inspect} is not an absolute http(s) url" unless uri.is_a?(URI::HTTP) && uri.host

    uri
  rescue URI::InvalidURIError
    raise Refused, "reference url #{url.inspect} is not a valid url"
  end

  def host_for(uri)
    host = @hosts[uri.host.downcase]
    raise Refused, "reference host #{uri.host} is not allowlisted; pass --reference-host #{uri.host}" unless host
    raise Refused, "reference host #{uri.host} is https only; list it as #{uri.host}=http to allow http" if uri.scheme != 'https' && !host.allow_http

    host
  end

  # Every address the name resolves to is checked, and the first one is the one
  # the connection is made to.
  def checked_address(uri, host)
    addresses = literal?(uri.host) ? [ uri.host ] : Array(@resolver.call(uri.host))
    raise Refused, "reference host #{uri.host} did not resolve" if addresses.empty?

    blocked = addresses.find { |address| self.class.private_address?(address) }
    if blocked && !host.allow_private
      raise Refused, "reference host #{uri.host} resolves to #{blocked}, a private, loopback or link-local address; " \
                     "list it as #{uri.host}=private to allow it"
    end

    addresses.first
  end

  def literal?(host)
    IPAddr.new(host.delete_prefix('[').delete_suffix(']'))
    true
  rescue IPAddr::InvalidAddressError
    false
  end

  def reading(uri, status, type, body, path)
    raise Error, "reference #{uri.host} answered a redirect (#{status}); redirects are not followed" if status.to_i.between?(300, 399)
    raise Error, "reference #{uri.host} answered #{status}" unless status.to_i.between?(200, 299)
    raise Error, "reference #{uri.host} answered #{type.to_s.inspect}, not JSON" unless type.to_s.downcase.include?('json')

    now = @clock.call
    value = self.class.shape(self.class.pick(parse_json(body), path), path)
    Reading.new(value: value, read_at: Time.at(now / 1000.0).utc.iso8601(3), read_at_ms: now)
  end

  def parse_json(body)
    JSON.parse(body.to_s)
  rescue JSON::ParserError
    raise Error, 'reference answered a body that is not valid JSON'
  end

  # The real GET: connects to the checked address (Net::HTTP's ipaddr), keeps
  # the host name for TLS verification and the Host header, and stops reading at
  # the cap.
  def http_get(uri, address, timeout, cap)
    http = Net::HTTP.new(uri.host, uri.port)
    http.ipaddr = address
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = http.read_timeout = http.write_timeout = timeout
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
    request = Net::HTTP::Get.new(uri.request_uri, 'Accept' => 'application/json')
    http.start do
      http.request(request) do |response|
        body = +''
        response.read_body do |chunk|
          body << chunk
          raise Error, "reference answered more than #{cap} bytes" if body.bytesize > cap
        end
        return [ response.code.to_i, response['content-type'], body ]
      end
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
    raise Error, "reference did not answer within #{timeout} s"
  rescue SystemCallError, SocketError, OpenSSL::SSL::SSLError => e
    raise Error, "reference could not be reached: #{e.class}"
  end
end

# The host end of the reference bridge: a token-guarded socket on all
# interfaces (the browser container reaches the host through
# `host.docker.internal`, not loopback), so a reference read
# happens on the host (where the policy lives) while the case keeps one browser
# page. It answers only POSTs that carry this run's token, and only through a
# ChangeReferenceRead, so it cannot be used to fetch anything the allowlist
# does not already permit.
class ChangeReferenceBridge
  HOST_ALIAS = 'host.docker.internal'

  attr_reader :token, :port

  def initialize(reader, secrets: [])
    @reader = reader
    @secrets = Array(secrets).map(&:to_s).reject(&:empty?).sort_by { |secret| -secret.length }
    @token = SecureRandom.hex(16)
    @server = TCPServer.new('0.0.0.0', 0)
    @port = @server.addr[1]
    @thread = Thread.new { serve }
  end

  # What the compiled case module is handed: where to POST, and the token.
  def endpoint = { url: "http://#{HOST_ALIAS}:#{port}/", token: token }

  def close
    @server.close
    @thread.kill
  rescue IOError
    nil
  end

  # The JSON answer for one request body: { ok:, value:, readAt:, readAtMs: } or
  # { ok: false, error: }. Public so a test can drive it without a socket.
  def answer(raw)
    request = JSON.parse(raw)
    return { ok: false, error: 'bad token' } unless request['token'] == token

    reading = @reader.read_paired(url: request['url'], json_path: request['jsonPath'], page_read_at_ms: Integer(request['pageReadAt']),
                                  max_skew_ms: Integer(request['maxSkewMs'] || ChangeReferenceRead::DEFAULT_MAX_SKEW_MS))
    { ok: true, value: redact(reading.value), readAt: reading.read_at, readAtMs: reading.read_at_ms }
  rescue ChangeReferenceRead::Error, JSON::ParserError, ArgumentError, TypeError => e
    { ok: false, error: e.message }
  end

  private

  def redact(value)
    return value.map { |item| redact(item) } if value.is_a?(Array)
    return value unless value.is_a?(String)

    @secrets.empty? ? value : value.gsub(Regexp.union(@secrets), '[redacted]')
  end

  def serve
    loop { Thread.new(@server.accept) { |client| handle(client) } }
  rescue IOError, SystemCallError
    nil
  end

  def handle(client)
    length = 0
    method = nil
    body = nil
    # A client that stalls mid-request gets ten seconds, not a thread forever.
    Timeout.timeout(10) do
      method = client.gets.to_s.split.first
      while (line = client.gets) && line != "\r\n"
        length = line.split(':', 2).last.to_i if line.downcase.start_with?('content-length:')
      end
      body = method == 'POST' && length.positive? && length < 16_384 ? client.read(length) : nil
    end
    payload = JSON.generate(body ? answer(body) : { ok: false, error: 'not a bridge request' })
    client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
  rescue Timeout::Error, SystemCallError, IOError
    nil
  ensure
    client.close
  end
end
